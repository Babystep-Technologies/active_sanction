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
    class UnConsolidated < Base
      # One `<INDIVIDUAL>` or `<ENTITY>` turned into an Entity.
      #
      # Separate from the adapter because they are two jobs: the adapter says
      # what the list is and where it lives, and this says what the UN's
      # elements mean. The mapping is where all the judgment sits, so it is
      # worth being able to read it on its own.
      #
      # The two record shapes are mapped by one class rather than two. Every
      # element that differs between them differs only by prefix --
      # `INDIVIDUAL_ALIAS` against `ENTITY_ALIAS`, `INDIVIDUAL_ADDRESS` against
      # `ENTITY_ADDRESS` -- so the prefix is taken from the record's own name.
      # An element only individuals have then resolves to a path entities do
      # not carry, which reads as absent, which is what it is.
      #
      # @api private
      class Record
        extend T::Sig

        TYPES = T.let({ UnConsolidated::INDIVIDUAL => :individual,
                        UnConsolidated::ENTITY => :organization }.freeze, T::Hash[String, Symbol])

        # The UN splits one name across up to four numbered elements, and any
        # subset may be present: 736 individuals have a FIRST_NAME, 170 have a
        # FOURTH_NAME, and an entity's whole name is in FIRST_NAME alone.
        NAME_PARTS = T.let(%w[FIRST_NAME SECOND_NAME THIRD_NAME FOURTH_NAME].freeze, T::Array[String])

        # `QUALITY` under `<INDIVIDUAL_ALIAS>` grades the alias. Published as
        # Good (1,534), Low (629), or blank (169).
        ALIAS_QUALITIES = T.let({ "good" => :good, "low" => :low }.freeze, T::Hash[String, Symbol])

        # `QUALITY` under `<ENTITY_ALIAS>` is not a grade at all -- it is the
        # alias kind, published as a.k.a. (585), f.k.a. (19), or blank (125).
        # One element name, two vocabularies, in one document. Both tables are
        # consulted for every alias and each misses the other's values, so
        # neither shape needs a branch and neither loses what it publishes.
        ALIAS_KINDS = T.let(
          { "a.k.a." => :aka, "f.k.a." => :fka, "n.k.a." => :nka }.freeze, T::Hash[String, Symbol]
        )

        # `TYPE_OF_DOCUMENT` is free text, and the UN writes it in three
        # languages. Anything unrecognised is :other, which is a real answer:
        # a document we cannot classify still matches on its number.
        DOCUMENT_KINDS = T.let({
          "passport" => :passport,
          "numéro de passeport" => :passport,
          "número de pasaporte" => :passport,
          "national identification number" => :national_id
        }.freeze, T::Hash[String, Symbol])

        # `TYPE_OF_DATE`, of which only these two change how the date is read.
        # EXACT and a blank value are the same instruction: read what is there.
        BETWEEN = T.let("BETWEEN", String)
        APPROXIMATELY = T.let("APPROXIMATELY", String)

        # Elements the canonical model has no home for, appended to remarks
        # rather than dropped. A gender and a place of birth are real screening
        # signal, and losing them to keep a schema tidy is the wrong trade.
        EXTRA_FIELDS = T.let({
          "VERSIONNUM" => "Version", "REFERENCE_NUMBER" => "Reference", "GENDER" => "Gender",
          "TITLE/VALUE" => "Title", "DESIGNATION/VALUE" => "Designation"
        }.freeze, T::Hash[String, String])

        PLACE_OF_BIRTH_PARTS = T.let(%w[STREET CITY STATE_PROVINCE COUNTRY NOTE].freeze, T::Array[String])

        WHITESPACE = T.let(/\s+/, Regexp)

        sig { returns(Parsers::XmlRecords::Record) }
        attr_reader :node

        sig { params(node: Parsers::XmlRecords::Record).void }
        def initialize(node)
          @node = T.let(node, Parsers::XmlRecords::Record)
          @names = T.let(nil, T.nilable(T::Array[Name]))
        end

        # The entity, or nil for a record with no name -- which cannot be
        # screened against and is never what the Committee meant to publish.
        sig { returns(T.nilable(Entity)) }
        def entity
          return nil if names.empty?

          Entity.new(source: :un_consolidated, source_ref: source_ref, type: type, names: names,
                     addresses: addresses, identifiers: identifiers, dates_of_birth: dates_of_birth,
                     nationalities: nationalities, programs: programs, listed_on: listed_on,
                     remarks: remarks)
        end

        sig { returns(Symbol) }
        def type = TYPES.fetch(node.name, :organization)

        sig { returns(T.nilable(String)) }
        def source_ref = node["DATAID"]

        sig { returns(T::Array[String]) }
        def nationalities = node.values("NATIONALITY/VALUE")

        sig { returns(T.nilable(PartialDate)) }
        def listed_on = PartialDate.parse(node["LISTED_ON"])

        # The joined published name first, then the original script, then every
        # alias in the order the Committee filed it.
        sig { returns(T::Array[Name]) }
        def names
          @names ||= [published_name, original_script].compact + alias_names
        end

        sig { returns(T::Array[PartialDate]) }
        def dates_of_birth
          each("DATE_OF_BIRTH").filter_map { |born| date_of_birth(born) }
        end

        sig { returns(T::Array[Identifier]) }
        def identifiers
          each("DOCUMENT").filter_map { |document| identifier(document) }
        end

        sig { returns(T::Array[Address]) }
        def addresses
          each("ADDRESS").filter_map { |place| address(place) }
        end

        sig { returns(T::Array[String]) }
        def programs = node.values("UN_LIST_TYPE")

        # The UN's own comment verbatim, then the elements that have nowhere
        # else to go, behind the marker that makes them trivial to strip again.
        sig { returns(T.nilable(String)) }
        def remarks
          Remarks.build(node["COMMENTS1"], extras)
        end

        private

        # The child elements of a record, which the UN names after the record
        # they hang off. See the class comment for why that is worth exploiting.
        sig { params(suffix: String).returns(T::Array[Parsers::XmlRecords::Record]) }
        def each(suffix) = node.nodes("#{node.name}_#{suffix}")

        sig { returns(T.nilable(Name)) }
        def published_name
          value = collapse(NAME_PARTS.filter_map { |part| node[part] }.join(" "))
          value && Name.new(value: value, kind: :primary)
        end

        # The name as the publisher's own script writes it -- Arabic for 338 of
        # the individuals. Filed as an alias with no `script` declared: which
        # script a string is in is a question about its characters, and
        # answering it from the element's name would be a guess. The normalizer
        # (#26) reads the characters and is the right place for it.
        sig { returns(T.nilable(Name)) }
        def original_script
          value = collapse(node["NAME_ORIGINAL_SCRIPT"])
          value && Name.new(value: value, kind: :aka)
        end

        # 294 of the 3,061 alias elements are placeholders: `<QUALITY/>` and
        # `<ALIAS_NAME/>` and nothing else. They must produce no name at all --
        # a blank-valued Name would be a record that matches everything.
        sig { returns(T::Array[Name]) }
        def alias_names
          each("ALIAS").filter_map do |alt|
            value = collapse(alt["ALIAS_NAME"])
            next nil if value.nil?

            published = alt["QUALITY"].to_s.downcase
            Name.new(value: value, kind: ALIAS_KINDS.fetch(published, :aka),
                     quality: ALIAS_QUALITIES[published])
          end
        end

        # 55 of the 949 date elements carry a TYPE_OF_DATE and no date, which
        # reads as nil rather than as a date of unknown value.
        sig { params(born: Parsers::XmlRecords::Record).returns(T.nilable(PartialDate)) }
        def date_of_birth(born)
          type_of_date = born["TYPE_OF_DATE"].to_s.upcase
          return between(born) if type_of_date == BETWEEN

          approximate(PartialDate.parse(born["DATE"] || born["YEAR"]), type_of_date)
        end

        sig { params(born: Parsers::XmlRecords::Record).returns(T.nilable(PartialDate)) }
        def between(born)
          from = born["FROM_YEAR"]
          to = born["TO_YEAR"]
          return nil if from.nil? || to.nil?

          PartialDate.range(from, to)
        end

        # "Circa 1962" and "1963" are the same claim about a person, and
        # PartialDate already knows to compare an approximate date loosely --
        # but only if the adapter tells it the publisher said approximately.
        sig { params(date: T.nilable(PartialDate), type_of_date: String).returns(T.nilable(PartialDate)) }
        def approximate(date, type_of_date)
          return date if date.nil? || type_of_date != APPROXIMATELY

          PartialDate.from_h(date.to_h.merge(approximate: true))
        end

        # 447 of the UN's 954 document elements name a document type and give
        # no number. There is nothing there to match on, so they are dropped
        # rather than kept as identifiers with no identity.
        sig { params(document: Parsers::XmlRecords::Record).returns(T.nilable(Identifier)) }
        def identifier(document)
          return nil if document.null?("NUMBER")

          Identifier.new(kind: document_kind(document), value: document["NUMBER"],
                         country: document["ISSUING_COUNTRY"] || document["COUNTRY_OF_ISSUE"],
                         issued_on: PartialDate.parse(document["DATE_OF_ISSUE"]),
                         expires_on: PartialDate.parse(document["DATE_OF_EXPIRY"]),
                         note: document_note(document))
        rescue ArgumentError
          nil
        end

        sig { params(document: Parsers::XmlRecords::Record).returns(Symbol) }
        def document_kind(document)
          DOCUMENT_KINDS.fetch(collapse(document["TYPE_OF_DOCUMENT"]).to_s.downcase, :other)
        end

        sig { params(document: Parsers::XmlRecords::Record).returns(T.nilable(String)) }
        def document_note(document)
          parts = [collapse(document["TYPE_OF_DOCUMENT2"]), document["CITY_OF_ISSUE"], document["NOTE"]].compact
          parts.empty? ? nil : parts.join("; ")
        end

        # An address element that located nothing is dropped rather than kept
        # empty: it cannot be screened on and would only inflate the count.
        sig { params(place: Parsers::XmlRecords::Record).returns(T.nilable(Address)) }
        def address(place)
          Address.new(street: place["STREET"], city: place["CITY"], state_province: place["STATE_PROVINCE"],
                      postal_code: place["ZIP_CODE"], country: place["COUNTRY"], note: place["NOTE"])
        rescue ArgumentError
          nil
        end

        # Label/value pairs for Remarks.build, which drops the ones the record
        # left blank. A value may be several -- the UN files three designations
        # under one element -- and arrives as the Array it published.
        sig { returns(T::Array[T.untyped]) }
        def extras
          EXTRA_FIELDS.map { |path, label| [label, node.values(path)] } + places_of_birth
        end

        sig { returns(T::Array[T.untyped]) }
        def places_of_birth
          each("PLACE_OF_BIRTH").map do |place|
            ["Place of birth", PLACE_OF_BIRTH_PARTS.filter_map { |part| place[part] }.join(", ")]
          end
        end

        # The UN's own line wrapping arrives inside values: two names in the
        # published file carry a newline and fifty spaces mid-string, and 39
        # name parts are padded on one side. Joined verbatim those produce
        # "JOHN  IMANI", which is a name nothing will ever match.
        sig { params(value: T.untyped).returns(T.nilable(String)) }
        def collapse(value)
          string = value.to_s.split(WHITESPACE).join(" ")
          string.empty? ? nil : -string
        end
      end
    end
  end
end
