# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

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
  #     dates_of_birth: [PartialDate, ...],
  #     nationalities: ["EG"],
  #     programs:      ["SDGT"],
  #     listed_on:     PartialDate,
  #     remarks:       "..."
  #   )
  #
  # Instances are frozen on construction and compare by value.
  class Entity
    extend T::Sig

    # `vessel` and `aircraft` are first-class because they are ~10% of the OFAC
    # SDN list (1,540 vessels, 342 aircraft) and carry name-like strings. Without
    # a distinct type a search for a person can rank a ship.
    TYPES = T.let(%i[individual organization vessel aircraft].freeze, T::Array[Symbol])

    # Canonical member order. Snapshot (#8) checksums the serialized form, so
    # #to_h must lay its keys out the same way every time.
    MEMBERS = T.let(%i[
      id source source_ref type names addresses identifiers dates_of_birth
      nationalities programs listed_on remarks
    ].freeze, T::Array[Symbol])

    # Plural, and it is not a hedge. The UN publishes more than one date of
    # birth for 140 of its 736 individuals and as many as ten for one of them,
    # because that is the honest state of the intelligence: several
    # governments reported several dates and the Committee listed all of them.
    # Collapsing that to one would mean choosing, on no evidence, which
    # report to believe -- and a screening decision that clears someone whose
    # DOB matched the discarded one is exactly the failure this library exists
    # to prevent. The scorer (#32) reads them the way PartialDate#overlaps?
    # already reads a single imprecise date: any of them matching is a match.
    DATE_MEMBERS = T.let(%i[dates_of_birth].freeze, T::Array[Symbol])

    # Which class rebuilds each nested member from a hash. The names are
    # strings, resolved lazily through `const_get`, so this file depends on
    # none of those four classes at load time -- and Sorbet cannot see through
    # that, deliberately. What the checker holds instead is the other end:
    # #initialize declares all four member types, so a hash that rebuilds into
    # the wrong thing is caught where the entity is built rather than here.
    COLLECTION_TYPES = T.let({
      names: "ActiveSanction::Name",
      addresses: "ActiveSanction::Address",
      identifiers: "ActiveSanction::Identifier",
      dates_of_birth: "ActiveSanction::PartialDate"
    }.freeze, T::Hash[Symbol, String])

    SCALAR_TYPES = T.let({ listed_on: "ActiveSanction::PartialDate" }.freeze, T::Hash[Symbol, String])

    # Namespaced, and never nil: #initialize derives one from the source and
    # the publisher's own reference when the caller gives none.
    sig { returns(String) }
    attr_reader :id

    sig { returns(Symbol) }
    attr_reader :source

    sig { returns(T.nilable(String)) }
    attr_reader :source_ref

    sig { returns(Symbol) }
    attr_reader :type

    sig { returns(T::Array[Name]) }
    attr_reader :names

    sig { returns(T::Array[Address]) }
    attr_reader :addresses

    sig { returns(T::Array[Identifier]) }
    attr_reader :identifiers

    sig { returns(T::Array[PartialDate]) }
    attr_reader :dates_of_birth

    sig { returns(T::Array[String]) }
    attr_reader :nationalities

    sig { returns(T::Array[String]) }
    attr_reader :programs

    sig { returns(T.nilable(PartialDate)) }
    attr_reader :listed_on

    sig { returns(T.nilable(String)) }
    attr_reader :remarks

    # Rebuilds an entity from #to_h output. Accepts string keys too, so a record
    # that has been through JSON round-trips without a separate coercion step.
    sig { params(hash: T.untyped).returns(T.attached_class) }
    def self.from_h(hash)
      attributes = hash.to_h.transform_keys(&:to_sym)
      unknown = attributes.keys - MEMBERS
      raise InvalidArgument, "unknown Entity attribute(s): #{unknown.join(", ")}" if unknown.any?

      # `new(**hash)` past required keyword parameters is one of the few
      # things Sorbet cannot check statically. The hash is validated on the two
      # lines above and by #initialize below, so what is lost here is only the
      # checker's ability to see it happen.
      T.unsafe(self).new(**coerce_members(attributes))
    end

    sig { params(attributes: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
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
    sig { params(class_name: String, value: T.untyped).returns(T.untyped) }
    def self.build(class_name, value)
      return value unless value.is_a?(Hash)

      Object.const_get(class_name).from_h(value)
    end
    private_class_method :build

    # Each collection is nilable because nil is how "the publisher listed
    # none" arrives from a store or a half-built hash; #list! turns it into the
    # empty array the reader hands back.
    #
    # The four collection members and `listed_on` are declared, and the rest is
    # `T.untyped` on purpose. The difference is who wrote the value: the nested
    # members are canonical objects an adapter builds, and declaring them is
    # what makes `srb tc` refuse an adapter that hands over the string a
    # publisher wrote where a PartialDate belongs. The runtime check that comes
    # with the signature is shallow -- it sees the Array and not what is in it
    # -- so the adapter conformance group goes on asserting the element types
    # per fixture, which is what covers an adapter written outside this repo.
    #
    # Everything else is the publisher's own text arriving as whatever the
    # parser made of it, and the coercions below say what happens to it in
    # messages written for whoever has to fix the record. A type error would
    # say less.
    sig do
      params(
        source: T.untyped,
        type: T.untyped,
        id: T.untyped,
        source_ref: T.untyped,
        names: T.nilable(T::Array[Name]),
        addresses: T.nilable(T::Array[Address]),
        identifiers: T.nilable(T::Array[Identifier]),
        dates_of_birth: T.nilable(T::Array[PartialDate]),
        nationalities: T.untyped,
        programs: T.untyped,
        listed_on: T.nilable(PartialDate),
        remarks: T.untyped
      ).void
    end
    def initialize(source:, type:, id: nil, source_ref: nil, names: [], addresses: [], identifiers: [],
                   dates_of_birth: [], nationalities: [], programs: [], listed_on: nil, remarks: nil)
      @source = T.let(symbol!(:source, source), Symbol)
      @type = T.let(type!(type), Symbol)
      @source_ref = T.let(string_or_nil(source_ref), T.nilable(String))
      @id = T.let(string_or_nil(id) || derived_id, String)
      @names = T.let(list!(:names, names), T::Array[Name])
      @addresses = T.let(list!(:addresses, addresses), T::Array[Address])
      @identifiers = T.let(list!(:identifiers, identifiers), T::Array[Identifier])
      @dates_of_birth = T.let(list!(:dates_of_birth, dates_of_birth), T::Array[PartialDate])
      @nationalities = T.let(strings!(:nationalities, nationalities), T::Array[String])
      @programs = T.let(strings!(:programs, programs), T::Array[String])
      @listed_on = T.let(listed_on, T.nilable(PartialDate))
      # original free text, always retained verbatim
      @remarks = T.let(string_or_nil(remarks), T.nilable(String))
      freeze
    end

    # True when the publisher gave no date at all, which is most of OFAC --
    # its dates are prose in Remarks and stay there until #19 reads them.
    sig { returns(T::Boolean) }
    def dates_of_birth? = dates_of_birth.any?

    # The name an adapter marked `:primary`, falling back to the first name for
    # sources such as Canada that publish no alias kinds at all.
    sig { returns(T.nilable(Name)) }
    def primary_name
      names.find(&:primary?) || names.first
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h
      {
        id: id,
        source: source,
        source_ref: source_ref,
        type: type,
        names: names.map(&:to_h),
        addresses: addresses.map(&:to_h),
        identifiers: identifiers.map(&:to_h),
        dates_of_birth: dates_of_birth.map(&:to_h),
        nationalities: nationalities,
        programs: programs,
        listed_on: listed_on&.to_h,
        remarks: remarks
      }
    end

    # Compared through #to_h so nested members only have to serialize, not
    # implement value equality themselves. Class is part of the comparison to
    # keep #== and #hash agreeing, which is what Hash and Set rely on.
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
      "#<#{self.class} id=#{id.inspect} type=#{type.inspect} names=#{names.size}>"
    end

    private

    sig { returns(String) }
    def derived_id
      raise InvalidArgument, "id is required when source_ref is nil" if source_ref.nil?

      # Namespaced so ids stay unique and stable across sources.
      -"#{source}:#{source_ref}"
    end

    sig { params(value: T.untyped).returns(Symbol) }
    def type!(value)
      type = symbol!(:type, value)
      return type if TYPES.include?(type)

      raise InvalidArgument, "unknown type #{type.inspect}, expected one of #{TYPES.join(", ")}"
    end

    sig { params(member: Symbol, value: T.untyped).returns(Symbol) }
    def symbol!(member, value)
      raise InvalidArgument, "#{member} is required" if value.nil? || value.to_s.empty?

      value.to_sym
    end

    sig { params(value: T.untyped).returns(T.nilable(String)) }
    def string_or_nil(value)
      value.nil? ? nil : -value.to_s
    end

    sig { params(member: Symbol, value: T.untyped).returns(T.untyped) }
    def list!(member, value)
      return [].freeze if value.nil?
      raise InvalidArgument, "#{member} must be an Array" unless value.is_a?(Array)

      value.dup.freeze
    end

    sig { params(member: Symbol, value: T.untyped).returns(T::Array[String]) }
    def strings!(member, value)
      list!(member, value).map { |item| -item.to_s }.freeze
    end
  end
end
