# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "json"
require "time"
require "active_sanction/error"
require "active_sanction/snapshot"
require "active_sanction/sources"
require "active_sanction/version"

module ActiveSanction
  class Snapshot
    module Bundle
      # What a bundle says about itself, in one line, before any of its records
      # are read.
      #
      #   header = ActiveSanction::Snapshot::Bundle.header(io)
      #
      #   header.source             # => :ofac_sdn
      #   header.record_count       # => 19015
      #   header.snapshot_checksum  # => "sha256:9f86d081884c7d65..."
      #   header.generator          # => "active_sanction/1.0.0"
      #   header.fetched_at         # => 2026-08-28 09:30:00 UTC
      #
      # This is Storage::Meta's job for a file somebody sent you, and the two
      # are deliberately the same shape: small, cheap, and answerable without
      # inflating tens of megabytes. `active_sanction import` prints one, a
      # mirror indexes them, and a deploy decides whether it already holds this
      # list version by comparing `snapshot_checksum` against what it stored.
      #
      # ### It is the thing that gets signed
      #
      # A signature covers these bytes and nothing else -- see Bundle::Signature.
      # It can, because `payload_digest` is a SHA-256 over every record in the
      # file: signing ~300 bytes here transitively covers all 19,015 of them,
      # and a verifier settles who published a bundle before it inflates a byte
      # of what they sent.
      #
      # So every field that could change what the payload *means* is in here,
      # and a field whose value is not reproducible from the snapshot is not:
      # there is no written-at timestamp, because two writes of one snapshot
      # have to produce identical files.
      #
      # Instances are frozen on construction and compare by value.
      class Header
        extend T::Sig

        # Canonical member order. This is the order #to_h builds and #to_line
        # serializes, and it is part of the format: a reader in another language
        # that emits these keys in another order produces a different file.
        #
        # @api private
        MEMBERS = T.let(
          %i[format_version gem_version generator source schema_version snapshot_checksum record_count
             fetched_at source_version payload_encoding payload_compression payload_digest payload_bytes].freeze,
          T::Array[Symbol]
        )

        # The one field a publisher may leave out, because plenty of lists
        # publish no version of their own. It still serializes, as null: the
        # key order is the format, so nothing is omitted from the line.
        #
        # @api private
        OPTIONAL_MEMBERS = T.let(%i[source_version].freeze, T::Array[Symbol])

        # `sha256:` and 64 hex digits, the form this library quotes every digest
        # in -- a snapshot's checksum, a cached payload's, and both of the ones
        # here.
        #
        # @api private
        DIGEST_PATTERN = T.let(/\A#{Snapshot::ALGORITHM}:\h{64}\z/, Regexp)

        # Who wrote the file, defaulted to this gem and this version. A
        # publisher that is not this gem -- a commercial mirror, a bank's
        # internal pipeline -- overrides it, which is the point of the field:
        # `gem_version` says what code serialized the records, and this says
        # whose bundle it is.
        sig { returns(String) }
        def self.default_generator = -"active_sanction/#{VERSION}"

        # The header for a snapshot about to be written, given what the payload
        # came to. Both payload values are measurements of bytes that already
        # exist rather than promises about bytes to come -- see Bundle.write.
        sig do
          params(snapshot: Snapshot, payload_digest: String, payload_bytes: Integer,
                 generator: T.untyped).returns(T.attached_class)
        end
        def self.from_snapshot(snapshot, payload_digest:, payload_bytes:, generator: nil)
          new(format_version: FORMAT_VERSION, gem_version: VERSION, generator: generator || default_generator,
              source: snapshot.source, schema_version: snapshot.schema_version,
              snapshot_checksum: snapshot.checksum, record_count: snapshot.record_count,
              fetched_at: snapshot.fetched_at, source_version: snapshot.source_version,
              payload_digest: payload_digest, payload_bytes: payload_bytes)
        end

        # Reads one serialized header line. Everything that can be wrong with it
        # raises -- an unknown key, a missing one, a digest that is not a
        # digest -- because a header this code half understands is a header it
        # cannot say the signature covers.
        sig { params(line: T.untyped).returns(T.attached_class) }
        def self.parse(line)
          parsed = JSON.parse(line.to_s)
          raise InvalidArgument, "a bundle header is a JSON object, got #{parsed.class}" unless parsed.is_a?(Hash)

          from_h(parsed)
        end

        # Rebuilds from #to_h output, accepting string keys so a header
        # survives the round-trip through JSON.
        sig { params(hash: T.untyped).returns(T.attached_class) }
        def self.from_h(hash)
          attributes = hash.to_h.transform_keys(&:to_sym)
          unknown = attributes.keys - MEMBERS
          raise InvalidArgument, "unknown bundle header field(s): #{unknown.join(", ")}" if unknown.any?

          missing = MEMBERS - attributes.keys - OPTIONAL_MEMBERS
          raise InvalidArgument, "bundle header is missing #{missing.join(", ")}" if missing.any?

          # `new(**hash)` past required keyword parameters is one of the few
          # things Sorbet cannot check statically. #initialize validates what
          # arrives, which is where a bad header is caught.
          T.unsafe(self).new(**attributes)
        end

        sig { returns(Integer) }
        attr_reader :format_version

        # The active_sanction that serialized the records, which is what a
        # `schema_version` this reader does not know is diagnosed against.
        sig { returns(String) }
        attr_reader :gem_version

        sig { returns(String) }
        attr_reader :generator

        sig { returns(Symbol) }
        attr_reader :source

        # Snapshot::SCHEMA_VERSION the records were written under.
        sig { returns(Integer) }
        attr_reader :schema_version

        # The checksum of the list itself: content only, and identical to what
        # the snapshot had before it was ever written to a file. This is what a
        # stored MatchResult cites, so a bundle can be matched to a screening
        # decision made years earlier.
        sig { returns(String) }
        attr_reader :snapshot_checksum

        sig { returns(Integer) }
        attr_reader :record_count

        # UTC, truncated to the second: when the publisher's file was fetched,
        # not when this bundle was written.
        sig { returns(Time) }
        attr_reader :fetched_at

        sig { returns(T.nilable(String)) }
        attr_reader :source_version

        # How the records are laid out once decompressed. `ndjson` in v1, and
        # named so that a later version can add another without a reader having
        # to guess which it is looking at.
        sig { returns(String) }
        attr_reader :payload_encoding

        # `deflate` in v1: a raw zlib stream, RFC 1950.
        sig { returns(String) }
        attr_reader :payload_compression

        # SHA-256 over the *uncompressed* payload. Over the uncompressed bytes
        # because that is the half of the file two machines can be held to:
        # zlib builds differ in what they emit for identical input, and the
        # records do not.
        sig { returns(String) }
        attr_reader :payload_digest

        # The length of the uncompressed payload. Checked as a reader inflates,
        # so a bundle that decompresses to more than it declared is refused part
        # way through rather than absorbed.
        sig { returns(Integer) }
        attr_reader :payload_bytes

        sig do
          params(format_version: T.untyped, gem_version: T.untyped, generator: T.untyped, source: T.untyped,
                 schema_version: T.untyped, snapshot_checksum: T.untyped, record_count: T.untyped,
                 fetched_at: T.untyped, payload_digest: T.untyped, payload_bytes: T.untyped,
                 source_version: T.untyped, payload_encoding: T.untyped, payload_compression: T.untyped).void
        end
        def initialize(format_version:, gem_version:, generator:, source:, schema_version:, snapshot_checksum:,
                       record_count:, fetched_at:, payload_digest:, payload_bytes:, source_version: nil,
                       payload_encoding: ENCODING, payload_compression: COMPRESSION)
          @format_version = T.let(version!(:format_version, format_version), Integer)
          @gem_version = T.let(string!(:gem_version, gem_version), String)
          @generator = T.let(string!(:generator, generator), String)
          @source = T.let(Sources::Definition.key!(source), Symbol)
          @schema_version = T.let(version!(:schema_version, schema_version), Integer)
          @snapshot_checksum = T.let(digest!(:snapshot_checksum, snapshot_checksum), String)
          @record_count = T.let(count!(:record_count, record_count), Integer)
          @fetched_at = T.let(time!(fetched_at), Time)
          @source_version = T.let(string_or_nil(source_version), T.nilable(String))
          @payload_encoding = T.let(string!(:payload_encoding, payload_encoding), String)
          @payload_compression = T.let(string!(:payload_compression, payload_compression), String)
          @payload_digest = T.let(digest!(:payload_digest, payload_digest), String)
          @payload_bytes = T.let(count!(:payload_bytes, payload_bytes), Integer)
          freeze
        end

        # The documented shape, in the documented order.
        sig { returns(T::Hash[Symbol, T.untyped]) }
        def to_h
          {
            format_version: format_version, gem_version: gem_version, generator: generator,
            source: source.to_s, schema_version: schema_version, snapshot_checksum: snapshot_checksum,
            record_count: record_count, fetched_at: fetched_at.iso8601, source_version: source_version,
            payload_encoding: payload_encoding, payload_compression: payload_compression,
            payload_digest: payload_digest, payload_bytes: payload_bytes
          }
        end

        # The exact bytes that go into the file, and the exact bytes a
        # signature is computed over. No trailing newline: the newline is the
        # container's, not the header's, so a reader that strips line endings
        # differently still verifies.
        sig { returns(String) }
        def to_line = JSON.generate(to_h)

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
          "#<#{self.class} #{source} #{record_count} entities #{snapshot_checksum} by #{generator}>"
        end

        private

        sig { params(member: Symbol, value: T.untyped).returns(Integer) }
        def version!(member, value)
          integer = Integer(value)
          raise InvalidArgument, "#{member} must be positive, got #{integer}" unless integer.positive?

          integer
        end

        sig { params(member: Symbol, value: T.untyped).returns(String) }
        def string!(member, value)
          string = value.to_s.strip
          raise InvalidArgument, "#{member} is required" if string.empty?

          -string
        end

        sig { params(member: Symbol, value: T.untyped).returns(String) }
        def digest!(member, value)
          string = value.to_s.strip
          return -string if DIGEST_PATTERN.match?(string)

          raise InvalidArgument, "#{member} is not a #{Snapshot::ALGORITHM} digest: #{value.inspect}"
        end

        sig { params(member: Symbol, value: T.untyped).returns(Integer) }
        def count!(member, value)
          integer = Integer(value)
          raise InvalidArgument, "#{member} cannot be negative, got #{integer}" if integer.negative?

          integer
        end

        # Truncated to the second, the precision #to_h serializes, so a header
        # read back is equal to the one that was written.
        sig { params(value: T.untyped).returns(Time) }
        def time!(value)
          time = case value
                 when Time then value
                 when String then Time.parse(value)
                 else raise InvalidArgument, "fetched_at is not a time: #{value.inspect}"
                 end
          Time.at(time.to_i).utc
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
end
