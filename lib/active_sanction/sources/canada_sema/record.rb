# frozen_string_literal: true

require "active_sanction/entity"
require "active_sanction/name"
require "active_sanction/identifier"
require "active_sanction/partial_date"
require "active_sanction/parsers"
require "active_sanction/sources/remarks"
require "active_sanction/sources/canada_sema/source_ref"

module ActiveSanction
  module Sources
    class CanadaSema < Base
      # One `<record>` turned into an Entity.
      #
      # Separate from the adapter because they are two jobs: the adapter says
      # what the list is and where it lives, and this says what Global Affairs'
      # elements mean. The mapping is where all the judgment sits, so it is
      # worth being able to read it on its own.
      #
      # Every element is optional and the file has no nesting, so which of the
      # three record shapes a `<record>` is has to be read off which elements
      # it happens to carry. See #type.
      class Record
        COUNTRY = "Country-Pays"
        LAST_NAME = "LastName-NomDeFamille"
        GIVEN_NAME = "GivenName-Prenom"
        ENTITY_OR_SHIP = "EntityOrShip-EntiteOuNavire"
        ALIASES = "Aliases-Alias"
        TITLE_OR_SHIP_TYPE = "TitleOrShipType-TitreOuTypeDeNavire"
        IMO = "ShipIMONumber-NumeroOMIDuNavire"
        BORN_OR_BUILT = "DateOfBirthOrShipBuildDate-DateDeNaissanceOuDateDeConstructionDuNavire"
        SCHEDULE = "Schedule-Annexe"
        ITEM = "Item-NumeroDarticle"
        LISTED_ON = "DateOfListing-DateDinscription"

        # The bilingual separator, which is not one string. Countries pair on
        # ` / ` and vessel types and titles pair on `|`, which the publisher
        # writes with a space on neither, either or both sides and sometimes
        # with a line break inside the half either side of it. The English half
        # is the one before the first separator; whichever separator comes
        # first in the string is the one that split it.
        BILINGUAL = %r{\s*\|\s*|\s+/\s+}

        # The one separator in the alias field that means what it looks like.
        # See CanadaSema's class comment for why the comma is left alone.
        ALIAS_SEPARATOR = ";"

        # Nine of the 2,598 published dates are two candidate dates rather than
        # one -- `1972-08-26 or 1974-05-31`, `1987/1988` -- which is exactly
        # what `Entity#dates_of_birth` is plural for. Only consulted after the
        # whole string has failed to parse, so `1963-1964` stays the span the
        # publisher wrote and no ISO date is ever split on its own separator.
        ALTERNATIVES = %r{\s+or\s+|\s*/\s*}i

        # Every element carrying a name or a name-like string arrives padded
        # with whitespace the publisher did not mean, and 764 of those pads are
        # U+00A0 rather than a space -- which `String#strip` does not touch, so
        # `Premier ` would reach the matcher as a name nothing types.
        WHITESPACE = /[[:space:]]+/

        # For comparing two names the publisher wrote with different
        # punctuation, which is the only thing that makes an alias a duplicate
        # of the primary name rather than a second name.
        INSIGNIFICANT = /[^[:alnum:]]+/

        attr_reader :node, :warnings

        def initialize(node)
          @node = node
          @warnings = []
        end

        # The entity, or nil for a record with no name in any of its three name
        # elements -- which cannot be screened against and is never what Global
        # Affairs meant to publish.
        def entity
          return nil if names.empty?

          Entity.new(source: :canada_sema, source_ref: source_ref, type: type, names: names,
                     identifiers: identifiers, dates_of_birth: dates_of_birth,
                     programs: programs, listed_on: listed_on, remarks: remarks)
        end

        # An IMO number is only ever published for a ship, and a ship's name is
        # published in the same element an organization's is, so the number is
        # what separates them. The 1,445 records naming an entity with no IMO
        # number are called organizations: some of them may be ships the
        # publisher gave no number for, and nothing in the file says which.
        def type
          return :vessel unless node.null?(IMO)

          node.null?(ENTITY_OR_SHIP) ? :individual : :organization
        end

        # Derived, because Canada publishes no id at all. See SourceRef.
        def source_ref
          @source_ref ||= SourceRef.for(country: node[COUNTRY], schedule: node[SCHEDULE],
                                        item: node[ITEM], name: primary_name)
        end

        # The primary name, then every alias the publisher separated
        # unambiguously, minus any that is only the primary name repunctuated.
        def names
          @names ||= build_names
        end

        # `Country-Pays` is not a nationality and must never be read as one:
        # a Ukrainian official listed under the Special Economic Measures
        # (Russia) Regulations is published under `Russia / Russie`. What the
        # element names is the regulation the person is listed by, which is a
        # sanctions program -- and for 80 of the records it says so outright,
        # naming the Justice for Victims of Corrupt Foreign Officials
        # Regulations rather than a country at all.
        def programs = [english(node[COUNTRY])].compact

        def listed_on = PartialDate.parse(node[LISTED_ON])

        # Empty for a vessel: the element it would come from is the ship's
        # build date, and a hull laid down in 1980 has not got a date of birth.
        def dates_of_birth
          return [] if type == :vessel

          @dates_of_birth ||= published_dates
        end

        # A ship's IMO number, which is permanent, unique and assigned by the
        # IMO rather than by an owner -- so it is by far the most decisive
        # thing this list publishes about anything. Filed as a registration
        # number, which is what it is, with the note saying whose.
        def identifiers
          return [] if node.null?(IMO)

          [Identifier.new(kind: :registration_number, value: collapse(node[IMO]), note: "IMO number")]
        rescue ArgumentError
          []
        end

        # Canada publishes no free text of its own -- there is no comment or
        # remarks element anywhere in the file -- so everything here is behind
        # the marker, and `Remarks.published` on a Canadian record is correctly
        # nil. What is kept is the citation the id was derived from, which is
        # what an examiner needs to look a listing up in the Gazette, and both
        # halves of every bilingual value verbatim.
        def remarks = Remarks.build(nil, extras)

        private

        def build_names
          primary = primary_name
          return [] if primary.nil?

          names = [Name.new(value: primary, kind: :primary)]
          alias_values.each do |value|
            next if names.any? { |name| comparable(name.value) == comparable(value) }

            names << Name.new(value: value, kind: :aka)
          end
          names
        end

        # Canada files a person under surname then given names, which joined in
        # that order reads "Balaba Dmitry Vladimirovich" -- not how anyone types
        # a name into a screening form. The parts are joined the way they are
        # spoken instead; the publisher's filing order is not lost, because the
        # two elements are what the remark records the citation against.
        def primary_name
          @primary_name ||= collapse(node[ENTITY_OR_SHIP]) ||
                            collapse([node[GIVEN_NAME], node[LAST_NAME]].compact.join(" "))
        end

        def alias_values
          collapse(node[ALIASES]).to_s.split(ALIAS_SEPARATOR).filter_map { |value| collapse(value) }
        end

        def comparable(value) = value.gsub(INSIGNIFICANT, "").downcase

        # A date the whole string reads as, or the two candidates it reads as
        # when split. Anything else is kept verbatim in the remark and warned
        # about rather than dropped: `born in the early 1970s` is real signal
        # that this class has no shape for.
        def published_dates
          raw = collapse(node[BORN_OR_BUILT])
          return [] if raw.nil?

          whole = PartialDate.parse(raw)
          return [whole] unless whole.nil?

          alternatives(raw)
        end

        def alternatives(raw)
          dates = raw.split(ALTERNATIVES).filter_map { |part| PartialDate.parse(part) }
          note_unreadable(raw) if dates.empty?
          dates
        end

        def note_unreadable(raw)
          @warnings << Parsers::Warning.new(
            line: node.line,
            message: "#{primary_name.inspect} has a date this parser does not read (#{raw.inspect}); " \
                     "it was kept in remarks instead"
          )
        end

        # Label/value pairs for Remarks.build, which drops the ones the record
        # left blank. The bilingual values go in whole: the English half is
        # what the canonical fields carry, and the remark is where the French
        # the publisher wrote survives. Only the publisher's own line wrapping
        # is taken out -- sixteen vessel types are published with a newline
        # mid-phrase, and a remark is a line in a report.
        def extras
          [["Country", node[COUNTRY]], ["Schedule", node[SCHEDULE]], ["Item", node[ITEM]],
           [title_label, node[TITLE_OR_SHIP_TYPE]], *date_extras]
            .map { |label, value| [label, collapse(value)] }
        end

        # One element, two meanings, split by what the record is -- the same
        # split the date element needs, for the same reason.
        def title_label = type == :vessel ? "Vessel type" : "Title"

        # A build year for a ship, and for anyone else the date string only if
        # nothing could be read from it, so a date already in `dates_of_birth`
        # is not also printed here.
        def date_extras
          return [["Built", node[BORN_OR_BUILT]]] if type == :vessel
          return [] if dates_of_birth.any?

          [["Date of birth", node[BORN_OR_BUILT]]]
        end

        # The English half of a value the publisher wrote in both languages,
        # and the whole of one it wrote in only one.
        def english(value) = collapse(value.to_s.split(BILINGUAL, 2).first)

        def collapse(value)
          string = value.to_s.split(WHITESPACE).join(" ")
          string.empty? ? nil : -string
        end
      end
    end
  end
end
