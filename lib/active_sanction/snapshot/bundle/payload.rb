# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "digest"
require "zlib"
require "active_sanction/error"

module ActiveSanction
  class Snapshot
    module Bundle
      # The records half of a bundle: newline-delimited JSON, deflated, with a
      # SHA-256 over what it says before it was compressed.
      #
      # Two rules are worth stating outright, because between them they are why
      # a bundle can be published once and trusted everywhere.
      #
      # ### The digest is over the uncompressed bytes
      #
      # zlib builds disagree. The same records fed to zlib 1.3 and to zlib-ng
      # at the same level can come out as different bytes, so a digest over the
      # compressed stream would make "the same snapshot produces the same
      # bundle" a claim about which Linux distribution built somebody's Ruby.
      # Over the records it is a claim about the records, which is the one worth
      # signing.
      #
      # ### Reading never holds the whole list
      #
      # `.unpack` inflates in 64 KiB pieces and yields one record at a time, so
      # a 25 MB EU bundle is read with a buffer of one chunk plus one line
      # rather than with a decompressed copy beside the entities being built
      # from it. The digest is accumulated on the way past.
      #
      # It also refuses to inflate more than the header declared. A file that
      # says it holds 48 MB and keeps producing bytes at 49 MB is either damaged
      # or built to exhaust whoever opens it, and either way there is nothing to
      # gain by decompressing the rest of it.
      #
      # @api private
      module Payload
        extend T::Sig
        extend T::Helpers

        # Called as `Payload.pack` -- module functions on a module, which is an
        # Object, which is where `raise` comes from.
        requires_ancestor { Kernel }

        # How much compressed input is inflated at a time. The same 64 KiB
        # PayloadCache digests a download in, and for the same reason.
        CHUNK_SIZE = T.let(64 * 1024, Integer)

        # Named rather than Zlib::DEFAULT_COMPRESSION, which is -1 and means
        # "whatever this build calls default". Two writers of one snapshot
        # should not produce different files because one of them linked a
        # different zlib, and a level in the specification is what a non-Ruby
        # implementation has to be told anyway.
        COMPRESSION_LEVEL = T.let(6, Integer)

        module_function

        # Compresses `records` -- JSON strings, one per entity, in the order
        # they belong in -- and returns the compressed bytes, the digest of the
        # uncompressed stream, and its length.
        #
        # Compressed output is buffered rather than streamed to the file,
        # because the header that has to be written *before* it states its
        # digest and its length, and neither is known until the last record has
        # gone past. The snapshot is already wholly in memory by then; this adds
        # the compressed copy of it, which for the largest list published is
        # about 25 MB and is released as soon as it is written.
        sig { params(records: T::Enumerable[String]).returns([String, String, Integer]) }
        def pack(records)
          digest = Digest::SHA256.new
          deflate = Zlib::Deflate.new(COMPRESSION_LEVEL)
          bytes = T.let(0, Integer)
          compressed = String.new(encoding: Encoding::BINARY)
          begin
            records.each do |record|
              line = "#{record}\n"
              digest << line
              bytes += line.bytesize
              compressed << deflate.deflate(line)
            end
            compressed << deflate.finish
          ensure
            deflate.close
          end
          [compressed, -"#{Snapshot::ALGORITHM}:#{digest.hexdigest}", bytes]
        end

        # Inflates the rest of `io`, yielding each record as the JSON string it
        # was written as, and returns the digest and length of what it read so
        # a caller can hold them against what the header promised.
        sig do
          params(io: T.untyped, limit: Integer, block: T.proc.params(record: String).void).returns([String, Integer])
        end
        def unpack(io, limit:, &block)
          digest = Digest::SHA256.new
          bytes = T.let(0, Integer)
          buffer = String.new(encoding: Encoding::BINARY)
          inflate = Zlib::Inflate.new
          fed = T.let(0, Integer)
          begin
            while (chunk = io.read(CHUNK_SIZE))
              fed += chunk.bytesize
              buffer << inflate!(inflate, chunk)
              bytes = drain(buffer, bytes, limit, digest, &block)
            end
            bytes = finish(inflate, buffer, bytes, limit, digest, &block)
            trailing!(fed, inflate.total_in)
          ensure
            inflate.close unless inflate.closed?
          end
          [-"#{Snapshot::ALGORITHM}:#{digest.hexdigest}", bytes]
        end

        # Every complete line the buffer now holds, leaving any partial one
        # behind for the next chunk.
        sig do
          params(buffer: String, bytes: Integer, limit: Integer, digest: Digest::SHA256,
                 block: T.proc.params(record: String).void).returns(Integer)
        end
        def drain(buffer, bytes, limit, digest, &block)
          total = bytes
          while (index = buffer.index("\n"))
            line = T.must(buffer.slice!(0, index + 1))
            digest << line
            total += line.bytesize
            oversized!(total, limit)
            block.call(line.chomp.force_encoding(Encoding::UTF_8))
          end
          total
        end

        # What is left when the compressed stream ends: nothing, if the writer
        # terminated its last record. A trailing partial line is a truncated
        # file and says so.
        sig do
          params(inflate: Zlib::Inflate, buffer: String, bytes: Integer, limit: Integer, digest: Digest::SHA256,
                 block: T.proc.params(record: String).void).returns(Integer)
        end
        def finish(inflate, buffer, bytes, limit, digest, &block)
          buffer << inflate.finish unless inflate.finished?
          total = drain(buffer, bytes, limit, digest, &block)
          return total if buffer.empty?

          raise Corrupt, "the last record in this bundle is unterminated, so the payload was cut short"
        rescue Zlib::Error => e
          raise Corrupt, "this bundle's payload ends mid-stream and cannot be decompressed (#{e.message})"
        end

        sig { params(inflate: Zlib::Inflate, chunk: String).returns(String) }
        def inflate!(inflate, chunk)
          inflate.inflate(chunk)
        rescue Zlib::Error => e
          raise Corrupt, "this bundle's payload is not readable as #{COMPRESSION} (#{e.message})"
        end

        # Bytes after the end of the compressed stream. zlib stops reading at
        # the end of what it was given and would let them pass unmentioned,
        # which would make a bundle somebody appended to indistinguishable from
        # the one that was signed.
        sig { params(fed: Integer, consumed: Integer).void }
        def trailing!(fed, consumed)
          return if fed <= consumed

          raise Corrupt,
                "this bundle carries #{fed - consumed} bytes after the end of its payload. Nothing was written " \
                "there, so something else put them there"
        end

        sig { params(total: Integer, limit: Integer).void }
        def oversized!(total, limit)
          return if total <= limit

          raise Corrupt,
                "this bundle's payload decompresses to more than the #{limit} bytes its header declares. " \
                "Nothing further is read: a file that lies about its own size is either damaged or built to " \
                "exhaust whoever opens it"
        end
      end
    end
  end
end
