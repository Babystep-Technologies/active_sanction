# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/parsers/xml_records"

module ActiveSanction
  module Parsers
    class Spreadsheet
      # One pass over one workbook. Enumerable, and lazy in the same sense the
      # XML reader is: the sheet is streamed row by row, so what is held is one
      # row plus the shared string table -- which is not optional, a cell being
      # an offset into it.
      #
      #   reader = table.read(bytes)
      #   reader.each { |row| row[:reference] }
      #   reader.warnings          # => rows that could not be read
      #   reader.sheet_names       # => every sheet, whether or not it was read
      #
      # Re-enumerating re-reads from the start, which also resets #warnings --
      # so `reader.count` followed by `reader.warnings` reports the warnings
      # from the counting pass, not from two passes appended together. The ZIP
      # is unpacked once and reused across passes.
      class Reader
        extend T::Sig
        extend T::Generic
        include Enumerable

        Elem = type_member { { fixed: Row } }

        ROWS = T.let(Parsers::XmlRecords.new(records: %w[row]), Parsers::XmlRecords)

        # `A`, `AB`, `XFD`: the letters in a cell's `r="C7"` address, which is
        # the only thing that says which column a cell is in. A row states only
        # the cells that hold something, so position in the row means nothing.
        ADDRESS = T.let(/\A([A-Z]+)/, Regexp)

        LETTERS = T.let(26, Integer)

        DATE_FORMATS = T.let({ day: "%Y-%m-%d", month: "%Y-%m", year: "%Y" }.freeze, T::Hash[Symbol, String])

        sig { returns(Spreadsheet) }
        attr_reader :table

        sig { returns(T::Array[Warning]) }
        attr_reader :warnings

        sig { params(table: Spreadsheet, payload: T.untyped).void }
        def initialize(table:, payload:)
          @table = T.let(table, Spreadsheet)
          @payload = T.let(payload, T.untyped)
          @warnings = T.let([], T::Array[Warning])
          @workbook = T.let(nil, T.nilable(Workbook))
        end

        # The workbook's sheets, in the order it lists them. Worth printing when
        # a publisher adds a second tab: only one of them is being read.
        sig { returns(T::Array[String]) }
        def sheet_names = workbook.sheet_names

        # When the workbook says it was last saved -- see Workbook#modified.
        # Costs one part of the archive and no pass over the sheet.
        sig { returns(T.nilable(String)) }
        def modified = workbook.modified

        sig { override.params(block: T.nilable(T.proc.params(row: Row).void)).returns(T.untyped) }
        def each(&block)
          return enum_for(:each) unless block

          @warnings = []
          rows = ROWS.read(workbook.sheet(table.sheet))
          columns = T.let(nil, T.nilable(T::Array[Symbol]))
          rows.each do |node|
            cells = read_row(node)
            columns = table.columns || header!(cells, node) and next if columns.nil?

            # A `<row>` with no cell holding anything is spacing, not a record.
            block.call(build(columns, cells, number(node))) if cells.any?
          end
          @warnings.concat(rows.warnings)
          self
        end

        # Every row, in memory. The convenience the small sheets get to use.
        sig { returns(T::Array[Row]) }
        def to_a = each.to_a

        sig { returns(String) }
        def inspect = "#<#{self.class} #{table.sheet_name} of #{sheet_names.size} sheet(s)>"

        private

        sig { returns(Workbook) }
        def workbook
          @workbook ||= Workbook.new(table: table, archive: Archive.new(@payload))
        end

        # Column index to value, indexed from the cell's own address so that a
        # row which states only the cells it filled still lines up with the
        # header. Nothing here assumes the row is contiguous, because it is not:
        # a row whose first two cells are empty starts at `C`.
        sig { params(node: Parsers::XmlRecords::Record).returns(T::Hash[Integer, String]) }
        def read_row(node)
          node.nodes("c").each_with_object({}) do |cell, values|
            index = column_index(cell.attribute("r"))
            value = table.value(cell_value(cell))
            values[index] = value if index && value
          end
        end

        # `C` is 2, `AA` is 26, in the bijective base-26 a spreadsheet numbers
        # its columns with.
        sig { params(address: T.nilable(String)).returns(T.nilable(Integer)) }
        def column_index(address)
          letters = ADDRESS.match(address.to_s)&.captures&.first
          return nil if letters.nil?

          letters.each_char.inject(0) { |index, letter| (index * LETTERS) + (letter.ord - 64) } - 1
        end

        # A cell states its type in `t` and its value in `<v>` -- except an
        # inline string, which is the one shape that carries its text where a
        # shared string's offset would be.
        sig { params(cell: Parsers::XmlRecords::Record).returns(T.nilable(String)) }
        def cell_value(cell)
          case cell.attribute("t")
          when "s" then shared(cell["v"])
          when "inlineStr" then table.unescape(cell.values("is/t").join)
          when "b" then cell["v"] == "1" ? "TRUE" : "FALSE"
          when "str", "e", "d" then cell["v"]
          else numeric(cell)
          end
        end

        sig { params(offset: T.nilable(String)).returns(T.nilable(String)) }
        def shared(offset) = offset.nil? ? nil : workbook.strings[offset.to_i]

        # A number is a date when the cell's style says it is displayed as one,
        # and is otherwise passed through as the publisher wrote it -- `1963`
        # stays `1963`, because a year is not a date and rendering it as one
        # would invent a January the 1st nobody published.
        sig { params(cell: Parsers::XmlRecords::Record).returns(T.nilable(String)) }
        def numeric(cell)
          raw = cell["v"]
          precision = workbook.precision(cell.attribute("s")&.to_i)
          return raw if raw.nil? || precision.nil?

          formatted(raw, precision) || raw
        end

        # ISO 8601, truncated to what the cell's format actually displays: a
        # `mmm-yy` cell says a month and its serial's day is whatever Excel
        # needed to store one. PartialDate::Parser reads all three shapes, so an
        # adapter gets the publisher's own precision without a format of its own.
        sig { params(raw: String, precision: Symbol).returns(T.nilable(String)) }
        def formatted(raw, precision)
          workbook.date(raw)&.strftime(DATE_FORMATS.fetch(precision))
        end

        # Column names from the sheet's own first row, normalized the way the
        # delimited reader normalizes a CSV header, so that `Name of Individual
        # or Entity` and `name_of_individual_or_entity` are the same column
        # however the publisher capitalized it this quarter.
        sig { params(cells: T::Hash[Integer, String], node: Parsers::XmlRecords::Record).returns(T::Array[Symbol]) }
        def header!(cells, node)
          raise ParseError.new("expected a header row, and it is empty", line: number(node)) if cells.empty?

          (0..T.must(cells.keys.max)).map { |index| normalize_header(cells[index], index) }
        end

        # A header cell the publisher left blank still names a column, because
        # the columns after it have to keep their positions.
        sig { params(value: T.nilable(String), index: Integer).returns(Symbol) }
        def normalize_header(value, index)
          name = value.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").delete_prefix("_").delete_suffix("_")
          name.empty? ? :"column_#{index + 1}" : name.to_sym
        end

        sig { params(node: Parsers::XmlRecords::Record).returns(Integer) }
        def number(node) = node.attribute("r")&.to_i || node.line || 0

        sig do
          params(columns: T::Array[Symbol], cells: T::Hash[Integer, String], number: Integer).returns(Row)
        end
        def build(columns, cells, number)
          record_width(columns, cells, number)
          Row.new(values: table.coerce(columns, cells), number: number)
        end

        # A row with a value in a column the header never named is kept, and the
        # extra value is dropped rather than the row. A publisher appending a
        # column mid-year should degrade the fields nobody has mapped yet, not
        # the whole list -- but it must say so, because a column silently
        # ignored is how a new sanctions measure stops being read.
        sig { params(columns: T::Array[Symbol], cells: T::Hash[Integer, String], number: Integer).void }
        def record_width(columns, cells, number)
          beyond = cells.keys.select { |index| index >= columns.size }
          return if beyond.empty?

          @warnings << Warning.new(
            line: number,
            message: "row #{number} holds #{beyond.size} value(s) past the #{columns.size} column(s) " \
                     "this sheet named",
            snippet: beyond.map { |index| cells[index] }.join(" | ")
          )
        end
      end
    end
  end
end
