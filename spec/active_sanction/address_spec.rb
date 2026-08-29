# frozen_string_literal: true

require "json"
require "set"

RSpec.describe ActiveSanction::Address do
  let(:address) do
    described_class.new(
      street: "Ave. Luis Maria Drago 1136",
      city: "Buenos Aires",
      state_province: "Buenos Aires Province",
      postal_code: "C1414",
      country: "Argentina",
      note: "as of early 2016"
    )
  end

  describe "immutability" do
    it "freezes the address" do
      expect(address).to be_frozen
    end

    it "freezes each field, which repeats across thousands of ADD.CSV rows" do
      expect([address.city, address.country]).to all(be_frozen)
    end
  end

  describe "fields" do
    it "keeps the published strings verbatim" do
      expect(address.street).to eq("Ave. Luis Maria Drago 1136")
    end

    # The delimited sources pad their fields out; case, diacritics and
    # punctuation are signal the matcher has to see as published.
    it "strips surrounding whitespace without touching the rest" do
      expect(described_class.new(city: "  Sao  Paulo \n").city).to eq("Sao  Paulo")
    end

    # An empty string is not a smaller address, it is an absent field, and
    # keeping one would split two otherwise identical addresses.
    it "reads a field that was only whitespace as absent" do
      expect(described_class.new(city: "Tehran", street: "   ").street).to be_nil
    end

    # The UN routinely supplies only COUNTRY plus a free-text NOTE.
    it "accepts a country and a note alone" do
      sparse = described_class.new(country: "Iraq", note: "as of early 2016")

      expect([sparse.country, sparse.note, sparse.street]).to eq(["Iraq", "as of early 2016", nil])
    end

    it "raises on an address with every field blank, which is a parsing accident" do
      expect { described_class.new(city: "  ") }
        .to raise_error(ArgumentError, /an address needs at least one populated field/)
    end
  end

  describe "#parts" do
    it "returns the populated parts in canonical order" do
      expect(described_class.new(city: "Tehran", country: "Iran", street: "12 Vali Asr").parts)
        .to eq(["12 Vali Asr", "Tehran", "Iran"])
    end

    it "excludes the note, which annotates an address rather than locating it" do
      expect(described_class.new(country: "Iraq", note: "as of early 2016").parts).to eq(["Iraq"])
    end

    it "reports a note with no place at all as note-only" do
      expect(described_class.new(note: "address unknown")).to be_note_only
    end

    it "does not report an address carrying a place as note-only" do
      expect(described_class.new(country: "Iraq", note: "as of early 2016")).not_to be_note_only
    end
  end

  describe "#to_h" do
    it "lays keys out in canonical member order" do
      expect(address.to_h.keys).to eq(described_class::MEMBERS)
    end

    it "serializes every member" do
      expect(address.to_h).to eq(
        street: "Ave. Luis Maria Drago 1136",
        city: "Buenos Aires",
        state_province: "Buenos Aires Province",
        postal_code: "C1414",
        country: "Argentina",
        note: "as of early 2016"
      )
    end

    it "emits unset members as nil rather than dropping them" do
      expect(described_class.new(country: "Iraq").to_h)
        .to eq(street: nil, city: nil, state_province: nil, postal_code: nil, country: "Iraq", note: nil)
    end
  end

  describe ".from_h" do
    it "round-trips a fully populated address" do
      expect(described_class.from_h(address.to_h)).to eq(address)
    end

    it "round-trips an address with every optional member unset" do
      sparse = described_class.new(country: "Iraq")

      expect(described_class.from_h(sparse.to_h)).to eq(sparse)
    end

    # Storage::FileSystem (#24) persists gzipped JSON, which loses symbol keys.
    it "round-trips through JSON" do
      expect(described_class.from_h(JSON.parse(JSON.generate(address.to_h)))).to eq(address)
    end

    it "rejects unknown attributes rather than dropping them" do
      expect { described_class.from_h(address.to_h.merge(latitude: -34.6)) }
        .to raise_error(ArgumentError, /unknown Address attribute\(s\): latitude/)
    end
  end

  describe "equality" do
    it "compares by value" do
      expect(described_class.from_h(address.to_h)).to eq(address)
    end

    it "distinguishes addresses differing only in country" do
      expect(described_class.new(city: "Tripoli", country: "Libya"))
        .not_to eq(described_class.new(city: "Tripoli", country: "Lebanon"))
    end

    # De-duplicating the 25,078 addresses OFAC ships leans on this.
    it "hashes equal values alike, so addresses can key a Hash or join a Set" do
      expect(Set[address, described_class.from_h(address.to_h)].size).to eq(1)
    end
  end

  describe "#to_s" do
    it "joins the populated parts into one line" do
      expect(described_class.new(street: "12 Vali Asr", city: "Tehran", country: "Iran").to_s)
        .to eq("12 Vali Asr, Tehran, Iran")
    end

    it "renders the note apart from the place it annotates" do
      expect(described_class.new(country: "Iraq", note: "as of early 2016").to_s)
        .to eq("Iraq (as of early 2016)")
    end

    it "renders a note-only address as the note itself" do
      expect(described_class.new(note: "address unknown").to_s).to eq("address unknown")
    end
  end

  # Entity (#4) serializes its nested members through #to_h and rebuilds them
  # with .from_h.
  describe "as an Entity member" do
    it "survives an Entity round-trip" do
      entity = ActiveSanction::Entity.new(
        source: :ofac_sdn, source_ref: "2674", type: :organization, addresses: [address]
      )

      expect(ActiveSanction::Entity.from_h(JSON.parse(JSON.generate(entity.to_h))).addresses).to eq([address])
    end
  end
end
