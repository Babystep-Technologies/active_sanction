# frozen_string_literal: true

require "json"
require "set"

RSpec.describe ActiveSanction::Identifier do
  let(:identifier) do
    described_class.new(
      kind: :passport,
      value: "AB-123 456",
      country: "Egypt",
      issued_on: ActiveSanction::PartialDate.new(year: 2004, month: 6, day: 1),
      expires_on: ActiveSanction::PartialDate.new(year: 2009, month: 5, day: 31),
      note: "expired"
    )
  end

  describe "immutability" do
    it "freezes the identifier" do
      expect(identifier).to be_frozen
    end

    it "freezes the value and its normalized form" do
      expect([identifier.value, identifier.normalized_value]).to all(be_frozen)
    end
  end

  describe "value" do
    it "keeps the published string verbatim, which is what justifies a hit" do
      expect(identifier.value).to eq("AB-123 456")
    end

    it "strips surrounding whitespace" do
      expect(described_class.new(value: "  123456 \n").value).to eq("123456")
    end

    it "raises on a missing value" do
      expect { described_class.new(value: nil) }.to raise_error(ArgumentError, /value is required/)
    end

    it "raises on a value that is only whitespace" do
      expect { described_class.new(value: "   ") }.to raise_error(ArgumentError, /value is required/)
    end

    # Punctuation is all that normalization strips, so a value made only of it
    # would compare equal to every other such value.
    it "raises on a value with no alphanumerics at all" do
      expect { described_class.new(value: "---") }
        .to raise_error(ArgumentError, /value has no alphanumerics: "---"/)
    end
  end

  describe "#normalized_value" do
    it "strips punctuation and spaces and folds case" do
      expect(identifier.normalized_value).to eq("ab123456")
    end

    it "leaves the original untouched" do
      expect(identifier.value).to eq("AB-123 456")
    end

    it "normalizes the separators the sources actually use" do
      normalized = ["AB/123.456", "ab 123 456", "AB-123-456"].map do |value|
        described_class.new(value: value).normalized_value
      end

      expect(normalized).to all(eq("ab123456"))
    end
  end

  describe "kind" do
    it "accepts every member of the enum" do
      kinds = described_class::KINDS.map { |kind| described_class.new(value: "1", kind: kind).kind }

      expect(kinds).to eq(%i[passport national_id tax_id registration_number other])
    end

    # OFAC remarks give plenty of numbers we cannot classify; the number still
    # matches, so an unclassified document is a real answer rather than a loss.
    it "defaults to other" do
      expect(described_class.new(value: "123456").kind).to eq(:other)
    end

    # The UN publishes TYPE_OF_DOCUMENT as capitalized free text.
    it "accepts a capitalized string kind" do
      expect(described_class.new(value: "123456", kind: "Passport").kind).to eq(:passport)
    end

    it "raises on an unknown kind, naming what it will accept" do
      expect { described_class.new(value: "123456", kind: :drivers_license) }
        .to raise_error(ArgumentError, /unknown kind :drivers_license, expected one of passport, national_id/)
    end

    it "raises on an explicitly nil kind" do
      expect { described_class.new(value: "123456", kind: nil) }.to raise_error(ArgumentError, /kind is required/)
    end

    it "reports a passport, which the scorer (#32) weights above every other kind" do
      expect(identifier).to be_passport
    end
  end

  describe "dates" do
    it "accepts PartialDates" do
      expect(identifier.expires_on).to eq(ActiveSanction::PartialDate.new(year: 2009, month: 5, day: 31))
    end

    # The UN publishes year-only expiries, which is exactly what PartialDate
    # exists to hold.
    it "parses a date given as text" do
      expect(described_class.new(value: "1", expires_on: "2009").expires_on)
        .to eq(ActiveSanction::PartialDate.new(year: 2009))
    end

    it "builds a date from a #to_h hash" do
      expect(described_class.new(value: "1", issued_on: { year: 2004, month: 6 }).issued_on)
        .to eq(ActiveSanction::PartialDate.new(year: 2004, month: 6))
    end

    it "defaults to nil, since most sources publish no dates at all" do
      expect(described_class.new(value: "1").issued_on).to be_nil
    end

    it "raises on text it cannot read as a date" do
      expect { described_class.new(value: "1", expires_on: "whenever") }
        .to raise_error(ArgumentError, /expires_on is not a date: "whenever"/)
    end
  end

  describe "#to_h" do
    it "lays keys out in canonical member order" do
      expect(identifier.to_h.keys).to eq(described_class::MEMBERS)
    end

    it "serializes the published value rather than the normalized one" do
      expect(identifier.to_h[:value]).to eq("AB-123 456")
    end

    it "serializes nested dates" do
      expect(identifier.to_h[:expires_on]).to eq(
        year: 2009, month: 5, day: 31, from: nil, to: nil, approximate: false
      )
    end

    it "emits unset members as nil rather than dropping them" do
      expect(described_class.new(value: "123456").to_h)
        .to eq(kind: :other, value: "123456", country: nil, issued_on: nil, expires_on: nil, note: nil)
    end
  end

  describe ".from_h" do
    it "round-trips a fully populated identifier" do
      expect(described_class.from_h(identifier.to_h)).to eq(identifier)
    end

    it "round-trips a value whose punctuation normalization would have lost" do
      expect(described_class.from_h(identifier.to_h).value).to eq("AB-123 456")
    end

    it "round-trips an identifier with every optional member unset" do
      minimal = described_class.new(value: "123456")

      expect(described_class.from_h(minimal.to_h)).to eq(minimal)
    end

    # Storage::FileSystem (#24) persists gzipped JSON, which loses symbol keys
    # and symbol values alike.
    it "round-trips through JSON, dates included" do
      revived = described_class.from_h(JSON.parse(JSON.generate(identifier.to_h)))

      expect([revived, revived.expires_on]).to eq([identifier, identifier.expires_on])
    end

    it "rejects unknown attributes rather than dropping them" do
      expect { described_class.from_h(identifier.to_h.merge(normalized_value: "ab123456")) }
        .to raise_error(ArgumentError, /unknown Identifier attribute\(s\): normalized_value/)
    end
  end

  describe "equality" do
    # The acceptance criterion: one passport written down by two governments.
    it "treats values differing only in punctuation and case as equal" do
      expect(described_class.new(kind: :passport, value: "ab123456", country: "EGYPT"))
        .to eq(described_class.new(kind: :passport, value: "AB-123 456", country: "Egypt"))
    end

    it "distinguishes identifiers whose numbers actually differ" do
      expect(described_class.new(value: "AB-123 457")).not_to eq(described_class.new(value: "AB-123 456"))
    end

    # Same number, different document: a national ID is not a passport.
    it "distinguishes identifiers differing only in kind" do
      expect(described_class.new(kind: :passport, value: "123456"))
        .not_to eq(described_class.new(kind: :national_id, value: "123456"))
    end

    it "distinguishes identifiers differing only in issuing country" do
      expect(described_class.new(kind: :passport, value: "123456", country: "Egypt"))
        .not_to eq(described_class.new(kind: :passport, value: "123456", country: "Iraq"))
    end

    # A country stated on one side only is a thinner record of the same claim,
    # not a competing one -- but it is still a difference the key keeps, since
    # nothing here can prove the unstated country matches.
    it "distinguishes an identifier with a country from one without" do
      expect(described_class.new(kind: :passport, value: "123456"))
        .not_to eq(described_class.new(kind: :passport, value: "123456", country: "Egypt"))
    end

    # Publishers report issue dates, expiries and notes inconsistently; letting
    # them split one document into two records would defeat the de-duplication
    # this comparison exists for.
    it "ignores dates and notes, which are metadata about one same document" do
      expect(described_class.new(kind: :passport, value: "123456", expires_on: "2009", note: "expired"))
        .to eq(described_class.new(kind: :passport, value: "123456"))
    end

    it "hashes equal values alike, so identifiers can key a Hash or join a Set" do
      expect(Set[identifier, described_class.new(kind: "passport", value: "ab123456", country: "egypt")].size)
        .to eq(1)
    end
  end

  describe "#to_s" do
    it "returns the published value, so an identifier interpolates as its string" do
      expect("passport #{identifier}").to eq("passport AB-123 456")
    end
  end

  # Entity (#4) serializes its nested members through #to_h and rebuilds them
  # with .from_h.
  describe "as an Entity member" do
    it "survives an Entity round-trip" do
      entity = ActiveSanction::Entity.new(
        source: :un, source_ref: "6908555", type: :individual, identifiers: [identifier]
      )
      revived = ActiveSanction::Entity.from_h(JSON.parse(JSON.generate(entity.to_h)))

      expect(revived.identifiers.map(&:value)).to eq(["AB-123 456"])
    end
  end
end
