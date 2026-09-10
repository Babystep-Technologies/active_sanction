# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "zlib"

module ActiveSanction
  module Parsers
    class Spreadsheet
      # The ZIP container an .xlsx workbook arrives in, read with nothing but
      # `zlib`.
      #
      #   archive = Archive.new(bytes)
      #   archive.names             # => ["[Content_Types].xml", "xl/workbook.xml", ...]
      #   archive.fetch("xl/workbook.xml")   # => "<?xml version=..."
      #
      # ### Why this is here rather than in a gem
      #
      # An .xlsx file is a ZIP of XML parts, and the gem already reads XML. The
      # only thing standing between it and a spreadsheet is the container, and
      # the container is a 1990 format with a fixed-width header -- a hundred
      # lines of unpacking, against a spreadsheet gem that would be the first
      # third-party dependency this library has taken for one publisher's
      # choice of file format. The gemspec's rule is that a compliance library
      # should not be the reason a deployment installs something; that rule is
      # worth more than the hundred lines.
      #
      # What is deliberately not implemented is everything a *general* ZIP
      # reader needs and a published spreadsheet never uses: encryption, spanned
      # archives, and ZIP64. Each of them raises by name rather than being
      # half-read, because a container this cannot read is a payload that must
      # not be parsed as though it were empty.
      #
      # ### Read from the central directory, not from the local headers
      #
      # A ZIP entry's sizes appear twice -- once in the central directory at the
      # end of the file and once in the local header in front of the bytes --
      # and the local copy is allowed to be zeroes, with the real sizes written
      # in a data descriptor *after* the compressed data. Excel does exactly
      # that on some writes. So sizes and offsets are taken from the central
      # directory, which is authoritative, and the local header is read only for
      # the two lengths that say where the entry's bytes actually begin.
      #
      # @api private
      class Archive
        extend T::Sig

        EOCD_SIGNATURE = T.let("PK\x05\x06".b, String)
        CENTRAL_SIGNATURE = T.let("PK\x01\x02".b, String)
        LOCAL_SIGNATURE = T.let("PK\x03\x04".b, String)

        # 22 bytes of fixed header plus a comment that the format caps at 64 KB.
        EOCD_FIXED = T.let(22, Integer)
        MAX_COMMENT = T.let(0xFFFF, Integer)

        CENTRAL_FIXED = T.let(46, Integer)
        LOCAL_FIXED = T.let(30, Integer)

        STORED = T.let(0, Integer)
        DEFLATED = T.let(8, Integer)

        # The value every ZIP64 field is replaced by in the 32-bit record that
        # cannot hold it. Seeing one means the real number is in an extra field
        # this does not read -- see the class comment.
        OVERFLOW_32 = T.let(0xFFFFFFFF, Integer)
        OVERFLOW_16 = T.let(0xFFFF, Integer)

        # General purpose bit 0. Set on an entry whose bytes are encrypted,
        # which inflates to noise rather than failing, so it is refused here.
        ENCRYPTED = T.let(0x0001, Integer)

        # A raw deflate stream -- no zlib header, no adler checksum -- which is
        # what a ZIP entry holds and what a negative window size selects.
        RAW_DEFLATE = T.let(-Zlib::MAX_WBITS, Integer)

        sig { params(payload: T.untyped).void }
        def initialize(payload)
          @bytes = T.let(binary(payload), String)
          @entries = T.let(read_central_directory, T::Hash[String, T::Hash[Symbol, Integer]])
        end

        # The part names in the archive, in central-directory order.
        sig { returns(T::Array[String]) }
        def names = @entries.keys

        sig { params(name: T.untyped).returns(T::Boolean) }
        def include?(name) = @entries.key?(name.to_s)

        # One part's bytes, decompressed, or nil when the archive has no such
        # part. The parts of a workbook are all XML, and the XML reader decodes
        # them, so what comes back here is binary.
        sig { params(name: T.untyped).returns(T.nilable(String)) }
        def [](name)
          entry = @entries[name.to_s]
          entry.nil? ? nil : extract(name.to_s, entry)
        end

        # For a part the caller cannot proceed without. Names what the archive
        # does hold, because the usual cause of a missing part is that the
        # payload is not the workbook it was taken for.
        sig { params(name: T.untyped).returns(String) }
        def fetch(name)
          self[name] || raise(ParseError, "#{name.to_s.inspect} is not in this archive. It holds: #{names.join(", ")}")
        end

        sig { returns(String) }
        def inspect = "#<#{self.class} #{@entries.size} part(s)>"

        private

        sig { params(payload: T.untyped).returns(String) }
        def binary(payload)
          string = payload.to_s
          string.encoding == Encoding::BINARY ? string : string.dup.force_encoding(Encoding::BINARY)
        end

        # The end-of-central-directory record is the only fixed landmark in a
        # ZIP, and it is at the end -- behind a comment of unknown length, so it
        # is searched for backwards. A payload with no such record is not a
        # truncated spreadsheet that could be salvaged; it is a file whose index
        # was never received, and none of the entries can be located without it.
        sig { returns(Integer) }
        def eocd_offset
          last = @bytes.bytesize - EOCD_FIXED
          offset = last.negative? ? nil : @bytes.rindex(EOCD_SIGNATURE, last)
          return offset if offset && offset >= last - MAX_COMMENT

          raise ParseError,
                "expected a ZIP archive (an .xlsx workbook is one), and found no end-of-central-directory " \
                "record in #{@bytes.bytesize} byte(s) -- the payload is truncated, or is not a workbook"
        end

        sig { returns(T::Hash[String, T::Hash[Symbol, Integer]]) }
        def read_central_directory
          eocd = eocd_offset
          count, size, start = @bytes[eocd + 10, 12].to_s.unpack("vVV")
          refuse_zip64!(count, start)
          walk_central_directory(Integer(start), Integer(size), Integer(count))
        end

        sig { params(count: T.untyped, start: T.untyped).void }
        def refuse_zip64!(count, start)
          return unless count == OVERFLOW_16 || start == OVERFLOW_32

          raise ParseError,
                "this is a ZIP64 archive, which this reader does not implement. No published sanctions list is " \
                "anywhere near the 4 GB that requires one, so the payload is almost certainly not a workbook"
        end

        sig { params(start: Integer, size: Integer, count: Integer).returns(T::Hash[String, T::Hash[Symbol, Integer]]) }
        def walk_central_directory(start, size, count)
          entries = {}
          offset = start
          finish = start + size
          count.times do
            break if offset + CENTRAL_FIXED > finish

            name, entry, offset = read_central_entry(offset)
            entries[name] = entry
          end
          entries
        end

        sig { params(offset: Integer).returns([String, T::Hash[Symbol, Integer], Integer]) }
        def read_central_entry(offset)
          header = @bytes[offset, CENTRAL_FIXED].to_s
          unless header.start_with?(CENTRAL_SIGNATURE)
            raise ParseError.new("the central directory ends inside an entry header", offset: offset)
          end

          entry = central_entry(header)
          lengths = header[28, 6].to_s.unpack("vvv").map { |length| Integer(length) }
          name = @bytes[offset + CENTRAL_FIXED, T.must(lengths.first)].to_s.force_encoding(Encoding::UTF_8)
          [name, entry, offset + CENTRAL_FIXED + lengths.sum]
        end

        # Flags, compression method, both sizes and where the entry's local
        # header sits. The four bytes skipped are the modification timestamp,
        # and the four after them the CRC, which the size check below stands in
        # for -- a part that inflates to the stated length has not been
        # truncated, and a part whose deflate stream is damaged raises out of
        # zlib before it can be measured.
        sig { params(header: String).returns(T::Hash[Symbol, Integer]) }
        def central_entry(header)
          flags, method, compressed, uncompressed = header[8, 20].to_s.unpack("vvx8VV")
          { flags: Integer(flags), method: Integer(method), compressed: Integer(compressed),
            uncompressed: Integer(uncompressed), local: Integer(header[42, 4].to_s.unpack1("V")) }
        end

        sig { params(name: String, entry: T::Hash[Symbol, Integer]).returns(String) }
        def extract(name, entry)
          refuse_unreadable!(name, entry)
          data = @bytes[data_offset(name, entry), Integer(entry.fetch(:compressed))].to_s
          bytes = entry.fetch(:method) == STORED ? data : inflate(name, data)
          verify_size!(name, bytes, Integer(entry.fetch(:uncompressed)))
          bytes
        end

        sig { params(name: String, entry: T::Hash[Symbol, Integer]).void }
        def refuse_unreadable!(name, entry)
          if entry.fetch(:flags).anybits?(ENCRYPTED)
            raise ParseError, "#{name.inspect} is encrypted, and this reader holds no password"
          end
          if entry.values_at(:compressed, :uncompressed, :local).include?(OVERFLOW_32)
            raise ParseError, "#{name.inspect} states its size in a ZIP64 extra field, which this reader does not read"
          end
          return if [STORED, DEFLATED].include?(entry.fetch(:method))

          raise ParseError,
                "#{name.inspect} is stored with compression method #{entry.fetch(:method)}, and this reader " \
                "implements only stored (0) and deflate (8), which is everything a spreadsheet writer emits"
        end

        # The local header repeats the name and carries its own extra field,
        # and the two lengths are the only thing read from it -- see the class
        # comment on why the sizes are not.
        sig { params(name: String, entry: T::Hash[Symbol, Integer]).returns(Integer) }
        def data_offset(name, entry)
          offset = Integer(entry.fetch(:local))
          header = @bytes[offset, LOCAL_FIXED].to_s
          unless header.start_with?(LOCAL_SIGNATURE)
            raise ParseError.new("the central directory points at #{name.inspect}, which is not a local header",
                                 offset: offset)
          end

          name_length, extra_length = header[26, 4].to_s.unpack("vv")
          offset + LOCAL_FIXED + Integer(name_length) + Integer(extra_length)
        end

        sig { params(name: String, data: String).returns(String) }
        def inflate(name, data)
          stream = Zlib::Inflate.new(RAW_DEFLATE)
          begin
            stream.inflate(data) << stream.finish
          ensure
            stream.close
          end
        rescue Zlib::Error => e
          raise ParseError, "#{name.inspect} could not be decompressed: #{e.class} #{e.message}"
        end

        # The central directory states what the part should weigh, and a part
        # that arrives short is a truncated download rather than a shorter
        # spreadsheet. Saying so here is what stops half a sanctions list being
        # parsed as though it were the whole one.
        sig { params(name: String, bytes: String, expected: Integer).void }
        def verify_size!(name, bytes, expected)
          return if expected.zero? || bytes.bytesize == expected

          raise ParseError,
                "#{name.inspect} unpacked to #{bytes.bytesize} byte(s) where the archive's own index says " \
                "#{expected} -- the payload is truncated or corrupt"
        end
      end
    end
  end
end
