# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/parsers/format"
require "active_sanction/parsers/spreadsheet/archive"
require "active_sanction/parsers/spreadsheet/workbook"
require "active_sanction/parsers/spreadsheet/row"
require "active_sanction/parsers/spreadsheet/reader"

module ActiveSanction
  module Parsers
    # Reads an Office Open XML workbook -- an `.xlsx` file -- into rows an
    # adapter can map onto Entities.
    #
    # A table is a description of the file, built once and reused for every
    # sync; a Reader is one pass over one payload.
    #
    #   LIST = ActiveSanction::Parsers::Spreadsheet.new(sheet: "Consolidated List")
    #
    #   LIST.read(bytes).each { |row| row[:name_of_individual_or_entity] }
    #
    # ### With no dependency, which was the point
    #
    # Australia publishes its Consolidated List as a spreadsheet and as nothing
    # else -- no CSV, no XML, no JSON -- so reading it is the price of screening
    # against Australian sanctions at all. The alternative was a spreadsheet
    # gem, which would have been this library's first third-party dependency
    # taken on one publisher's behalf, in a gem whose stated rule is that a
    # compliance library should not be the reason a deployment installs
    # something.
    #
    # It turned out not to cost much. An `.xlsx` is a ZIP of XML parts; `zlib`
    # is in the standard library and this gem already reads XML, so what was
    # actually missing was a ZIP header unpacker (Archive) and the two lookups
    # that make a cell mean something (Workbook). Everything below that is the
    # XML toolkit the other five adapters use.
    #
    # ### What it reads, and what it does not
    #
    # One sheet of cell values, as strings. Dates are rendered ISO 8601 at the
    # precision the cell's own format displays -- see Workbook -- so that
    # `PartialDate::Parser` reads them without an adapter writing a format.
    #
    # Formulas are not evaluated: a formula cell is read as the value last
    # cached in it, which is what a publisher's export contains and what the
    # file displays. Merged cells, comments, charts, styling and every other
    # thing a spreadsheet can hold are ignored, because none of them is data on
    # a sanctions list. Only `.xlsx` is read, not the older binary `.xls` --
    # they share a file extension in conversation and nothing at all in format.
    #
    # ### Columns, and why declaring them is optional here
    #
    # A published spreadsheet has a header row, unlike OFAC's CSVs, so the first
    # row of the sheet is always the header and never a record. By default its
    # cells are what the columns are named. Declaring `columns:` instead renames
    # them by position, which pins the sheet's shape for a publisher who has
    # form for re-labelling things -- the header is still consumed, because it
    # is still a header.
    class Spreadsheet
      extend T::Sig
      include Format

      # Excel escapes a character XML cannot carry as `_x000D_`, and escapes a
      # literal `_x000D_` somebody typed as `_x005F_x000D_`. Both are matched
      # here, the doubled form first, so unescaping does not itself turn one
      # into the other. The Australian list carries them in 205 cells, all
      # carriage returns inside a birth date, an address or a place of birth.
      ESCAPE = T.let(/_x005F_(_x[0-9A-Fa-f]{4}_)|_x([0-9A-Fa-f]{4})_/, Regexp)

      # nil where the sheet names its own columns -- see #headers?.
      sig { returns(T.nilable(T::Array[Symbol])) }
      attr_reader :columns

      # The sheet to read: a name, a zero-based index, or nil for the first one.
      sig { returns(T.untyped) }
      attr_reader :sheet

      sig { override.returns(T::Array[String]) }
      attr_reader :nulls

      # Always UTF-8, and not a caller's choice: the parts of a workbook are XML
      # documents that declare their own encoding, and every writer emits UTF-8.
      sig { override.returns(Encoding) }
      attr_reader :encoding

      sig { params(columns: T.untyped, null: T.untyped, sheet: T.untyped).void }
      def initialize(columns: nil, null: nil, sheet: nil)
        @columns = T.let(columns!(columns), T.nilable(T::Array[Symbol]))
        @nulls = T.let(nulls!(null), T::Array[String])
        @sheet = T.let(sheet, T.untyped)
        @encoding = T.let(DEFAULT_ENCODING, Encoding)
        freeze
      end

      # A pass over one payload. Takes the bytes as a String, which is what
      # Sources::Base hands #parse.
      sig { params(payload: T.untyped).returns(Reader) }
      def read(payload) = Reader.new(table: self, payload: payload)

      # A cell's text with Excel's escapes resolved. Applied to every string a
      # sheet holds, shared or inline, because a name carrying a literal
      # `_x000D_` is a name nothing will match.
      sig { params(text: T.nilable(String)).returns(T.nilable(String)) }
      def unescape(text)
        return text if text.nil? || !text.include?("_x")

        text.gsub(ESCAPE) { ::Regexp.last_match(1) || [::Regexp.last_match(2).to_s.hex].pack("U") }
      end

      # Whether the sheet names its own columns.
      sig { returns(T::Boolean) }
      def headers? = columns.nil?

      # What to call the sheet being read, for a message: the name or index the
      # caller asked for, or what "the first one" means when they asked for
      # nothing.
      sig { returns(String) }
      def sheet_name
        return "the first sheet" if sheet.nil?

        sheet.is_a?(Integer) ? "sheet #{sheet}" : sheet.to_s.inspect
      end

      # Zips a row's cells against the column names by position. A column the
      # row left empty is nil, and a cell past the last named column is dropped
      # -- the Reader has already warned about the second.
      sig do
        params(names: T::Array[Symbol], cells: T::Hash[Integer, String])
          .returns(T::Hash[Symbol, T.nilable(String)])
      end
      def coerce(names, cells)
        names.each_with_index.to_h { |name, index| [name, cells[index]] }.freeze
      end

      sig { returns(String) }
      def inspect
        declared = columns
        shape = declared.nil? ? "headers from the sheet" : "#{declared.size} columns"
        "#<#{self.class} #{sheet_name}, #{shape}#{" null=#{nulls.first.inspect}" if nulls.any?}>"
      end

      private

      sig { params(value: T.untyped).returns(T.nilable(T::Array[Symbol])) }
      def columns!(value)
        return nil if value.nil?

        names = column_names!(value)
        duplicated = names.tally.select { |_, count| count > 1 }.keys
        raise InvalidArgument, "duplicate column name(s): #{duplicated.join(", ")}" if duplicated.any?

        names.freeze
      end

      sig { params(value: T.untyped).returns(T::Array[Symbol]) }
      def column_names!(value)
        raise InvalidArgument, "columns must be an Array of names, got #{value.inspect}" unless value.is_a?(Array)
        raise InvalidArgument, "columns cannot be empty; pass nil to read them from the sheet's header" if value.empty?

        value.map { |name| name.to_s.strip.to_sym }
      end
    end
  end
end
