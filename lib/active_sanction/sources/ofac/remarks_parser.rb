# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/identifier"
require "active_sanction/name"
require "active_sanction/partial_date"

module ActiveSanction
  module Sources
    class Ofac < Base
      # Reads the fields OFAC publishes no columns for out of the free text it
      # packs them into.
      #
      #   parsed = RemarksParser.new("DOB 10 Dec 1948; POB Egypt; Passport 123456 (Egypt)")
      #   parsed.dates_of_birth  # => [#<PartialDate 1948-12-10>]
      #   parsed.places_of_birth # => ["Egypt"]
      #   parsed.identifiers     # => [#<Identifier :passport "123456" country="Egypt">]
      #   parsed.unrecognized    # => []
      #
      # SDN.CSV has no date of birth, place of birth, nationality or passport
      # column. All of it -- 88,827 semicolon-delimited segments across 19,015
      # remarks -- is prose in one field, written for a human reading a page.
      # Until it is read, every OFAC entity carries names and nothing else, and
      # names alone are what makes a screening tool cry wolf: the secondary
      # identifiers that clear a false positive (#32) are all in here.
      #
      # ### Nothing is ever removed from the remark
      #
      # Extraction is additive. `Entity#remarks` keeps the publisher's whole
      # string byte for byte whether this class understood it or not, so a
      # pattern that drifts costs structure and never content. That is the one
      # rule this file must not break: these are heuristics against text a
      # government writes for people, they will go stale, and silent data loss
      # in a compliance tool is the worst failure there is. A segment we cannot
      # read is still in front of the user, in the publisher's own words.
      #
      # ### How a segment is read
      #
      # Segments are split on `;` and matched against a label vocabulary. A
      # segment either extracts a value, or matches a shape known to be prose
      # (`Secondary sanctions risk: ...`, which is 12% of the file and carries
      # nothing structured), or is unrecognized -- and #unrecognized is what
      # Coverage counts, so drift shows up as a number rather than as a bug
      # report years later.
      #
      # Nothing here raises. A malformed segment -- `Passport issued in
      # Sarajevo`, which names no passport at all -- reads as unrecognized and
      # stays in the remark, because one unparseable clause must never cost the
      # entity around it.
      class RemarksParser
        extend T::Sig

        SEPARATOR = T.let(";", String)

        # `alt.` prefixes a repeat: "DOB 1955; alt. DOB 1956" is one person two
        # governments reported differently. It marks repetition and nothing
        # else, so it is stripped and what follows is matched normally -- which
        # is how multiple values of one kind fall out without a second rule.
        ALTERNATE = T.let(/\Aalt\.\s+/i, Regexp)

        # The full stop that ends a remark belongs to the sentence, not to the
        # value: "Gender Male." is not a gender spelled with a period.
        TRAILING_STOP = T.let(/\s*\.\z/, Regexp)

        # OFAC publishes wallet addresses as `Digital Currency Address - XBT
        # 1abc...`, one label per currency. They are matched by shape rather
        # than enumerated: the list of currencies grows every time a new one is
        # designated, and none of them changes how the address is read.
        DIGITAL_CURRENCY = T.let(
          /\ADigital Currency Address\s*-\s*(?<currency>[[:alnum:]]+)\s+(?<value>\S+)\z/i, Regexp
        )

        # The parenthesised qualifiers a document segment ends in: `Passport
        # 123456 (Egypt)`, and sometimes two -- `Folio Mercantil No. 22839
        # (Jalisco) (Mexico)` is a state and then a country. The space is what
        # makes it a qualifier rather than part of the number: Hong Kong writes
        # its ID numbers as `D489833(9)`, and splitting that off would leave a
        # document number the issuing government would not recognize.
        TRAILING_QUALIFIER = T.let(/\s+\(([^)]*)\)\s*\z/, Regexp)

        # `Passport ZG4109521 (Pakistan) issued 07 Jun 2008 expires 06 Jun 2013`
        # -- either clause may be absent and both may be present, so the value
        # ends wherever the first one starts.
        DATE_KEYWORDS = T.let(/\b(?:issued|expires|expired)\b/i, Regexp)
        DATE_CLAUSE = T.let(/(issued|expires|expired)\s+(?:on\s+)?(.*?)(?=\s+#{DATE_KEYWORDS}|\z)/i, Regexp)

        # A document number is a code, not a sentence. `Passport 265 216` and
        # `SWIFT/BIC SBERRUMM` are numbers; `License to operate` is prose that
        # happened to open with a label, and without this rule it would become
        # an identifier that matches nothing and misleads everyone.
        CODE = T.let(%r{\A[[:alnum:]][[:alnum:]\s._()/-]*\z}, Regexp)
        DIGIT = T.let(/\d/, Regexp)

        # No government issues a document number this long -- China's 18-digit
        # social credit code is the longest in the file. What exceeds it is a
        # clause that ran on: "Passport OR801168 and Kuwaiti National ID No.
        # 281020505755 issued under the name ..." is one segment OFAC wrote as
        # a sentence, and an identifier built from all of it would match
        # nothing and mislead whoever read it.
        MAX_CODE_LENGTH = T.let(40, Integer)

        QUOTES = T.let(/\A['"“”‘’]|['"“”‘’]\z/, Regexp)

        # The remark as published, and how this parser read it: every segment,
        # those it extracted something from, those it recognized as prose, and
        # those it could not read -- which is what Coverage counts.
        sig { returns(String) }
        attr_reader :text

        sig { returns(T::Array[String]) }
        attr_reader :segments

        sig { returns(T::Array[String]) }
        attr_reader :extracted

        sig { returns(T::Array[String]) }
        attr_reader :prose

        sig { returns(T::Array[String]) }
        attr_reader :unrecognized

        sig { returns(T::Array[PartialDate]) }
        attr_reader :dates_of_birth

        sig { returns(T::Array[String]) }
        attr_reader :places_of_birth

        sig { returns(T::Array[String]) }
        attr_reader :nationalities

        sig { returns(T::Array[String]) }
        attr_reader :genders

        sig { returns(T::Array[Name]) }
        attr_reader :aliases

        sig { returns(T::Array[Identifier]) }
        attr_reader :identifiers

        sig { params(text: T.untyped).void }
        def initialize(text)
          @text = T.let(text.to_s, String)
          @segments = T.let([], T::Array[String])
          @extracted = T.let([], T::Array[String])
          @prose = T.let([], T::Array[String])
          @unrecognized = T.let([], T::Array[String])
          @dates_of_birth = T.let([], T::Array[PartialDate])
          @places_of_birth = T.let([], T::Array[String])
          @nationalities = T.let([], T::Array[String])
          @genders = T.let([], T::Array[String])
          @aliases = T.let([], T::Array[Name])
          @identifiers = T.let([], T::Array[Identifier])
          read
          freeze
        end

        # True when the remark yielded anything structured at all.
        sig { returns(T::Boolean) }
        def any? = extracted.any?

        private

        sig { void }
        def read
          text.split(SEPARATOR).each do |raw|
            segment = raw.strip
            next if segment.empty?

            @segments << segment
            classify(segment)
          end
        end

        sig { params(segment: String).void }
        def classify(segment)
          body = segment.sub(ALTERNATE, "")
          if field(body) || document(body) || digital_currency(body)
            @extracted << segment
          elsif Vocabulary::PROSE_PATTERN.match?(body)
            @prose << segment
          else
            @unrecognized << segment
          end
        end

        sig { params(body: String).returns(T.untyped) }
        def field(body)
          match = Vocabulary::FIELD_PATTERN.match(body)
          return nil unless match

          value = trim(match[:value])
          return nil if value.nil?

          case Vocabulary::FIELD_KINDS.fetch(T.must(match[:label]).downcase)
          when :date_of_birth then born(value)
          when :place_of_birth then keep(@places_of_birth, value)
          when :nationality then keep(@nationalities, value)
          when :gender then keep(@genders, value)
          else known_as(Vocabulary::FIELD_KINDS.fetch(T.must(match[:label]).downcase), value)
          end
        end

        # An unreadable date is not a date. It reads as unrecognized rather
        # than as a nil the entity would carry around, which puts it in the
        # coverage histogram where a new OFAC spelling can be seen.
        sig { params(value: String).returns(T.untyped) }
        def born(value)
          date = PartialDate.parse(value)
          return nil if date.nil?

          keep(@dates_of_birth, date)
        end

        # `a.k.a. 'EL SENOR'` -- quoted, and the quotes are OFAC's punctuation
        # rather than part of the name. 4,325 of the 4,349 inline aliases
        # appear nowhere in ALT.CSV, so these are names the list publishes here
        # and only here.
        sig { params(kind: Symbol, value: String).returns(T.untyped) }
        def known_as(kind, value)
          keep(@aliases, Name.new(value: value.sub(QUOTES, "").sub(QUOTES, ""), kind: kind))
        rescue ArgumentError
          nil
        end

        sig { params(body: String).returns(T.untyped) }
        def document(body)
          match = Vocabulary::DOCUMENT_PATTERN.match(body)
          return nil unless match

          rest = trim(match[:rest])
          return nil if rest.nil?

          label = T.must(match[:label])
          identify(label, Vocabulary::DOCUMENT_KINDS.fetch(label.downcase), rest)
        end

        sig { params(label: String, kind: Symbol, rest: String).returns(T.untyped) }
        def identify(label, kind, rest)
          head, issued_on, expires_on = split(rest)
          value, qualifiers = unwrap(head)
          return nil unless code?(value)

          keep(@identifiers, Identifier.new(kind: kind, value: value, country: qualifiers.last,
                                            issued_on: issued_on, expires_on: expires_on,
                                            note: note(label, qualifiers)))
        rescue ArgumentError
          nil
        end

        sig { params(rest: String).returns([String, T.nilable(PartialDate), T.nilable(PartialDate)]) }
        def split(rest)
          dates = T.let({}, T::Hash[String, T.nilable(PartialDate)])
          rest.scan(DATE_CLAUSE) { |keyword, date| dates[keyword.downcase] ||= PartialDate.parse(date) }
          [rest.split(/\s+#{DATE_KEYWORDS}/, 2).first.to_s, dates["issued"], dates["expires"] || dates["expired"]]
        end

        # Outermost qualifier last, which is the one Identifier has a country
        # field for. Anything inside it -- a state, a province -- has no home
        # on the record and goes to the note rather than being dropped.
        sig { params(head: String).returns([String, T::Array[String]]) }
        def unwrap(head)
          qualifiers = T.let([], T::Array[String])
          text = head.dup
          qualifiers.unshift(T.must(Regexp.last_match(1))) while text.sub!(TRAILING_QUALIFIER, "")
          [text.strip, qualifiers]
        end

        sig { params(label: String, qualifiers: T::Array[String]).returns(String) }
        def note(label, qualifiers)
          inner = qualifiers[0..-2].to_a
          inner.empty? ? label : "#{label} (#{inner.join(", ")})"
        end

        sig { params(body: String).returns(T.untyped) }
        def digital_currency(body)
          match = DIGITAL_CURRENCY.match(trim(body).to_s)
          return nil unless match

          currency = T.must(match[:currency]).upcase
          keep(@identifiers, Identifier.new(kind: :other, value: match[:value], note: "#{currency} address"))
        rescue ArgumentError
          nil
        end

        sig { params(value: String).returns(T::Boolean) }
        def code?(value)
          return false if value.empty? || value.length > MAX_CODE_LENGTH || !CODE.match?(value)

          DIGIT.match?(value) || value == value.upcase
        end

        # Returns the list, which is truthy: a caller reads "something was
        # kept" from it, and a miss answers nil.
        sig { params(list: T::Array[T.untyped], value: T.untyped).returns(T::Array[T.untyped]) }
        def keep(list, value)
          list << value
        end

        sig { params(value: T.untyped).returns(T.nilable(String)) }
        def trim(value)
          string = value.to_s.sub(TRAILING_STOP, "").strip
          string.empty? ? nil : string
        end
      end
    end
  end
end

require "active_sanction/sources/ofac/remarks_parser/vocabulary"
require "active_sanction/sources/ofac/remarks_parser/coverage"
