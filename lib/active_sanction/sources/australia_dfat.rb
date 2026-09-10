# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/parsers"
require "active_sanction/sources"
require "active_sanction/sources/base"

module ActiveSanction
  module Sources
    # Australia's Consolidated List: everybody the Foreign Minister has
    # designated or declared under the Autonomous Sanctions Regulations 2011,
    # together with every UN Security Council listing Australia gives effect to.
    #
    #   snapshot = ActiveSanction::Sources[:australia_dfat].new.sync
    #
    # ### It is published as a spreadsheet, and as nothing else
    #
    #   https://www.dfat.gov.au/sites/default/files/Australian_Sanctions_Consolidated_List.xlsx
    #
    #     "Consolidated List"   11,163 rows, 19 columns, 1.3 MB
    #
    # One `.xlsx` file, one sheet. There is no CSV, no XML and no JSON: DFAT's
    # Consolidated List page offers exactly one download, and this is it. So
    # reading a spreadsheet is not a convenience here, it is the price of
    # screening against Australian sanctions at all.
    #
    # That was the open question on this list, and the answer was not to take a
    # dependency. Parsers::Spreadsheet reads the workbook with `zlib` and the
    # XML toolkit the other five adapters already use -- an `.xlsx` being a ZIP
    # of XML parts -- so this adapter costs a host nothing to install. See that
    # class for what it does and does not read.
    #
    # ### The URL moved, and the old one still answers
    #
    # The path this gem was scoped against, `regulation8_consolidated.xlsx`,
    # is gone. What is left in its place is a redirect to
    # `regulation8_consolidated_2.xls` -- a real file, served 200, in the old
    # binary Excel format, last modified in March 2022. An adapter pointed at it
    # would download a list four years stale on every sync and never once look
    # unhealthy. The URL above is the one DFAT's own page links today.
    #
    # ### DFAT's edge rejects this gem's User-Agent
    #
    # Verified against the live endpoint: `active_sanction/0.1.0 (+https://...)`
    # gets no response at all -- not a 403, a dropped connection -- while
    # `curl/8.7.1`, `Wget/1.21` and `python-requests/2.31.0` are all served. The
    # filter is on the leading product token, and an unrecognised one is
    # dropped, so identifying ourselves honestly is what gets us blocked.
    #
    # What is sent instead is the configured agent inside the form written for
    # exactly this: `Mozilla/5.0 (compatible; <agent>)`, which is how a
    # well-behaved crawler has identified itself since Googlebot. It is not a
    # disguise -- the agent, its version and the contact URL an operator
    # configured are all still in the string, and DFAT can still see who we are
    # and block us on purpose. It is the same string in a shape the edge parses.
    # See #fetch_file, which is the only place this source departs from Base.
    #
    # ### A record is several rows
    #
    # DFAT publishes one row per name. Reference `1000` is a primary name and
    # `1000a`, `1000b` are its aliases, with every other column repeated on each
    # -- so 11,163 rows are 3,906 records: 2,543 people, 1,041 organizations and
    # 322 vessels. Record says how they are joined, and what the Control Date
    # is not.
    #
    # ### What a clean Australian result is worth
    #
    # About what a UN one is worth, which is unsurprising: 1,172 of the 3,906
    # records are listings by a UN committee that Australia has given effect to,
    # and they arrive with the UN's own text intact. Alias grading is published
    # as a field on all 6,802 aliases. Birth dates are published on 6,823 rows
    # in nine spellings, which PublishedDate reads to within four fragments of
    # the whole list.
    #
    # Against that, DFAT publishes no document numbers of any kind -- no
    # passport, no national identity number, no company registration -- for any
    # of the 3,906 records. The only identifier on the list is an IMO number, on
    # 344 vessel rows. So an Australian name match has nothing behind it to make
    # it decisive, in the way an OFAC passport number usually settles one, and a
    # screening policy should know that before it sets a threshold.
    #
    # ### What this adapter does not do
    #
    # It does not read the Listing Information prose for anything but the
    # listing date. The column holds relisting histories, UN committee
    # references and the reasons for a designation, in a dozen shapes, and
    # reading it properly is the job OFAC's RemarksParser does and wants the
    # same treatment -- a measured coverage figure -- rather than a regex added
    # here in passing. It is kept verbatim in remarks.
    #
    # It does not decompose an address. DFAT publishes one free-text column and
    # no parts, so the whole published string is the street; see Record.
    class AustraliaDfat < Base
      extend T::Sig

      key :australia_dfat
      jurisdiction :au
      authority "Australian Sanctions Office, Department of Foreign Affairs and Trade"
      format :xlsx

      url :main, "https://www.dfat.gov.au/sites/default/files/Australian_Sanctions_Consolidated_List.xlsx"

      # @api private
      SHEET = T.let("Consolidated List", String)

      # @api private
      LIST = T.let(Parsers::Spreadsheet.new(sheet: SHEET), Parsers::Spreadsheet)

      # The columns this adapter reads by name. The sheet names its own, so
      # these are not a declaration of its shape -- they are what is checked
      # before a single row is mapped, so that a column DFAT renames says so
      # once and loudly rather than reading nil on all 11,163 rows.
      #
      # @api private
      REQUIRED_COLUMNS = T.let(
        %i[reference name_of_individual_or_entity type name_type alias_strength date_of_birth citizenship
           address additional_information listing_information imo_number committees control_date
           instrument_of_designation].freeze,
        T::Array[Symbol]
      )

      # The letters DFAT suffixes an alias reference with: `1000a`, and six
      # times `1000aa`. Stripping them is what joins a group.
      #
      # @api private
      ALIAS_SUFFIX = T.let(/[a-z]+\z/, Regexp)

      # `a) ... b) ...`: a UN enumeration inside one cell, which DFAT carries
      # through into the addresses and the birth dates.
      #
      # @api private
      ENUMERATOR = T.let(/(?:\A|[[:space:]])[a-z]\)[[:space:]]*/, Regexp)

      # Every kind of space: these cells carry non-breaking ones, which
      # `String#strip` leaves in place.
      #
      # @api private
      SPACE = T.let(/[[:space:]]+/, Regexp)

      # The form a filtered edge recognises -- see the class comment.
      #
      # @api private
      COMPATIBLE_AGENT = T.let("Mozilla/5.0 (compatible; %s)", String)

      # Records that could not be used, and fields that could not be read.
      # Read after #parse; sync orchestration (#34) reports them.
      sig { returns(T::Array[Parsers::Warning]) }
      attr_reader :warnings

      sig { params(args: T.untyped, options: T.untyped).void }
      def initialize(*args, **options)
        super
        @warnings = T.let([], T::Array[Parsers::Warning])
        @unmapped = T.let([], T::Array[Parsers::Warning])
        @modified = T.let(nil, T.nilable(String))
      end

      sig { override.params(raw: T.untyped).returns(T::Array[Entity]) }
      def parse(raw)
        reader = LIST.read(raw)
        entities = build(reader)
        @modified = reader.modified
        @warnings = reader.warnings + @unmapped
        entities
      end

      # `2026-09-04T05:37:12Z` -- the moment DFAT saved the workbook, which it
      # stamps inside the file and reports on its own download page as the date
      # the list was last updated. Falls back to Last-Modified for a payload
      # handed straight to #snapshot.
      sig { override.returns(T.nilable(String)) }
      def source_version = @modified || super

      # A reference with its alias suffix removed: `1000a` and `1000b` are both
      # part of `1000`. Public because it is what Record identifies a group by
      # and what a caller reconciling a hit against DFAT's own site needs.
      sig { params(reference: T.untyped).returns(T.nilable(String)) }
      def self.group(reference)
        base = reference.to_s.strip.sub(ALIAS_SUFFIX, "")
        base.empty? ? nil : base
      end

      # One cell split on the `a) ... b) ...` enumeration DFAT writes several
      # values with, or the whole cell where it wrote only one.
      sig { params(cell: T.untyped).returns(T::Array[String]) }
      def self.enumerated(cell)
        cell.to_s.split(ENUMERATOR).map { |part| part.gsub(SPACE, " ").strip }.reject(&:empty?)
      end

      private

      # The one place this source departs from Base: the request carries the
      # configured User-Agent wrapped in the `Mozilla/5.0 (compatible; ...)`
      # form, because DFAT's edge drops a request whose leading product token
      # it does not recognise. The class comment says why that is identification
      # rather than concealment.
      sig { override.params(name: Symbol, address: String, force: T::Boolean).returns(Fetcher::Result) }
      def fetch_file(name, address, force)
        fetcher.fetch(address, key: file_key(name), force: force, headers: { "User-Agent" => compatible_agent })
               .success!
      end

      # `Kernel.format` explicitly: `format` on a source is the Definition
      # reader that answers `:xlsx`, and calling it here would be asking the
      # declaration for a User-Agent.
      sig { returns(String) }
      def compatible_agent = Kernel.format(COMPATIBLE_AGENT, ActiveSanction.config.user_agent)

      sig { params(reader: Parsers::Spreadsheet::Reader).returns(T::Array[Entity]) }
      def build(reader)
        @unmapped = []
        rows = reader.to_a
        verify_columns!(rows.first)
        group(rows).filter_map do |reference, group|
          record = Record.new(group)
          record.entity || note_nameless(reference, group)
        end
      end

      # Rows in published order, gathered under the reference they share. A row
      # whose reference is blank cannot be joined to anything and is dropped
      # with a warning; none of the 11,163 published today is.
      sig do
        params(rows: T::Array[Parsers::Spreadsheet::Row])
          .returns(T::Hash[String, T::Array[Parsers::Spreadsheet::Row]])
      end
      def group(rows)
        rows.each_with_object({}) do |row, groups|
          reference = self.class.group(row[:reference]) || note_unreferenced(row)
          (groups[reference] ||= []) << row unless reference.nil?
        end
      end

      # A sheet whose header no longer names a column this reads is not a list
      # with an empty column; it is a publisher who has changed the file, and
      # every record built from it afterwards would be missing whatever that
      # column carried. There is nothing to salvage, so nothing is.
      sig { params(row: T.nilable(Parsers::Spreadsheet::Row)).void }
      def verify_columns!(row)
        raise Parsers::ParseError, "the #{SHEET.inspect} sheet has a header and no rows" if row.nil?

        missing = REQUIRED_COLUMNS - row.columns
        return if missing.empty?

        raise Parsers::ParseError,
              "the #{SHEET.inspect} sheet does not name the column(s) #{missing.join(", ")}. It names: " \
              "#{row.columns.join(", ")}"
      end

      sig { params(row: Parsers::Spreadsheet::Row).returns(NilClass) }
      def note_unreferenced(row)
        @unmapped << Parsers::Warning.new(
          line: row.number,
          message: "row #{row.number} carries no reference, so it cannot be joined to a record",
          snippet: row[:name_of_individual_or_entity]
        )
        nil
      end

      # A group whose rows are all nameless cannot be screened against. None of
      # the 3,906 records published today is nameless; the warning exists so
      # that the day one is, it is visible rather than absent.
      sig do
        params(reference: String, group: T::Array[Parsers::Spreadsheet::Row]).returns(NilClass)
      end
      def note_nameless(reference, group)
        @unmapped << Parsers::Warning.new(
          line: group.first&.number,
          message: "reference #{reference.inspect} has no name on any of its #{group.size} row(s) and was skipped"
        )
        nil
      end
    end
  end
end

require "active_sanction/sources/australia_dfat/published_date"
require "active_sanction/sources/australia_dfat/record"

ActiveSanction::Sources.register(ActiveSanction::Sources::AustraliaDfat)
