# frozen_string_literal: true

require "json"
require "set"

RSpec.describe ActiveSanction::Name do
  let(:name) do
    described_class.new(value: "AERO-CARIBBEAN", kind: :aka, quality: :good, script: :latin)
  end

  describe "immutability" do
    it "freezes the name" do
      expect(name).to be_frozen
    end

    it "freezes the value, which is shared across thousands of records" do
      expect(name.value).to be_frozen
    end
  end

  describe "value" do
    it "keeps the published string verbatim" do
      expect(described_class.new(value: "AL-ZAWAHIRI, Dr. Ayman").value).to eq("AL-ZAWAHIRI, Dr. Ayman")
    end

    # The delimited sources pad fields out; case, diacritics and word order are
    # signal the matcher has to see as published, so only whitespace goes.
    it "strips surrounding whitespace without touching the rest" do
      expect(described_class.new(value: "  Ayman  al Zawahiri \n").value).to eq("Ayman  al Zawahiri")
    end

    it "raises on a missing value" do
      expect { described_class.new(value: nil) }.to raise_error(ArgumentError, /value is required/)
    end

    it "raises on a value that is only whitespace" do
      expect { described_class.new(value: "   ") }.to raise_error(ArgumentError, /value is required/)
    end
  end

  describe "kind" do
    it "accepts every member of the enum" do
      kinds = described_class::KINDS.map { |kind| described_class.new(value: "ACME", kind: kind).kind }

      expect(kinds).to eq(%i[primary aka fka nka])
    end

    # Canada publishes no aliases at all, so its adapter (#22) never sets a kind.
    it "defaults to primary" do
      expect(described_class.new(value: "ACME").kind).to eq(:primary)
    end

    # OFAC's ALT.CSV supplies alt_type as a string.
    it "accepts a string kind" do
      expect(described_class.new(value: "ACME", kind: "fka").kind).to eq(:fka)
    end

    it "raises on an unknown kind" do
      expect { described_class.new(value: "ACME", kind: :nickname) }
        .to raise_error(ArgumentError, /unknown kind :nickname, expected one of primary, aka, fka, nka/)
    end

    it "raises on an explicitly nil kind" do
      expect { described_class.new(value: "ACME", kind: nil) }.to raise_error(ArgumentError, /kind is required/)
    end
  end

  describe "quality" do
    it "accepts every member of the enum" do
      qualities = described_class::QUALITIES.map do |quality|
        described_class.new(value: "ACME", kind: :aka, quality: quality).quality
      end

      expect(qualities).to eq(%i[good low])
    end

    # The UN ships QUALITY as Good / Low.
    it "accepts a capitalized string, as the UN list publishes it" do
      expect(described_class.new(value: "ACME", kind: :aka, quality: "Low").quality).to eq(:low)
    end

    it "defaults to nil, since only the UN grades its aliases" do
      expect(described_class.new(value: "ACME", kind: :aka).quality).to be_nil
    end

    it "raises on an unknown quality" do
      expect { described_class.new(value: "ACME", kind: :aka, quality: :excellent) }
        .to raise_error(ArgumentError, /unknown quality :excellent, expected one of good, low/)
    end
  end

  describe "script" do
    it "defaults to nil" do
      expect(described_class.new(value: "ACME").script).to be_nil
    end

    # ISO 15924 defines roughly 200 scripts; a source shipping one we have not
    # seen should record it, not raise.
    it "accepts any script, symbolized and case-folded" do
      expect(described_class.new(value: "الظواهري", script: "Arabic").script).to eq(:arabic)
    end
  end

  describe "predicates" do
    it "reports a primary name as primary and not an alias" do
      primary = described_class.new(value: "ACME")

      expect([primary.primary?, primary.alias?]).to eq([true, false])
    end

    it "reports every non-primary kind as an alias" do
      aliases = %i[aka fka nka].map { |kind| described_class.new(value: "ACME", kind: kind).alias? }

      expect(aliases).to all(be(true))
    end

    it "reports a low quality alias, which the scorer (#32) penalizes" do
      expect(described_class.new(value: "ACME", kind: :aka, quality: :low)).to be_low_quality
    end

    # An ungraded name must not be penalized for a field its source never
    # publishes -- unstated is not the same as low.
    it "does not report an ungraded alias as low quality" do
      expect(described_class.new(value: "ACME", kind: :aka)).not_to be_low_quality
    end
  end

  describe "#to_h" do
    it "lays keys out in canonical member order" do
      expect(name.to_h.keys).to eq(described_class::MEMBERS)
    end

    it "serializes every member" do
      expect(name.to_h).to eq(value: "AERO-CARIBBEAN", kind: :aka, quality: :good, script: :latin)
    end

    it "emits unset optional members as nil rather than dropping them" do
      expect(described_class.new(value: "ACME").to_h).to eq(value: "ACME", kind: :primary, quality: nil, script: nil)
    end
  end

  describe ".from_h" do
    it "round-trips a fully populated name" do
      expect(described_class.from_h(name.to_h)).to eq(name)
    end

    it "round-trips a name with every optional member unset" do
      minimal = described_class.new(value: "ACME")

      expect(described_class.from_h(minimal.to_h)).to eq(minimal)
    end

    # Storage::FileSystem (#24) persists gzipped JSON, which loses symbol keys
    # and symbol values alike.
    it "round-trips through JSON" do
      expect(described_class.from_h(JSON.parse(JSON.generate(name.to_h)))).to eq(name)
    end

    it "rejects unknown attributes rather than dropping them" do
      expect { described_class.from_h(name.to_h.merge(normalized: "aero caribbean")) }
        .to raise_error(ArgumentError, /unknown Name attribute\(s\): normalized/)
    end
  end

  describe "equality" do
    it "compares by value" do
      expect(described_class.new(value: "AERO-CARIBBEAN", kind: :aka, quality: :good, script: :latin)).to eq(name)
    end

    it "distinguishes names differing only in kind" do
      expect(described_class.new(value: "AERO-CARIBBEAN", kind: :fka, quality: :good, script: :latin)).not_to eq(name)
    end

    it "distinguishes names differing only in quality" do
      expect(described_class.new(value: "AERO-CARIBBEAN", kind: :aka, quality: :low, script: :latin)).not_to eq(name)
    end

    # De-duplicating the 20,147 aliases OFAC ships leans on this.
    it "hashes equal values alike, so names can key a Hash or join a Set" do
      expect(Set[name, described_class.new(value: "AERO-CARIBBEAN", kind: :aka, quality: :good, script: :latin)].size)
        .to eq(1)
    end
  end

  describe "#to_s" do
    it "returns the value, so a name interpolates as its string" do
      expect("wanted: #{name}").to eq("wanted: AERO-CARIBBEAN")
    end
  end

  # Entity (#4) finds its primary name by asking each name for #kind, and
  # serializes nested members through #to_h.
  describe "as an Entity member" do
    it "satisfies the contract Entity depends on" do
      entity = ActiveSanction::Entity.new(
        source: :ofac_sdn, source_ref: "2674", type: :individual,
        names: [name, described_class.new(value: "AEROCARIBBEAN AIRLINES")]
      )

      expect(entity.primary_name.value).to eq("AEROCARIBBEAN AIRLINES")
    end

    it "survives an Entity round-trip" do
      entity = ActiveSanction::Entity.new(source: :un, source_ref: "1", type: :organization, names: [name])

      expect(ActiveSanction::Entity.from_h(JSON.parse(JSON.generate(entity.to_h))).names).to eq([name])
    end
  end
end
