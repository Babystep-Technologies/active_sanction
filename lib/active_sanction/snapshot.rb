# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

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
    extend T::Sig

    # Raised when a stored snapshot's content no longer hashes to the checksum
    # stored beside it: the file is corrupt, was edited, or was written by a
    # serializer this version does not agree with. Never silently repaired --
    # a snapshot that cannot prove what it contains cannot anchor an audit.
    class ChecksumMismatch < IntegrityError; end

    # Bumped whenever the serialized form changes shape. Stored snapshots carry
    # the version they were written under so they can be migrated or discarded
    # rather than silently misread; it is folded into the checksum, so content
    # that means one thing under v1 and another under v2 cannot collide.
    #
    # v2 added Entity#dates_of_birth, which the UN adapter (#21) needed and the
    # canonical model had no slot for.
    SCHEMA_VERSION = T.let(2, Integer)

    # Canonical member order, matching the layout #to_h must produce.
    MEMBERS = T.let(
      %i[source entities fetched_at checksum record_count schema_version source_version].freeze,
      T::Array[Symbol]
    )

    ALGORITHM = T.let("sha256", String)

    sig { returns(Symbol) }
    attr_reader :source

    # Deliberately not `T::Array[Entity]`, and the one member of the canonical
    # model that is not declared. The storage conformance group builds a
    # snapshot out of half-deserialized hashes on purpose, to prove it catches
    # a store that hands them back that way (#24); #entities! below states the
    # real contract -- anything that serializes -- in a message written for
    # whoever has to fix the adapter. An element type would raise a TypeError
    # there instead, one layer too early to say anything useful.
    sig { returns(T::Array[T.untyped]) }
    attr_reader :entities

    # UTC, truncated to the second, which is the precision #to_h serializes.
    sig { returns(Time) }
    attr_reader :fetched_at

    # `sha256:` and 64 hex digits, over the content and nothing else.
    sig { returns(String) }
    attr_reader :checksum

    sig { returns(Integer) }
    attr_reader :record_count

    sig { returns(Integer) }
    attr_reader :schema_version

    # The publisher's own version string where it gives one, which is not
    # something every list does.
    sig { returns(T.nilable(String)) }
    attr_reader :source_version

    # Rebuilds a snapshot from #to_h output, verifying the checksum as it goes.
    # Accepts string keys, so a snapshot survives the round-trip through
    # gzipped JSON that storage (#24) puts it through.
    sig { params(hash: T.untyped).returns(T.attached_class) }
    def self.from_h(hash)
      attributes = hash.to_h.transform_keys(&:to_sym)
      unknown = attributes.keys - MEMBERS
      raise InvalidArgument, "unknown Snapshot attribute(s): #{unknown.join(", ")}" if unknown.any?

      attributes[:entities] &&= attributes[:entities].map { |value| build_entity(value) }
      # `new(**hash)` past required keyword parameters is one of the few things
      # Sorbet cannot check statically. #initialize validates what arrives --
      # including, here, the checksum -- which is where a bad round-trip is
      # caught.
      T.unsafe(self).new(**attributes)
    end

    # Entities that are already objects pass through untouched, so from_h is
    # safe to call on a half-deserialized hash.
    sig { params(value: T.untyped).returns(T.untyped) }
    def self.build_entity(value)
      value.is_a?(Hash) ? Entity.from_h(value) : value
    end
    private_class_method :build_entity

    # `checksum` and `record_count` are derived, not supplied. Passing them --
    # which is what .from_h does with a stored snapshot -- asserts what the
    # content should be, and construction fails if it is not.
    sig do
      params(source: T.untyped, entities: T.untyped, fetched_at: T.untyped, checksum: T.untyped,
             record_count: T.untyped, schema_version: T.untyped, source_version: T.untyped).void
    end
    def initialize(source:, entities:, fetched_at: nil, checksum: nil, record_count: nil,
                   schema_version: SCHEMA_VERSION, source_version: nil)
      @source = T.let(symbol!(:source, source), Symbol)
      @entities = T.let(entities!(entities), T::Array[T.untyped])
      @fetched_at = T.let(time!(fetched_at), Time)
      @schema_version = T.let(version!(schema_version), Integer)
      @source_version = T.let(string_or_nil(source_version), T.nilable(String))
      @record_count = T.let(count!(record_count), Integer)
      @checksum = T.let(checksum!(checksum), String)
      freeze
    end

    sig { returns(T::Boolean) }
    def empty? = entities.empty?

    sig { returns(T::Hash[Symbol, T.untyped]) }
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
    sig { params(other: T.untyped).returns(T::Boolean) }
    def ==(other)
      return false unless other.instance_of?(self.class)

      checksum == other.checksum
    end
    alias eql? ==

    sig { returns(Integer) }
    def hash
      [self.class, checksum].hash
    end

    sig { returns(String) }
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
    sig { returns(String) }
    def compute_checksum
      digest = Digest::SHA256.new
      digest << "#{schema_version}\n#{source}\n"
      entities.map { |entity| Digest::SHA256.hexdigest(JSON.generate(entity.to_h)) }
              .sort
              .each { |fingerprint| digest << fingerprint << "\n" }
      -"#{ALGORITHM}:#{digest.hexdigest}"
    end

    sig { params(supplied: T.untyped).returns(String) }
    def checksum!(supplied)
      computed = compute_checksum
      return computed if supplied.nil? || supplied.to_s == computed

      raise ChecksumMismatch,
            "#{source} snapshot content hashes to #{computed}, not the stored #{supplied} " \
            "(schema_version #{schema_version})"
    end

    sig { params(value: T.untyped).returns(T::Array[T.untyped]) }
    def entities!(value)
      raise InvalidArgument, "entities must be an Array" unless value.is_a?(Array)

      value.each do |entity|
        raise InvalidArgument, "entities must respond to #to_h, got #{entity.class}" unless entity.respond_to?(:to_h)
      end
      value.dup.freeze
    end

    sig { params(value: T.untyped).returns(Integer) }
    def count!(value)
      return entities.size if value.nil? || value.to_i == entities.size

      raise InvalidArgument, "record_count #{value} does not match the #{entities.size} entities given"
    end

    # Truncated to the second, which is the precision #to_h serializes, so a
    # stored snapshot reloads to a value equal to the one that was written.
    sig { params(value: T.untyped).returns(Time) }
    def time!(value)
      time = case value
             when nil then Time.now
             when Time then value
             when String then Time.parse(value)
             else raise InvalidArgument, "fetched_at is not a time: #{value.inspect}"
             end
      Time.at(time.to_i).utc
    end

    sig { params(value: T.untyped).returns(Integer) }
    def version!(value)
      integer = Integer(value)
      raise InvalidArgument, "schema_version must be positive, got #{integer}" unless integer.positive?

      integer
    end

    sig { params(member: Symbol, value: T.untyped).returns(Symbol) }
    def symbol!(member, value)
      raise InvalidArgument, "#{member} is required" if value.nil? || value.to_s.empty?

      value.to_sym
    end

    sig { params(value: T.untyped).returns(T.nilable(String)) }
    def string_or_nil(value)
      return nil if value.nil?

      string = value.to_s.strip
      string.empty? ? nil : -string
    end
  end
end
