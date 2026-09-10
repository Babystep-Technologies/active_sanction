# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "date"
require "active_sanction/parsers/xml_records"

module ActiveSanction
  module Parsers
    class Spreadsheet
      # The three parts of a workbook that have to be read before a single cell
      # means anything: which part holds the sheet, what the shared strings are,
      # and which cell styles are dates.
      #
      #   workbook = Workbook.new(table: table, archive: archive)
      #   workbook.sheet_names            # => ["Consolidated List"]
      #   workbook.strings[19]            # => "MOHAMMAD HASSAN AKHUND"
      #   workbook.precision(5)           # => :day
      #
      # ### A spreadsheet does not store text, or dates, in its cells
      #
      # Two indirections stand between a cell and its value, and both are here.
      #
      # **Text lives in a separate part.** A cell of type `s` holds an offset
      # into `xl/sharedStrings.xml`, which is how one workbook stores 109,264
      # cells as 24,467 distinct strings. A reader that skipped that part would
      # produce a list of integers.
      #
      # **A date is a number plus a display format.** `18798` is a date if the
      # cell's style formats it as one and the year 18798 if it does not, and
      # the file says which only in `xl/styles.xml`. The Australian list turns
      # on exactly this: 4,194 of its birth dates are serial numbers whose style
      # is `m/d/yyyy`, and 2,711 are the *year* the person was born written as a
      # plain number under the General format. Read without the styles they are
      # the same thing, and one of the two readings is wrong for every row.
      #
      # @api private
      class Workbook
        extend T::Sig

        WORKBOOK = T.let("xl/workbook.xml", String)
        RELATIONSHIPS = T.let("xl/_rels/workbook.xml.rels", String)
        CORE = T.let("docProps/core.xml", String)
        BASE = T.let("xl/", String)

        SHEETS = T.let(Parsers::XmlRecords.new(records: %w[sheet workbookPr]), Parsers::XmlRecords)
        LINKS = T.let(Parsers::XmlRecords.new(records: %w[Relationship]), Parsers::XmlRecords)
        STRINGS = T.let(Parsers::XmlRecords.new(records: %w[si]), Parsers::XmlRecords)
        STYLES = T.let(Parsers::XmlRecords.new(records: %w[numFmt cellXfs]), Parsers::XmlRecords)
        CORE_PROPERTIES = T.let(Parsers::XmlRecords.new(records: %w[modified]), Parsers::XmlRecords)

        # The date formats every spreadsheet writer has without declaring them,
        # from ECMA-376 -- and only the ones that carry a date. 18 to 21, 45, 46
        # and 47 are times, whose serial fraction says nothing about a day.
        BUILTIN_FORMATS = T.let(
          { 14 => "mm-dd-yy", 15 => "d-mmm-yy", 16 => "d-mmm", 17 => "mmm-yy", 22 => "m/d/yy h:mm" }.freeze,
          T::Hash[Integer, String]
        )

        # What a format code says once its literal text is out of the way: an
        # `m` means a month beside a `y` and minutes beside an `h`, so year is
        # what makes the difference and `d` settles the precision on its own.
        LITERALS = T.let(%r{"[^"]*"|\[[^\]]*\]|\\.|AM/PM|A/P}i, Regexp)

        # Serial 0 is 1900-01-00 and serial 60 is 1900-02-29, neither of which
        # exists: Lotus 1-2-3 treated 1900 as a leap year and every spreadsheet
        # since has kept the bug for compatibility. So the epoch that makes the
        # arithmetic come out right is two days before 1900-01-01 for serials
        # past the phantom day, and one day before it for the 59 below it.
        EPOCH_1900 = T.let(Date.new(1899, 12, 30), Date)
        LEAP_BUG_EPOCH = T.let(Date.new(1899, 12, 31), Date)
        LEAP_BUG_SERIAL = T.let(60, Integer)

        # The other date system, which Excel for Mac wrote until 2011 and which
        # a workbook declares on `<workbookPr date1904="1">`.
        EPOCH_1904 = T.let(Date.new(1904, 1, 1), Date)

        # Serials outside this are not dates anybody typed. The low end rejects
        # a plain small number that happens to sit in a date-formatted cell; the
        # high end is the year 9999, past which Date arithmetic is answering a
        # question nobody asked.
        SERIALS = T.let(1..2_958_465, T::Range[Integer])

        sig { returns(Archive) }
        attr_reader :archive

        sig { params(table: Spreadsheet, archive: Archive).void }
        def initialize(table:, archive:)
          @table = T.let(table, Spreadsheet)
          @archive = T.let(archive, Archive)
          @sheets = T.let(nil, T.nilable(T::Array[[String, String]]))
          @strings = T.let(nil, T.nilable(T::Array[String]))
          @precisions = T.let(nil, T.nilable(T::Array[T.nilable(Symbol)]))
          @date1904 = T.let(nil, T.nilable(T::Boolean))
        end

        # The sheet names, in the order the workbook lists them.
        sig { returns(T::Array[String]) }
        def sheet_names = sheets.map(&:first)

        # The bytes of the sheet a caller asked for by name, by zero-based
        # index, or -- passing nil -- of the first one, which is the whole
        # workbook for every list that publishes as a spreadsheet.
        sig { params(wanted: T.untyped).returns(String) }
        def sheet(wanted = nil)
          archive.fetch(sheet_part(wanted))
        end

        # The shared string table, indexed the way a cell of type `s` indexes
        # it. Empty for a workbook that has no such part, which is legal and
        # means every string in it is inline.
        sig { returns(T::Array[String]) }
        def strings
          @strings ||= read_strings
        end

        # What a cell carrying this style index means by a number: :day, :month
        # or :year for the date formats, nil for everything else -- which is
        # every General, numeric and text format, and every time-only one.
        sig { params(style: T.nilable(Integer)).returns(T.nilable(Symbol)) }
        def precision(style)
          return nil if style.nil?

          precisions[style]
        end

        # A serial number as the date its workbook means by it, or nil for one
        # outside the range any real date occupies. The fractional part is the
        # time of day and is dropped: a spreadsheet's date cell carries one
        # whether or not anybody typed one.
        sig { params(serial: T.untyped).returns(T.nilable(Date)) }
        def date(serial)
          number = Float(serial, exception: false)
          return nil if number.nil?

          days = number.floor
          return nil unless SERIALS.cover?(days)
          return EPOCH_1904 + days if date1904?

          days > LEAP_BUG_SERIAL ? EPOCH_1900 + days : LEAP_BUG_EPOCH + days
        end

        # When the workbook was last saved, as its own core properties record it
        # -- `2026-09-04T05:37:12Z`. A publisher who exports a fresh spreadsheet
        # on every update stamps the export here, which makes it a version
        # marker from inside the document rather than from the HTTP response.
        # nil for a workbook that carries no core properties, which is legal.
        sig { returns(T.nilable(String)) }
        def modified
          part = archive[CORE]
          return nil if part.nil?

          CORE_PROPERTIES.read(part).first&.text
        end

        # Whether the workbook counts its days from 1904 rather than from 1900.
        sig { returns(T::Boolean) }
        def date1904?
          read_sheets if @date1904.nil?
          @date1904 || false
        end

        sig { returns(String) }
        def inspect = "#<#{self.class} #{sheet_names.join(", ")}>"

        private

        sig { returns(Spreadsheet) }
        attr_reader :table

        sig { params(wanted: T.untyped).returns(String) }
        def sheet_part(wanted)
          return by_index(Integer(wanted)) if wanted.is_a?(Integer)
          return by_name(wanted.to_s) unless wanted.nil?

          by_index(0)
        end

        sig { params(index: Integer).returns(String) }
        def by_index(index)
          found = sheets[index]
          return found.last if found

          raise ParseError,
                "this workbook has #{sheets.size} sheet(s), so there is no sheet #{index}: #{sheet_names.join(", ")}"
        end

        sig { params(name: String).returns(String) }
        def by_name(name)
          found = sheets.find { |sheet_name, _part| sheet_name == name }
          return found.last if found

          raise ParseError, "this workbook has no sheet named #{name.inspect}. It has: #{sheet_names.join(", ")}"
        end

        sig { returns(T::Array[[String, String]]) }
        def sheets
          @sheets ||= read_sheets
        end

        # `<sheet name="Consolidated List" r:id="rId1"/>` says which sheet is
        # which, and the relationship that `rId1` names says which part holds
        # it. Neither half is optional: a workbook is free to store its first
        # sheet in `sheet3.xml`, and several do.
        sig { returns(T::Array[[String, String]]) }
        def read_sheets
          @date1904 = false
          targets = relationships
          named = SHEETS.read(archive.fetch(WORKBOOK)).filter_map { |node| declared_sheet(node, targets) }
          return named if named.any?

          raise ParseError, "#{WORKBOOK} declares no sheets, so this payload is not a workbook this can read"
        end

        sig do
          params(node: Parsers::XmlRecords::Record, targets: T::Hash[String, String])
            .returns(T.nilable([String, String]))
        end
        def declared_sheet(node, targets)
          if node.name == "workbookPr"
            @date1904 = %w[1 true].include?(node.attribute("date1904").to_s)
            return nil
          end

          part = targets[node.attribute("id").to_s]
          part.nil? ? nil : [node.attribute("name").to_s, part]
        end

        # Relationship id to part name, with the target resolved against `xl/`,
        # which is the directory the workbook part lives in. A writer may state
        # the target absolutely instead, and OpenOffice does.
        sig { returns(T::Hash[String, String]) }
        def relationships
          LINKS.read(archive.fetch(RELATIONSHIPS)).to_h do |node|
            target = node.attribute("Target").to_s
            [node.attribute("Id").to_s, target.start_with?("/") ? target.delete_prefix("/") : "#{BASE}#{target}"]
          end
        end

        # ### What a rich-text string loses here
        #
        # A shared string may be split into runs -- `<si><r><t>` -- when parts
        # of it are styled differently, and whitespace at a run boundary does
        # not survive being read element by element. No sanctions list has ever
        # published one: this workbook's 24,467 strings contain not a single
        # `<r>`, and a publisher who started styling half a name would be doing
        # something no reader of the list wants. The phonetic guides in `<rPh>`
        # are skipped, being a Japanese reading aid rather than part of the
        # string.
        sig { returns(T::Array[String]) }
        def read_strings
          part = archive["xl/sharedStrings.xml"]
          return [] if part.nil?

          STRINGS.read(part).map { |node| table.unescape(runs(node)).to_s }
        end

        sig { params(node: Parsers::XmlRecords::Record).returns(String) }
        def runs(node)
          return node.text.to_s if node.name == "t"

          node.children.reject { |child| child.name == "rPh" }.map { |child| runs(child) }.join
        end

        # `<cellXfs>` is a list of cell formats, and a cell's `s` attribute is
        # an index into it; each entry names a number format by id. Read once
        # into a flat array, because it is asked of every numeric cell in the
        # sheet.
        sig { returns(T::Array[T.nilable(Symbol)]) }
        def precisions
          @precisions ||= read_precisions
        end

        # `<numFmt>` and `<cellXfs>` arrive in one pass, and the order the file
        # puts them in is the order they are needed: the schema requires
        # `<numFmts>` before `<cellXfs>`.
        #
        # It has to be `<cellXfs>` and not every `<xf>` in the part. `<xf>` also
        # appears inside `<cellStyleXfs>`, which precedes it and holds the named
        # styles a cell format inherits from -- collecting both would shift every
        # index by the number of named styles, and a cell would be read against
        # some other cell's number format.
        sig { returns(T::Array[T.nilable(Symbol)]) }
        def read_precisions
          part = archive["xl/styles.xml"]
          return [] if part.nil?

          codes = BUILTIN_FORMATS.dup
          formats = T.let([], T::Array[T.nilable(Symbol)])
          STYLES.read(part).each do |node|
            if node.name == "numFmt"
              codes[node.attribute("numFmtId").to_i] = node.attribute("formatCode").to_s
            else
              formats = node.nodes("xf").map { |style| date_precision(codes[style.attribute("numFmtId").to_i]) }
            end
          end
          formats
        end

        sig { params(code: T.nilable(String)).returns(T.nilable(Symbol)) }
        def date_precision(code)
          return nil if code.nil?

          tokens = code.gsub(LITERALS, "").downcase
          return :day if tokens.include?("d")
          return nil unless tokens.include?("y")

          tokens.include?("m") ? :month : :year
        end
      end
    end
  end
end
