# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "time"
require "active_sanction/payload_cache/checksum"

module ActiveSanction
  class PayloadCache
    # One cached payload: where its bytes are, what they hash to, and what the
    # publisher said while serving them.
    #
    #   entry = cache.latest(:ofac_sdn)
    #   entry.checksum    #=> "sha256:9f86d081884c7d65..."
    #   entry.byte_size   #=> 132_046_336
    #   entry.read        # verified bytes, or ChecksumMismatch
    #
    # An entry carries its own directory, so a caller holding one can read the
    # bytes without asking the cache again -- which matters for the audit case
    # this cache exists for, where the thing passed around is "the payload that
    # produced that screening decision", not a source name and a moment.
    #
    # The metadata is the fetch's provenance and nothing else: which URL was
    # asked for, which one finally answered (OFAC 302s to blob storage, and a
    # bug report about a bad download is much easier to read when it names the
    # host that actually served the bytes -- minus its query string, which on
    # both OFAC and the UN is a presigned credential), when it was fetched, and
    # the validators the publisher stamped on it. What the bytes *mean* is not
    # here -- parsing them is #14 and #15's job, and a cache that recorded its
    # own opinion of a payload's contents would be a second, quietly diverging
    # record.
    #
    # Instances are frozen on construction and compare by value.
    class Entry
      extend T::Sig

      # Bumped whenever the sidecar's shape changes, so an entry written by an
      # older gem can be migrated or discarded rather than silently misread.
      SCHEMA_VERSION = T.let(1, Integer)

      # What a caller supplies about where the bytes came from. Everything else
      # is measured from the bytes themselves.
      PROVENANCE = T.let(%i[url final_url fetched_at etag last_modified].freeze, T::Array[Symbol])

      MEMBERS = T.let([:source, :checksum, :byte_size, *PROVENANCE, :schema_version].freeze, T::Array[Symbol])

      BLOB_EXTENSION = T.let(".blob", String)
      METADATA_EXTENSION = T.let(".json", String)

      sig { returns(Symbol) }
      attr_reader :source

      # `sha256:` and 64 hex digits -- see Checksum, which every filename under
      # the cache directory is built from.
      sig { returns(String) }
      attr_reader :checksum

      sig { returns(Integer) }
      attr_reader :byte_size

      sig { returns(String) }
      attr_reader :url

      # The host that actually served the bytes, minus its query string, which
      # on both OFAC and the UN is a presigned credential. See #redacted.
      sig { returns(T.nilable(String)) }
      attr_reader :final_url

      sig { returns(Time) }
      attr_reader :fetched_at

      sig { returns(T.nilable(String)) }
      attr_reader :etag

      sig { returns(T.nilable(String)) }
      attr_reader :last_modified

      sig { returns(Integer) }
      attr_reader :schema_version

      # Where the sidecar was found rather than anything stored in it, which is
      # why moving the cache directory does not invalidate every entry in it.
      sig { returns(String) }
      attr_reader :dir

      # Rebuilds from #to_h output, accepting string keys so an entry survives
      # the round-trip through its sidecar JSON. `dir` is not stored: it is
      # where the sidecar was found, and moving the cache directory should not
      # invalidate every entry in it.
      sig { params(hash: T.untyped, dir: T.untyped).returns(T.attached_class) }
      def self.from_h(hash, dir:)
        attributes = hash.to_h.transform_keys(&:to_sym)
        unknown = attributes.keys - MEMBERS
        raise ArgumentError, "unknown Entry attribute(s): #{unknown.join(", ")}" if unknown.any?

        # `new(**hash)` past required keyword parameters is one of the few
        # things Sorbet cannot check statically. #initialize validates what
        # arrives, which is where a bad sidecar is caught.
        T.unsafe(self).new(dir: dir, **attributes)
      end

      # Content addressing puts the digest in the filename, so two fetches of
      # the same bytes are one file and a payload cannot be confused with a
      # different payload of the same age. The `sha256:` prefix Snapshot uses
      # is spelled `sha256-` here, because a colon in a filename is legal on
      # every platform this runs on and pleasant on none of them.
      sig { params(checksum: T.untyped).returns(String) }
      def self.basename_for(checksum) = checksum.to_s.tr(":", "-")

      # Untyped on purpose, and for the same reason the value objects are: an
      # entry is rebuilt from a sidecar JSON file whose keys have been through
      # a serializer, and the coercions below say what happens to each of them.
      sig do
        params(source: T.untyped, checksum: T.untyped, byte_size: T.untyped, url: T.untyped, dir: T.untyped,
               final_url: T.untyped, fetched_at: T.untyped, etag: T.untyped, last_modified: T.untyped,
               schema_version: T.untyped).void
      end
      def initialize(source:, checksum:, byte_size:, url:, dir:, final_url: nil, fetched_at: nil,
                     etag: nil, last_modified: nil, schema_version: SCHEMA_VERSION)
        @source = T.let(symbol!(:source, source), Symbol)
        @checksum = T.let(Checksum.normalize!(checksum), String)
        @byte_size = T.let(size!(byte_size), Integer)
        @url = T.let(string!(:url, url), String)
        @dir = T.let(-::File.expand_path(dir.to_s), String)
        @final_url = T.let(redacted(final_url), T.nilable(String))
        @fetched_at = T.let(time!(fetched_at), Time)
        @etag = T.let(string_or_nil(etag), T.nilable(String))
        @last_modified = T.let(string_or_nil(last_modified), T.nilable(String))
        @schema_version = T.let(version!(schema_version), Integer)
        freeze
      end

      sig { returns(String) }
      def basename = self.class.basename_for(checksum)

      sig { returns(String) }
      def path = ::File.join(dir, "#{basename}#{BLOB_EXTENSION}")

      sig { returns(String) }
      def metadata_path = ::File.join(dir, "#{basename}#{METADATA_EXTENSION}")

      sig { returns(T::Boolean) }
      def exist? = ::File.exist?(path)

      # The hex digest without the algorithm prefix, for callers that want to
      # compare against a checksum a publisher printed on a download page.
      sig { returns(T.nilable(String)) }
      def hex = Checksum.hex(checksum)

      # The bytes, verified first. A payload that no longer hashes to what was
      # recorded beside it raises rather than being handed to a parser: the
      # whole reason to keep raw payloads is to be able to say what a list
      # contained on a given date, and a file that cannot prove it is unchanged
      # answers that question with a guess.
      sig { returns(String) }
      def read
        verify!
        ::File.binread(path)
      end

      # The same guarantee for a caller that would rather stream 126 MB than
      # hold it. Verification is a separate pass over the file before the
      # handle is yielded, because a parser cannot un-parse the first half of a
      # payload once the second half turns out to be corrupt.
      # The block is untyped rather than a `T.proc`: it is handed straight to
      # `File.open`, and sorbet-runtime checks a declared block against what it
      # was passed strictly enough to reject the probe object RSpec's
      # `expect { |probe| ... }` yields with -- a test idiom this method is
      # exercised by, and worth more here than a shape the file handle already
      # fixes.
      sig { params(block: T.untyped).returns(T.untyped) }
      def open(&block)
        verify!
        ::File.open(path, "rb", &block)
      end

      sig { returns(T.self_type) }
      def verify!
        raise PayloadMissing, "#{source} payload #{checksum} is not at #{path}" unless exist?

        actual = Checksum.of_file(path)
        return self if actual == checksum

        raise ChecksumMismatch, "#{source} payload at #{path} hashes to #{actual}, not the #{checksum} " \
                                "recorded beside it (#{::File.size(path)} bytes on disk, #{byte_size} " \
                                "recorded). Delete the entry to re-fetch."
      end

      sig { returns(T::Boolean) }
      def valid?
        verify!
        true
      rescue PayloadMissing, ChecksumMismatch
        false
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h
        {
          source: source,
          checksum: checksum,
          byte_size: byte_size,
          url: url,
          final_url: final_url,
          fetched_at: fetched_at.iso8601(6),
          etag: etag,
          last_modified: last_modified,
          schema_version: schema_version
        }
      end

      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.instance_of?(self.class)

        dir == other.dir && to_h == other.to_h
      end
      alias eql? ==

      sig { returns(Integer) }
      def hash = [self.class, dir, to_h].hash

      sig { returns(String) }
      def to_s = "#{source} #{checksum} (#{byte_size} bytes)"

      sig { returns(String) }
      def inspect
        "#<#{self.class} #{source} #{checksum} #{byte_size}B url=#{url} fetched_at=#{fetched_at.iso8601}>"
      end

      private

      sig { params(member: Symbol, value: T.untyped).returns(Symbol) }
      def symbol!(member, value)
        raise ArgumentError, "#{member} is required" if value.nil? || value.to_s.empty?

        value.to_sym
      end

      sig { params(member: Symbol, value: T.untyped).returns(String) }
      def string!(member, value)
        string = value.to_s.strip
        raise ArgumentError, "#{member} is required" if string.empty?

        -string
      end

      sig { params(value: T.untyped).returns(Integer) }
      def size!(value)
        integer = Integer(value)
        raise ArgumentError, "byte_size cannot be negative, got #{integer}" if integer.negative?

        integer
      end

      sig { params(value: T.untyped).returns(Integer) }
      def version!(value)
        integer = Integer(value)
        raise ArgumentError, "schema_version must be positive, got #{integer}" unless integer.positive?

        integer
      end

      # Kept to microseconds rather than truncated to the second, unlike the
      # other timestamps in this library: retention orders entries by when they
      # were fetched, and two payloads written in the same second have to sort
      # in the order they were written or pruning discards the wrong one.
      sig { params(value: T.untyped).returns(Time) }
      def time!(value)
        time = case value
               when nil then Time.now
               when Time then value
               when String then Time.parse(value)
               else raise ArgumentError, "fetched_at is not a time: #{value.inspect}"
               end
        time.getutc.round(6)
      end

      # A publisher's last hop is usually presigned: OFAC's 302 lands on an S3
      # URL carrying an `X-Amz-Security-Token`, the UN's on a blob SAS
      # signature, both good for about an hour. What is worth keeping is which
      # host served the bytes; the query string is a credential, and a cache
      # file is the wrong place for one -- it outlives the token, gets copied
      # into bug reports, and is readable by anything that can read the cache.
      # So it is cut before the entry is written.
      sig { params(value: T.untyped).returns(T.nilable(String)) }
      def redacted(value)
        string = string_or_nil(value)
        return nil if string.nil?

        string_or_nil(string.split(/[?#]/).first)
      end

      sig { params(value: T.untyped).returns(T.nilable(String)) }
      def string_or_nil(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : -string
      end
    end
  end
end
