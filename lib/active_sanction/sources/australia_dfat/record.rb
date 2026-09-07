# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/entity"
require "active_sanction/name"
require "active_sanction/address"
require "active_sanction/identifier"
require "active_sanction/partial_date"
require "active_sanction/sources/remarks"

module ActiveSanction
  module Sources
    class AustraliaDfat < Base
      # The rows sharing one reference, turned into an Entity.
      #
      # Separate from the adapter because they are two jobs: the adapter says
      # what the list is and where it lives, and this says what DFAT's columns
      # mean. The mapping is where all the judgment sits, so it is worth being
      # able to read it on its own.
      #
      # ### A record is several rows, and the reference says which
      #
      # DFAT publishes one row per *name*, not per person. `1000` is the primary
      # name and `1000a`, `1000b`, `1000c` are its aliases, and every other
      # column is repeated on each of them. The 11,163 rows of the published
      # list are 3,906 records: 3,906 primary names, 6,802 aliases and 455 names
      # in original script.
      #
      # The repetition is not quite exact. 80 groups disagree with themselves
      # about the additional information, 39 about the birth dates and 23 about
      # the address -- an alias row carrying a detail the primary row does not,
      # usually because the two came from different UN listings of the same
      # person. So every column is unioned across the group rather than read off
      # the primary row: two of the 3,906 records have a place of birth, and one
      # an address, only because an alias row carried it.
      #
      # ### The trap in this list is the Control Date
      #
      # It is on all 11,163 rows, it is a real date, and it is not the day
      # anybody was sanctioned. DFAT's own guide defines it as "the last date
      # the sanction entry was updated or edited on the Consolidated List",
      # which for the Taliban listings of January 2001 is a date in 2026. An
      # adapter that mapped it to `listed_on` would report the whole list as
      # having been sanctioned within the last few months, and would do it
      # without anything looking wrong.
      #
      # The listing date is in the Listing Information prose instead, on the
      # 1,438 records that state one; see PublishedDate.listing. The Control
      # Date is kept in remarks, labelled as what it is.
      class Record
        extend T::Sig

        # The `Type` column, which is populated on every row and is the only
        # place the list says what a listing is about. 346 rows are vessels:
        # without the distinct type a search for a person can rank a tanker.
        TYPES = T.let(
          { "individual" => :individual, "entity" => :organization, "vessel" => :vessel }.freeze,
          T::Hash[String, Symbol]
        )

        # `Name Type`, case-folded. A name in original script is the same name
        # written another way rather than the designation proper, so it is filed
        # as an alias -- which is what leaves `Entity#primary_name` answering
        # with the one name DFAT calls primary.
        NAME_KINDS = T.let(
          { "primary name" => :primary, "alias" => :aka, "original script" => :aka }.freeze,
          T::Hash[String, Symbol]
        )

        # `Alias Strength`, which DFAT publishes on all 6,802 aliases -- 6,346
        # strong, 456 weak -- and on nothing else. Its guide defines strong as an
        # alias assessed to be closely associated with the listing and weak as
        # one that is not, which is the distinction the UN grades Good and Low,
        # so it maps onto the grade the scorer already knows how to discount.
        ALIAS_QUALITIES = T.let({ "strong" => :good, "weak" => :low }.freeze, T::Hash[String, Symbol])

        # The four measures, which DFAT publishes as 1 and 0 rather than as the
        # TRUE and FALSE its guide describes. Real screening context -- an arms
        # embargo and an asset freeze are not the same finding -- with nowhere
        # in the canonical model to live, so they are named in remarks.
        MEASURES = T.let(
          { targeted_financial_sanction: "targeted financial sanction", travel_ban: "travel ban",
            arms_embargo: "arms embargo", maritime_restriction: "maritime restriction" }.freeze,
          T::Hash[Symbol, String]
        )

        TRUTHY = T.let(%w[1 true yes y].freeze, T::Array[String])

        # Columns kept verbatim in remarks, in the order they are printed. Place
        # of birth is real screening signal with no member of its own; the
        # instrument is the legislative vehicle, which is narrower than the
        # framework in `programs` and changes every time a list is amended.
        EXTRA_FIELDS = T.let(
          [[:place_of_birth, "Place of birth"], [:instrument_of_designation, "Instrument of designation"],
           [:control_date, "Control date (last edited, not listed)"]].freeze,
          T::Array[[Symbol, String]]
        )

        # DFAT separates citizenships with a semicolon and nothing else, on all
        # 399 rows that publish more than one.
        SEMICOLON = T.let(";", String)

        # What separates the two prose columns once they are joined.
        PARAGRAPH = T.let("\n\n", String)

        # Trailing spaces, and the carriage returns Excel escapes as `_x000D_`
        # and the spreadsheet reader unescapes. A name that keeps either is a
        # name nothing will ever match.
        WHITESPACE = T.let(/[[:space:]]+/, Regexp)

        sig { returns(T::Array[Parsers::Spreadsheet::Row]) }
        attr_reader :rows

        sig { params(rows: T::Array[Parsers::Spreadsheet::Row]).void }
        def initialize(rows)
          @rows = T.let(rows, T::Array[Parsers::Spreadsheet::Row])
          @dates_of_birth = T.let(nil, T.nilable(T::Array[PartialDate]))
          @unread_dates = T.let([], T::Array[String])
        end

        # The entity, or nil for a group whose rows are all nameless -- which
        # cannot be screened against and is never what DFAT meant to publish.
        sig { returns(T.nilable(Entity)) }
        def entity
          return nil if names.empty?

          Entity.new(source: :australia_dfat, source_ref: source_ref, type: type, names: names,
                     addresses: addresses, identifiers: identifiers, dates_of_birth: dates_of_birth,
                     nationalities: nationalities, programs: programs, listed_on: listed_on,
                     remarks: remarks)
        end

        # DFAT's own reference with the alias suffix removed: the `1000` that
        # `1000`, `1000a` and `1000b` are all part of. Stable across syncs, and
        # the number DFAT will quote back in a permit application.
        sig { returns(T.nilable(String)) }
        def source_ref = AustraliaDfat.group(primary[:reference])

        sig { returns(Symbol) }
        def type = TYPES.fetch(primary[:type].to_s.downcase, :organization)

        # In published order, which puts the primary name first. A spelling
        # DFAT files twice -- once as an alias and once in original script --
        # keeps the first kind it was given.
        sig { returns(T::Array[Name]) }
        def names
          @names ||= T.let(dedupe(rows.filter_map { |row| name(row) }), T.nilable(T::Array[Name]))
        end

        # Memoized, because reading them is also what fills the list of dates
        # this could not use, which #remarks then keeps rather than losing.
        sig { returns(T::Array[PartialDate]) }
        def dates_of_birth
          @dates_of_birth ||= begin
            @unread_dates = []
            column(:date_of_birth).flat_map { |cell| read_dates(cell) }.uniq
          end
        end

        # Prose, the way the UN and the UK publish it: `Russia`, `Democratic
        # People's Republic of Korea (North Korea)`. Country resolves it to an
        # ISO code at scoring time and treats one it cannot resolve as absent
        # rather than as a conflict.
        sig { returns(T::Array[String]) }
        def nationalities
          column(:citizenship).flat_map { |cell| cell.split(SEMICOLON) }.filter_map { |value| collapse(value) }.uniq
        end

        # One column of free text, which DFAT does not decompose and this does
        # not guess at. The whole published string is the street, because it is
        # the address rather than an annotation about one -- and 859 rows hold
        # more than one address, enumerated `a) ... b) ...` the way the birth
        # dates are.
        sig { returns(T::Array[Address]) }
        def addresses
          column(:address).flat_map { |cell| AustraliaDfat.enumerated(cell) }.uniq.filter_map { |line| address(line) }
        end

        # IMO numbers, on the 344 vessel rows that carry one. Filed the way the
        # UK adapter files them: a registry number that is not any of the four
        # document kinds, labelled in its note.
        sig { returns(T::Array[Identifier]) }
        def identifiers
          column(:imo_number).filter_map { |number| identifier(number) }.uniq
        end

        # The sanctions framework, which is the closest thing DFAT publishes to
        # OFAC's programme codes: `1267 (ISIL (Da'esh) and Al-Qaida)`,
        # `Autonomous (Russia)`. Populated on every row, and 29 values cover the
        # whole list.
        sig { returns(T::Array[String]) }
        def programs = column(:committees).uniq

        sig { returns(T.nilable(PartialDate)) }
        def listed_on = column(:listing_information).filter_map { |cell| PublishedDate.listing(cell) }.first

        # DFAT's own prose verbatim -- the identifying detail and the listing
        # narrative, which are two columns and one voice -- then the columns
        # that have nowhere else to go, behind the marker that makes them
        # trivial to strip again.
        sig { returns(T.nilable(String)) }
        def remarks
          dates_of_birth # for its side effect: it is what fills @unread_dates, which #extras keeps
          Remarks.build(published_prose, extras)
        end

        sig { returns(String) }
        def inspect = "#<#{self.class} #{source_ref} #{rows.size} row(s)>"

        private

        # The row DFAT calls the primary name, falling back to the first row of
        # the group: a group with no primary name is not published today, and if
        # one ever is, its aliases still describe a real designation.
        sig { returns(Parsers::Spreadsheet::Row) }
        def primary
          @primary ||= T.let(rows.find { |row| row[:name_type].to_s.downcase == "primary name" } || T.must(rows.first),
                             T.nilable(Parsers::Spreadsheet::Row))
        end

        # One column across every row of the group, blanks dropped, order kept.
        # Unioned rather than read off the primary row -- see the class comment
        # on the 79 groups that disagree with themselves.
        #
        # De-duplicated on the collapsed text rather than on the string, because
        # DFAT's repetition is not always byte-for-byte: an alias row routinely
        # repeats the primary row's address or place of birth with one more
        # trailing space, and keeping both would print the same sentence twice
        # in the remark.
        sig { params(name: Symbol).returns(T::Array[String]) }
        def column(name)
          seen = T.let({}, T::Hash[String, String])
          rows.each do |row|
            text = row[name]
            key = collapse(text)
            seen[key] ||= T.must(text).strip if key
          end
          seen.values
        end

        sig { params(row: Parsers::Spreadsheet::Row).returns(T.nilable(Name)) }
        def name(row)
          value = collapse(row[:name_of_individual_or_entity])
          return nil if value.nil?

          Name.new(value: value, kind: NAME_KINDS.fetch(row[:name_type].to_s.downcase, :aka),
                   quality: ALIAS_QUALITIES[row[:alias_strength].to_s.downcase])
        end

        # A spelling published twice is two index entries that can only ever
        # fire together. The first wins, so a name published as primary keeps
        # its kind.
        sig { params(published: T::Array[Name]).returns(T::Array[Name]) }
        def dedupe(published)
          seen = T.let({}, T::Hash[String, Name])
          published.each { |name| seen[name.value] ||= name }
          seen.values
        end

        sig { params(cell: String).returns(T::Array[PartialDate]) }
        def read_dates(cell)
          dates, unread = PublishedDate.dates(cell)
          @unread_dates.concat(unread - dates.map(&:to_s))
          dates
        end

        sig { params(line: String).returns(T.nilable(Address)) }
        def address(line)
          Address.new(street: collapse(line))
        rescue ArgumentError
          nil
        end

        sig { params(number: String).returns(T.nilable(Identifier)) }
        def identifier(number)
          Identifier.new(kind: :other, value: number, note: "IMO number")
        rescue ArgumentError
          nil
        end

        # The two columns DFAT writes prose in: the detail that identifies the
        # person, and the account of how the listing came about. Both are the
        # publisher's own words, so both are kept ahead of the marker.
        sig { returns(T.nilable(String)) }
        def published_prose
          prose = (column(:additional_information) + column(:listing_information)).filter_map { |text| collapse(text) }
          prose.empty? ? nil : prose.uniq.join(PARAGRAPH)
        end

        # Label/value pairs for Remarks.build, which drops the ones the record
        # left blank.
        sig { returns(T::Array[T.untyped]) }
        def extras
          EXTRA_FIELDS.map { |name, label| [label, column(name)] } +
            [["Measures", measures], ["Date of birth, as published", @unread_dates.uniq]]
        end

        # The measures actually imposed, named rather than left as the four ones
        # and zeroes DFAT publishes them as.
        sig { returns(T::Array[String]) }
        def measures
          MEASURES.filter_map { |name, label| label if column(name).any? { |value| TRUTHY.include?(value.downcase) } }
        end

        sig { params(value: T.untyped).returns(T.nilable(String)) }
        def collapse(value)
          return nil if value.nil?

          text = value.to_s.gsub(WHITESPACE, " ").strip
          text.empty? ? nil : text
        end
      end
    end
  end
end
