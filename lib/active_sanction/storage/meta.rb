# frozen_string_literal: true

require "time"
require "active_sanction/snapshot"
require "active_sanction/storage"

module ActiveSanction
  module Storage
    # What a store can say about a stored list without reading the list.
    #
    #   store.snapshot_meta(:ofac_sdn)
    #   # => #<ActiveSanction::Storage::Meta ofac_sdn 19015 entities sha256:1f3b... 3h old>
    #
    # Every field here is small and every field a snapshot holds besides these
    # is not: OFAC's is 19,015 entities and tens of megabytes of JSON. The
    # questions an operator and a sync actually ask -- when was this last
    # fetched, how old is it now, how many records are on it, is it still the
    # version we screened against in January -- are all answerable from these
    # six values, so they are worth being able to answer separately.
    #
    # That separation is what makes the two things downstream cheap:
    #
    # - `sources` in the CLI (#36) and the per-source summary in sync
    #   orchestration (#34) print an age per list. A store that had to
    #   deserialize every snapshot to print a table would make the cheapest
    #   command in the library the slowest.
    # - Storage::FileSystem (#24) writes exactly this beside each snapshot as
    #   `meta.json`, so `#to_h` is that file's contents and `.from_h` reads it
    #   back. Base derives a Meta from the snapshot for adapters that have
    #   nothing cheaper; an adapter with a sidecar or a metadata row overrides
    #   `#snapshot_meta` and never opens the list.
    #
    # `checksum` is the one that outlives the rest. A match result cites it
    # (#33), so "which list version cleared this customer" is answered by
    # comparing a stored meta against a checksum in an audit record -- without
    # loading either list.
    #
    # Instances are frozen on construction and compare by value.
    class Meta
      MEMBERS = %i[source fetched_at checksum record_count schema_version source_version].freeze

      attr_reader(*MEMBERS)

      # The metadata of a snapshot already in hand. What a store that keeps no
      # separate record of it answers `#snapshot_meta` with.
      def self.from_snapshot(snapshot)
        new(source: snapshot.source, fetched_at: snapshot.fetched_at, checksum: snapshot.checksum,
            record_count: snapshot.record_count, schema_version: snapshot.schema_version,
            source_version: snapshot.source_version)
      end

      # Rebuilds from #to_h output, accepting string keys so a sidecar survives
      # the round-trip through JSON.
      def self.from_h(hash)
        attributes = hash.to_h.transform_keys(&:to_sym)
        unknown = attributes.keys - MEMBERS
        raise ArgumentError, "unknown Meta attribute(s): #{unknown.join(", ")}" if unknown.any?

        new(**attributes)
      end

      def initialize(source:, fetched_at:, checksum:, record_count:, schema_version: Snapshot::SCHEMA_VERSION,
                     source_version: nil)
        @source = symbol!(:source, source)
        @fetched_at = time!(fetched_at)
        @checksum = string!(:checksum, checksum)
        @record_count = count!(record_count)
        @schema_version = Integer(schema_version)
        @source_version = source_version.nil? ? nil : -source_version.to_s
        freeze
      end

      # How long ago this list was fetched, in seconds. Sync (#34) reports it
      # per source: a list that failed to refresh keeps its previous snapshot,
      # which is the right call and only safe if the age of what is being
      # screened against is visible.
      def age(now = Time.now) = now.to_i - fetched_at.to_i

      # Whether this is the same list content as another meta, or as a snapshot
      # about to be written. Ignores when either was fetched, because a refetch
      # of an unchanged list is not a new version of it.
      def same_content?(other) = !other.nil? && other.checksum == checksum

      def to_h
        {
          source: source,
          fetched_at: fetched_at.iso8601,
          checksum: checksum,
          record_count: record_count,
          schema_version: schema_version,
          source_version: source_version
        }
      end

      def ==(other)
        other.instance_of?(self.class) && other.to_h == to_h
      end
      alias eql? ==

      def hash = [self.class, to_h].hash

      def inspect
        "#<#{self.class} #{source} #{record_count} entities #{checksum} fetched_at=#{fetched_at.iso8601}>"
      end

      private

      # Truncated to the second, the precision #to_h serializes, so a meta read
      # back off disk is equal to the one that was written.
      def time!(value)
        time = case value
               when Time then value
               when String then Time.parse(value)
               else raise ArgumentError, "fetched_at is not a time: #{value.inspect}"
               end
        Time.at(time.to_i).utc
      end

      def symbol!(member, value)
        raise ArgumentError, "#{member} is required" if value.nil? || value.to_s.empty?

        value.to_sym
      end

      def string!(member, value)
        string = value.to_s.strip
        raise ArgumentError, "#{member} is required" if string.empty?

        -string
      end

      def count!(value)
        integer = Integer(value)
        raise ArgumentError, "record_count cannot be negative, got #{integer}" if integer.negative?

        integer
      end
    end
  end
end
