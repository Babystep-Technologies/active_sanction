# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "fileutils"
require "json"
require "securerandom"
require "zlib"
require "active_sanction/configuration"
require "active_sanction/snapshot"
require "active_sanction/sources"
require "active_sanction/storage"
require "active_sanction/storage/base"
require "active_sanction/storage/meta"

module ActiveSanction
  module Storage
    # Snapshots as gzipped JSON in a directory. The default adapter, and the
    # reason this gem screens a name without an application having provisioned
    # anything first.
    #
    #   store = ActiveSanction::Storage::FileSystem.new           # ~/.active_sanction
    #   store = ActiveSanction::Storage::FileSystem.new(root: "/srv/lists")
    #
    #   store.write_snapshot(ActiveSanction::Sources[:ofac_sdn].new.sync)
    #   store.snapshot_meta(:ofac_sdn).age   # without opening the list
    #   store.read_snapshot(:ofac_sdn)       # => Snapshot, checksum verified
    #
    # Nothing here is required. `zlib` and `json` are stdlib, so the cost of
    # persisting 19,015 OFAC records is a directory -- which is what makes this
    # usable from a cron job, a CLI (#36), a CI run, and an air-gapped host
    # that only ever gets a copied directory. Storage::ActiveRecord (#25) is
    # for an installation that already has a database and wants to query the
    # lists; it is not a prerequisite for using this library.
    #
    # ### The layout is private
    #
    # Under #62 the contents of `root` are `@api private`. What is on disk is
    # optimized for reading and rewriting locally, and it is expected to change
    # -- the portable, cross-machine, signature-verified representation is the
    # bundle format (#57), which has its own stability contract and is specified
    # in docs/bundle_format.md. An application that reads these files itself
    # makes every future storage optimization a breaking change for it.
    #
    # As it stands:
    #
    #     root/ofac_sdn/meta.json
    #     root/ofac_sdn/snapshot-sha256-9f86d081884c7d65....json.gz
    #
    # ### Why the snapshot file is named after its checksum
    #
    # Because "a sync interrupted mid-write leaves the previous good snapshot
    # intact" cannot be honoured by two files at fixed names. Replacing a list
    # means replacing both the list and the sidecar describing it, and whatever
    # order those two renames happen in, a process killed between them leaves a
    # snapshot and a meta that do not describe each other -- the new list under
    # the old checksum, or a sidecar advertising records that are not there.
    # Either way the previous list is gone and the source is unreadable until
    # the next successful sync.
    #
    # Naming the list file after the content it holds removes the conflict. A
    # new list is written to a name nothing else occupies, so it cannot destroy
    # the list already there, and `meta.json` -- one small file, replaced by one
    # atomic rename -- is the single point at which the new generation becomes
    # the live one. Interrupt anywhere before that rename and the store is
    # exactly as it was, plus a stray file the next write sweeps. Interrupt
    # after it and the new list is live and complete. There is no third state.
    #
    # This is the pattern PayloadCache uses for raw payloads, for the same
    # reason and with the same tradeoff: a brief second copy on disk.
    #
    # ### What it refuses to do
    #
    # Return anything it cannot prove. `Snapshot.from_h` re-derives the
    # checksum from the records that came back and construction fails if it
    # does not match what was stored, so a truncated file, an edited file and a
    # half-written file all raise CorruptSnapshot instead of screening against
    # a list that is missing records. A schema version this code does not know
    # raises UnsupportedSchema *before* the list is parsed, since a snapshot
    # from a newer gem will usually deserialize into a valid-looking, quietly
    # wrong record set.
    #
    # ### Concurrency
    #
    # Many readers and one writer, across processes, which is the arrangement
    # it exists for: a scheduled sync replacing a list while web workers screen
    # against it. Committing is a rename, so a reader sees the whole previous
    # generation or the whole new one; a reader that had already read the old
    # `meta.json` when the new one landed re-reads it if the file it was sent
    # to has since been swept.
    #
    # Two processes writing the *same* source at once is not supported and is
    # not made safe by anything here -- run one sync.
    class FileSystem < Base
      extend T::Sig

      # The sidecar, and the commit point. Its presence is what makes a
      # directory a stored source, and replacing it is what publishes a write.
      META_FILENAME = T.let("meta.json", String)

      SNAPSHOT_PREFIX = T.let("snapshot-", String)
      SNAPSHOT_EXTENSION = T.let(".json.gz", String)

      # Snapshot versions this code can read. Anything above the version it
      # writes was produced by a newer gem; anything at or below it round-trips
      # through Snapshot.from_h, which folds the version into the checksum it
      # verifies, so a list cannot be read under a schema it was not written
      # under without the mismatch being caught.
      READABLE_SCHEMA_VERSIONS = T.let(1..Snapshot::SCHEMA_VERSION, T::Range[Integer])

      # Zlib's default, not its best. A parsed OFAC list is tens of megabytes
      # of highly repetitive JSON that gzip already reduces by better than 90%;
      # the last few points cost several seconds of a sync and buy a rounding
      # error of disk.
      COMPRESSION_LEVEL = T.let(Zlib::DEFAULT_COMPRESSION, Integer)

      # A checksum becomes a filename, so it is matched rather than sanitized:
      # this is the one place a value read back off disk is joined to a path,
      # and `sha256:<64 hex>` is the only shape allowed through.
      CHECKSUM_PATTERN = T.let(/\A#{Snapshot::ALGORITHM}:(\h{64})\z/, Regexp)

      # A directory is only a source if it is named like one. Held to the rule
      # source keys are held to everywhere, so an unrelated directory a user
      # left under `root` is not reported as a sanctions list.
      SOURCE_PATTERN = T.let(Sources::Definition::KEY_PATTERN, Regexp)

      # How long a `.part` file from a killed write is left alone before the
      # next write sweeps it. Well past any real write and short of leaving
      # abandoned megabytes on disk forever.
      ORPHAN_GRACE = T.let(3600, Integer)

      # The directory every source is filed under. Its layout is private --
      # see the class comment.
      sig { returns(String) }
      attr_reader :root

      sig { params(root: T.untyped).void }
      def initialize(root: nil)
        @root = T.let(-::File.expand_path((root || ActiveSanction.config.storage_dir).to_s), String)
        super()
      end

      # Writes the list, then publishes it by replacing `meta.json`. The
      # previous generation stays readable until that rename lands and is swept
      # immediately after it.
      sig { override.params(snapshot: T.untyped).returns(Snapshot) }
      def write_snapshot(snapshot)
        stored = snapshot!(snapshot)
        directory = directory_for(source_key!(stored.source))
        FileUtils.mkdir_p(directory)

        path = snapshot_path(directory, stored.checksum)
        write_atomically(path) { |file| compress(JSON.generate(stored.to_h), file) }
        commit(directory, Meta.from_snapshot(stored))
        prune(directory, path)
        stored
      end

      sig { override.params(source: T.untyped).returns(T.nilable(Snapshot)) }
      def read_snapshot(source)
        key = source_key!(source)
        directory = directory_for(key)
        meta = read_meta(directory)
        meta, json = read_list(directory, meta) if meta
        return nil if json.nil? || meta.nil?

        build(key, meta, json, snapshot_path(directory, meta.checksum))
      end

      # Off the sidecar, without opening the list. What makes `sources` in the
      # CLI (#36) and the per-source summary in sync (#34) cheap: printing how
      # old six lists are reads six small JSON files rather than inflating and
      # deserializing tens of megabytes.
      sig { override.params(source: T.untyped).returns(T.nilable(Meta)) }
      def snapshot_meta(source) = read_meta(directory_for(source_key!(source)))

      sig { override.params(source: T.untyped).returns(T::Boolean) }
      def delete_snapshot(source)
        directory = directory_for(source_key!(source))
        stored = ::File.file?(::File.join(directory, META_FILENAME))
        FileUtils.rm_rf(directory)
        stored
      end

      # Every directory under `root` holding a committed sidecar. Deliberately
      # does not parse them: this is what `stored?`, `empty?` and `clear` are
      # built on, and one unreadable list must not make the store impossible to
      # inspect or to repair.
      sig { override.returns(T::Array[Symbol]) }
      def sources
        return [] unless ::File.directory?(root)

        Dir.children(root)
           .select { |name| name.match?(SOURCE_PATTERN) && ::File.file?(::File.join(root, name, META_FILENAME)) }
           .map(&:to_sym).sort
      end

      sig { override.returns(String) }
      def inspect = "#<#{self.class} #{root} #{list}>"

      private

      sig { params(key: T.untyped).returns(String) }
      def directory_for(key) = ::File.join(root, key.to_s)

      sig { params(directory: String, checksum: T.untyped).returns(String) }
      def snapshot_path(directory, checksum)
        ::File.join(directory, "#{SNAPSHOT_PREFIX}#{checksum_slug!(checksum)}#{SNAPSHOT_EXTENSION}")
      end

      sig { params(checksum: T.untyped).returns(String) }
      def checksum_slug!(checksum)
        match = CHECKSUM_PATTERN.match(checksum.to_s)
        raise CorruptSnapshot, "#{checksum.inspect} is not a #{Snapshot::ALGORITHM} checksum" if match.nil?

        "#{Snapshot::ALGORITHM}-#{T.must(match[1]).downcase}"
      end

      # Bytes go to a `.part` sibling, are flushed to the platter, and only
      # then take the real name. A rename within a directory is atomic, so no
      # reader ever opens a partially written file -- it sees the previous one
      # or the new one.
      sig { params(path: String, block: T.proc.params(file: ::File).void).void }
      def write_atomically(path, &block)
        temporary = T.let("#{path}.#{Process.pid}-#{SecureRandom.hex(8)}.part", T.nilable(String))
        ::File.open(T.must(temporary), "wb") do |file|
          block.call(file)
          file.flush
          file.fsync
        end
        ::File.rename(T.must(temporary), path)
      ensure
        FileUtils.rm_f(temporary) if temporary
      end

      # The rename that publishes a write. Everything the new generation needs
      # is already on disk and fsynced by the time this runs, so the list a
      # reader gets is whole whichever side of it they arrive on.
      sig { params(directory: String, meta: Meta).void }
      def commit(directory, meta)
        write_atomically(::File.join(directory, META_FILENAME)) do |file|
          file.write("#{JSON.pretty_generate(meta.to_h)}\n")
        end
      end

      sig { params(json: String, sink: ::File).void }
      def compress(json, sink)
        gzip = Zlib::GzipWriter.new(sink, COMPRESSION_LEVEL)
        begin
          gzip.write(json)
        ensure
          gzip.finish
        end
      end

      # The list `meta` names and the meta it actually came from, or nil when
      # the source is gone. A missing file is not corruption on its own:
      # another process can have committed a new generation and swept this one
      # between our reading the sidecar and our opening what it pointed at, so
      # the sidecar is read again before the absence is believed -- and the
      # generation that read finds is the one the caller is answered with.
      sig { params(directory: String, meta: Meta).returns(T.nilable([Meta, String])) }
      def read_list(directory, meta)
        json = inflate(snapshot_path(directory, meta.checksum))
        return [meta, json] unless json.nil?

        current = read_meta(directory)
        return nil if current.nil?

        path = snapshot_path(directory, current.checksum)
        [current,
         inflate(path) || raise(CorruptSnapshot, corrupt(path, "the sidecar names a list that is not there"))]
      end

      sig { params(path: String).returns(T.nilable(String)) }
      def inflate(path)
        Zlib.gunzip(::File.binread(path))
      rescue Errno::ENOENT
        nil
      rescue Zlib::Error => e
        raise CorruptSnapshot, corrupt(path, e.message)
      end

      sig { params(directory: String).returns(T.nilable(Meta)) }
      def read_meta(directory)
        path = T.let(::File.join(directory, META_FILENAME), T.nilable(String))
        hash = JSON.parse(::File.read(T.must(path)))
        raise CorruptSnapshot, corrupt(T.must(path), "it does not hold a JSON object") unless hash.is_a?(Hash)

        schema_version!(hash["schema_version"], T.must(path))
        Meta.from_h(hash)
      rescue Errno::ENOENT
        nil
      rescue JSON::ParserError, ArgumentError, TypeError => e
        # `T.must` because Sorbet reads a `rescue` as reachable before the
        # first assignment in the body; `path` is that assignment.
        raise CorruptSnapshot, corrupt(T.must(path), e.message)
      end

      # Checked against the sidecar before a byte of the list is inflated, so
      # an unreadable schema costs a small read rather than tens of megabytes,
      # and so it is caught before Snapshot.from_h has a chance to build
      # plausible records out of a shape this version does not understand.
      sig { params(value: T.untyped, path: String).returns(Integer) }
      def schema_version!(value, path)
        # `exception: false` answers nil for anything unparseable, which the
        # stdlib RBI does not say -- hence the nilable annotation.
        version = T.let(Integer(value, exception: false), T.nilable(Integer))
        return version if !version.nil? && READABLE_SCHEMA_VERSIONS.cover?(version)

        raise UnsupportedSchema,
              "#{path} was written under snapshot schema_version #{value.inspect}; active_sanction #{VERSION} " \
              "reads #{READABLE_SCHEMA_VERSIONS.first}-#{READABLE_SCHEMA_VERSIONS.last}. Upgrade the gem, or " \
              "delete the directory and re-sync the source."
      end

      # Snapshot.from_h recomputes the checksum over the records that came back
      # and refuses to build if it does not match the one stored with them,
      # which is what catches a truncated or edited list. The two checks after
      # it catch the pair coming apart: a sidecar describing a different
      # generation than the file it points at, or a list filed under the wrong
      # source.
      sig { params(key: Symbol, meta: Meta, json: String, path: String).returns(Snapshot) }
      def build(key, meta, json, path)
        snapshot = Snapshot.from_h(JSON.parse(json))
        wrong_generation = "it holds #{snapshot.checksum}, not the #{meta.checksum} recorded in #{META_FILENAME}"
        raise CorruptSnapshot, corrupt(path, wrong_generation) if snapshot.checksum != meta.checksum
        raise CorruptSnapshot, corrupt(path, "it is #{snapshot.source}, filed under #{key}") if snapshot.source != key

        snapshot
      rescue JSON::ParserError, ArgumentError, TypeError, Snapshot::ChecksumMismatch => e
        raise CorruptSnapshot, corrupt(path, e.message)
      end

      sig { params(path: String, detail: String).returns(String) }
      def corrupt(path, detail)
        "#{path} cannot be trusted to be the list it says it is (#{detail}). Nothing partial is returned from " \
          "storage -- delete #{::File.dirname(path)} and re-sync the source to replace it."
      end

      # Everything the committed generation does not need: the list files of
      # generations it replaced, and `.part` files old enough to be from a
      # write that died rather than one in flight.
      sig { params(directory: String, keep: String).void }
      def prune(directory, keep)
        Dir.glob(::File.join(directory, "#{SNAPSHOT_PREFIX}*#{SNAPSHOT_EXTENSION}")).each do |path|
          FileUtils.rm_f(path) unless path == keep
        end
        cutoff = Time.now - ORPHAN_GRACE
        Dir.glob(::File.join(directory, "*.part")).each do |path|
          FileUtils.rm_f(path) if ::File.mtime(path) < cutoff
        rescue Errno::ENOENT
          nil
        end
      end
    end
  end
end
