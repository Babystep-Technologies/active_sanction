# frozen_string_literal: true

require "uri"
require "active_sanction/sources"

module ActiveSanction
  module Sources
    # What an adapter declares about the list it reads. Extended into
    # Sources::Base, so every adapter's class body reads as a description of
    # the list rather than as a constructor:
    #
    #   class UnConsolidated < ActiveSanction::Sources::Base
    #     key          :un_consolidated
    #     jurisdiction :un
    #     authority    "United Nations Security Council"
    #     format       :xml
    #     url          :main, "https://scsanctions.un.org/resources/xml/en/consolidated.xml"
    #   end
    #
    # Every declaration reads back with no argument -- `UnConsolidated.authority`
    # -- and that is not decoration. It is what the registry files the adapter
    # under, what the CLI's `sources` command prints, and what a match result
    # cites when an examiner asks which list a name was found on.
    #
    # ### Multiple URLs
    #
    # OFAC publishes the SDN list as three files that only mean something
    # joined -- the names, their aliases, their addresses -- so a source
    # declares as many as it has:
    #
    #   url :sdn, "https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV"
    #   url :alt, "https://sanctionslistservice.ofac.treas.gov/api/download/ALT.CSV"
    #   url :add, "https://sanctionslistservice.ofac.treas.gov/api/download/ADD.CSV"
    #
    # Each is fetched, validated and cached independently, because they change
    # independently: a sync where only ALT.CSV moved should download only
    # ALT.CSV.
    #
    # ### What is inherited, and what is not
    #
    # Declarations resolve up the superclass chain, so adapters sharing a
    # publisher can share a base holding the jurisdiction, the authority and
    # the format. `key` is the exception: it is looked up on the exact class
    # and nowhere else, since a subclass silently inheriting its parent's key
    # would try to register under a name already taken -- which is the one
    # mistake the registry cannot let through.
    module Definition
      UNSET = Object.new.freeze
      private_constant :UNSET

      # Keys are typed by people -- into an initializer, into a CLI argument --
      # stored in snapshots, and used as directory names by the payload cache.
      # Lowercase snake_case is the intersection of all of that.
      KEY_PATTERN = /\A[a-z][a-z0-9_]*\z/

      URL_SCHEMES = %w[http https].freeze

      # Shared with the registry, so a source registered without going through
      # Base is held to the same rule as one that declared its key here.
      def self.key!(value)
        key = value.to_s
        return key.to_sym if key.match?(KEY_PATTERN)

        raise DeclarationError,
              "#{value.inspect} is not a usable source key: it is typed into configuration and used as a " \
              "directory name, so it must be lowercase snake_case starting with a letter, like :ofac_sdn"
      end

      # The name this list answers to everywhere. Required, and never inherited.
      def key(value = UNSET)
        return own(:key) { "does not declare a key. Add `key :something` to its class body" } if unset?(value)

        declarations[:key] = Definition.key!(value)
      end

      # Who publishes the list, as a symbol: :us, :un, :ca, :eu. Not validated
      # against a country list -- an internal watchlist's jurisdiction is
      # whatever its owner says it is.
      def jurisdiction(value = UNSET)
        return required(:jurisdiction) { "does not declare a jurisdiction, e.g. `jurisdiction :un`" } if unset?(value)

        declarations[:jurisdiction] = symbol!(:jurisdiction, value)
      end

      # The body behind the list, spelled the way it spells itself. This is
      # what a compliance report prints beside a hit, so "United Nations
      # Security Council", not "UN".
      def authority(value = UNSET)
        return required(:authority) { "does not declare an authority, e.g. `authority \"...\"`" } if unset?(value)

        declarations[:authority] = string!(:authority, value)
      end

      # What the publisher serves: :csv, :xml, :json. Informational, and
      # deliberately not checked against a list of known formats -- the parser
      # toolkits (#14, #15) are chosen by the adapter, not dispatched from
      # here, and a source arriving as :fixed_width or :xlsx should be able to
      # say so without waiting for a release of this gem. Optional: a source
      # that builds entities from a database has no format to name.
      def format(value = UNSET)
        return declared(:format) if unset?(value)

        declarations[:format] = symbol!(:format, value)
      end

      # Declares a file with two arguments, reads one back with one, and with
      # none returns the primary -- the first declared, conventionally :main.
      def url(name = UNSET, address = UNSET)
        return primary_url if unset?(name)
        return read_url(name) if unset?(address)

        declared_urls[name.to_sym] = address!(name, address)
      end

      # Every declared file, in declaration order, inherited ones first.
      def urls
        lineage.reverse.inject({}) { |all, klass| all.merge(klass.declared_urls) }.freeze
      end

      # A source with several files needs each filed separately -- separate
      # ETags, separate cache entries -- or three files sharing one name would
      # evict each other out of a cache that retains N payloads per name. One
      # file is filed under the source key itself, which keeps the common case
      # legible on disk and in a validators.json somebody is reading to find
      # out why a sync downloaded more than it should have.
      def file_key(name)
        multi_url? ? :"#{key}-#{name}" : key
      end

      def multi_url? = urls.size > 1

      # Whether a declaration was made, without raising if it was not. What a
      # conformance spec (#16) asks before reporting which ones are missing.
      def declared?(name)
        name == :key ? !declarations[:key].nil? : !declared(name).nil?
      end

      # A summary of the declarations, for a CLI listing or a bug report. Reads
      # what is there rather than insisting: an adapter missing a declaration
      # is exactly what somebody printing this is trying to find out.
      def to_h
        { key: declarations[:key], jurisdiction: declared(:jurisdiction), authority: declared(:authority),
          format: declared(:format), urls: urls }
      end

      # The declarations made on this exact class, ignoring anything inherited.
      # Public because resolving a reader means walking the superclass chain
      # asking each one what it declared.
      def declarations = @declarations ||= {}

      def declared_urls = @declared_urls ||= {}

      private

      # This class and its ancestors that declare, most derived first.
      def lineage
        chain = []
        klass = self
        while klass.respond_to?(:declarations)
          chain << klass
          klass = klass.superclass
        end
        chain
      end

      def declared(name) = lineage.filter_map { |klass| klass.declarations[name] }.first

      def unset?(value) = value.equal?(UNSET)

      def own(name)
        declarations[name] || raise(DeclarationError, "#{self} #{yield}")
      end

      # Not named `inherited`: that is Class's own subclassing hook, and a
      # module extended into a class must not take it over.
      def required(name)
        declared(name) || raise(DeclarationError, "#{self} #{yield}")
      end

      def primary_url
        urls.values.first ||
          raise(DeclarationError,
                "#{self} declares no URL. Add `url :main, \"https://...\"`, or override #retrieve for a source " \
                "that is not fetched over HTTP")
      end

      def read_url(name)
        urls.fetch(name.to_sym) do
          raise DeclarationError, "#{self} declares no #{name.inspect} URL. Declared: #{urls.keys.join(", ")}"
        end
      end

      def symbol!(name, value)
        string = value.to_s.strip
        raise DeclarationError, "#{self} #{name} cannot be blank" if string.empty?

        string.downcase.to_sym
      end

      def string!(name, value)
        string = value.to_s.strip
        raise DeclarationError, "#{self} #{name} cannot be blank" if string.empty?

        -string
      end

      def address!(name, value)
        uri = URI.parse(value.to_s.strip)
        raise URI::InvalidURIError unless URL_SCHEMES.include?(uri.scheme) && uri.host

        -uri.to_s
      rescue URI::InvalidURIError
        raise DeclarationError,
              "#{self} #{name} URL #{value.inspect} is not an http(s) URL"
      end
    end
  end
end
