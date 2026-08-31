# frozen_string_literal: true

require "active_sanction/parsers"
require "active_sanction/sources"
require "active_sanction/sources/base"

module ActiveSanction
  module Sources
    # The US Specially Designated Nationals list: the largest and most
    # frequently screened sanctions list there is, and the one whose format
    # dictates most of what the parsing toolkits have to handle.
    #
    #   snapshot = ActiveSanction::Sources[:ofac_sdn].new.sync
    #
    # ### Three files, one list
    #
    # OFAC publishes the SDN list as three headerless CSVs joined on `ent_num`:
    #
    #   SDN.CSV   19,321 rows   primary names, type, programs, remarks
    #   ALT.CSV   20,147 rows   aliases -- more of them than there are entities
    #   ADD.CSV   25,078 rows   addresses
    #
    # Each is fetched and cached independently by Base, because they change
    # independently; the join happens here, in #parse.
    #
    # ### The fields OFAC publishes no columns for
    #
    # There is no date of birth, place of birth, nationality or passport
    # column. All of it is prose in `Remarks`:
    #
    #     "DOB 10 Dec 1948; POB Egypt; nationality Egypt; Passport 123456 (Egypt)"
    #
    # RemarksParser reads it, and #remarks_coverage reports how much of it it
    # understood -- 97% of the published file's 88,827 segments, which is a
    # figure to watch rather than a guarantee. The remark is kept verbatim
    # either way, so a pattern that goes stale costs structure and never
    # content.
    #
    # This adapter is written entirely against the public extension points:
    # declarations from Definition, fetch and cache and checksum from Base,
    # reading and joining from Parsers. It required no change to any of them,
    # which is the property M4 exists to prove.
    class OfacSdn < Base
      key :ofac_sdn
      jurisdiction :us
      authority "U.S. Department of the Treasury, Office of Foreign Assets Control"
      format :csv

      url :sdn, "https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV"
      url :alt, "https://sanctionslistservice.ofac.treas.gov/api/download/ALT.CSV"
      url :add, "https://sanctionslistservice.ofac.treas.gov/api/download/ADD.CSV"

      # OFAC serves Windows-1252, not UTF-8, and says nothing about it in a
      # header. Read as UTF-8 the accented names in the list -- and there are
      # thousands -- arrive as replacement characters.
      ENCODING = Encoding::WINDOWS_1252

      # OFAC writes "-0- " for null, with a trailing space, in every one of its
      # files and roughly a quarter of a million times overall.
      NULL = "-0-"

      # Column names, positional: all three files ship without a header row.
      # Declaring them here also pins each file's width, so a column inserted
      # upstream surfaces as a warning on every row rather than as 19,321
      # entities quietly built from shifted fields.
      SDN_COLUMNS = %i[
        ent_num sdn_name sdn_type program title call_sign vessel_type
        tonnage gross_registered_tonnage vessel_flag vessel_owner remarks
      ].freeze

      ALT_COLUMNS = %i[ent_num alt_num alt_type alt_name alt_remarks].freeze

      ADD_COLUMNS = %i[ent_num add_num address city_state_province_postal_code country add_remarks].freeze

      SDN = Parsers::DelimitedTable.new(columns: SDN_COLUMNS, null: NULL, encoding: ENCODING)
      ALT = Parsers::DelimitedTable.new(columns: ALT_COLUMNS, null: NULL, encoding: ENCODING)
      ADD = Parsers::DelimitedTable.new(columns: ADD_COLUMNS, null: NULL, encoding: ENCODING)

      # Rows that could not be read, and child rows that matched no entity.
      # Populated by #parse and read afterwards -- sync orchestration (#34)
      # reports them, and a nonzero orphan count is the signal that the three
      # files were downloaded at different moments and no longer agree.
      attr_reader :warnings, :orphans

      # How much of OFAC's free text the last #parse understood. Not a warning,
      # because an unread segment is not an error -- it is still in the remark,
      # in the publisher's own words -- but a figure to watch: it is the only
      # thing that moves when OFAC changes how it writes a passport line.
      attr_reader :remarks_coverage

      def initialize(...)
        super
        @warnings = []
        @orphans = {}
        @remarks_coverage = RemarksParser::Coverage.new
      end

      def parse(raw)
        join = Parsers::Join.new(on: :ent_num, aliases: ALT.read(raw[:alt]), addresses: ADD.read(raw[:add]))
        entities = build(join, SDN.read(raw[:sdn]))
        @warnings = join.warnings + @unmapped
        @orphans = join.orphans
        entities
      end

      private

      # Coverage is folded over every row, the nameless ones that produce no
      # entity included: the question it answers is how much of the file this
      # parser can read, and a row we drop is still a row OFAC published.
      def build(join, rows)
        @unmapped = []
        @remarks_coverage = RemarksParser::Coverage.new
        entities = []
        join.each(rows) do |row, related|
          record = Record.new(row: row, aliases: related[:aliases], addresses: related[:addresses])
          note_unknown_type(record) if record.unknown_type?
          @remarks_coverage.record(record.parsed_remarks)
          entity = record.entity
          entity.nil? ? note_nameless(row) : entities << entity
        end
        entities
      end

      def note_unknown_type(record)
        @unmapped << Parsers::Warning.new(
          line: record.row.line,
          message: "unknown SDN_Type #{record.row[:sdn_type].inspect}; treated as an organization"
        )
      end

      def note_nameless(row)
        @unmapped << Parsers::Warning.new(
          line: row.line, message: "row #{row[:ent_num].inspect} has no SDN_Name and was skipped"
        )
      end
    end
  end
end

require "active_sanction/sources/ofac_sdn/record"

ActiveSanction::Sources.register(ActiveSanction::Sources::OfacSdn)
