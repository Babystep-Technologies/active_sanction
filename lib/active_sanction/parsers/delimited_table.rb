# frozen_string_literal: true

require "csv"
require "active_sanction/parsers/delimited_table/row"
require "active_sanction/parsers/delimited_table/reader"

module ActiveSanction
  module Parsers
    # Reads a record-oriented delimited list -- CSV, TSV, anything stdlib CSV
    # can be told about -- into rows an adapter can map onto Entities.
    #
    # A table is a description of the file, built once and reused for every
    # sync; a Reader is one pass over one payload.
    #
    #   SDN = ActiveSanction::Parsers::DelimitedTable.new(
    #     columns:  %i[ent_num sdn_name sdn_type program title remarks],
    #     null:     "-0-",
    #     encoding: Encoding::WINDOWS_1252
    #   )
    #
    #   SDN.read(bytes).each { |row| row[:sdn_name] }
    #
    # ### Headerless files, and why columns are declared
    #
    # OFAC ships all three of its files with no header row, so the names have
    # to come from somewhere. Declaring them in the adapter also pins the
    # file's shape: if OFAC inserts a column, rows arrive the wrong width and
    # every one of them says so in #warnings, which is a far better failure
    # than 19,321 entities quietly built from shifted fields.
    #
    # A file that does carry a header is read with `columns: nil`, and the
    # names come from its first row.
    #
    # ### The null sentinel
    #
    # OFAC does not leave a field empty; it writes `-0- `, with a trailing
    # space, and it does this roughly a quarter of a million times:
    #
    #     36,"AEROCARIBBEAN AIRLINES",-0- ,"CUBA",-0- ,-0- ,...
    #
    # Any declared sentinel is matched after stripping surrounding whitespace,
    # and a field that is empty or all whitespace is nil as well -- a list that
    # uses both conventions in one file (they all do) should not make an
    # adapter check for both.
    class DelimitedTable
      DEFAULT_ENCODING = Encoding::UTF_8

      SEPARATOR_NAMES = { "," => "CSV", "\t" => "TSV", "|" => "pipe-delimited text",
                          ";" => "semicolon-delimited text" }.freeze

      attr_reader :columns, :nulls, :col_sep, :quote_char, :encoding

      # `liberal_parsing` is on by default because these files are published,
      # not validated: an unescaped quote inside a company name is common
      # enough in OFAC and UK OFSI data that failing the row is the wrong
      # default. Turn it off for a source where a stray quote should be loud.
      def initialize(columns: nil, null: nil, col_sep: ",", quote_char: '"',
                     encoding: DEFAULT_ENCODING, liberal_parsing: true)
        @columns = columns!(columns)
        @nulls = nulls!(null)
        @col_sep = col_sep.to_s
        @quote_char = quote_char.to_s
        @encoding = encoding!(encoding)
        @liberal_parsing = liberal_parsing
        freeze
      end

      # A pass over one payload. Takes the bytes as a String, which is what
      # Sources::Base hands #parse.
      def read(payload) = Reader.new(table: self, payload: payload)

      # Whether the file names its own columns.
      def headers? = columns.nil?

      # What a caller declared as null, resolved. Public because an adapter
      # joining files by hand needs the same rule the reader applies.
      #
      #   table.value("-0- ")   # => nil
      #   table.value("  ")     # => nil
      #   table.value(" CUBA")  # => "CUBA"
      def value(raw)
        string = raw.to_s.strip
        return nil if string.empty? || nulls.include?(string)

        -string
      end

      # Zips a row's values against the column names. Extra values are dropped
      # and missing ones are nil; the Reader has already warned about both.
      def coerce(names, values)
        names.each_with_index.to_h { |name, index| [name, value(values[index])] }.freeze
      end

      def csv_options
        { col_sep: col_sep, quote_char: quote_char, headers: false,
          liberal_parsing: @liberal_parsing, skip_blanks: true }
      end

      # What to call this format in an error message, so a complaint about
      # OFAC's file says "CSV" rather than "delimited text".
      def col_sep_name = SEPARATOR_NAMES.fetch(col_sep, "delimited text")

      def inspect
        shape = headers? ? "headers from file" : "#{columns.size} columns"
        "#<#{self.class} #{col_sep_name} #{shape}#{" null=#{nulls.first.inspect}" if nulls.any?}>"
      end

      private

      def columns!(value)
        return nil if value.nil?

        names = column_names!(value)
        duplicated = names.tally.select { |_, count| count > 1 }.keys
        raise ArgumentError, "duplicate column name(s): #{duplicated.join(", ")}" if duplicated.any?

        names.freeze
      end

      def column_names!(value)
        raise ArgumentError, "columns must be an Array of names, got #{value.inspect}" unless value.is_a?(Array)
        raise ArgumentError, "columns cannot be empty; pass nil to read them from the file's header" if value.empty?

        value.map { |name| name.to_s.strip.to_sym }
      end

      # Accepts one sentinel or several: a publisher that writes both "-0-" and
      # "N/A" is not unusual, and an adapter should be able to say so once.
      def nulls!(value)
        Array(value).map { |sentinel| -sentinel.to_s.strip }.reject(&:empty?).uniq.freeze
      end

      def encoding!(value)
        return value if value.is_a?(Encoding)

        Encoding.find(value.to_s)
      rescue ArgumentError
        raise ArgumentError, "unknown encoding #{value.inspect}"
      end
    end
  end
end
