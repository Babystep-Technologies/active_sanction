# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "digest"

module ActiveSanction
  class PayloadCache
    # The content address of a payload: `sha256:<64 hex digits>`, the same form
    # Snapshot stamps on a parsed list, so a payload and the snapshot parsed
    # from it are quoted the same way in an audit trail.
    #
    # It is a module rather than a pair of methods on the cache because two
    # things depend on it and one guarantee rests on it: every filename this
    # library builds under the cache directory comes from .normalize!, so a
    # checksum that arrived from a database column or a URL parameter cannot
    # become a directory traversal. Anything that is not a SHA-256 raises here,
    # before it is joined to a path.
    module Checksum
      extend T::Sig
      extend T::Helpers

      # Called as `Checksum.normalize!` -- module functions on a module, which
      # is an Object, which is where `raise` comes from.
      requires_ancestor { Kernel }

      ALGORITHM = T.let("sha256", String)

      # With or without the prefix: callers copy checksums out of log lines and
      # database columns, and both forms show up there.
      PATTERN = T.let(/\A(?:#{ALGORITHM}[:-])?(\h{64})\z/i, Regexp)

      # Payloads run to 126 MB, so they are digested in pieces. A cache that
      # had to hold a list in memory to verify it would defeat the point of
      # having streamed it to disk in the first place.
      CHUNK_SIZE = T.let(64 * 1024, Integer)

      module_function

      sig { params(value: T.untyped).returns(String) }
      def normalize!(value)
        match = PATTERN.match(value.to_s.strip)
        raise InvalidArgument, "#{value.inspect} is not a #{ALGORITHM} checksum" if match.nil?

        -"#{ALGORITHM}:#{T.must(match[1]).downcase}"
      end

      sig { params(path: T.untyped).returns(String) }
      def of_file(path)
        digest = Digest::SHA256.new
        ::File.open(path, "rb") do |file|
          while (chunk = file.read(CHUNK_SIZE))
            digest << chunk
          end
        end
        -"#{ALGORITHM}:#{digest.hexdigest}"
      end

      # The hex digits without the algorithm prefix, for comparing against a
      # checksum a publisher printed on its download page.
      sig { params(checksum: T.untyped).returns(T.nilable(String)) }
      def hex(checksum) = checksum.to_s.split(":").last
    end
  end
end
