# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

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
      extend T::Sig

      MEMBERS = T.let(
        %i[source fetched_at checksum record_count schema_version source_version].freeze,
        T::Array[Symbol]
      )

      sig { returns(Symbol) }
      attr_reader :source

      sig { returns(Time) }
      attr_reader :fetched_at

      # The one field that outlives the rest: a match result cites it, so a
      # stored meta answers "which list version cleared this customer".
      sig { returns(String) }
      attr_reader :checksum

      sig { returns(Integer) }
      attr_reader :record_count

      sig { returns(Integer) }
      attr_reader :schema_version

      sig { returns(T.nilable(String)) }
      attr_reader :source_version

      # The metadata of a snapshot already in hand. What a store that keeps no
      # separate record of it answers `#snapshot_meta` with.
      sig { params(snapshot: Snapshot).returns(T.attached_class) }
      def self.from_snapshot(snapshot)
        new(source: snapshot.source, fetched_at: snapshot.fetched_at, checksum: snapshot.checksum,
            record_count: snapshot.record_count, schema_version: snapshot.schema_version,
            source_version: snapshot.source_version)
      end

      # Rebuilds from #to_h output, accepting string keys so a sidecar survives
      # the round-trip through JSON.
      sig { params(hash: T.untyped).returns(T.attached_class) }
      def self.from_h(hash)
        attributes = hash.to_h.transform_keys(&:to_sym)
        unknown = attributes.keys - MEMBERS
        raise ArgumentError, "unknown Meta attribute(s): #{unknown.join(", ")}" if unknown.any?

        # `new(**hash)` past required keyword parameters is one of the few
        # things Sorbet cannot check statically. #initialize validates what
        # arrives, which is where a bad sidecar is caught.
        T.unsafe(self).new(**attributes)
      end

      sig do
        params(source: T.untyped, fetched_at: T.untyped, checksum: T.untyped, record_count: T.untyped,
               schema_version: T.untyped, source_version: T.untyped).void
      end
      def initialize(source:, fetched_at:, checksum:, record_count:, schema_version: Snapshot::SCHEMA_VERSION,
                     source_version: nil)
        @source = T.let(symbol!(:source, source), Symbol)
        @fetched_at = T.let(time!(fetched_at), Time)
        @checksum = T.let(string!(:checksum, checksum), String)
        @record_count = T.let(count!(record_count), Integer)
        @schema_version = T.let(Integer(schema_version), Integer)
        @source_version = T.let(source_version.nil? ? nil : -source_version.to_s, T.nilable(String))
        freeze
      end

      # How long ago this list was fetched, in seconds. Sync (#34) reports it
      # per source: a list that failed to refresh keeps its previous snapshot,
      # which is the right call and only safe if the age of what is being
      # screened against is visible.
      sig { params(now: Time).returns(Integer) }
      def age(now = Time.now) = now.to_i - fetched_at.to_i

      # Whether this is the same list content as another meta, or as a snapshot
      # about to be written. Ignores when either was fetched, because a refetch
      # of an unchanged list is not a new version of it.
      sig { params(other: T.untyped).returns(T::Boolean) }
      def same_content?(other) = !other.nil? && other.checksum == checksum

      sig { returns(T::Hash[Symbol, T.untyped]) }
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

      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.instance_of?(self.class)

        to_h == other.to_h
      end
      alias eql? ==

      sig { returns(Integer) }
      def hash = [self.class, to_h].hash

      sig { returns(String) }
      def inspect
        "#<#{self.class} #{source} #{record_count} entities #{checksum} fetched_at=#{fetched_at.iso8601}>"
      end

      private

      # Truncated to the second, the precision #to_h serializes, so a meta read
      # back off disk is equal to the one that was written.
      sig { params(value: T.untyped).returns(Time) }
      def time!(value)
        time = case value
               when Time then value
               when String then Time.parse(value)
               else raise ArgumentError, "fetched_at is not a time: #{value.inspect}"
               end
        Time.at(time.to_i).utc
      end

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
      def count!(value)
        integer = Integer(value)
        raise ArgumentError, "record_count cannot be negative, got #{integer}" if integer.negative?

        integer
      end
    end
  end
end
