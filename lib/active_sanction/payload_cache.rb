# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "fileutils"
require "json"
require "securerandom"
require "active_sanction/configuration"
require "active_sanction/error"

module ActiveSanction
  # The raw bytes a publisher served, kept on disk so a parse can be re-run or
  # audited without re-fetching.
  #
  #   cache = ActiveSanction::PayloadCache.new
  #
  #   result = fetcher.fetch(url, key: :ofac_sdn)
  #   cache.write(:ofac_sdn, result.body, url: url, etag: result.etag,
  #               last_modified: result.last_modified) if result.changed?
  #
  #   cache.latest(:ofac_sdn).read   # the exact bytes, verified
  #
  # Anything list-sized streams instead, and the cache owns the temporary file
  # so the atomicity guarantee below covers a 126 MB download as well as a
  # string:
  #
  #   cache.write(:ofac_sdn, url: url) do |sink|
  #     response = client.download(url, to: sink)
  #     next false unless response.success?     # nothing is committed
  #
  #     { etag: response.etag, last_modified: response.last_modified,
  #       final_url: response.uri.to_s }
  #   end
  #
  # ### Why keep the raw payload at all
  #
  # Because re-fetching cannot recover it. Publishers overwrite their files in
  # place: OFAC's SDN.CSV lives at one URL forever and yesterday's contents are
  # simply gone. When a parser bug is found in November, the question is what
  # the list said in March -- the payload that produced a screening decision --
  # and only the bytes can answer it. The parsed Snapshot cannot: it is the
  # output of the code now under suspicion.
  #
  # ### What the layout guarantees
  #
  # Entries are content-addressed under `<cache_dir>/payloads/<source>/`, named
  # by their SHA-256, with a JSON sidecar beside each one:
  #
  #     ofac_sdn/sha256-9f86d081884c7d65....blob
  #     ofac_sdn/sha256-9f86d081884c7d65....json
  #
  # * **Nothing partial is ever readable.** Bytes are written to a `.part`
  #   sibling, hashed once complete, renamed into place, and only then given a
  #   sidecar. Listing reads sidecars, so a write killed at any point leaves at
  #   worst an unreferenced blob -- never an entry that looks whole.
  # * **The checksum is computed from what landed on disk**, not from what the
  #   caller believed it was writing, and it is verified again on every read.
  #   A payload that no longer hashes to its sidecar raises ChecksumMismatch
  #   rather than reaching a parser.
  # * **The same bytes fetched twice are one entry.** A re-download of an
  #   unchanged list overwrites its own sidecar, moving the fetch metadata
  #   forward; it does not consume a retention slot.
  #
  # ### What this is not
  #
  # A bounded cache, not an archive. Only the last `retain` payloads per source
  # survive (default 3 -- enough to diff a suspicious list against what came
  # before it), and the rest are pruned on the next write. An institution that
  # must keep every version it ever screened against should copy payloads out
  # to its own retention storage; this directory is under `~/.cache` and a user
  # is entitled to delete it. Storage of the parsed record is #23 and #24.
  #
  # @api private
  class PayloadCache
    extend T::Sig

    # The subdirectory under the configured cache directory. Kept separate from
    # validators.json so that deleting one does not disturb the other.
    DEFAULT_DIRNAME = T.let("payloads", String)

    # Source names become directory names, so they are checked rather than
    # sanitized: quietly rewriting `../../etc` into something safe would file a
    # payload somewhere the caller cannot find it, and the callers here are
    # source adapters (#12) whose names are symbols like `:ofac_sdn`.
    SOURCE_PATTERN = T.let(/\A[a-z0-9][a-z0-9_-]*\z/i, Regexp)

    # How long a file with no sidecar is left alone before pruning sweeps it.
    # A blob is renamed into place two syscalls before its sidecar is written,
    # and a `.part` file is live for as long as a download takes; an hour is
    # far past both and far short of leaving abandoned megabytes forever.
    ORPHAN_GRACE = T.let(3600, Integer)

    # A cached payload that cannot be trusted: the sidecar is unreadable, or
    # the bytes no longer match it. Never silently repaired -- an entry that
    # cannot prove what it holds is worse than no entry, because a caller would
    # act on it.
    #
    # @api public
    class CorruptEntry < IntegrityError; end

    # The bytes no longer hash to the checksum recorded beside them.
    #
    # @api public
    class ChecksumMismatch < CorruptEntry; end

    # Nothing is stored under that source and checksum, or its blob is gone.
    #
    # @api public
    class PayloadMissing < StorageError; end

    sig { returns(String) }
    attr_reader :dir

    # How many payloads are kept per source -- see the class comment: this is
    # a bounded cache, not an archive.
    sig { returns(Integer) }
    attr_reader :retain

    sig { params(dir: T.untyped, retain: T.untyped).void }
    def initialize(dir: nil, retain: ActiveSanction.config.retain_payloads)
      @dir = T.let(
        -::File.expand_path((dir || ::File.join(ActiveSanction.config.cache_dir, DEFAULT_DIRNAME)).to_s), String
      )
      @retain = T.let(Configuration.retain_payloads!(retain), Integer)
    end

    # Stores one payload and returns its Entry, pruning the source afterwards.
    #
    # Either hand it the bytes -- a String, or anything with #read -- or pass a
    # block and write into the sink it yields. The block's return value refines
    # the metadata: a Hash is merged over what was passed as keyword arguments,
    # which is how a streaming caller supplies validators it only learns after
    # the response has been read, and `false` abandons the write entirely so
    # that a failed download commits nothing.
    sig do
      params(source: T.untyped, payload: T.untyped, metadata: T.untyped, block: T.untyped)
        .returns(T.nilable(Entry))
    end
    def write(source, payload = nil, **metadata, &block)
      raise InvalidArgument, "pass a payload or a block, not both" if block && payload

      name = source!(source)
      metadata!(metadata)
      temporary = stage(name)
      begin
        outcome = ::File.open(temporary, "wb") { |sink| block ? block.call(sink) : copy(payload, sink) }
        return nil if outcome == false

        commit(name, temporary, metadata!(metadata.merge(outcome.is_a?(Hash) ? outcome : {})))
      ensure
        FileUtils.rm_f(temporary)
      end
    end

    # Every entry for a source, newest first, or every entry in the cache when
    # asked for nothing in particular.
    sig { params(source: T.untyped).returns(T::Array[Entry]) }
    def entries(source = nil)
      return sources.flat_map { |name| entries(name) }.sort_by { |entry| order(entry) } if source.nil?

      name = source!(source)
      Dir.glob(::File.join(directory_for(name), "*#{Entry::METADATA_EXTENSION}"))
         .map { |path| read_entry(name, path) }
         .sort_by { |entry| order(entry) }
    end

    # The payload a source was last fetched with, or nil. What a re-parse or an
    # audit starts from.
    sig { params(source: T.untyped).returns(T.nilable(Entry)) }
    def latest(source) = entries(source).first

    sig { params(source: T.untyped, checksum: T.untyped).returns(T.nilable(Entry)) }
    def find(source, checksum)
      name = source!(source)
      path = ::File.join(directory_for(name), "#{Entry.basename_for(Checksum.normalize!(checksum))}" \
                                              "#{Entry::METADATA_EXTENSION}")
      return nil unless ::File.exist?(path)

      read_entry(name, path)
    end

    # For a caller that means to read the payload: a missing entry is a failure
    # rather than a nil to check, the same way a corrupt one is.
    sig { params(source: T.untyped, checksum: T.untyped).returns(Entry) }
    def fetch(source, checksum)
      find(source, checksum) ||
        raise(PayloadMissing, "no #{Checksum.normalize!(checksum)} payload cached for #{source}")
    end

    # The bytes, verified. `cache.read(:ofac_sdn, checksum)` is the whole point
    # of the class: the exact payload a past decision was made against.
    sig { params(source: T.untyped, checksum: T.untyped).returns(String) }
    def read(source, checksum) = fetch(source, checksum).read

    sig { params(source: T.untyped, checksum: T.untyped).returns(T::Boolean) }
    def include?(source, checksum) = !find(source, checksum).nil?

    sig { returns(T::Array[Symbol]) }
    def sources
      return [] unless ::File.directory?(dir)

      Dir.children(dir).select { |name| name.match?(SOURCE_PATTERN) && ::File.directory?(::File.join(dir, name)) }
         .map(&:to_sym).sort
    end

    sig { params(source: T.untyped).returns(Integer) }
    def size(source = nil) = entries(source).size

    sig { params(source: T.untyped).returns(T::Boolean) }
    def empty?(source = nil) = entries(source).empty?

    # Removes one entry, bytes and sidecar together, and returns it -- or nil
    # when there was nothing there.
    sig { params(source: T.untyped, checksum: T.untyped).returns(T.nilable(Entry)) }
    def delete(source, checksum)
      entry = find(source, checksum)
      remove(entry) if entry
      entry
    end

    # Keeps the `retain` most recent payloads per source and discards the rest,
    # returning what was discarded. Runs after every write, so a caller only
    # calls it directly after lowering `retain` or to sweep what a crash left.
    sig { params(source: T.untyped).returns(T::Array[Entry]) }
    def prune(source = nil)
      (source.nil? ? sources : [source!(source)]).flat_map { |name| prune_source(name) }
    end

    # Drops a source's payloads, or the whole cache. Nothing here is a record
    # of what a list contained that is not also in storage (#24), so this is
    # recoverable by re-fetching -- with the exception the class comment names:
    # the *previous* contents of a list are gone once a publisher overwrites
    # its file, whether or not this directory still has them.
    sig { params(source: T.untyped).returns(T.self_type) }
    def clear(source = nil)
      if source.nil?
        FileUtils.rm_rf(dir)
      else
        FileUtils.rm_rf(directory_for(source!(source)))
      end
      self
    end

    sig { returns(String) }
    def inspect = "#<#{self.class} #{dir} retain=#{retain} #{sources.size} source(s)>"

    private

    # Newest first, with the checksum breaking a tie so that two entries
    # written in the same microsecond still prune in a defined order.
    sig { params(entry: Entry).returns([Rational, String]) }
    def order(entry) = [-entry.fetched_at.to_r, entry.checksum]

    sig { params(name: Symbol).returns(String) }
    def stage(name)
      directory = directory_for(name)
      FileUtils.mkdir_p(directory)
      ::File.join(directory, "#{Process.pid}-#{SecureRandom.hex(8)}.part")
    end

    # The blob goes into place before its sidecar is written, never after: a
    # crash between the two leaves an unreferenced file that pruning sweeps,
    # where the other order would leave a sidecar advertising bytes that are
    # not there.
    sig { params(name: Symbol, temporary: String, metadata: T::Hash[Symbol, T.untyped]).returns(Entry) }
    def commit(name, temporary, metadata)
      # `new(**hash)` past required keyword parameters is one of the few things
      # Sorbet cannot check statically. #metadata! has already refused every
      # key Entry does not declare.
      entry = T.let(
        T.unsafe(Entry).new(dir: directory_for(name), source: name, byte_size: ::File.size(temporary),
                            checksum: Checksum.of_file(temporary), **metadata),
        Entry
      )
      ::File.rename(temporary, entry.path)
      write_metadata(entry)
      prune_source(name)
      entry
    end

    sig { params(entry: Entry).void }
    def write_metadata(entry)
      temporary = T.let("#{entry.metadata_path}.#{Process.pid}.part", T.nilable(String))
      ::File.write(T.must(temporary), "#{JSON.pretty_generate(entry.to_h)}\n")
      ::File.rename(T.must(temporary), entry.metadata_path)
    ensure
      FileUtils.rm_f(temporary) if temporary
    end

    sig { params(payload: T.untyped, sink: T.untyped).returns(T.untyped) }
    def copy(payload, sink)
      raise InvalidArgument, "a payload or a block is required" if payload.nil?

      payload.respond_to?(:read) ? IO.copy_stream(payload, sink) : sink.write(payload.to_s)
    end

    sig { params(name: Symbol).returns(T::Array[Entry]) }
    def prune_source(name)
      discarded = entries(name).drop(retain)
      discarded.each { |entry| remove(entry) }
      sweep(name)
      discarded
    end

    sig { params(entry: Entry).void }
    def remove(entry)
      FileUtils.rm_f([entry.path, entry.metadata_path])
    end

    # What a crashed write leaves behind: a blob whose sidecar never landed, a
    # sidecar whose blob is gone, a `.part` file from a download that died.
    sig { params(name: Symbol).void }
    def sweep(name)
      cutoff = Time.now - ORPHAN_GRACE
      Dir.glob(::File.join(directory_for(name), "*.{blob,json,part}")).each do |path|
        FileUtils.rm_f(path) if orphan?(path) && ::File.mtime(path) < cutoff
      end
    end

    sig { params(path: String).returns(T::Boolean) }
    def orphan?(path)
      return true if ::File.extname(path) == ".part"

      stem = path.chomp(::File.extname(path))
      !(::File.exist?("#{stem}#{Entry::BLOB_EXTENSION}") && ::File.exist?("#{stem}#{Entry::METADATA_EXTENSION}"))
    end

    sig { params(name: Symbol, path: String).returns(Entry) }
    def read_entry(name, path)
      Entry.from_h(JSON.parse(::File.read(path)), dir: directory_for(name))
    rescue JSON::ParserError, ArgumentError, TypeError => e
      raise CorruptEntry, "#{path} does not describe a cached payload (#{e.message}). " \
                          "Delete it to drop the entry; the source re-fetches in full."
    end

    sig { params(name: T.untyped).returns(String) }
    def directory_for(name) = ::File.join(dir, name.to_s)

    sig { params(source: T.untyped).returns(Symbol) }
    def source!(source)
      name = source.to_s.strip
      unless name.match?(SOURCE_PATTERN)
        raise InvalidArgument, "#{source.inspect} is not a usable source name: it becomes a directory, " \
                               "so it must start alphanumeric and hold only letters, digits, _ and -"
      end

      name.to_sym
    end

    # Checked before a byte is written, so a caller does not stream 126 MB to
    # learn it misspelled a keyword.
    sig { params(metadata: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
    def metadata!(metadata)
      unknown = metadata.keys - Entry::PROVENANCE
      raise InvalidArgument, "unknown payload metadata: #{unknown.join(", ")}" if unknown.any?
      raise InvalidArgument, "url: is required -- a cached payload records where it came from" if
        metadata[:url].to_s.strip.empty?

      metadata
    end
  end
end

require "active_sanction/payload_cache/checksum"
require "active_sanction/payload_cache/entry"
