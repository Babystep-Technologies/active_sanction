# frozen_string_literal: true

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
    # Canonical member order, from the most specific part of an address to the
    # least. Snapshot (#8) checksums the serialized form, so #to_h must lay its
    # keys out the same way every time.
    MEMBERS = %i[street city state_province postal_code country note].freeze

    # `note` is an annotation about the address rather than a part of it, so it
    # is rendered apart from the rest by #to_s.
    PARTS = (MEMBERS - %i[note]).freeze

    attr_reader(*MEMBERS)

    # Rebuilds an address from #to_h output. Accepts string keys, so a record
    # that has been through JSON round-trips without a separate coercion step.
    def self.from_h(hash)
      attributes = hash.to_h.transform_keys(&:to_sym)
      unknown = attributes.keys - MEMBERS
      raise ArgumentError, "unknown Address attribute(s): #{unknown.join(", ")}" if unknown.any?

      new(**attributes)
    end

    def initialize(street: nil, city: nil, state_province: nil, postal_code: nil, country: nil, note: nil)
      @street = string_or_nil(street)
      @city = string_or_nil(city)
      @state_province = string_or_nil(state_province)
      @postal_code = string_or_nil(postal_code)
      @country = string_or_nil(country)
      @note = string_or_nil(note)
      reject_empty!
      freeze
    end

    # The address parts the publisher actually filled in, in canonical order.
    def parts
      PARTS.filter_map { |member| public_send(member) }
    end

    # True when nothing but a note survived parsing -- the UN's "as of early
    # 2016" with no place attached. Such an address is worth keeping (it is
    # evidence the publisher had something) but is not worth matching on.
    def note_only? = parts.empty?

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
    def to_s
      line = parts.join(", ")
      return line if note.nil?

      line.empty? ? note : "#{line} (#{note})"
    end

    # Class is part of the comparison to keep #== and #hash agreeing, which is
    # what Hash and Set rely on.
    def ==(other)
      other.instance_of?(self.class) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      [self.class, to_h].hash
    end

    def inspect
      "#<#{self.class} #{to_s.inspect}>"
    end

    private

    # Surrounding whitespace is stripped -- the delimited sources pad their
    # fields -- but nothing else is touched. Case, diacritics and punctuation
    # are all signal the matcher needs to see as published. A field that was
    # only whitespace is nil: an empty string is not a smaller address, it is
    # an absent field, and storing one would split two identical addresses.
    def string_or_nil(value)
      return nil if value.nil?

      string = value.to_s.strip
      string.empty? ? nil : -string
    end

    def reject_empty!
      return if MEMBERS.any? { |member| public_send(member) }

      raise ArgumentError, "an address needs at least one populated field"
    end
  end
end
