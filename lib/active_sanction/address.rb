# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  # A place a sanctions list attached to an entity. OFAC ships 25,078 of them in
  # ADD.CSV; the UN ships far fewer and far thinner ones.
  #
  #   ActiveSanction::Address.new(
  #     street:         "Ave. Luis Maria Drago 1136",
  #     city:           "Buenos Aires",
  #     state_province: nil,
  #     postal_code:    "C1414",
  #     country:        "Argentina",
  #     note:           "as of early 2016"
  #   )
  #
  # Every field is optional because the publishers populate wildly different
  # subsets: the UN routinely supplies only COUNTRY plus a free-text NOTE, and
  # an address type that insisted on a street would drop those rows entirely.
  # What it will not accept is an address that says nothing at all -- a record
  # with every field blank is a parsing accident, not a location.
  #
  # A pure data holder: it stores what the publisher said and nothing more. No
  # geocoding, no country-code lookup, no case folding. Instances are frozen on
  # construction and compare by value.
  class Address
    extend T::Sig

    # Canonical member order, from the most specific part of an address to the
    # least. Snapshot (#8) checksums the serialized form, so #to_h must lay its
    # keys out the same way every time.
    MEMBERS = T.let(%i[street city state_province postal_code country note].freeze, T::Array[Symbol])

    # `note` is an annotation about the address rather than a part of it, so it
    # is rendered apart from the rest by #to_s.
    PARTS = T.let((MEMBERS - %i[note]).freeze, T::Array[Symbol])

    # Every field is nilable because the publishers populate wildly different
    # subsets of them; what #initialize refuses is all six being empty at once.
    sig { returns(T.nilable(String)) }
    attr_reader :street

    sig { returns(T.nilable(String)) }
    attr_reader :city

    sig { returns(T.nilable(String)) }
    attr_reader :state_province

    sig { returns(T.nilable(String)) }
    attr_reader :postal_code

    sig { returns(T.nilable(String)) }
    attr_reader :country

    sig { returns(T.nilable(String)) }
    attr_reader :note

    # Rebuilds an address from #to_h output. Accepts string keys, so a record
    # that has been through JSON round-trips without a separate coercion step.
    sig { params(hash: T.untyped).returns(T.attached_class) }
    def self.from_h(hash)
      attributes = hash.to_h.transform_keys(&:to_sym)
      unknown = attributes.keys - MEMBERS
      raise InvalidArgument, "unknown Address attribute(s): #{unknown.join(", ")}" if unknown.any?

      new(**attributes)
    end

    # Untyped on purpose, and the same choice Entity makes: all six are the
    # publisher's own text arriving as whatever the parser made of it, and
    # #string_or_nil says below what happens to it.
    sig do
      params(street: T.untyped, city: T.untyped, state_province: T.untyped, postal_code: T.untyped,
             country: T.untyped, note: T.untyped).void
    end
    def initialize(street: nil, city: nil, state_province: nil, postal_code: nil, country: nil, note: nil)
      @street = T.let(string_or_nil(street), T.nilable(String))
      @city = T.let(string_or_nil(city), T.nilable(String))
      @state_province = T.let(string_or_nil(state_province), T.nilable(String))
      @postal_code = T.let(string_or_nil(postal_code), T.nilable(String))
      @country = T.let(string_or_nil(country), T.nilable(String))
      @note = T.let(string_or_nil(note), T.nilable(String))
      reject_empty!
      freeze
    end

    # The address parts the publisher actually filled in, in canonical order.
    sig { returns(T::Array[String]) }
    def parts
      PARTS.filter_map { |member| public_send(member) }
    end

    # True when nothing but a note survived parsing -- the UN's "as of early
    # 2016" with no place attached. Such an address is worth keeping (it is
    # evidence the publisher had something) but is not worth matching on.
    sig { returns(T::Boolean) }
    def note_only? = parts.empty?

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h
      {
        street: street,
        city: city,
        state_province: state_province,
        postal_code: postal_code,
        country: country,
        note: note
      }
    end

    # A single line, which is how an address is displayed in a hit list and how
    # the normalizer (#26) will want it before folding.
    sig { returns(String) }
    def to_s
      line = parts.join(", ")
      note = self.note
      return line if note.nil?

      line.empty? ? note : "#{line} (#{note})"
    end

    # Class is part of the comparison to keep #== and #hash agreeing, which is
    # what Hash and Set rely on.
    sig { params(other: T.untyped).returns(T::Boolean) }
    def ==(other)
      return false unless other.instance_of?(self.class)

      to_h == other.to_h
    end
    alias eql? ==

    sig { returns(Integer) }
    def hash
      [self.class, to_h].hash
    end

    sig { returns(String) }
    def inspect
      "#<#{self.class} #{to_s.inspect}>"
    end

    private

    # Surrounding whitespace is stripped -- the delimited sources pad their
    # fields -- but nothing else is touched. Case, diacritics and punctuation
    # are all signal the matcher needs to see as published. A field that was
    # only whitespace is nil: an empty string is not a smaller address, it is
    # an absent field, and storing one would split two identical addresses.
    sig { params(value: T.untyped).returns(T.nilable(String)) }
    def string_or_nil(value)
      return nil if value.nil?

      string = value.to_s.strip
      string.empty? ? nil : -string
    end

    sig { void }
    def reject_empty!
      return if MEMBERS.any? { |member| public_send(member) }

      raise InvalidArgument, "an address needs at least one populated field"
    end
  end
end
