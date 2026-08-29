# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "active_sanction/error"
require "active_sanction/entity"

module ActiveSanction
  # One source's entities as they stood at one moment, with a checksum over
  # their content. This is the unit of persistence (#24) and the anchor for
  # reproducibility.
  #
  #   ActiveSanction::Snapshot.new(
  #     source:         :ofac_sdn,
  #     entities:       [Entity, ...],
  #     fetched_at:     Time.now.utc,
  #     source_version: "2026-08-28"   # the publisher's own date, if it gives one
  #   )
  #
  # A screening decision has to be reproducible months later, in front of an
  # examiner. MatchResult (#33) stamps `checksum` onto every result, so "why
  # did we clear this customer on 5 Jan" is answered by reloading the exact
  # list version that was screened against. Without that the library produces
  # unauditable results.
  #
  # Instances are frozen on construction and compare by value.
  class Snapshot
    # Raised when a stored snapshot's content no longer hashes to the checksum
    # stored beside it: the file is corrupt, was edited, or was written by a
    # serializer this version does not agree with. Never silently repaired --
    # a snapshot that cannot prove what it contains cannot anchor an audit.
    class ChecksumMismatch < Error; end

    # Bumped whenever the serialized form changes shape. Stored snapshots carry
    # the version they were written under so they can be migrated or discarded
    # rather than silently misread; it is folded into the checksum, so content
    # that means one thing under v1 and another under v2 cannot collide.
    SCHEMA_VERSION = 1

    # Canonical member order, matching the layout #to_h must produce.
    MEMBERS = %i[source entities fetched_at checksum record_count schema_version source_version].freeze

    ALGORITHM = "sha256"

    attr_reader(*MEMBERS)

    # Rebuilds a snapshot from #to_h output, verifying the checksum as it goes.
    # Accepts string keys, so a snapshot survives the round-trip through
    # gzipped JSON that storage (#24) puts it through.
    def self.from_h(hash)
      attributes = hash.to_h.transform_keys(&:to_sym)
      unknown = attributes.keys - MEMBERS
      raise ArgumentError, "unknown Snapshot attribute(s): #{unknown.join(", ")}" if unknown.any?

      attributes[:entities] &&= attributes[:entities].map { |value| build_entity(value) }
      new(**attributes)
    end

    # Entities that are already objects pass through untouched, so from_h is
    # safe to call on a half-deserialized hash.
    def self.build_entity(value)
      value.is_a?(Hash) ? Entity.from_h(value) : value
    end
    private_class_method :build_entity

    # `checksum` and `record_count` are derived, not supplied. Passing them --
    # which is what .from_h does with a stored snapshot -- asserts what the
    # content should be, and construction fails if it is not.
    def initialize(source:, entities:, fetched_at: nil, checksum: nil, record_count: nil,
                   schema_version: SCHEMA_VERSION, source_version: nil)
      @source = symbol!(:source, source)
      @entities = entities!(entities)
      @fetched_at = time!(fetched_at)
      @schema_version = version!(schema_version)
      @source_version = string_or_nil(source_version)
      @record_count = count!(record_count)
      @checksum = checksum!(checksum)
      freeze
    end

    def empty? = entities.empty?

    def to_h
      {
        source: source,
        entities: entities.map(&:to_h),
        fetched_at: fetched_at.iso8601,
        checksum: checksum,
        record_count: record_count,
        schema_version: schema_version,
        source_version: source_version
      }
    end

    # Two fetches of an unchanged list are the same snapshot with different
    # timestamps, and the checksum is what says so; equality follows it rather
    # than #to_h so a re-fetch does not read as a new list version.
    def ==(other)
      other.instance_of?(self.class) && other.checksum == checksum
    end
    alias eql? ==

    def hash
      [self.class, checksum].hash
    end

    def inspect
      "#<#{self.class} #{source} #{record_count} entities #{checksum} fetched_at=#{fetched_at.iso8601}>"
    end

    private

    # Order is a fact about how a publisher happened to emit its file, not
    # about what the file says, so each entity is digested on its own and the
    # digests are sorted before being folded together. Duplicates survive that
    # -- an entity listed twice hashes to two identical fingerprints -- and
    # changing any field of any entity changes exactly one of them.
    #
    # `fetched_at` and `source_version` stay out: this is a checksum of
    # content, and refetching an unchanged list has to reproduce it or it
    # cannot answer "has this list changed since we last screened?".
    def compute_checksum
      digest = Digest::SHA256.new
      digest << "#{schema_version}\n#{source}\n"
      entities.map { |entity| Digest::SHA256.hexdigest(JSON.generate(entity.to_h)) }
              .sort
              .each { |fingerprint| digest << fingerprint << "\n" }
      -"#{ALGORITHM}:#{digest.hexdigest}"
    end

    def checksum!(supplied)
      computed = compute_checksum
      return computed if supplied.nil? || supplied.to_s == computed

      raise ChecksumMismatch,
            "#{source} snapshot content hashes to #{computed}, not the stored #{supplied} " \
            "(schema_version #{schema_version})"
    end

    def entities!(value)
      raise ArgumentError, "entities must be an Array" unless value.is_a?(Array)

      value.each do |entity|
        raise ArgumentError, "entities must respond to #to_h, got #{entity.class}" unless entity.respond_to?(:to_h)
      end
      value.dup.freeze
    end

    def count!(value)
      return entities.size if value.nil? || value.to_i == entities.size

      raise ArgumentError, "record_count #{value} does not match the #{entities.size} entities given"
    end

    # Truncated to the second, which is the precision #to_h serializes, so a
    # stored snapshot reloads to a value equal to the one that was written.
    def time!(value)
      time = case value
             when nil then Time.now
             when Time then value
             when String then Time.parse(value)
             else raise ArgumentError, "fetched_at is not a time: #{value.inspect}"
             end
      Time.at(time.to_i).utc
    end

    def version!(value)
      integer = Integer(value)
      raise ArgumentError, "schema_version must be positive, got #{integer}" unless integer.positive?

      integer
    end

    def symbol!(member, value)
      raise ArgumentError, "#{member} is required" if value.nil? || value.to_s.empty?

      value.to_sym
    end

    def string_or_nil(value)
      return nil if value.nil?

      string = value.to_s.strip
      string.empty? ? nil : -string
    end
  end
end
