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
    class EuFsf < Base
      # One `<sanctionEntity>` turned into an Entity.
      #
      # Separate from the adapter because they are two jobs: the adapter says
      # what the list is and where it lives, and this says what the
      # Commission's elements mean. The mapping is where all the judgment sits,
      # so it is worth being able to read it on its own.
      #
      # ### Nearly everything is an attribute
      #
      # The FSF export puts its data in attributes and its prose in elements:
      # a name is `<nameAlias wholeName="...">` and the only text nodes in the
      # whole 25.7 MB file are `<remark>` and `<publicationUrl>`. So most reads
      # here are the toolkit's `@attribute` paths, and the `<remark>` child of
      # a name, a date, an address or a document is the one place the
      # Commission writes free prose about that one field.
      #
      # ### The regulation trail this deliberately flattens
      #
      # Every repeated element carries a `<regulationSummary>` naming the act
      # that put it there, so the file records not just that a person has an
      # address but which regulation added it. That is a provenance graph, and
      # the canonical Entity is not one: what survives here is the entity's own
      # current `<regulation>` -- its programme, its number and its Official
      # Journal URL -- and the per-field trail is dropped rather than
      # flattened into 31,053 remark fragments nothing reads.
      class Record
        extend T::Sig

        TYPES = T.let({ "person" => :individual, "enterprise" => :organization }.freeze,
                      T::Hash[String, Symbol])

        # `identificationTypeCode` is a closed vocabulary of 18 values, which
        # is why this maps codes rather than the free-text description beside
        # them. Anything unrecognised is :other, which is a real answer: a
        # document we cannot classify still matches on its number, and the
        # Commission's own description is kept in the note either way.
        DOCUMENT_KINDS = T.let({
          "passport" => :passport,
          "id" => :national_id, "ssn" => :national_id, "unssn" => :national_id,
          "fiscalcode" => :tax_id, "taxid" => :tax_id, "euvat" => :tax_id,
          "regnumber" => :registration_number, "tradelic" => :registration_number
        }.freeze, T::Hash[String, Symbol])

        # The EU publishes no alias-quality column and no alias-kind column.
        # What it publishes instead is prose in a name's `<remark>`: "low
        # quality alias", "Good quality a.k.a.", "formerly known as", "Maiden
        # name: Al Akhras". Read, because a low-quality alias is a weaker
        # signal and the scorer (#32) penalizes it, and because a former name
        # is a real hit that should not rank as a current one.
        #
        # ### Why these are anchored to the start of a clause
        #
        # Searching the remark for the phrase anywhere is what a first version
        # did, and it is wrong on real records. The remark on Zadna
        # International's own name is five lines about the company, one of
        # which reads "99 % owned by the Special Fund ..., formerly known as
        # the Charity Organisation for the Support of the Armed Forces" -- a
        # sentence about the *owner*. Matched loosely it files the company's
        # published English name as a former name and promotes the French
        # translation in its place, on a record where the Commission said no
        # such thing.
        #
        # A grading is a whole annotation, so it starts one: the remark is cut
        # into clauses at newlines and semicolons -- which is how the
        # Commission writes them, "born 11.8.1960 in Libya\ngood quality
        # alias" -- and a clause grades the name only if it begins with one of
        # these. Every embedded occurrence in the published file is prose about
        # some other entity, and every standalone one is a grading.
        LOW_QUALITY = T.let(/\Alow[[:space:]]+quality[[:space:]]+(?:alias|a\.k\.a)/i, Regexp)
        GOOD_QUALITY = T.let(/\A(?:good|high)[[:space:]]+quality[[:space:]]+(?:alias|a\.k\.a)/i, Regexp)
        FORMER_NAME = T.let(
          /\A(?:formerly[[:space:]]+known[[:space:]]+as|former[[:space:]]+name|f\.k\.a|maiden[[:space:]]+name)/i,
          Regexp
        )

        # What the Commission separates annotations with, and the punctuation
        # it opens one with -- `(formerly known as State enterprise ...)`.
        CLAUSE = T.let(/[\n;]/, Regexp)
        CLAUSE_OPENING = T.let(/\A[[:space:]("'\u2018]+/, Regexp)

        # `calendarType`, and the one value that means the date components can
        # be read as they are written. See the adapter's class comment for what
        # reading a Hijri year as a Gregorian one does to a score.
        GREGORIAN = T.let("GREGORIAN", String)

        # The Commission's own sentinel for "not stated", published in the
        # ISO 3166 field with `countryDescription="UNKNOWN"` beside it. 1,743
        # of the 4,373 birth dates carry it, and passing it through would file
        # 1,743 people as citizens of a country called `00`.
        UNKNOWN_COUNTRY = T.let("00", String)

        UNKNOWN_COUNTRY_NAME = T.let("UNKNOWN", String)

        # Every boolean in the export is the lowercase string, on the
        # attribute rather than as a present-or-absent flag: `circa="false"`
        # appears 4,176 times. So a flag is read by comparing, and the absent
        # attribute -- which is a different thing from `"false"` -- is nil and
        # compares false without a branch.
        BOOLEAN_TRUE = T.let("true", String)

        # Attributes that say something about a document rather than
        # identifying it, kept in the identifier's note. `knownFalse` is on one
        # document in the whole file and is the most important of them: it is
        # the Commission saying the number is a forgery.
        DOCUMENT_FLAGS = T.let({
          "knownFalse" => "known false", "knownExpired" => "known expired",
          "revokedByIssuer" => "revoked by issuer", "reportedLost" => "reported lost",
          "diplomatic" => "diplomatic"
        }.freeze, T::Hash[String, String])

        # The parts of a place of birth, which the canonical model has no home
        # for and which are on 2,462 of the 4,373 birthdate elements. Ordered
        # from the most specific to the least, the way an address reads.
        PLACE_PARTS = T.let(%w[@place @city @region].freeze, T::Array[String])

        WHITESPACE = T.let(/[[:space:]]+/, Regexp)

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
        # screened against and is never what the Commission meant to publish.
        sig { returns(T.nilable(Entity)) }
        def entity
          return nil if names.empty?

          Entity.new(source: :eu_fsf, source_ref: source_ref, type: type, names: names,
                     addresses: addresses, identifiers: identifiers, dates_of_birth: dates_of_birth,
                     nationalities: nationalities, programs: programs, listed_on: listed_on,
                     remarks: remarks)
        end

        sig { returns(Symbol) }
        def type = TYPES.fetch(node["subjectType/@code"].to_s, :organization)

        # `euReferenceNumber` rather than `logicalId`: both are unique across
        # all 6,234 records, but the reference number is the one the
        # Commission prints in its own consolidated list and the one a person
        # checking a hit against the official file can search for. The internal
        # id is kept in remarks so the two can still be reconciled.
        sig { returns(T.nilable(String)) }
        def source_ref = node["@euReferenceNumber"]

        # ISO 3166 alpha-2, which is what the scorer compares on, rather than
        # the shouty description beside it. Three withdrawn codes are in the
        # file -- AN, CS and YU, for states that no longer exist -- and
        # Country resolves none of them, which Scorer::Adjustments reads as
        # absent rather than as a conflict. That is the right answer: nobody
        # holds a Yugoslav passport to contradict.
        sig { returns(T::Array[String]) }
        def nationalities
          node.values("citizenship/@countryIso2Code").reject { |code| code == UNKNOWN_COUNTRY }.uniq
        end

        # The date the Council designated the entity, which 5,654 of the 6,234
        # records carry. Not the regulation's publication date: a record is
        # amended by later acts, so `regulation/@publicationDate` moves while
        # this does not.
        sig { returns(T.nilable(PartialDate)) }
        def listed_on = PartialDate.parse(node["@designationDate"])

        sig { returns(T::Array[String]) }
        def programs = node.values("regulation/@programme").uniq

        sig { returns(T::Array[Name]) }
        def names
          @names ||= promote(published_names)
        end

        # Memoized, because reading them is also what fills the list of dates
        # this could not use -- a Hijri year with no Gregorian equivalent, a
        # half-open span -- which #remarks then keeps rather than losing.
        sig { returns(T::Array[PartialDate]) }
        def dates_of_birth
          @dates_of_birth ||= begin
            @unread_dates = []
            # Deduped: one Saudi record publishes the same day three times,
            # twice as itself and once as the Gregorian rendering of a Hijri
            # date. Three copies of one date are three ways to say the same
            # thing to a comparison that already reads it once.
            node.nodes("birthdate").filter_map { |born| date_of_birth(born) }.uniq
          end
        end

        sig { returns(T::Array[Identifier]) }
        def identifiers
          node.nodes("identification").filter_map { |document| identifier(document) }
        end

        sig { returns(T::Array[Address]) }
        def addresses
          node.nodes("address").filter_map { |place| address(place) }
        end

        # The Commission's own comment verbatim, then the elements that have
        # nowhere else to go, behind the marker that makes them trivial to
        # strip again.
        sig { returns(T.nilable(String)) }
        def remarks
          dates_of_birth # for its side effect: it is what fills @unread_dates, which #extras keeps
          Remarks.build(node["remark"], extras)
        end

        private

        # Every `<nameAlias>` the record carries, in document order, deduped on
        # the published spelling: 222 records file the same string twice under
        # two `nameLanguage` values, and two identical Names are two index
        # entries that can only ever fire together.
        sig { returns(T::Array[Name]) }
        def published_names
          seen = T.let({}, T::Hash[String, Name])
          node.nodes("nameAlias").each do |alt|
            value = collapse(alt["@wholeName"])
            next if value.nil? || seen.key?(value)

            annotation = clauses(alt["remark"])
            seen[value] = Name.new(value: value, kind: alias_kind(annotation),
                                   quality: alias_quality(annotation))
          end
          seen.values
        end

        # The EU marks no name as the official one, so one is chosen: the first
        # the Commission published that it did not itself annotate as an alias.
        # 24 records lead with a name their own remark calls a low-quality
        # alias or a former name, and promoting one of those would report a hit
        # under a spelling the Commission had flagged as weak.
        #
        # The script is left unstated throughout, the same choice the UN
        # adapter makes: which script a string is in is a question about its
        # characters, and `nameLanguage` does not answer it -- record
        # EU.2797.3 files a Cyrillic spelling under `nameLanguage="EN"`.
        sig { params(published: T::Array[Name]).returns(T::Array[Name]) }
        def promote(published)
          chosen = published.find { |name| name.kind == :aka && name.quality.nil? } || published.first
          published.map do |name|
            name.equal?(chosen) ? Name.new(value: name.value, kind: :primary, quality: name.quality) : name
          end
        end

        sig { params(annotation: T.untyped).returns(T::Array[String]) }
        def clauses(annotation)
          annotation.to_s.split(CLAUSE).map { |clause| clause.sub(CLAUSE_OPENING, "") }
        end

        sig { params(annotation: T::Array[String]).returns(Symbol) }
        def alias_kind(annotation)
          annotation.any? { |clause| clause.match?(FORMER_NAME) } ? :fka : :aka
        end

        sig { params(annotation: T::Array[String]).returns(T.nilable(Symbol)) }
        def alias_quality(annotation)
          return :low if annotation.any? { |clause| clause.match?(LOW_QUALITY) }

          :good if annotation.any? { |clause| clause.match?(GOOD_QUALITY) }
        end

        # A Hijri date is not a Gregorian one, and the components hold the
        # Hijri reading: `year="1343"` for a man born in 1964. Where the
        # Commission also supplied `birthdate` -- which it does on one of the
        # four -- that attribute is already converted and is read; where it did
        # not, there is no date here at all, and the published one goes to
        # remarks rather than into a comparison it would poison.
        sig { params(born: Parsers::XmlRecords::Record).returns(T.nilable(PartialDate)) }
        def date_of_birth(born)
          return converted(born) unless born["@calendarType"] == GREGORIAN

          approximate = born["@circa"] == BOOLEAN_TRUE
          point(born, approximate) || span(born, approximate) || note_unread(born)
        end

        sig { params(born: Parsers::XmlRecords::Record, approximate: T::Boolean).returns(T.nilable(PartialDate)) }
        def point(born, approximate)
          year = born["@year"]
          return nil if year.nil?

          PartialDate.new(year: year, month: born["@monthOfYear"], day: born["@dayOfMonth"],
                          approximate: approximate)
        rescue ArgumentError
          nil
        end

        # `yearRangeFrom` and `yearRangeTo`, on 55 records. One record in the
        # file carries only the `to` half, which is a claim about an interval
        # with no beginning: PartialDate has no shape for it, and inventing one
        # end of a span is exactly the false precision it exists to prevent.
        sig { params(born: Parsers::XmlRecords::Record, approximate: T::Boolean).returns(T.nilable(PartialDate)) }
        def span(born, approximate)
          from = born["@yearRangeFrom"]
          to = born["@yearRangeTo"]
          return nil if from.nil? || to.nil?

          PartialDate.range(from, to, approximate: approximate)
        rescue ArgumentError
          nil
        end

        sig { params(born: Parsers::XmlRecords::Record).returns(T.nilable(PartialDate)) }
        def converted(born)
          PartialDate.parse(born["@birthdate"]) || note_unread(born)
        end

        # A birthdate element that gave no usable date. 110 of them are a place
        # of birth and nothing else, which #extras already keeps; what is
        # recorded here is the rest -- the Hijri dates and the half-open span
        # -- so that nothing the Commission published about when a person was
        # born disappears silently.
        sig { params(born: Parsers::XmlRecords::Record).returns(NilClass) }
        def note_unread(born)
          published = [born["@birthdate"], born["@year"], span_text(born)].compact
          return nil if published.empty?

          calendar = born["@calendarType"].to_s
          suffix = " (#{calendar.downcase} calendar)" unless calendar == GREGORIAN
          @unread_dates << "#{published.join(" ")}#{suffix}"
          nil
        end

        # A span with one end missing, written so that the missing end is
        # visible rather than implied.
        sig { params(born: Parsers::XmlRecords::Record).returns(T.nilable(String)) }
        def span_text(born)
          from = born["@yearRangeFrom"]
          to = born["@yearRangeTo"]
          return nil if from.nil? && to.nil?

          "#{from || "?"} to #{to || "?"}"
        end

        # `number` is populated on all 3,013 identification elements, but six
        # of them hold `-`, which is the Commission writing "no number" in the
        # number field. Identifier refuses a value with no alphanumerics and
        # those six are dropped: a document with a type and no identity is
        # nothing to match on, which is the same call the UN adapter makes
        # about the 447 numberless documents on its list.
        #
        # The kind that could not be classified still keeps the Commission's
        # own description, which is what a person reading the hit needs.
        sig { params(document: Parsers::XmlRecords::Record).returns(T.nilable(Identifier)) }
        def identifier(document)
          Identifier.new(kind: document_kind(document), value: document["@number"],
                         country: country(document),
                         issued_on: PartialDate.parse(document["@issueDate"] || document["@validFrom"]),
                         expires_on: PartialDate.parse(document["@validTo"]),
                         note: document_note(document))
        rescue ArgumentError
          nil
        end

        sig { params(document: Parsers::XmlRecords::Record).returns(Symbol) }
        def document_kind(document)
          DOCUMENT_KINDS.fetch(document["@identificationTypeCode"].to_s.downcase, :other)
        end

        sig { params(document: Parsers::XmlRecords::Record).returns(T.nilable(String)) }
        def document_note(document)
          flags = DOCUMENT_FLAGS.filter_map { |attribute, label| label if document["@#{attribute}"] == BOOLEAN_TRUE }
          parts = [document["@identificationTypeDescription"], document["@issuedBy"], document["@region"],
                   document["remark"], *flags]
          joined = parts.compact.join("; ")
          joined.empty? ? nil : joined
        end

        # An address element that located nothing is dropped rather than kept
        # empty: it cannot be screened on and would only inflate the count.
        # 87 of the 2,648 carry the `00` country sentinel and nothing else.
        sig { params(place: Parsers::XmlRecords::Record).returns(T.nilable(Address)) }
        def address(place)
          Address.new(street: place["@street"], city: place["@city"], state_province: place["@region"],
                      postal_code: place["@zipCode"], country: country(place), note: address_note(place))
        rescue ArgumentError
          nil
        end

        # `poBox` and `place` have no member of their own on Address, and
        # `contactInfo` -- a web site, a phone number, an email address, on
        # 1,681 of the addresses -- has nowhere at all. All of it is real
        # locating detail, so it goes to the note rather than over the side.
        sig { params(place: Parsers::XmlRecords::Record).returns(T.nilable(String)) }
        def address_note(place)
          contacts = place.nodes("contactInfo").map { |info| "#{info["@key"]}: #{info["@value"]}" }
          box = place["@poBox"]
          parts = [box && "P.O. Box #{box}", place["@place"], place["remark"], *contacts,
                   ("as at listing time" if place["@asAtListingTime"] == BOOLEAN_TRUE)]
          joined = parts.compact.join("; ")
          joined.empty? ? nil : joined
        end

        # The Commission's prose name for a country, or nil for its sentinel.
        # Prose rather than the code beside it because Address#country and
        # Identifier#country are what a reviewer reads, and `IQ` is not.
        sig { params(element: Parsers::XmlRecords::Record).returns(T.nilable(String)) }
        def country(element)
          return nil if element["@countryIso2Code"] == UNKNOWN_COUNTRY

          name = element["@countryDescription"]
          name == UNKNOWN_COUNTRY_NAME ? nil : name
        end

        # Label/value pairs for Remarks.build, which drops the ones the record
        # left blank. A value may be several -- one person's function is filed
        # once per name -- and arrives as the Array it published.
        sig { returns(T::Array[T.untyped]) }
        def extras
          [["EU logical id", node["@logicalId"]],
           ["UN reference", node["@unitedNationId"]],
           ["Designation details", node["@designationDetails"]],
           ["Regulation", node["regulation/@numberTitle"]],
           ["Official Journal", node["regulation/publicationUrl"]],
           ["Function", node.values("nameAlias/@function").uniq],
           ["Title", node.values("nameAlias/@title").uniq],
           ["Gender", node.values("nameAlias/@gender").uniq],
           ["Date of birth as published", @unread_dates]] + places_of_birth
        end

        # A place of birth is real screening signal and the canonical model has
        # no home for it, so it is kept rather than dropped to keep a schema
        # tidy. One line per birthdate element, because a person with two
        # reported birth dates usually has two reported birth places.
        sig { returns(T::Array[T.untyped]) }
        def places_of_birth
          places = node.nodes("birthdate").filter_map do |born|
            parts = PLACE_PARTS.filter_map { |part| born[part] } + [country(born)].compact
            parts.join(", ") if parts.any?
          end
          places.uniq.map { |place| ["Place of birth", place] }
        end

        # The Commission's own line wrapping arrives inside attribute values:
        # 2,149 of the 31,053 names carry a newline, a run of spaces, or
        # padding on one side. Left verbatim those produce "Ivan  Ivanov",
        # which is a name nothing will ever match.
        sig { params(value: T.untyped).returns(T.nilable(String)) }
        def collapse(value)
          string = value.to_s.split(WHITESPACE).join(" ")
          string.empty? ? nil : -string
        end
      end
    end
  end
end
