# frozen_string_literal: true

require "json"

RSpec.describe ActiveSanction::Entity do
  # #5, #6 and #7 supply the real Name, PartialDate, Address and Identifier.
  # Entity only asks for the contract all four honour: #to_h to serialize and
  # .from_h to rebuild. Standing in for them here keeps this spec honest about
  # what Entity itself is responsible for.
  let(:value_class) do
    Class.new do
      attr_reader :attributes

      # Each real value object coerces its own enum fields back to symbols in
      # .from_h, which is what makes a JSON round-trip land where it started.
      def self.from_h(hash)
        attributes = hash.transform_keys(&:to_sym)
        %i[kind precision].each { |enum| attributes[enum] &&= attributes[enum].to_sym }
        new(**attributes)
      end

      def initialize(**attributes)
        @attributes = attributes
      end

      def kind = attributes[:kind]
      def to_h = attributes
      def ==(other) = other.is_a?(self.class) && other.attributes == attributes
    end
  end

  let(:primary) { value_class.new(value: "AL ZAWAHIRI, Aiman", kind: :primary) }
  let(:alias_name) { value_class.new(value: "ABU MUHAMMAD", kind: :aka) }

  let(:attributes) do
    {
      id: "ofac_sdn:2674",
      source: :ofac_sdn,
      source_ref: "2674",
      type: :individual,
      names: [primary, alias_name],
      addresses: [value_class.new(city: "Cairo", country: "EG")],
      identifiers: [value_class.new(kind: :passport, value: "1084010")],
      nationalities: ["EG"],
      programs: %w[SDGT SDT],
      listed_on: value_class.new(year: 2001, precision: :year),
      remarks: "DOB 19 Jun 1951; Passport 1084010 (Egypt)"
    }
  end

  let(:entity) { described_class.new(**attributes) }

  before do
    stub_const("ActiveSanction::Name", value_class)
    stub_const("ActiveSanction::Address", value_class)
    stub_const("ActiveSanction::Identifier", value_class)
    stub_const("ActiveSanction::PartialDate", value_class)
  end

  describe "immutability" do
    it "freezes the entity" do
      expect(entity).to be_frozen
    end

    it "freezes its collections" do
      expect([entity.names, entity.addresses, entity.identifiers, entity.nationalities, entity.programs])
        .to all(be_frozen)
    end

    it "does not share the caller's array" do
      names = [primary]
      built = described_class.new(source: :ofac_sdn, source_ref: "1", type: :individual, names: names)
      names << alias_name

      expect(built.names).to eq([primary])
    end
  end

  describe "type validation" do
    it "accepts every member of the enum" do
      types = described_class::TYPES.map do |type|
        described_class.new(source: :ofac_sdn, source_ref: "1", type: type).type
      end

      expect(types).to eq(%i[individual organization vessel aircraft])
    end

    it "accepts a string type" do
      built = described_class.new(source: "ofac_sdn", source_ref: "1", type: "vessel")

      expect(built.type).to eq(:vessel)
    end

    it "raises on an unknown type" do
      expect { described_class.new(source: :ofac_sdn, source_ref: "1", type: :ship) }
        .to raise_error(ArgumentError, /unknown type :ship/)
    end

    it "raises on a missing type" do
      expect { described_class.new(source: :ofac_sdn, source_ref: "1", type: nil) }
        .to raise_error(ArgumentError, /type is required/)
    end
  end

  describe "identity" do
    it "derives a namespaced id from the source and source_ref" do
      built = described_class.new(source: :ofac_sdn, source_ref: "2674", type: :individual)

      expect(built.id).to eq("ofac_sdn:2674")
    end

    it "keeps an explicitly supplied id" do
      expect(entity.id).to eq("ofac_sdn:2674")
    end

    # Canada publishes no stable record id, so its adapter must mint one.
    it "raises when neither an id nor a source_ref is given" do
      expect { described_class.new(source: :canada_sema, type: :individual) }
        .to raise_error(ArgumentError, /id is required/)
    end
  end

  describe "#primary_name" do
    it "returns the name marked primary, whatever its position" do
      built = described_class.new(source: :ofac_sdn, source_ref: "1", type: :individual,
                                  names: [alias_name, primary])

      expect(built.primary_name).to eq(primary)
    end

    it "falls back to the first name when no kind is marked primary" do
      built = described_class.new(source: :canada_sema, source_ref: "1", type: :individual,
                                  names: [alias_name])

      expect(built.primary_name).to eq(alias_name)
    end

    it "returns nil when there are no names" do
      built = described_class.new(source: :ofac_sdn, source_ref: "1", type: :individual)

      expect(built.primary_name).to be_nil
    end
  end

  describe "#to_h" do
    it "serializes nested value objects" do
      expect(entity.to_h).to include(
        id: "ofac_sdn:2674", source: :ofac_sdn, source_ref: "2674", type: :individual,
        names: [{ value: "AL ZAWAHIRI, Aiman", kind: :primary }, { value: "ABU MUHAMMAD", kind: :aka }],
        listed_on: { year: 2001, precision: :year }
      )
    end

    it "lays keys out in canonical member order" do
      expect(entity.to_h.keys).to eq(described_class::MEMBERS)
    end

    it "retains the original remarks verbatim" do
      expect(entity.to_h[:remarks]).to eq("DOB 19 Jun 1951; Passport 1084010 (Egypt)")
    end
  end

  describe ".from_h" do
    it "round-trips a fully populated entity" do
      expect(described_class.from_h(entity.to_h)).to eq(entity)
    end

    it "round-trips an entity with every optional member empty" do
      minimal = described_class.new(source: :canada_sema, source_ref: "17", type: :organization)

      expect(described_class.from_h(minimal.to_h)).to eq(minimal)
    end

    # Storage (#24) persists gzipped JSON, which loses symbol keys entirely.
    it "round-trips through JSON" do
      revived = described_class.from_h(JSON.parse(JSON.generate(entity.to_h)))

      expect(revived.to_h).to eq(entity.to_h)
    end

    it "rejects unknown attributes rather than dropping them" do
      expect { described_class.from_h(entity.to_h.merge(score: 91)) }
        .to raise_error(ArgumentError, /unknown Entity attribute\(s\): score/)
    end
  end

  describe "equality" do
    it "compares by value" do
      expect(described_class.new(**attributes)).to eq(entity)
    end

    it "distinguishes entities differing in a single nested field" do
      other = described_class.new(**attributes, names: [alias_name])

      expect(other).not_to eq(entity)
    end

    it "hashes equal values alike, so entities can key a Hash or join a Set" do
      expect({ entity => :hit }[described_class.new(**attributes)]).to eq(:hit)
    end
  end
end
