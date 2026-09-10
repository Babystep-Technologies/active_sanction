# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "openssl"
require "active_sanction/error"

module ActiveSanction
  class Snapshot
    module Bundle
      # The third line of a bundle: who says this is the file they published.
      #
      #   key = OpenSSL::PKey::EC.generate("prime256v1")
      #   Bundle.write(snapshot, io: io, sign_with: key)
      #   Bundle.read(io, verify_with: key)   # => Snapshot, trusted?
      #
      # ### Detached, and over the header only
      #
      # The signed bytes are the header line's, without its newline. That line
      # carries `payload_digest`, a SHA-256 over every record in the file, so
      # ~300 bytes of signature input stand for all 19,015 of them. Three things
      # follow, and all three are the reason it is done this way:
      #
      # - **A verifier settles who published a bundle before inflating a byte
      #   of it.** Compressed data from a party you have not yet authenticated
      #   is exactly what you do not want to expand.
      # - **Verification costs the same for OFAC and for the EU.** One
      #   signature over a fixed-size line, not over 25 MB.
      # - **A bundle without a signature is still a bundle.** The line reads
      #   `-`, everything else about the file is unchanged, and a reader that
      #   was given no key never looks at it. Signing is a claim about
      #   provenance laid on top of a format that works without one.
      #
      # ### What it does not cover
      #
      # Nothing about the file that is not in the header. A bundle re-compressed
      # at a different level still verifies, because the digest is over the
      # uncompressed records -- which is correct: the claim is about the list,
      # not about the packing. Tampering with the records themselves fails, but
      # it fails as corruption (the digest) rather than as a bad signature, and
      # Bundle raises two different errors to say which.
      #
      # ### Keys
      #
      # RSA and EC, both of which every OpenSSL this gem can run against
      # supports. `ed25519` is reserved as an algorithm name and deliberately
      # not implemented yet: support for it varies by OpenSSL build, and a
      # format whose signatures verify on some machines is worse than one that
      # signs with a key everybody has.
      #
      # Note that an ECDSA signature is randomized -- signing one snapshot twice
      # with one key produces two different lines. Determinism is a property of
      # the magic line, the header and the payload; see Bundle.
      #
      # @api private
      module Signature
        extend T::Sig
        extend T::Helpers

        # Called as `Signature.sign` -- module functions on a module, which is
        # an Object, which is where `raise` comes from.
        requires_ancestor { Kernel }

        # What an unsigned bundle carries. A literal, rather than an empty
        # line, so that a truncated file cannot read as an unsigned one.
        NONE = T.let("-", String)

        # The algorithm names the format defines, and the kind of OpenSSL key
        # each one is produced by. `ed25519` is reserved and not in here: a name
        # a v1 reader rejects is a name a v1 reader cannot get wrong.
        ALGORITHMS = T.let({ "rsa-sha256" => OpenSSL::PKey::RSA, "ecdsa-sha256" => OpenSSL::PKey::EC }.freeze,
                           T::Hash[String, T.untyped])

        # Reserved, and refused with a message that says so rather than with
        # "unknown algorithm", so a bundle from a newer publisher diagnoses
        # itself.
        RESERVED_ALGORITHMS = T.let(%w[ed25519].freeze, T::Array[String])

        DIGEST = T.let("SHA256", String)

        module_function

        # The signature line for a header, or NONE when there is no key.
        sig { params(header_line: String, key: T.untyped).returns(String) }
        def sign(header_line, key)
          return NONE if key.nil?

          pkey = key!(key)
          algorithm = algorithm_for(pkey)
          "#{algorithm} #{[pkey.sign(OpenSSL::Digest.new(DIGEST), header_line)].pack("m0")}"
        end

        # Whether a line carries a signature at all.
        sig { params(line: T.untyped).returns(T::Boolean) }
        def signed?(line) = !line.nil? && line.to_s.strip != NONE && !line.to_s.strip.empty?

        # True when the signature on `line` was made over `header_line` by the
        # holder of `key`. Raises rather than answering false: a caller that
        # asked for verification and got a boolean it forgot to check would
        # screen against unverified data believing otherwise.
        sig { params(line: T.untyped, header_line: String, key: T.untyped).returns(T::Boolean) }
        def verify!(line, header_line, key)
          raise Unsigned, unsigned_message unless signed?(line)

          algorithm, encoded = split!(line)
          pkey = key!(key)
          expected!(algorithm, pkey)
          verified = begin
            pkey.verify(OpenSSL::Digest.new(DIGEST), decode!(encoded), header_line)
          rescue OpenSSL::OpenSSLError
            false
          end
          return true if verified

          raise UntrustedSignature, mismatch_message(algorithm)
        end

        # An OpenSSL key from what a caller supplied: a key, or a PEM.
        sig { params(value: T.untyped).returns(OpenSSL::PKey::PKey) }
        def key!(value)
          return value if value.is_a?(OpenSSL::PKey::PKey)

          if value.is_a?(String)
            begin
              return OpenSSL::PKey.read(value)
            rescue OpenSSL::OpenSSLError => e
              raise InvalidArgument, "the key given is not a readable PEM (#{e.message})"
            end
          end

          raise InvalidArgument,
                "a bundle is signed and verified with an OpenSSL::PKey or a PEM string, got #{value.class}. " \
                "Read a key file yourself -- OpenSSL::PKey.read(File.read(\"public.pem\"))"
        end

        # The format's name for the key's algorithm.
        sig { params(pkey: OpenSSL::PKey::PKey).returns(String) }
        def algorithm_for(pkey)
          name = ALGORITHMS.find { |_, kind| pkey.is_a?(kind) }&.first
          return name if name

          raise UnsupportedError,
                "a bundle cannot be signed with a #{pkey.class} key. The format defines " \
                "#{ALGORITHMS.keys.join(" and ")}, and reserves #{RESERVED_ALGORITHMS.join(", ")}"
        end

        # The two fields of a signature line.
        sig { params(line: T.untyped).returns([String, String]) }
        def split!(line)
          algorithm, encoded = line.to_s.strip.split(" ", 2)
          raise Corrupt, "#{line.to_s.strip.inspect} is not a signature line" if algorithm.nil? || encoded.nil?

          [algorithm, encoded]
        end

        # A signature this reader could verify if it had the right key, or the
        # exception that says why it never could.
        sig { params(algorithm: String, pkey: OpenSSL::PKey::PKey).void }
        def expected!(algorithm, pkey)
          unless ALGORITHMS.key?(algorithm)
            raise UnsupportedFormat, unsupported_message(algorithm) if RESERVED_ALGORITHMS.include?(algorithm)

            raise Corrupt, "#{algorithm.inspect} is not a signature algorithm this format defines"
          end
          return if pkey.is_a?(ALGORITHMS.fetch(algorithm))

          raise UntrustedSignature,
                "this bundle is signed #{algorithm}, and the key supplied is a #{pkey.class}. It was signed " \
                "by somebody else, or verification was pointed at the wrong key"
        end

        sig { params(encoded: String).returns(String) }
        def decode!(encoded)
          encoded.unpack1("m0")
        rescue ArgumentError
          raise Corrupt, "the signature is not base64"
        end

        sig { params(algorithm: String).returns(String) }
        def unsupported_message(algorithm)
          "this bundle is signed #{algorithm}, which active_sanction #{VERSION} reserves but does not verify. " \
            "Upgrade the gem, or read the bundle without verify_with: and accept that it is unverified"
        end

        sig { params(algorithm: String).returns(String) }
        def mismatch_message(algorithm)
          "this bundle's #{algorithm} signature was not made by the key supplied. The file is intact -- its " \
            "records still hash to what its header says -- but somebody other than the expected publisher " \
            "signed it, so nothing here says where it came from"
        end

        sig { returns(String) }
        def unsigned_message
          "this bundle carries no signature, and a key was supplied to verify one. An unsigned bundle is " \
            "readable without verify_with:, but then nothing attests to who published it"
        end
      end
    end
  end
end
