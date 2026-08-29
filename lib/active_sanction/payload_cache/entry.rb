# frozen_string_literal: true

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
      # Bumped whenever the sidecar's shape changes, so an entry written by an
      # older gem can be migrated or discarded rather than silently misread.
      SCHEMA_VERSION = 1

      # What a caller supplies about where the bytes came from. Everything else
      # is measured from the bytes themselves.
      PROVENANCE = %i[url final_url fetched_at etag last_modified].freeze

      MEMBERS = [:source, :checksum, :byte_size, *PROVENANCE, :schema_version].freeze

      BLOB_EXTENSION = ".blob"
      METADATA_EXTENSION = ".json"

      attr_reader(*MEMBERS, :dir)

      # Rebuilds from #to_h output, accepting string keys so an entry survives
      # the round-trip through its sidecar JSON. `dir` is not stored: it is
      # where the sidecar was found, and moving the cache directory should not
      # invalidate every entry in it.
      def self.from_h(hash, dir:)
        attributes = hash.to_h.transform_keys(&:to_sym)
        unknown = attributes.keys - MEMBERS
        raise ArgumentError, "unknown Entry attribute(s): #{unknown.join(", ")}" if unknown.any?

        new(dir: dir, **attributes)
      end

      # Content addressing puts the digest in the filename, so two fetches of
      # the same bytes are one file and a payload cannot be confused with a
      # different payload of the same age. The `sha256:` prefix Snapshot uses
      # is spelled `sha256-` here, because a colon in a filename is legal on
      # every platform this runs on and pleasant on none of them.
      def self.basename_for(checksum) = checksum.to_s.tr(":", "-")

      def initialize(source:, checksum:, byte_size:, url:, dir:, final_url: nil, fetched_at: nil,
                     etag: nil, last_modified: nil, schema_version: SCHEMA_VERSION)
        @source = symbol!(:source, source)
        @checksum = Checksum.normalize!(checksum)
        @byte_size = size!(byte_size)
        @url = string!(:url, url)
        @dir = -::File.expand_path(dir.to_s)
        @final_url = redacted(final_url)
        @fetched_at = time!(fetched_at)
        @etag = string_or_nil(etag)
        @last_modified = string_or_nil(last_modified)
        @schema_version = version!(schema_version)
        freeze
      end

      def basename = self.class.basename_for(checksum)
      def path = ::File.join(dir, "#{basename}#{BLOB_EXTENSION}")
      def metadata_path = ::File.join(dir, "#{basename}#{METADATA_EXTENSION}")
      def exist? = ::File.exist?(path)

      # The hex digest without the algorithm prefix, for callers that want to
      # compare against a checksum a publisher printed on a download page.
      def hex = Checksum.hex(checksum)

      # The bytes, verified first. A payload that no longer hashes to what was
      # recorded beside it raises rather than being handed to a parser: the
      # whole reason to keep raw payloads is to be able to say what a list
      # contained on a given date, and a file that cannot prove it is unchanged
      # answers that question with a guess.
      def read
        verify!
        ::File.binread(path)
      end

      # The same guarantee for a caller that would rather stream 126 MB than
      # hold it. Verification is a separate pass over the file before the
      # handle is yielded, because a parser cannot un-parse the first half of a
      # payload once the second half turns out to be corrupt.
      def open(&)
        verify!
        ::File.open(path, "rb", &)
      end

      def verify!
        raise PayloadMissing, "#{source} payload #{checksum} is not at #{path}" unless exist?

        actual = Checksum.of_file(path)
        return self if actual == checksum

        raise ChecksumMismatch, "#{source} payload at #{path} hashes to #{actual}, not the #{checksum} " \
                                "recorded beside it (#{::File.size(path)} bytes on disk, #{byte_size} " \
                                "recorded). Delete the entry to re-fetch."
      end

      def valid?
        verify!
        true
      rescue PayloadMissing, ChecksumMismatch
        false
      end

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

      def ==(other)
        other.instance_of?(self.class) && other.dir == dir && other.to_h == to_h
      end
      alias eql? ==

      def hash = [self.class, dir, to_h].hash

      def to_s = "#{source} #{checksum} (#{byte_size} bytes)"

      def inspect
        "#<#{self.class} #{source} #{checksum} #{byte_size}B url=#{url} fetched_at=#{fetched_at.iso8601}>"
      end

      private

      def symbol!(member, value)
        raise ArgumentError, "#{member} is required" if value.nil? || value.to_s.empty?

        value.to_sym
      end

      def string!(member, value)
        string = value.to_s.strip
        raise ArgumentError, "#{member} is required" if string.empty?

        -string
      end

      def size!(value)
        integer = Integer(value)
        raise ArgumentError, "byte_size cannot be negative, got #{integer}" if integer.negative?

        integer
      end

      def version!(value)
        integer = Integer(value)
        raise ArgumentError, "schema_version must be positive, got #{integer}" unless integer.positive?

        integer
      end

      # Kept to microseconds rather than truncated to the second, unlike the
      # other timestamps in this library: retention orders entries by when they
      # were fetched, and two payloads written in the same second have to sort
      # in the order they were written or pruning discards the wrong one.
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
      def redacted(value)
        string = string_or_nil(value)
        return nil if string.nil?

        string_or_nil(string.split(/[?#]/).first)
      end

      def string_or_nil(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : -string
      end
    end
  end
end
