# frozen_string_literal: true

require "tmpdir"

RSpec.describe ActiveSanction::Country do
  describe ".code" do
    it "resolves an alpha-2 code" do
      expect(described_class.code("RU")).to eq("RU")
    end

    it "resolves an alpha-3 code" do
      expect(described_class.code("RUS")).to eq("RU")
    end

    it "resolves the ISO name" do
      expect(described_class.code("Russian Federation")).to eq("RU")
    end

    # The whole reason the table has an alias column: the UN files nationality
    # as free text and OFAC writes it into a remarks sentence, so `Russia` is
    # far more common in this corpus than `Russian Federation`.
    it "resolves the name a publisher actually writes" do
      expect(described_class.code("Russia")).to eq("RU")
    end

    it "resolves a name whose word order the ISO entry inverts" do
      expect(described_class.code("Democratic People's Republic of Korea")).to eq("KP")
    end

    it "resolves the ISO entry's own word order too" do
      expect(described_class.code("Korea, Democratic People's Republic of")).to eq("KP")
    end

    it "folds case, accents and punctuation, so one line covers every spelling" do
      expect([described_class.code("côte d'ivoire"), described_class.code("COTE D IVOIRE")]).to all(eq("CI"))
    end

    it "resolves a historical name a record may still carry" do
      expect(described_class.code("Burma")).to eq("MM")
    end

    # A guess here would be applied as a decisive adjustment. `Niger` and
    # `Nigeria` are two countries and `Guinea` is three.
    it "does not guess at a name it does not have" do
      expect(described_class.code("Ruritania")).to be_nil
    end

    it "keeps countries whose names are prefixes of each other apart" do
      expect([described_class.code("Niger"), described_class.code("Nigeria")]).to eq(%w[NE NG])
    end

    it "is nil for nil, since an absent nationality is the common case" do
      expect(described_class.code(nil)).to be_nil
    end

    it "is nil for blank" do
      expect(described_class.code("   ")).to be_nil
    end
  end

  describe ".name" do
    it "gives the ISO name for a code" do
      expect(described_class.name("RU")).to eq("Russian Federation")
    end

    # An explanation that named one country two ways is one a reviewer has to
    # reconcile before they can read it.
    it "gives the ISO name for an alias, not the alias back" do
      expect(described_class.name("Burma")).to eq("Myanmar")
    end

    it "is nil for a country it does not have" do
      expect(described_class.name("Ruritania")).to be_nil
    end
  end

  describe "the shipped table" do
    it "carries every ISO 3166-1 country" do
      expect(described_class.codes.size).to eq(249)
    end

    it "resolves every code it lists" do
      expect(described_class.codes.map { |code| described_class.code(code) }).to eq(described_class.codes)
    end

    # Two countries quietly sharing a spelling would move a nationality
    # adjustment onto the wrong record, and every lookup would still answer.
    it "loads without a collision" do
      expect { described_class.read }.not_to raise_error
    end
  end

  describe ".read" do
    def write(rows)
      path = File.join(Dir.mktmpdir, "countries.txt")
      File.write(path, rows.join("\n"))
      path
    end

    it "ignores comments and blank lines" do
      codes, = described_class.read(write(["# a comment", "", "ZZ|ZZZ|Ruritania"]))

      expect(codes.fetch("ruritania")).to eq("ZZ")
    end

    it "refuses a row missing a field" do
      expect { described_class.read(write(["ZZ|ZZZ"])) }.to raise_error(ArgumentError, /needs a code/)
    end

    it "refuses two countries claiming one spelling" do
      expect { described_class.read(write(["ZZ|ZZZ|Ruritania", "YY|YYY|Ruritania"])) }
        .to raise_error(ArgumentError, /claimed by both/)
    end
  end
end
