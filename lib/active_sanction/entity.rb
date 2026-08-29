# frozen_string_literal: true

module ActiveSanction
  # The single source-agnostic record every adapter produces. Nothing
  # downstream -- storage, index, matcher -- should ever need to know which
  # government published a record.
  #
  #   ActiveSanction::Entity.new(
  #     id:            "ofac_sdn:2674",
  #     source:        :ofac_sdn,
  #     source_ref:    "2674",
  #     type:          :individual,
  #     names:         [Name, ...],
  #     addresses:     [Address, ...],
  #     identifiers:   [Identifier, ...],
  #     nationalities: ["EG"],
  #     programs:      ["SDGT"],
  #     listed_on:     PartialDate,
  #     remarks:       "..."
  #   )
  #
  # Instances are frozen on construction and compare by value.
  class Entity
    # `vessel` and `aircraft` are first-class because they are ~10% of the OFAC
    # SDN list (1,540 vessels, 342 aircraft) and carry name-like strings. Without
    # a distinct type a search for a person can rank a ship.
    TYPES = %i[individual organization vessel aircraft].freeze

    # Canonical member order. Snapshot (#8) checksums the serialized form, so
    # #to_h must lay its keys out the same way every time.
    MEMBERS = %i[
      id source source_ref type names addresses identifiers
      nationalities programs listed_on remarks
    ].freeze

    # Nested members are duck-typed: any object answering #to_h serializes, and
    # the named class rebuilds it. Names are resolved lazily so Entity neither
    # depends on load order nor on those classes existing yet (#5, #6, #7).
    COLLECTION_TYPES = {
      names: "ActiveSanction::Name",
      addresses: "ActiveSanction::Address",
      identifiers: "ActiveSanction::Identifier"
    }.freeze

    SCALAR_TYPES = { listed_on: "ActiveSanction::PartialDate" }.freeze

    attr_reader(*MEMBERS)

    # Rebuilds an entity from #to_h output. Accepts string keys too, so a record
    # that has been through JSON round-trips without a separate coercion step.
    def self.from_h(hash)
      attributes = hash.to_h.transform_keys(&:to_sym)
      unknown = attributes.keys - MEMBERS
      raise ArgumentError, "unknown Entity attribute(s): #{unknown.join(", ")}" if unknown.any?

      new(**coerce_members(attributes))
    end

    def self.coerce_members(attributes)
      COLLECTION_TYPES.each do |member, class_name|
        attributes[member] &&= attributes[member].map { |value| build(class_name, value) }
      end
      SCALAR_TYPES.each { |member, class_name| attributes[member] &&= build(class_name, attributes[member]) }
      attributes
    end
    private_class_method :coerce_members

    # Values that are already value objects pass through untouched, so from_h is
    # safe to call on a half-deserialized hash.
    def self.build(class_name, value)
      return value unless value.is_a?(Hash)

      Object.const_get(class_name).from_h(value)
    end
    private_class_method :build

    def initialize(source:, type:, id: nil, source_ref: nil, names: [], addresses: [], identifiers: [],
                   nationalities: [], programs: [], listed_on: nil, remarks: nil)
      @source = symbol!(:source, source)
      @type = type!(type)
      @source_ref = string_or_nil(source_ref)
      @id = string_or_nil(id) || derived_id
      @names = list!(:names, names)
      @addresses = list!(:addresses, addresses)
      @identifiers = list!(:identifiers, identifiers)
      @nationalities = strings!(:nationalities, nationalities)
      @programs = strings!(:programs, programs)
      @listed_on = listed_on
      @remarks = string_or_nil(remarks) # original free text, always retained verbatim
      freeze
    end

    # The name an adapter marked `:primary`, falling back to the first name for
    # sources such as Canada that publish no alias kinds at all.
    def primary_name
      names.find { |name| name.respond_to?(:kind) && name.kind == :primary } || names.first
    end

    def to_h
      {
        id: id,
        source: source,
        source_ref: source_ref,
        type: type,
        names: names.map(&:to_h),
        addresses: addresses.map(&:to_h),
        identifiers: identifiers.map(&:to_h),
        nationalities: nationalities,
        programs: programs,
        listed_on: listed_on&.to_h,
        remarks: remarks
      }
    end

    # Compared through #to_h so nested members only have to serialize, not
    # implement value equality themselves. Class is part of the comparison to
    # keep #== and #hash agreeing, which is what Hash and Set rely on.
    def ==(other)
      other.instance_of?(self.class) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      [self.class, to_h].hash
    end

    def inspect
      "#<#{self.class} id=#{id.inspect} type=#{type.inspect} names=#{names.size}>"
    end

    private

    def derived_id
      raise ArgumentError, "id is required when source_ref is nil" if source_ref.nil?

      # Namespaced so ids stay unique and stable across sources.
      -"#{source}:#{source_ref}"
    end

    def type!(value)
      type = symbol!(:type, value)
      return type if TYPES.include?(type)

      raise ArgumentError, "unknown type #{type.inspect}, expected one of #{TYPES.join(", ")}"
    end

    def symbol!(member, value)
      raise ArgumentError, "#{member} is required" if value.nil? || value.to_s.empty?

      value.to_sym
    end

    def string_or_nil(value)
      value.nil? ? nil : -value.to_s
    end

    def list!(member, value)
      return [].freeze if value.nil?
      raise ArgumentError, "#{member} must be an Array" unless value.is_a?(Array)

      value.dup.freeze
    end

    def strings!(member, value)
      list!(member, value).map { |item| -item.to_s }.freeze
    end
  end
end
