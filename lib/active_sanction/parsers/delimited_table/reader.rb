# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "csv"
require "stringio"

module ActiveSanction
  module Parsers
    class DelimitedTable
      # One pass over one payload. Enumerable, and lazy: rows are yielded as
      # they are read rather than collected, so a 5.6 MB list costs one row of
      # memory plus whatever the caller keeps.
      #
      #   reader = table.read(bytes)
      #   reader.each { |row| ... }
      #   reader.warnings          # => rows that could not be read
      #
      # Re-enumerating rewinds and starts over, which also resets #warnings --
      # so `reader.count` followed by `reader.warnings` reports the warnings
      # from the counting pass, not from two passes appended together.
      class Reader
        extend T::Sig
        extend T::Generic
        include Enumerable

        Elem = type_member { { fixed: Row } }

        # A parser that raises on every row is not isolating failures, it is
        # failing -- most often because the payload is not the format the table
        # was told to expect (an HTML error page saved as .csv is the classic).
        # Collecting 19,321 warnings to say so helps nobody.
        MAX_CONSECUTIVE_FAILURES = T.let(100, Integer)

        EOF = T.let(Object.new.freeze, Object)
        private_constant :EOF

        sig { returns(DelimitedTable) }
        attr_reader :table

        # The rows this pass could not read. Reset by each pass -- see the
        # class comment.
        sig { returns(T::Array[Warning]) }
        attr_reader :warnings

        sig { params(table: DelimitedTable, payload: T.untyped).void }
        def initialize(table:, payload:)
          @table = T.let(table, DelimitedTable)
          @payload = T.let(payload, T.untyped)
          @warnings = T.let([], T::Array[Warning])
        end

        sig { override.params(block: T.nilable(T.proc.params(row: Row).void)).returns(T.untyped) }
        def each(&block)
          return enum_for(:each) unless block

          csv = start
          columns = table.columns || header!(csv)
          consecutive = 0
          loop do
            values = shift(csv)
            break if values.equal?(EOF)

            consecutive = advance(consecutive, values)
            block.call(build(columns, values, csv.lineno)) unless values.nil?
          end
          self
        end

        # Every row, in memory. The convenience the small files get to use;
        # anything list-sized should stay with #each.
        sig { returns(T::Array[Row]) }
        def to_a = each.to_a

        private

        # Counts consecutive unreadable rows, and stops the pass once there
        # have been too many to be explained by anything but the wrong format.
        sig { params(consecutive: Integer, values: T.untyped).returns(Integer) }
        def advance(consecutive, values)
          return 0 unless values.nil?

          count = consecutive + 1
          give_up!(count) if count >= MAX_CONSECUTIVE_FAILURES
          count
        end

        sig { returns(CSV) }
        def start
          @warnings = []
          CSV.new(StringIO.new(payload!), **table.csv_options)
        end

        # No sanctions list has ever been published empty, so a payload with
        # nothing in it is a failed download, a moved URL or an outage -- never
        # a day on which nobody is sanctioned. Yielding no rows would let a
        # sync succeed at screening against nothing, which is the most
        # expensive way this library can fail, so it raises instead. The XML
        # reader refuses the same payload for the same reason.
        sig { returns(String) }
        def payload!
          string = decoded
          raise ParseError, "expected #{table.col_sep_name} rows, got an empty payload" if string.strip.empty?

          string
        end

        # Decoding happens once per pass rather than per row, and never raises.
        # Format#decode says why, and strips the BOM; what is left here is the
        # marker only a delimited file carries.
        sig { returns(String) }
        def decoded
          string, replaced = table.decode(@payload)
          record(0, table.invalid_bytes_message) if replaced
          trim(string)
        end

        # SUB (0x1A) is CP/M's end-of-file character, and DOS-lineage export
        # tooling still writes it: all three OFAC files end with `\r\n\x1A`.
        # Left alone it parses as a final one-column row, so every sync reports
        # a malformed row it can do nothing about -- and a warning that fires
        # every single time is a warning nobody reads.
        sig { params(string: String).returns(String) }
        def trim(string) = string.sub(/\r?\n?\x1A\s*\z/, "")

        # Column names taken from the file's own first row, lowercased and
        # snake_cased so that `City/State/Province/ZIP/Postal Code` and
        # `city_state_province_zip_postal_code` are the same column to an
        # adapter regardless of how the publisher capitalized it this quarter.
        # An empty payload has already been refused, so what is left to fail on
        # here is a first row that could not be read at all -- and a file whose
        # header is unreadable has no columns to name anything by.
        sig { params(csv: CSV).returns(T::Array[Symbol]) }
        def header!(csv)
          values = shift(csv)
          if values.nil? || values.equal?(EOF)
            raise ParseError.new("expected a header row, read nothing usable as one", line: 1)
          end

          values.map { |value| normalize_header(value) }
        end

        sig { params(value: T.untyped).returns(Symbol) }
        def normalize_header(value)
          value.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").delete_prefix("_").delete_suffix("_").to_sym
        end

        # Returns the row's values, EOF at the end of the payload, or nil for a
        # row that could not be parsed -- already recorded as a warning.
        sig { params(csv: CSV).returns(T.untyped) }
        def shift(csv)
          row = csv.shift
          row.nil? ? EOF : row
        rescue CSV::MalformedCSVError => e
          record(csv.lineno, "malformed #{table.col_sep_name}: #{e.message}")
          nil
        end

        sig { params(columns: T::Array[Symbol], values: T::Array[T.untyped], line: Integer).returns(Row) }
        def build(columns, values, line)
          record_arity(columns, values, line) unless values.size == columns.size
          Row.new(values: table.coerce(columns, values), line: line)
        end

        # A row of the wrong width is kept, not dropped. Short rows are padded
        # with nil and long ones keep their extra values under no name, because
        # a publisher appending a column mid-year should degrade the fields
        # nobody has mapped yet rather than the whole list.
        sig { params(columns: T::Array[Symbol], values: T::Array[T.untyped], line: Integer).void }
        def record_arity(columns, values, line)
          shape = values.size < columns.size ? "only #{values.size}" : values.size.to_s
          record(line, "expected #{columns.size} columns, got #{shape}", values.join(table.col_sep))
        end

        sig { params(line: T.nilable(Integer), message: String, snippet: T.untyped).void }
        def record(line, message, snippet = nil)
          @warnings << Warning.new(line: line, message: message, snippet: snippet)
        end

        sig { params(consecutive: Integer).void }
        def give_up!(consecutive)
          raise ParseError.new(
            "#{consecutive} consecutive rows could not be parsed. This payload is almost certainly not the " \
            "#{table.col_sep_name} it was read as -- check the URL, and whether the publisher served an " \
            "error page. First complaint: #{warnings.first}", line: warnings.first&.line
          )
        end
      end
    end
  end
end
