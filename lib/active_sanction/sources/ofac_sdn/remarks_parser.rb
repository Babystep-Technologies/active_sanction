# frozen_string_literal: true

require "active_sanction/identifier"
require "active_sanction/name"
require "active_sanction/partial_date"

module ActiveSanction
  module Sources
    class OfacSdn < Base
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
        SEPARATOR = ";"

        # `alt.` prefixes a repeat: "DOB 1955; alt. DOB 1956" is one person two
        # governments reported differently. It marks repetition and nothing
        # else, so it is stripped and what follows is matched normally -- which
        # is how multiple values of one kind fall out without a second rule.
        ALTERNATE = /\Aalt\.\s+/i

        # The full stop that ends a remark belongs to the sentence, not to the
        # value: "Gender Male." is not a gender spelled with a period.
        TRAILING_STOP = /\s*\.\z/

        # OFAC publishes wallet addresses as `Digital Currency Address - XBT
        # 1abc...`, one label per currency. They are matched by shape rather
        # than enumerated: the list of currencies grows every time a new one is
        # designated, and none of them changes how the address is read.
        DIGITAL_CURRENCY = /\ADigital Currency Address\s*-\s*(?<currency>[[:alnum:]]+)\s+(?<value>\S+)\z/i

        # The parenthesised qualifiers a document segment ends in: `Passport
        # 123456 (Egypt)`, and sometimes two -- `Folio Mercantil No. 22839
        # (Jalisco) (Mexico)` is a state and then a country. The space is what
        # makes it a qualifier rather than part of the number: Hong Kong writes
        # its ID numbers as `D489833(9)`, and splitting that off would leave a
        # document number the issuing government would not recognize.
        TRAILING_QUALIFIER = /\s+\(([^)]*)\)\s*\z/

        # `Passport ZG4109521 (Pakistan) issued 07 Jun 2008 expires 06 Jun 2013`
        # -- either clause may be absent and both may be present, so the value
        # ends wherever the first one starts.
        DATE_KEYWORDS = /\b(?:issued|expires|expired)\b/i
        DATE_CLAUSE = /(issued|expires|expired)\s+(?:on\s+)?(.*?)(?=\s+#{DATE_KEYWORDS}|\z)/i

        # A document number is a code, not a sentence. `Passport 265 216` and
        # `SWIFT/BIC SBERRUMM` are numbers; `License to operate` is prose that
        # happened to open with a label, and without this rule it would become
        # an identifier that matches nothing and misleads everyone.
        CODE = %r{\A[[:alnum:]][[:alnum:]\s._()/-]*\z}
        DIGIT = /\d/

        # No government issues a document number this long -- China's 18-digit
        # social credit code is the longest in the file. What exceeds it is a
        # clause that ran on: "Passport OR801168 and Kuwaiti National ID No.
        # 281020505755 issued under the name ..." is one segment OFAC wrote as
        # a sentence, and an identifier built from all of it would match
        # nothing and mislead whoever read it.
        MAX_CODE_LENGTH = 40

        QUOTES = /\A['"“”‘’]|['"“”‘’]\z/

        attr_reader :text, :segments, :extracted, :prose, :unrecognized,
                    :dates_of_birth, :places_of_birth, :nationalities, :genders, :aliases, :identifiers

        def initialize(text)
          @text = text.to_s
          @segments = []
          @extracted = []
          @prose = []
          @unrecognized = []
          @dates_of_birth = []
          @places_of_birth = []
          @nationalities = []
          @genders = []
          @aliases = []
          @identifiers = []
          read
          freeze
        end

        # True when the remark yielded anything structured at all.
        def any? = extracted.any?

        private

        def read
          text.split(SEPARATOR).each do |raw|
            segment = raw.strip
            next if segment.empty?

            @segments << segment
            classify(segment)
          end
        end

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

        def field(body)
          match = Vocabulary::FIELD_PATTERN.match(body)
          return nil unless match

          value = trim(match[:value])
          return nil if value.nil?

          case Vocabulary::FIELD_KINDS.fetch(match[:label].downcase)
          when :date_of_birth then born(value)
          when :place_of_birth then keep(@places_of_birth, value)
          when :nationality then keep(@nationalities, value)
          when :gender then keep(@genders, value)
          else known_as(Vocabulary::FIELD_KINDS.fetch(match[:label].downcase), value)
          end
        end

        # An unreadable date is not a date. It reads as unrecognized rather
        # than as a nil the entity would carry around, which puts it in the
        # coverage histogram where a new OFAC spelling can be seen.
        def born(value)
          date = PartialDate.parse(value)
          return nil if date.nil?

          keep(@dates_of_birth, date)
        end

        # `a.k.a. 'EL SENOR'` -- quoted, and the quotes are OFAC's punctuation
        # rather than part of the name. 4,325 of the 4,349 inline aliases
        # appear nowhere in ALT.CSV, so these are names the list publishes here
        # and only here.
        def known_as(kind, value)
          keep(@aliases, Name.new(value: value.sub(QUOTES, "").sub(QUOTES, ""), kind: kind))
        rescue ArgumentError
          nil
        end

        def document(body)
          match = Vocabulary::DOCUMENT_PATTERN.match(body)
          return nil unless match

          rest = trim(match[:rest])
          return nil if rest.nil?

          identify(match[:label], Vocabulary::DOCUMENT_KINDS.fetch(match[:label].downcase), rest)
        end

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

        def split(rest)
          dates = {}
          rest.scan(DATE_CLAUSE) { |keyword, date| dates[keyword.downcase] ||= PartialDate.parse(date) }
          [rest.split(/\s+#{DATE_KEYWORDS}/, 2).first.to_s, dates["issued"], dates["expires"] || dates["expired"]]
        end

        # Outermost qualifier last, which is the one Identifier has a country
        # field for. Anything inside it -- a state, a province -- has no home
        # on the record and goes to the note rather than being dropped.
        def unwrap(head)
          qualifiers = []
          text = head.dup
          qualifiers.unshift(Regexp.last_match(1)) while text.sub!(TRAILING_QUALIFIER, "")
          [text.strip, qualifiers]
        end

        def note(label, qualifiers)
          inner = qualifiers[0..-2]
          inner.empty? ? label : "#{label} (#{inner.join(", ")})"
        end

        def digital_currency(body)
          match = DIGITAL_CURRENCY.match(trim(body).to_s)
          return nil unless match

          keep(@identifiers,
               Identifier.new(kind: :other, value: match[:value], note: "#{match[:currency].upcase} address"))
        rescue ArgumentError
          nil
        end

        def code?(value)
          return false if value.empty? || value.length > MAX_CODE_LENGTH || !CODE.match?(value)

          DIGIT.match?(value) || value == value.upcase
        end

        # Returns the list, which is truthy: a caller reads "something was
        # kept" from it, and a miss answers nil.
        def keep(list, value)
          list << value
        end

        def trim(value)
          string = value.to_s.sub(TRAILING_STOP, "").strip
          string.empty? ? nil : string
        end
      end
    end
  end
end

require "active_sanction/sources/ofac_sdn/remarks_parser/vocabulary"
require "active_sanction/sources/ofac_sdn/remarks_parser/coverage"
