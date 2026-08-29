# frozen_string_literal: true

require "active_sanction/partial_date"

module ActiveSanction
  # A document number a sanctions list published for an entity: passport,
  # national ID, tax number, company registration. It is the highest-value
  # signal the matcher has -- an exact passport match is near-decisive in the
  # scorer (#32), where a name match never is.
  #
  #   ActiveSanction::Identifier.new(
  #     kind:       :passport,
  #     value:      "AB-123 456",
  #     country:    "Egypt",
  #     issued_on:  PartialDate.parse("2004-06-01"),
  #     expires_on: PartialDate.parse("2009-05-31"),
  #     note:       "expired"
  #   )
  #
  # `value` is the one required field: an identifier with no number is not an
  # identifier. Everything else is optional, because OFAC's remarks often give
  # just `Passport 123456 (Egypt)` and nothing more.
  #
  # The published string is kept verbatim -- it is what gets shown back to a
  # user justifying a hit -- while comparison runs on #normalized_value, since
  # two governments transcribing one passport rarely agree on its punctuation.
  # Instances are frozen on construction and compare by value.
  class Identifier
    # The UN publishes TYPE_OF_DOCUMENT as free text ("Passport", "National
    # Identification Number"), so adapters map onto these rather than passing a
    # source's own vocabulary through. :other is a real answer, not a failure:
    # a document we cannot classify still matches on its number.
    KINDS = %i[passport national_id tax_id registration_number other].freeze

    # Canonical member order. Snapshot (#8) checksums the serialized form, so
    # #to_h must lay its keys out the same way every time. `normalized_value`
    # is derived rather than stored: a stored copy can disagree with the value
    # it describes, and then two records that mean the same thing checksum
    # apart.
    MEMBERS = %i[kind value country issued_on expires_on note].freeze

    # Everything a number is not: spaces, hyphens, slashes, dots. OFAC writes
    # `AB-123 456` where the UN writes `AB123456`, and neither is more correct.
    INSIGNIFICANT = /[^[:alnum:]]+/

    attr_reader(*MEMBERS, :normalized_value)

    # Rebuilds an identifier from #to_h output. Accepts string keys, and dates
    # as the hashes JSON leaves behind, so a record survives a round-trip
    # through storage (#24) without a separate coercion step.
    def self.from_h(hash)
      attributes = hash.to_h.transform_keys(&:to_sym)
      unknown = attributes.keys - MEMBERS
      raise ArgumentError, "unknown Identifier attribute(s): #{unknown.join(", ")}" if unknown.any?

      new(**attributes)
    end

    # `kind` defaults to :other because a number we cannot classify is still
    # worth matching on -- OFAC remarks carry plenty of them.
    def initialize(value:, kind: :other, country: nil, issued_on: nil, expires_on: nil, note: nil)
      @value = value!(value)
      @normalized_value = -@value.downcase.gsub(INSIGNIFICANT, "")
      @kind = kind!(kind)
      @country = string_or_nil(country)
      @issued_on = date_or_nil(:issued_on, issued_on)
      @expires_on = date_or_nil(:expires_on, expires_on)
      @note = string_or_nil(note)
      freeze
    end

    def passport? = kind == :passport

    def to_h
      {
        kind: kind,
        value: value,
        country: country,
        issued_on: issued_on&.to_h,
        expires_on: expires_on&.to_h,
        note: note
      }
    end

    def to_s = value

    # Equality is the comparison the acceptance criteria asks for: `AB-123 456`
    # and `ab123456` are one passport written down twice, and de-duplicating
    # the same document across OFAC and the UN depends on saying so. Dates and
    # notes stay out of the key -- publishers report them inconsistently, and
    # letting them split one document into two records would defeat the dedup
    # this exists for. Entity (#4) still compares its members through #to_h, so
    # nothing here hides a differing published string from a record diff.
    def ==(other)
      other.instance_of?(self.class) && other.comparison_key == comparison_key
    end
    alias eql? ==

    def hash
      [self.class, comparison_key].hash
    end

    def inspect
      "#<#{self.class} #{kind.inspect} #{value.inspect}#{" country=#{country.inspect}" if country}>"
    end

    protected

    # Country is folded rather than dropped: two passports with the same number
    # from different countries are different documents.
    def comparison_key
      [kind, normalized_value, country&.downcase]
    end

    private

    def value!(value)
      string = value.to_s.strip
      raise ArgumentError, "value is required" if string.empty?
      raise ArgumentError, "value has no alphanumerics: #{string.inspect}" if string.gsub(INSIGNIFICANT, "").empty?

      -string
    end

    # Case is folded before the lookup: sources capitalize their document types
    # however they like, and no adapter should have to remember which.
    def kind!(value)
      raise ArgumentError, "kind is required" if value.nil? || value.to_s.empty?

      symbol = value.to_s.downcase.to_sym
      return symbol if KINDS.include?(symbol)

      raise ArgumentError, "unknown kind #{symbol.inspect}, expected one of #{KINDS.join(", ")}"
    end

    def string_or_nil(value)
      return nil if value.nil?

      string = value.to_s.strip
      string.empty? ? nil : -string
    end

    # Issue and expiry dates arrive as imprecisely as any other list date -- the
    # UN publishes year-only expiries -- so they are PartialDates. Hashes and
    # strings are coerced, which is what makes a JSON round-trip land where it
    # started.
    def date_or_nil(member, value)
      case value
      when nil, PartialDate then value
      when Hash then PartialDate.from_h(value)
      else PartialDate.parse(value) || raise(ArgumentError, "#{member} is not a date: #{value.inspect}")
      end
    end
  end
end
