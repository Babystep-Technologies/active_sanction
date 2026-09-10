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
    class UkSanctionsList < Base
      # One `<Designation>` turned into an Entity.
      #
      # Separate from the adapter because they are two jobs: the adapter says
      # what the list is and where it lives, and this says what the FCDO's
      # elements mean. The mapping is where all the judgment sits, so it is
      # worth being able to read it on its own.
      #
      # ### A name is six numbered parts, in order
      #
      # The FCDO splits a name across `<Name1>` to `<Name6>`: given names
      # ascending, and `<Name6>` holding the family name -- or, for an
      # organization or a ship, the whole name on its own, which is why
      # `<Name6>` is populated on 15,647 of the 15,677 names and `<Name1>` on
      # 9,691. Joined in numeric order they read the way the name is said:
      # `ABDUL KABIR MUHAMMAD JAN`, `ABDUL SALAM HANAFI ALI MARDAN QUL`.
      #
      # Note that the CSV rendering of this same list orders its columns
      # `Name 6, Name 1, Name 2, ...`, which is the FCDO filing surname-first
      # for a reader and not a different name. Following that order here would
      # produce `JAN ABDUL KABIR MUHAMMAD`, which is a string no query will
      # match and no publisher wrote.
      #
      # ### `Primary Name Variation` is an alias, and 5,513 names depend on it
      # not being treated as one more primary
      #
      # The FCDO publishes three name types. `Primary Name` is the designation
      # proper. `Alias` is a different name the person is known by. `Primary
      # Name Variation` is a different *spelling* of the primary name -- the
      # four rows `MITHOO`, `MITHU`, `MITTO`, `MITTU` against one Pakistani
      # cleric -- and it is by far the most common thing on the list after the
      # aliases themselves. All of them are real screening signal and none of
      # them is the official name, so a variation is filed as `:aka`, which is
      # what leaves `Entity#primary_name` answering with the name the FCDO
      # actually designated.
      #
      # @api private
      class Record
        extend T::Sig

        TYPES = T.let(
          { "individual" => :individual, "entity" => :organization, "ship" => :vessel }.freeze,
          T::Hash[String, Symbol]
        )

        # `NameType`, case-folded. The list contains `Primary Name`, `Primary
        # name`, `Primary Name Variation`, `Primary name variation`, `Alias`
        # and one `ALias`, which is the whole reason this is a folded lookup
        # rather than a comparison.
        NAME_KINDS = T.let(
          { "primary name" => :primary, "primary name variation" => :aka, "alias" => :aka }.freeze,
          T::Hash[String, Symbol]
        )

        # `AliasStrength`, which the FCDO publishes as exactly two strings on
        # 2,073 names and leaves absent on the rest. Absent is nil rather than
        # good: an ungraded name must not be penalized for a field the FCDO
        # did not fill in, and must not be credited for one either.
        ALIAS_QUALITIES = T.let(
          { "good quality a.k.a" => :good, "low quality a.k.a" => :low }.freeze,
          T::Hash[String, Symbol]
        )

        # Name parts, in the order they are said.
        NAME_PARTS = T.let((1..6).map { |part| "Name#{part}" }.freeze, T::Array[String])

        # Address lines 1 to 5 are the street and the locality detail; line 6
        # is the last line the FCDO writes before the country. See #address.
        STREET_LINES = T.let((1..5).map { |line| "AddressLine#{line}" }.freeze, T::Array[String])

        # 635 of the 670 IMO numbers are published as `IMO9562233` and the
        # other 35 as `9562233`. The prefix restates the element the number is
        # already inside, and Identifier compares on alphanumerics -- so left
        # alone the FCDO's own two spellings of one registry number are two
        # different identifiers, and a query for either finds one of them. It
        # is peeled off into the note, where it is still readable and no longer
        # part of what gets compared.
        IMO_PREFIX = T.let(/\AIMO[[:space:]]*(?=\d)/i, Regexp)

        # The FCDO's line wrapping arrives inside element text -- a statement
        # of reasons opens and closes on a newline -- and a name that keeps it
        # is a name nothing will ever match.
        WHITESPACE = T.let(/[[:space:]]+/, Regexp)

        # What separates the two prose fields once they are joined. See
        # #published_prose.
        PARAGRAPH = T.let("\n\n", String)

        sig { returns(Parsers::XmlRecords::Record) }
        attr_reader :node

        sig { params(node: Parsers::XmlRecords::Record).void }
        def initialize(node)
          @node = T.let(node, Parsers::XmlRecords::Record)
          @names = T.let(nil, T.nilable(T::Array[Name]))
          @dates_of_birth = T.let(nil, T.nilable(T::Array[PartialDate]))
          @unread_dates = T.let([], T::Array[String])
        end

        # The entity, or nil for a record with no name -- which cannot be
        # screened against and is never what the FCDO meant to publish.
        sig { returns(T.nilable(Entity)) }
        def entity
          return nil if names.empty?

          Entity.new(source: :uk_sanctions_list, source_ref: source_ref, type: type, names: names,
                     addresses: addresses, identifiers: identifiers, dates_of_birth: dates_of_birth,
                     nationalities: nationalities, programs: programs, listed_on: listed_on,
                     remarks: remarks)
        end

        # `IndividualEntityShip`, which is populated on every record and is the
        # only place the list says what a designation is about. A ship is a
        # `:vessel`, and there are 664 of them: without the distinct type a
        # search for a person can rank a tanker.
        sig { returns(Symbol) }
        def type = TYPES.fetch(node["IndividualEntityShip"].to_s.downcase, :organization)

        # `UniqueID` -- `AFG0001`, `RUS3379` -- rather than the OFSI Group ID
        # beside it. Both are unique where they are present, but the Group ID
        # is being retired: designations made since 28 January 2026 do not get
        # one, so an id built from it would be nil on everything the UK has
        # sanctioned this year. The historic Group ID is kept in remarks.
        sig { returns(T.nilable(String)) }
        def source_ref = node["UniqueID"]

        # Prose, the way the UN publishes it: `Russia`, `North Korea`,
        # `Congo (Democratic Republic)`. Country resolves it to an ISO code at
        # scoring time, and treats one it cannot resolve as absent rather than
        # as a conflict -- which is the answer that matters for `Kosovo`, a
        # nationality on ten of these records and a country with no ISO 3166-1
        # code to resolve to.
        sig { returns(T::Array[String]) }
        def nationalities = node.values("IndividualDetails/Individual/Nationalities/Nationality").uniq

        # The date the FCDO designated the entity, on all 6,334 records.
        sig { returns(T.nilable(PartialDate)) }
        def listed_on = PublishedDate.call(node["DateDesignated"])

        # The regime the designation is made under, which for this list is the
        # statutory instrument itself: `The Russia (Sanctions) (EU Exit)
        # Regulations 2019`. 31 of them cover the whole list, and it is the
        # closest thing the UK publishes to OFAC's programme codes -- the
        # measures actually imposed are a separate field, and are in remarks.
        sig { returns(T::Array[String]) }
        def programs = node.values("RegimeName").uniq

        sig { returns(T::Array[Name]) }
        def names
          @names ||= dedupe(published_names + non_latin_names)
        end

        # Memoized, because reading them is also what fills the list of dates
        # this could not use, which #remarks then keeps rather than losing.
        sig { returns(T::Array[PartialDate]) }
        def dates_of_birth
          @dates_of_birth ||= begin
            @unread_dates = []
            node.values("IndividualDetails/Individual/DOBs/DOB").filter_map { |born| date_of_birth(born) }.uniq
          end
        end

        # Passports and national identity numbers for a person, business
        # registration numbers for an organization, IMO numbers for a ship.
        # De-duplicated through Identifier's own equality, which compares a
        # number by its alphanumerics rather than by the punctuation around
        # them: the FCDO's export repeats a passport once per birth date, so
        # one Afghan record publishes the same number ten times.
        sig { returns(T::Array[Identifier]) }
        def identifiers = (passports + national_ids + registrations + imo_numbers).uniq

        sig { returns(T::Array[Address]) }
        def addresses
          node.nodes("Addresses/Address").filter_map { |place| address(place) }
        end

        # The FCDO's own prose verbatim -- its note on the designation and its
        # statement of reasons, which are two fields and one voice -- then the
        # elements that have nowhere else to go, behind the marker that makes
        # them trivial to strip again.
        sig { returns(T.nilable(String)) }
        def remarks
          dates_of_birth # for its side effect: it is what fills @unread_dates, which #extras keeps
          Remarks.build(published_prose, extras)
        end

        private

        # The two fields the FCDO writes prose in: its note on the designation,
        # and the legal case for it. Both are the publisher's own words and one
        # voice, so both are kept ahead of the marker -- what a consumer asking
        # what the FCDO said gets back should not depend on which of its two
        # boxes an examiner happened to type in.
        # nil for the 127 records the FCDO wrote neither field on, so that a
        # consumer asking what the publisher said is handed nothing rather than
        # a list of fields this adapter appended.
        sig { returns(T.nilable(String)) }
        def published_prose
          prose = [node["OtherInformation"], node["UKStatementofReasons"]].compact.map(&:strip).reject(&:empty?)
          prose.empty? ? nil : prose.join(PARAGRAPH)
        end

        # Every `<Name>` the record carries, in document order. 26 of the
        # 15,677 published carry a `NameType` and no part at all, and a
        # blank-valued Name is a record that matches everything.
        sig { returns(T::Array[Name]) }
        def published_names
          node.nodes("Names/Name").filter_map do |published|
            value = collapse(NAME_PARTS.filter_map { |part| published[part] }.join(" "))
            next nil if value.nil?

            Name.new(value: value, kind: name_kind(published), quality: alias_quality(published))
          end
        end

        # The name in the script the FCDO's source wrote it in -- Cyrillic for
        # 1,752 of them, Arabic for 179. Filed as an alias with no `script`
        # declared; the adapter's class comment says why the FCDO's own label
        # is not used to declare one.
        sig { returns(T::Array[Name]) }
        def non_latin_names
          node.values("NonLatinNames/NonLatinName/NameNonLatinScript").filter_map do |published|
            value = collapse(published)
            value && Name.new(value: value, kind: :aka)
          end
        end

        sig { params(published: Parsers::XmlRecords::Record).returns(Symbol) }
        def name_kind(published) = NAME_KINDS.fetch(published["NameType"].to_s.strip.downcase, :aka)

        sig { params(published: Parsers::XmlRecords::Record).returns(T.nilable(Symbol)) }
        def alias_quality(published) = ALIAS_QUALITIES[published["AliasStrength"].to_s.strip.downcase]

        # 36 names across 35 records repeat a spelling already on the record,
        # usually because the same string is filed once as a variation and once
        # as an alias. Two identical Names are two index entries that can only
        # ever fire together. The first wins, so a name published as primary
        # keeps its kind.
        sig { params(published: T::Array[Name]).returns(T::Array[Name]) }
        def dedupe(published)
          seen = T.let({}, T::Hash[String, Name])
          published.each { |name| seen[name.value] ||= name }
          seen.values
        end

        sig { params(born: String).returns(T.nilable(PartialDate)) }
        def date_of_birth(born)
          PublishedDate.call(born) || note_unread(born)
        end

        # A birth date string that gave no usable date -- today, the one record
        # published as `15/08/19yy`. Kept so that nothing the FCDO said about
        # when a person was born disappears silently.
        sig { params(born: String).returns(NilClass) }
        def note_unread(born)
          @unread_dates << born
          nil
        end

        sig { returns(T::Array[Identifier]) }
        def passports
          documents("IndividualDetails/Individual/PassportDetails/Passport", :passport,
                    "PassportNumber", "PassportAdditionalInformation")
        end

        sig { returns(T::Array[Identifier]) }
        def national_ids
          documents("IndividualDetails/Individual/NationalIdentifierDetails/NationalIdentifier", :national_id,
                    "NationalIdentifierNumber", "NationalIdentifierAdditionalInformation")
        end

        sig { params(path: String, kind: Symbol, number: String, information: String).returns(T::Array[Identifier]) }
        def documents(path, kind, number, information)
          node.nodes(path).filter_map do |document|
            identifier(kind: kind, value: document[number], note: document[information])
          end
        end

        # Kept exactly as published, prefixes and all. 340 of the 721 open with
        # a label -- `INN: 7710137066`, `OGRN: 1247700291200` -- and a further
        # handful carry two numbers, a country and a newline in one field. A
        # rule that peeled the label off `INN: 7710137066` would have to decide
        # what to do with `OGRN: 1247700291200\nKPP: 770701001\nINN:
        # 9707028663`, and every answer to that is a guess about free text.
        sig { returns(T::Array[Identifier]) }
        def registrations
          node.values("EntityDetails/Entity/BusinessRegistrationNumbers/BusinessRegistrationNumber")
              .filter_map { |number| identifier(kind: :registration_number, value: number) }
        end

        # Filed as :other because a ship's registry number is none of the
        # document kinds the model names, and it is a document rather than a
        # remark: an IMO number is unique, permanent and the one field on a
        # vessel record that a screening query can be decisive about.
        sig { returns(T::Array[Identifier]) }
        def imo_numbers
          node.values("ShipDetails/Ship/IMONumbers/IMONumber").filter_map do |number|
            identifier(kind: :other, value: number.sub(IMO_PREFIX, ""), note: "IMO number")
          end
        end

        # 8 of the 780 passport elements carry additional information and no
        # number. Identifier refuses a value with no alphanumerics, and those
        # are dropped: a document with a description and no identity is nothing
        # to match on, which is the same call the UN and EU adapters make.
        sig { params(kind: Symbol, value: T.untyped, note: T.untyped).returns(T.nilable(Identifier)) }
        def identifier(kind:, value:, note: nil)
          Identifier.new(kind: kind, value: value, note: note)
        rescue ArgumentError
          nil
        end

        # `AddressLine1` to `AddressLine5` are the street and the locality
        # detail, in order, and `AddressLine6` is the last line before the
        # country. Line 6 is filed under `city` whole rather than split on a
        # guess: it holds `Kabul` and `Dubai` on some records and `Helmand
        # Province` and `Nimroz Province` on others, and a rule that tried to
        # tell those apart would be wrong on both. 450 of the 3,816 addresses
        # have line 6 as their only line.
        sig { params(place: Parsers::XmlRecords::Record).returns(T.nilable(Address)) }
        def address(place)
          Address.new(street: join(STREET_LINES.filter_map { |line| place[line] }),
                      city: place["AddressLine6"], postal_code: place["AddressPostalCode"],
                      country: place["AddressCountry"])
        rescue ArgumentError
          nil
        end

        # Label/value pairs for Remarks.build, which drops the ones the record
        # left blank. A value may be several -- one person's positions are
        # filed one per element -- and arrives as the Array it published.
        sig { returns(T::Array[T.untyped]) }
        def extras
          [["OFSI group id", node["OFSIGroupID"]],
           ["UN reference", node["UNReferenceNumber"]],
           ["Designation source", node["DesignationSource"]],
           ["Sanctions imposed", node["SanctionsImposed"]],
           ["Last updated", node["LastUpdated"]],
           ["Title", node.values("Titles/Title")],
           ["Date of birth as published", @unread_dates]] + individual + organization + ship + contact
        end

        sig { returns(T::Array[T.untyped]) }
        def individual
          [["Gender", node.values("IndividualDetails/Individual/Genders/Gender").uniq],
           ["Position", node.values("IndividualDetails/Individual/Positions/Position")],
           ["Town of birth", node.values("IndividualDetails/Individual/BirthDetails/Location/TownOfBirth").uniq],
           ["Country of birth", node.values("IndividualDetails/Individual/BirthDetails/Location/CountryOfBirth").uniq]]
        end

        sig { returns(T::Array[T.untyped]) }
        def organization
          [["Type of entity", node.values("EntityDetails/Entity/TypeOfEntities/TypeOfEntity").uniq],
           ["Parent company", node.values("EntityDetails/Entity/ParentCompanies/ParentCompany")],
           ["Subsidiary", node.values("EntityDetails/Entity/Subsidiaries/Subsidiary")]]
        end

        # A ship's flag, owner and dimensions are real screening signal with no
        # home in the canonical model -- the same trade OFAC's adapter makes
        # for a vessel's tonnage and owner -- so they are kept here rather than
        # dropped to keep a schema tidy.
        sig { returns(T::Array[T.untyped]) }
        def ship
          { "Current owner/operator" => "CurrentOwnerOperators/CurrentOwnerOperator",
            "Previous owner/operator" => "PreviousOwnerOperators/PreviousOwnerOperator",
            "Current believed flag" => "CurrentBelievedFlagOfShips/CurrentBelievedFlagOfShip",
            "Previous flag" => "PreviousFlags/PreviousFlag",
            "Type of ship" => "TypeOfShipDetails/TypeOfShip",
            "Tonnage" => "TonnageOfShipDetails/TonnageOfShip",
            "Length" => "LengthOfShipDetails/LengthOfShip",
            "Year built" => "YearsBuilt/YearBuilt" }
            .map { |label, path| [label, node.values("ShipDetails/Ship/#{path}")] }
        end

        # Contact details, and the FCDO's own reading of the non-Latin names.
        # The script label is recorded rather than declared on the Name -- see
        # the adapter's class comment for the three records that say why.
        sig { returns(T::Array[T.untyped]) }
        def contact
          [["Phone", node.values("PhoneNumbers/PhoneNumber")],
           ["Website", node.values("Websites/Website")],
           ["Email", node.values("EmailAddresses/EmailAddress")],
           ["Non-Latin script", node.values("NonLatinNames/NonLatinName/NonLatinScriptType").uniq],
           ["Non-Latin language", node.values("NonLatinNames/NonLatinName/NonLatinScriptLanguage").uniq]]
        end

        sig { params(parts: T::Array[String]).returns(T.nilable(String)) }
        def join(parts) = parts.empty? ? nil : parts.join(", ")

        sig { params(value: T.untyped).returns(T.nilable(String)) }
        def collapse(value)
          string = value.to_s.split(WHITESPACE).join(" ")
          string.empty? ? nil : -string
        end
      end
    end
  end
end
