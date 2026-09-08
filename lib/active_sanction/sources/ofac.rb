# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/parsers"
require "active_sanction/sources"
require "active_sanction/sources/base"

module ActiveSanction
  module Sources
    # What the two OFAC lists have in common, which is nearly everything.
    #
    # OFAC publishes the SDN list and the Consolidated (non-SDN) list in
    # exactly the same shape: three headerless CSVs joined on `ent_num`, the
    # primary file carrying twelve columns, ALT carrying five and ADD six, all
    # of them in Windows-1252 with `-0- ` for null. Only the file names, the
    # sizes and the legal consequence of being on one differ.
    #
    #   SDN.CSV        19,321 rows      CONS_PRIM.CSV      481 rows
    #   ALT.CSV        20,147 rows      CONS_ALT.CSV     1,109 rows
    #   ADD.CSV        25,078 rows      CONS_ADD.CSV       614 rows
    #
    # So the reading is written once, here, and an adapter says only which
    # list it is and where its three files live. Abstract: it declares no key
    # and does not register, because there is no such list as "OFAC".
    #
    # ### The fields OFAC publishes no columns for
    #
    # Neither file has a date of birth, place of birth, nationality or
    # passport column. All of it is prose in `Remarks`:
    #
    #     "DOB 10 Dec 1948; POB Egypt; nationality Egypt; Passport 123456 (Egypt)"
    #
    # RemarksParser reads it, and #remarks_coverage reports how much of it it
    # understood -- 97% of the SDN file's 88,827 segments, which is a figure to
    # watch rather than a guarantee. The remark is kept verbatim either way, so
    # a pattern that goes stale costs structure and never content.
    #
    # This class is written entirely against the public extension points:
    # declarations from Definition, fetch and cache and checksum from Base,
    # reading and joining from Parsers. It required no change to any of them,
    # which is the property M4 exists to prove.
    class Ofac < Base
      extend T::Sig

      jurisdiction :us
      authority "U.S. Department of the Treasury, Office of Foreign Assets Control"
      format :csv

      # The one floor either OFAC list commits to, and only for the run that
      # has no previous snapshot to compare against. RemarksParser reads about
      # 97% of the SDN file's segments; 90% is a long way below anything the
      # file has done and still far above what a re-spelled document label
      # would leave. There is deliberately no floor on the record count: the
      # SDN list has roughly tripled since 2010, so any bound wide enough to
      # have survived that is too wide to catch a truncated download, and the
      # previous snapshot catches one for nothing. See Definition#floor.
      floor :remarks_coverage, 0.90

      # OFAC serves Windows-1252, not UTF-8, and says nothing about it in a
      # header. Read as UTF-8 the accented names in the list -- and there are
      # thousands -- arrive as replacement characters.
      ENCODING = T.let(Encoding::WINDOWS_1252, Encoding)

      # OFAC writes "-0- " for null, with a trailing space, in every one of its
      # files and roughly a quarter of a million times overall.
      NULL = T.let("-0-", String)

      # Column names, positional: all six files ship without a header row.
      # Declaring them here also pins each file's width, so a column inserted
      # upstream surfaces as a warning on every row rather than as 19,321
      # entities quietly built from shifted fields.
      PRIMARY_COLUMNS = T.let(%i[
        ent_num sdn_name sdn_type program title call_sign vessel_type
        tonnage gross_registered_tonnage vessel_flag vessel_owner remarks
      ].freeze, T::Array[Symbol])

      ALT_COLUMNS = T.let(%i[ent_num alt_num alt_type alt_name alt_remarks].freeze, T::Array[Symbol])

      ADD_COLUMNS = T.let(
        %i[ent_num add_num address city_state_province_postal_code country add_remarks].freeze,
        T::Array[Symbol]
      )

      PRIMARY = T.let(
        Parsers::DelimitedTable.new(columns: PRIMARY_COLUMNS, null: NULL, encoding: ENCODING),
        Parsers::DelimitedTable
      )
      ALT = T.let(
        Parsers::DelimitedTable.new(columns: ALT_COLUMNS, null: NULL, encoding: ENCODING),
        Parsers::DelimitedTable
      )
      ADD = T.let(
        Parsers::DelimitedTable.new(columns: ADD_COLUMNS, null: NULL, encoding: ENCODING),
        Parsers::DelimitedTable
      )

      # OFAC's join key. Every row of all six files carries one, and it is the
      # only column on the primary file whose *values* have a shape.
      ENT_NUM = T.let(/\A\d+\z/, Regexp)

      # Rows that could not be read, and child rows that matched no entity.
      # Populated by #parse and read afterwards -- sync orchestration (#34)
      # reports them, and a nonzero orphan count is the signal that the three
      # files were downloaded at different moments and no longer agree.
      sig { returns(T::Array[Parsers::Warning]) }
      attr_reader :warnings

      # Child rows that matched no entity, by file -- a nonzero count means the
      # three files were downloaded at different moments.
      sig { returns(T::Hash[Symbol, T.untyped]) }
      attr_reader :orphans

      # How much of OFAC's free text the last #parse understood. Not a warning,
      # because an unread segment is not an error -- it is still in the remark,
      # in the publisher's own words -- but a figure to watch: it is the only
      # thing that moves when OFAC changes how it writes a passport line.
      sig { returns(RemarksParser::Coverage) }
      attr_reader :remarks_coverage

      sig { params(args: T.untyped, options: T.untyped).void }
      def initialize(*args, **options)
        super
        @warnings = T.let([], T::Array[Parsers::Warning])
        @orphans = T.let({}, T::Hash[Symbol, T.untyped])
        @remarks_coverage = T.let(RemarksParser::Coverage.new, RemarksParser::Coverage)
        @unmapped = T.let([], T::Array[Parsers::Warning])
      end

      sig { override.params(raw: T.untyped).returns(T::Array[Entity]) }
      def parse(raw)
        join = Parsers::Join.new(on: :ent_num, aliases: ALT.read(raw[:alt]), addresses: ADD.read(raw[:add]))
        entities = build(join, PRIMARY.read(raw[primary_file]))
        @warnings = join.warnings + @unmapped
        @orphans = join.orphans
        entities
      end

      # What the two assertable columns of the primary file hold.
      #
      # The width declared in PRIMARY_COLUMNS catches a column OFAC *inserts*:
      # every row arrives the wrong width and every row says so. Nothing about
      # the width catches one OFAC *reorders*, which parses cleanly and builds
      # 19,321 entities out of shifted fields. These are what catches that.
      #
      # Two of twelve, because ten of the columns are free text a government
      # writes for people and there is nothing to assert about them. See
      # Parsers::ColumnShape.
      #
      # `sdn_type` is held to three quarters rather than the 99% `ent_num` is,
      # and the difference is what each one would cost to get wrong. OFAC does
      # publish types this adapter has never seen -- that is what
      # Record#unknown_type? exists for, and a new one is an `info` finding and
      # a mapping to write, not a broken file. Demanding 99% would turn the
      # week OFAC coins a word into an `error` on a list that is entirely fine,
      # and a diagnostic that cries wolf about a healthy list is one nobody
      # reads the week it is right. What three quarters still catches is the
      # only thing worth an error here: a column that has stopped being the
      # type column at all, which reads as zero.
      sig { returns(T::Array[Parsers::ColumnShape]) }
      def column_assertions
        [Parsers::ColumnShape.new(name: :ent_num, matches: ENT_NUM, description: "numeric"),
         Parsers::ColumnShape.new(name: :sdn_type, allowing: record_class.published_types, at_least: 0.75,
                                  description: "a published SDN_Type")]
      end

      # One extra pass over the primary file, for the doctor and nothing else.
      # It is the same reader the parse used, asked a different question.
      sig { override.params(raw: T.untyped).returns(T::Array[Parsers::ColumnShape::Tally]) }
      def column_shapes(raw)
        rows = PRIMARY.read(raw[primary_file]).to_a
        column_assertions.map { |shape| shape.tally(rows.map { |row| row[shape.name] }) }
      end

      # The declaration name of the file carrying one row per entity -- `:sdn`
      # for the SDN list, `:prim` for the consolidated one. The first file an
      # adapter declares, by the convention that the primary comes before the
      # children it is joined to.
      sig { returns(Symbol) }
      def primary_file = T.must(urls.keys.first)

      private

      # The class each joined row is handed to. Overridden by an adapter whose
      # list publishes something the shared mapping does not know about.
      sig { returns(T.untyped) }
      def record_class = Record

      # Coverage is folded over every row, the nameless ones that produce no
      # entity included: the question it answers is how much of the file this
      # parser can read, and a row we drop is still a row OFAC published.
      sig { params(join: Parsers::Join, rows: T.untyped).returns(T::Array[Entity]) }
      def build(join, rows)
        @unmapped = []
        @remarks_coverage = RemarksParser::Coverage.new
        entities = []
        join.each(rows) do |row, related|
          record = record_class.new(row: row, source: key, aliases: related[:aliases],
                                    addresses: related[:addresses])
          note(record)
          entity = record.entity
          entity.nil? ? note_nameless(row) : entities << entity
        end
        entities
      end

      # Everything worth saying about one record before it becomes an entity.
      # A subclass adds to it rather than replacing it, so a list that can
      # complain about more still complains about the same things.
      sig { params(record: T.untyped).void }
      def note(record)
        note_unknown_type(record) if record.unknown_type?
        @remarks_coverage.record(record.parsed_remarks)
      end

      sig { params(record: T.untyped).void }
      def note_unknown_type(record)
        @unmapped << Parsers::Warning.new(
          line: record.row.line,
          message: "unknown SDN_Type #{record.row[:sdn_type].inspect}; treated as an organization"
        )
      end

      sig { params(row: Parsers::DelimitedTable::Row).void }
      def note_nameless(row)
        @unmapped << Parsers::Warning.new(
          line: row.line, message: "row #{row[:ent_num].inspect} has no SDN_Name and was skipped"
        )
      end
    end
  end
end

require "active_sanction/sources/ofac/record"
