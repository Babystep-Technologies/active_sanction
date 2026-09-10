# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "json"
require "active_sanction/entity"
require "active_sanction/error"
require "active_sanction/snapshot"
require "active_sanction/sources"
require "active_sanction/version"

module ActiveSanction
  class Snapshot
    # One list, in one file, that another machine can load and trust without
    # ever reaching the publisher.
    #
    #   File.open("ofac_sdn.asb", "wb") do |io|
    #     ActiveSanction::Snapshot::Bundle.write(snapshot, io: io, sign_with: private_key)
    #   end
    #
    #   File.open("ofac_sdn.asb", "rb") do |io|
    #     snapshot = ActiveSanction::Snapshot::Bundle.read(io, verify_with: public_key)
    #     snapshot.trusted?   # => true
    #   end
    #
    # `ActiveSanction.export` and `.import` are the sugar over this that most
    # applications want; this is the format itself, and it is public API. The
    # byte-level specification is docs/bundle_format.md, which is written so
    # that a bundle can be produced and read by something that is not this gem
    # and not Ruby.
    #
    # ### Why a file, when there is already a store
    #
    # Storage::FileSystem writes gzipped JSON too, and its layout is explicitly
    # private and expected to change. This is the opposite thing: a published
    # artifact with a stability contract, which three situations need and a
    # directory cannot serve.
    #
    # - **Publishers go down.** OFAC breaks, changes format, and rate-limits. A
    #   bundle produced once and copied is the difference between a bad
    #   afternoon at Treasury and a failed deploy for everyone downstream.
    # - **Air-gapped and privacy-sensitive installations.** A compliance team
    #   that will not send subject names to a third-party API will happily
    #   consume fresh data. Only a file serves them.
    # - **Audit.** A checksum proves a list is internally intact. A signature
    #   proves it is *the one that was published*, which is the claim an
    #   examiner is actually asking about.
    #
    # ### The shape of a bundle
    #
    #     ACTIVESANCTION-BUNDLE/1\n     magic, and the format version
    #     {"format_version":1,...}\n    one canonical line -- see Header
    #     ecdsa-sha256 MEUCIQ...\n      or "-" -- see Signature
    #     <deflated NDJSON>             to EOF -- see Payload
    #
    # The first three lines are text on purpose: `head -c 512` on a bundle tells
    # an operator what list it holds, how many records, from when, and who says
    # so, without a tool and without decompressing anything.
    #
    # ### Determinism
    #
    # Two writes of one snapshot produce one file. Records are ordered by the
    # fingerprint Snapshot's own checksum is built from rather than by whatever
    # order a publisher's file happened to arrive in, the header's keys have a
    # fixed order, the compression level is named by the specification rather
    # than taken from a build's default, and there is deliberately no
    # written-at timestamp anywhere in the file.
    #
    # What that buys is comparability: two mirrors that bundled the same
    # snapshot can be held against each other byte for byte. The invariant that
    # survives everything, including a zlib that packs differently, is the
    # header line -- it pins the content, through `payload_digest`, and the
    # provenance. A signature line is the one part that may differ between two
    # signings, because ECDSA is randomized.
    #
    # ### What it refuses to do
    #
    # Return anything it cannot prove, on the same rule the stores follow. A
    # flipped byte, a truncated download and an edited record all raise Corrupt
    # rather than screening against a list that is quietly missing somebody. A
    # format version from a newer gem raises UnsupportedFormat *before* the
    # payload is touched, because a newer shape will usually deserialize into
    # plausible, wrong records. And a snapshot only comes back `trusted?` when a
    # key was supplied and the signature verified under it.
    module Bundle
      extend T::Sig
      extend T::Helpers

      # Called as `Bundle.read` -- module functions on a module, which is an
      # Object, which is where `raise` comes from.
      requires_ancestor { Kernel }

      # Bumped when the container changes shape. Readers refuse anything above
      # what they know rather than guessing, which is the whole reason it is on
      # the first line of the file.
      #
      # @api private
      FORMAT_VERSION = T.let(1, Integer)

      # Formats this code can read. A bundle below the version it writes still
      # round-trips; one above it does not, and says so.
      #
      # @api private
      READABLE_FORMAT_VERSIONS = T.let(1..FORMAT_VERSION, T::Range[Integer])

      # Snapshot schemas this code can read, held to the same range
      # Storage::FileSystem holds a stored list to.
      #
      # @api private
      READABLE_SCHEMA_VERSIONS = T.let(1..Snapshot::SCHEMA_VERSION, T::Range[Integer])

      # @api private
      MAGIC = T.let("ACTIVESANCTION-BUNDLE", String)

      # @api private
      MAGIC_PATTERN = T.let(%r{\A#{MAGIC}/(\d+)\z}, Regexp)

      # The conventional extension, and what the CLI-shaped helpers default to.
      #
      # @api private
      EXTENSION = T.let(".asb", String)

      # How the records are laid out, and how they are packed. Named in the
      # header of every bundle so that a v1 reader can refuse a v1 file that
      # uses something it has never heard of, rather than misreading it.
      #
      # @api private
      ENCODING = T.let("ndjson", String)
      # @api private
      COMPRESSION = T.let("deflate", String)

      # The longest any of the three text lines may be. A malformed file must
      # not be read as one 400 MB line before anything notices it is malformed.
      #
      # @api private
      MAX_LINE_BYTES = T.let(64 * 1024, Integer)

      # This bundle is not what it says it is: it does not begin like a bundle,
      # it stops in the middle, its records no longer hash to the digest in its
      # header, or it holds a different number of them than it claims.
      #
      # Never repaired and never partially returned, for the reason IntegrityError
      # exists: a list that is quietly half there produces a report that looks
      # exactly like a clean one.
      class Corrupt < IntegrityError; end

      # This bundle is intact, and somebody other than the expected publisher
      # signed it. Deliberately a different error from Corrupt: "these bytes
      # were damaged" and "these bytes came from somewhere else" are different
      # incidents, and only one of them is fixed by downloading the file again.
      class UntrustedSignature < IntegrityError; end

      # Verification was asked for and there is no signature to verify. A
      # subclass, so `rescue UntrustedSignature` covers both, while an operator
      # can still tell "our publisher did not sign this" from "somebody else
      # did".
      class Unsigned < UntrustedSignature; end

      # A bundle written under a format version, a snapshot schema or a payload
      # encoding this code does not know -- almost always because it was written
      # by a newer active_sanction.
      #
      # Separate from Corrupt because the file is fine and the fix is different:
      # upgrade the gem. Raised before the payload is read, for the reason
      # Storage::UnsupportedSchema is raised before a stored list is parsed.
      class UnsupportedFormat < StorageError; end

      module_function

      # Writes `snapshot` to `io` and returns the Header it wrote.
      #
      #   Bundle.write(snapshot, io: io)                        # unsigned, and fully usable
      #   Bundle.write(snapshot, io: io, sign_with: key)        # OpenSSL::PKey, or a PEM
      #   Bundle.write(snapshot, io: io, generator: "acme/2.0") # whose bundle this is
      #
      # `generator` is the one field a publisher other than this gem should set.
      # It is who published the file; `gem_version`, which is not overridable,
      # is what serialized the records.
      sig do
        params(snapshot: T.untyped, io: T.untyped, sign_with: T.untyped, generator: T.untyped).returns(Header)
      end
      def write(snapshot, io:, sign_with: nil, generator: nil)
        stored = snapshot!(snapshot)
        payload, digest, bytes = Payload.pack(records(stored))
        header = Header.from_snapshot(stored, payload_digest: digest, payload_bytes: bytes, generator: generator)
        line = header.to_line
        io.binmode if io.respond_to?(:binmode)
        io.write("#{MAGIC}/#{FORMAT_VERSION}\n", "#{line}\n", "#{Signature.sign(line, sign_with)}\n", payload)
        header
      end

      # Reads a bundle, verifying it as it goes, and returns the Snapshot.
      #
      #   Bundle.read(io)                     # => Snapshot, trusted? false
      #   Bundle.read(io, verify_with: key)   # => Snapshot, trusted? true, or an exception
      #
      # Without `verify_with:` the signature is not looked at: an unsigned
      # bundle is a first-class bundle, and a signed one read without a key is
      # exactly as useful as an unsigned one -- its records are still proven
      # against the digest in its header and against the snapshot checksum.
      # What it is not is attested, and `trusted?` says so.
      #
      # With a key, the signature is checked **before a byte of the payload is
      # inflated**. Compressed data from a party that has not authenticated is
      # the last thing anybody should expand.
      sig { params(io: T.untyped, verify_with: T.untyped).returns(Snapshot) }
      def read(io, verify_with: nil)
        io.binmode if io.respond_to?(:binmode)
        version = magic!(io)
        line = line!(io, "header")
        header = supported!(parse!(line), version)
        trusted = verified!(line!(io, "signature"), line, verify_with)
        build(header, entities(io, header), trusted)
      end

      # What a bundle says about itself, without reading its records:
      #
      #   header = File.open(path, "rb") { |io| Bundle.header(io) }
      #   header.record_count       # => 19015
      #   header.snapshot_checksum  # => "sha256:9f86d081884c7d65..."
      #
      # Storage::Meta's job for a file somebody sent you, and cheap for the same
      # reason: deciding whether a 25 MB bundle holds a list you already have
      # should cost a few hundred bytes.
      sig { params(io: T.untyped).returns(Header) }
      def header(io)
        io.binmode if io.respond_to?(:binmode)
        version = magic!(io)
        supported!(parse!(line!(io, "header")), version)
      end

      # The records of a snapshot, in the order a bundle lays them out.
      #
      # Sorted by the fingerprint Snapshot's checksum is built from, so that two
      # snapshots holding the same entities in the order two publishers happened
      # to emit them produce identical files -- and so that the order of a
      # payload and the meaning of a checksum can never drift apart. Serializing
      # each entity twice, once to fingerprint it and once to write it, is what
      # one definition of "the fingerprint of an entity" costs; an export is not
      # a hot path.
      sig { params(snapshot: Snapshot).returns(T::Array[String]) }
      def records(snapshot)
        snapshot.entities
                .sort_by { |entity| Snapshot.fingerprint(entity) }
                .map { |entity| JSON.generate(entity.to_h) }
      end

      # The format version off the first line, checked before anything else in
      # the file is looked at.
      sig { params(io: T.untyped).returns(Integer) }
      def magic!(io)
        match = MAGIC_PATTERN.match(line!(io, "magic"))
        raise Corrupt, "this is not an active_sanction bundle: it does not begin with #{MAGIC}/<version>" if match.nil?

        version = Integer(T.must(match[1]))
        return version if READABLE_FORMAT_VERSIONS.cover?(version)

        raise UnsupportedFormat, format_message(version)
      end

      sig { params(line: String).returns(Header) }
      def parse!(line)
        Header.parse(line)
      rescue JSON::ParserError, ArgumentError, TypeError, Sources::DeclarationError => e
        raise Corrupt, "this bundle's header cannot be read (#{e.message})"
      end

      # Everything about a header that decides whether this code may read the
      # payload at all. All of it happens before the payload is touched.
      sig { params(header: Header, version: Integer).returns(Header) }
      def supported!(header, version)
        if header.format_version != version
          raise Corrupt, "this bundle is labelled #{MAGIC}/#{version} and its header says format_version " \
                         "#{header.format_version}. The two have to agree -- only one of them is signed"
        end
        raise UnsupportedFormat, schema_message(header) unless READABLE_SCHEMA_VERSIONS.cover?(header.schema_version)
        raise UnsupportedFormat, payload_message(header) unless readable_payload?(header)

        header
      end

      sig { params(header: Header).returns(T::Boolean) }
      def readable_payload?(header)
        header.payload_encoding == ENCODING && header.payload_compression == COMPRESSION
      end

      # Whether this bundle was proven to come from the holder of `key`, or the
      # exception that says why it was not. False -- rather than an exception --
      # only when no key was given, which is the caller saying they do not care.
      sig { params(signature: String, header_line: String, key: T.untyped).returns(T::Boolean) }
      def verified!(signature, header_line, key)
        return false if key.nil?

        Signature.verify!(signature, header_line, key)
      end

      # The records, streamed, held against everything the header promised
      # about them.
      sig { params(io: T.untyped, header: Header).returns(T::Array[T.untyped]) }
      def entities(io, header)
        built = T.let([], T::Array[T.untyped])
        digest, bytes = Payload.unpack(io, limit: header.payload_bytes) { |record| built << entity!(record) }
        unless digest == header.payload_digest && bytes == header.payload_bytes
          raise Corrupt, digest_message(header, digest, bytes)
        end

        built
      end

      sig { params(record: String).returns(T.untyped) }
      def entity!(record)
        Entity.from_h(JSON.parse(record))
      rescue JSON::ParserError, ArgumentError, TypeError, KeyError => e
        raise Corrupt, "a record in this bundle cannot be read (#{e.message})"
      end

      # The snapshot itself, which re-derives its own checksum over the records
      # that actually arrived and refuses to be built if it does not match the
      # one in the header. The same defence a store relies on, applied to a file
      # that came from somebody else.
      sig { params(header: Header, entities: T::Array[T.untyped], trusted: T::Boolean).returns(Snapshot) }
      def build(header, entities, trusted)
        Snapshot.new(source: header.source, entities: entities, fetched_at: header.fetched_at,
                     checksum: header.snapshot_checksum, record_count: header.record_count,
                     schema_version: header.schema_version, source_version: header.source_version,
                     trusted: trusted)
      rescue Snapshot::ChecksumMismatch, InvalidArgument => e
        raise Corrupt, "this bundle does not hold the list its header describes (#{e.message})"
      end

      # One line of the container, refused rather than read without limit.
      sig { params(io: T.untyped, what: String).returns(String) }
      def line!(io, what)
        line = io.gets("\n", MAX_LINE_BYTES)
        raise Corrupt, "this bundle ends before its #{what} line" if line.nil? || line.empty?
        raise Corrupt, "this bundle's #{what} line is longer than #{MAX_LINE_BYTES} bytes" unless line.end_with?("\n")

        line.chomp.force_encoding(Encoding::UTF_8)
      end

      sig { params(value: T.untyped).returns(Snapshot) }
      def snapshot!(value)
        return value if value.is_a?(Snapshot)

        raise InvalidArgument, "Bundle.write takes an ActiveSanction::Snapshot, got #{value.class}"
      end

      sig { params(version: Integer).returns(String) }
      def format_message(version)
        "this bundle is written in bundle format version #{version}; active_sanction #{VERSION} reads " \
          "#{READABLE_FORMAT_VERSIONS.first}-#{READABLE_FORMAT_VERSIONS.last}. Upgrade the gem -- nothing here " \
          "can read it partially, and a format this code guessed at would produce a list nobody could defend"
      end

      sig { params(header: Header).returns(String) }
      def schema_message(header)
        "this bundle holds records written under snapshot schema_version #{header.schema_version} by " \
          "#{header.generator}; active_sanction #{VERSION} reads #{READABLE_SCHEMA_VERSIONS.first}-" \
          "#{READABLE_SCHEMA_VERSIONS.last}. Upgrade the gem, or ask the publisher for a bundle this old"
      end

      sig { params(header: Header).returns(String) }
      def payload_message(header)
        "this bundle's payload is #{header.payload_encoding}/#{header.payload_compression}; active_sanction " \
          "#{VERSION} reads #{ENCODING}/#{COMPRESSION}. Upgrade the gem"
      end

      sig { params(header: Header, digest: String, bytes: Integer).returns(String) }
      def digest_message(header, digest, bytes)
        "this bundle's records hash to #{digest} over #{bytes} bytes, not the #{header.payload_digest} over " \
          "#{header.payload_bytes} its header declares. The file was damaged in transit or edited after it was " \
          "written -- fetch it again rather than screening against it"
      end
    end
  end
end

require "active_sanction/snapshot/bundle/header"
require "active_sanction/snapshot/bundle/payload"
require "active_sanction/snapshot/bundle/signature"
