# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "time"
require "active_sanction/error"
require "active_sanction/entity"
require "active_sanction/snapshot"
require "active_sanction/fetcher"
require "active_sanction/parsers"
require "active_sanction/payload_cache"
require "active_sanction/sources"
require "active_sanction/sources/definition"
require "active_sanction/sources/remarks"

module ActiveSanction
  module Sources
    # The contract every sanctions list adapter implements: declare what the
    # list is and where it lives, then turn its bytes into Entities.
    #
    #   class UnConsolidated < ActiveSanction::Sources::Base
    #     key          :un_consolidated
    #     jurisdiction :un
    #     authority    "United Nations Security Council"
    #     format       :xml
    #     url          :main, "https://scsanctions.un.org/resources/xml/en/consolidated.xml"
    #
    #     def parse(raw)
    #       ...   # => [Entity, ...]
    #     end
    #   end
    #
    #   ActiveSanction::Sources.register(UnConsolidated)
    #
    # #parse is the whole of what an adapter must write. Everything above it is
    # declaration (Definition), and everything below it -- conditional GET,
    # payload caching, checksumming the result into a Snapshot -- is here, the
    # same for every list, so that adding a jurisdiction is a parsing problem
    # and not a plumbing one.
    #
    #   snapshot = ActiveSanction::Sources[:un_consolidated].new.sync
    #   snapshot                      # => Snapshot, or nil if nothing changed
    #
    # ### What #parse is handed
    #
    # A source declaring one URL gets the bytes. One declaring several gets a
    # Hash keyed by the names it declared, because OFAC's three files only mean
    # anything joined:
    #
    #   def parse(raw)
    #     join(raw[:sdn], raw[:alt], raw[:add])
    #   end
    #
    # Which of the two it is follows from the declaration, not from what a
    # caller happened to pass, so an adapter's signature does not change under
    # it when a fixture is handed to #snapshot directly.
    #
    # The bytes arrive as a String. A list too large to hold in memory wants
    # #15's streaming parse rather than this path; the cached Entry, which
    # knows how to hand out a verified file handle, is where that will start.
    #
    # ### What sync does not do
    #
    # It does not store the snapshot, and it does not rescue anything. One
    # source's failure being isolated from the others, and the previous good
    # snapshot being kept when a list fails, are decisions about a *run* rather
    # than about a list -- they belong to sync orchestration (#34), which needs
    # an exception here to notice.
    class Base
      extend T::Sig
      extend Definition

      sig { returns(Fetcher) }
      attr_reader :fetcher

      # nil turns payload caching off -- see #initialize.
      sig { returns(T.nilable(PayloadCache)) }
      attr_reader :cache

      # Anything Logger-shaped, or nil, as Configuration#logger has it.
      sig { returns(T.untyped) }
      attr_reader :logger

      # `cache: nil` turns off payload caching, which costs one thing worth
      # knowing: a multi-file source can no longer answer a sync where some of
      # its files changed and others came back 304, so the unchanged ones are
      # downloaded again in full.
      sig do
        params(fetcher: Fetcher, cache: T.nilable(PayloadCache), logger: T.untyped).void
      end
      def initialize(fetcher: Fetcher.new, cache: PayloadCache.new, logger: ActiveSanction.config.logger)
        @fetcher = T.let(fetcher, Fetcher)
        @cache = T.let(cache, T.nilable(PayloadCache))
        @logger = T.let(logger, T.untyped)
        @results = T.let({}, T::Hash[Symbol, Fetcher::Result])
      end

      sig { returns(Symbol) }
      def key = self.class.key

      sig { returns(Symbol) }
      def jurisdiction = self.class.jurisdiction

      sig { returns(String) }
      def authority = self.class.authority

      sig { returns(T.nilable(Symbol)) }
      def format = self.class.format

      sig { returns(T::Hash[Symbol, String]) }
      def urls = self.class.urls

      sig { params(name: T.untyped).returns(String) }
      def url(name = nil) = name.nil? ? self.class.url : self.class.url(name)

      sig { params(name: T.untyped).returns(Symbol) }
      def file_key(name) = self.class.file_key(name)

      # The lower bounds this list is held to when there is nothing to compare
      # it against. See Definition#floor, and Doctor, which is the only thing
      # that reads them.
      sig { returns(T::Hash[Symbol, Numeric]) }
      def floors = self.class.floors

      # A remark with everything this adapter appended stripped back off --
      # the publisher's own words and nothing else. Inherited, so it reads the
      # same for every source and a caller does not have to know which list a
      # remark came from before it can strip one. See Sources::Remarks.
      sig { params(remarks: T.untyped).returns(T.nilable(String)) }
      def self.published_remarks(remarks) = Remarks.published(remarks)

      # The one method an adapter must write: bytes in, canonical records out.
      sig { params(_raw: T.untyped).returns(T::Array[Entity]) }
      def parse(_raw)
        raise UnsupportedError,
              "#{self.class} must implement #parse(raw) and return an Array of ActiveSanction::Entity"
      end

      # Fetches, parses, and checksums -- or returns nil when the publisher
      # says nothing has changed, which is the outcome to expect on most runs
      # and the reason conditional GET exists.
      sig { params(force: T::Boolean).returns(T.nilable(Snapshot)) }
      def sync(force: false)
        payloads = retrieve(force: force)
        return nil if payloads.nil?

        snapshot(payloads)
      end

      # Parses payloads already in hand into a Snapshot. What #sync calls, and
      # what an adapter's own spec calls with a fixture and no network:
      #
      #   source.snapshot(main: File.read("spec/fixtures/un_consolidated.xml"))
      #
      # The files may be named as keywords, as above, or passed as one Hash --
      # or, for a source that declares a single file, as the bytes themselves.
      sig { params(payloads: T.untyped, files: T.untyped).returns(Snapshot) }
      def snapshot(payloads = nil, **files)
        Snapshot.new(source: key, entities: parse(parse_argument(payloads || files)),
                     fetched_at: Time.now.utc, source_version: source_version)
      rescue ActiveSanction::Error => e
        raise e.in_source(declared_key)
      end

      # Every declared file, conditionally: a Hash of name => bytes, or nil
      # when the publisher answered 304 for all of them.
      #
      # A file that came back unchanged is served from the payload cache, so a
      # sync in which one of OFAC's three files moved downloads one file and
      # not three. If the cache has nothing to serve -- a first run against a
      # store that already has validators, a cache directory a user deleted --
      # that file alone is re-fetched in full.
      sig { params(force: T::Boolean).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
      def retrieve(force: false)
        raise DeclarationError, "#{self.class} declares no URL to retrieve" if urls.empty?

        @results = urls.to_h { |name, address| [name, fetch_file(name, address, force)] }
        return nil if @results.each_value.all?(&:unchanged?)

        @results.keys.to_h { |name| [name, payload(name)] }
      rescue ActiveSanction::Error => e
        raise e.in_source(declared_key)
      end

      # The positional-column assertions this source's raw files satisfy, or
      # do not. Takes what #retrieve returned, or what #snapshot would be given,
      # and answers with one Parsers::ColumnShape::Tally per declared column.
      #
      # Empty here, because most publishers ship a file that names its own
      # fields and a named field cannot be quietly swapped with the one beside
      # it. An adapter over a headerless file overrides #column_shapes -- see
      # Sources::Ofac, and Parsers::ColumnShape for why a declared width is not
      # enough on its own.
      sig { params(payloads: T.untyped, files: T.untyped).returns(T::Array[Parsers::ColumnShape::Tally]) }
      def column_tallies(payloads = nil, **files)
        column_shapes(parse_argument(payloads || files))
      end

      # The hook #column_tallies dispatches to, handed exactly what #parse is
      # handed. Overridden by an adapter over a positional file.
      sig { params(_raw: T.untyped).returns(T::Array[Parsers::ColumnShape::Tally]) }
      def column_shapes(_raw) = []

      # Whether any of this source's files is due a fetch, answered locally and
      # without a request. See Fetcher#stale? for what that does and does not
      # claim.
      sig { returns(T::Boolean) }
      def stale? = urls.any? { |name, address| fetcher.stale?(file_key(name), url: address) }

      sig { returns(T::Boolean) }
      def fresh? = !stale?

      # The publisher's own marker for the version just fetched. Last-Modified
      # is the only one every launch source serves; an adapter whose document
      # carries a generation date inside it should override this and say so,
      # because that is the string an examiner will recognise.
      sig { returns(T.nilable(String)) }
      def source_version = @results.values.first&.last_modified

      sig { returns(String) }
      def inspect
        name = self.class.declared?(:key) ? key : "(no key)"
        "#<#{self.class} #{name} #{urls.size} url(s)>"
      end

      # What #parse is handed, worked out from what #retrieve returned: the
      # bytes for a source declaring one file, the Hash keyed by declaration
      # name for one declaring several. Public because a caller that has
      # already fetched -- Doctor, which parses and then reads the same
      # payloads a second time -- has to be able to produce the same argument
      # without knowing how many files this source declares.
      sig { params(payloads: T.untyped).returns(T.untyped) }
      def parse_argument(payloads)
        return payloads if payloads.is_a?(String)

        self.class.multi_url? ? payloads.to_h : payloads.to_h.values.first
      end

      private

      # This adapter's key, or nil for one that never declared it. What
      # #source_id is stamped from -- see Error#in_source. The layers under
      # here are deliberately ignorant of which list they are working on: the
      # HTTP client sees a URL, the XML reader sees a payload, and neither can
      # name the list in the error it raises. This is the one place that can,
      # and it is the boundary a caller rescues at.
      sig { returns(T.nilable(Symbol)) }
      def declared_key = self.class.declared?(:key) ? key : nil

      sig { params(name: Symbol, address: String, force: T::Boolean).returns(Fetcher::Result) }
      def fetch_file(name, address, force)
        fetcher.fetch(address, key: file_key(name), force: force).success!
      end

      sig { params(name: Symbol).returns(T.untyped) }
      def payload(name)
        result = @results.fetch(name)
        return store(name, result) if result.changed?

        cached(name) || store(name, refetch(name))
      end

      sig { params(name: Symbol, result: Fetcher::Result).returns(T.nilable(String)) }
      def store(name, result)
        cache&.write(file_key(name), result.body, url: url(name), final_url: result.uri.to_s,
                                                  etag: result.etag, last_modified: result.last_modified)
        result.body
      end

      # A cached payload that no longer hashes to its sidecar is not used and
      # not repaired -- but it is also not fatal here, because the bytes it
      # failed to prove are a download away. The corrupt entry stays on disk
      # for whoever investigates it.
      sig { params(name: Symbol).returns(T.nilable(String)) }
      def cached(name)
        cache&.latest(file_key(name))&.read
      rescue PayloadCache::CorruptEntry => e
        logger&.info("[active_sanction] #{key} #{name} cached payload unusable (#{e.class}); fetching in full")
        nil
      end

      sig { params(name: Symbol).returns(Fetcher::Result) }
      def refetch(name)
        logger&.info("[active_sanction] #{key} #{name} unchanged but not cached; fetching in full")
        result = fetcher.fetch(url(name), key: file_key(name), force: true).success!
        return result if result.changed?

        raise MissingPayload,
              "#{key} #{name} answered #{result.status} to an unconditional request, so the bytes " \
              "for #{url(name)} could not be obtained"
      end
    end
  end
end
