# frozen_string_literal: true

RSpec.describe ActiveSanction::Scorer::Subject do
  describe "#initialize" do
    it "folds the name through the one normalizer everything else uses" do
      expect(described_class.new(name: "O'Brien, Seán").form.value).to eq("o brien sean")
    end

    it "keeps the caller's own spelling, which is what a report quotes back" do
      expect(described_class.new(name: "O'Brien, Seán").name).to eq("O'Brien, Seán")
    end

    # The stoplists are what take the legal form out of a company's name, and
    # both sides of a comparison have to be folded the same way.
    it "folds under the type, so the stoplists apply" do
      expect(described_class.new(name: "Rosneft Oil Company", type: :organization).form.value).to eq("rosneft oil")
    end

    it "takes an already-folded Form as it stands" do
      form = ActiveSanction::Normalizer.call("PJSC Gazprom", type: :organization)

      expect(described_class.new(name: form).form).to be(form)
    end

    it "takes a Name" do
      expect(described_class.new(name: ActiveSanction::Name.new(value: "Abu Abbas")).form.value).to eq("abu abbas")
    end

    it "refuses a blank name -- there is nothing to screen without one" do
      expect { described_class.new(name: "  ") }.to raise_error(ArgumentError, /name is required/)
    end

    it "refuses a name that folds away to nothing" do
      expect { described_class.new(name: "---") }.to raise_error(ArgumentError, /folds away/)
    end

    it "refuses a type no entity can have" do
      expect { described_class.new(name: "Abu Abbas", type: :ship) }
        .to raise_error(ArgumentError, /unknown type :ship/)
    end

    it "allows no type at all, which asks a different question rather than a worse one" do
      expect(described_class.new(name: "Abu Abbas").type).to be_nil
    end
  end

  describe "the evidence beside the name" do
    it "reads a date of birth from anything PartialDate reads" do
      expect(described_class.new(name: "x", dates_of_birth: "circa 1962").dates_of_birth.first)
        .to eq(ActiveSanction::PartialDate.new(year: 1962, approximate: true))
    end

    it "takes one date rather than a list, which is what a caller with one writes" do
      expect(described_class.new(name: "x", dates_of_birth: "1948").dates_of_birth.size).to eq(1)
    end

    it "takes several, since the UN publishes several for one person" do
      subject = described_class.new(name: "x", dates_of_birth: %w[1948 1949])

      expect(subject.dates_of_birth.size).to eq(2)
    end

    it "refuses text that is not a date" do
      expect { described_class.new(name: "x", dates_of_birth: "whenever") }
        .to raise_error(ArgumentError, /not a date of birth/)
    end

    it "reads a bare document number as an identifier of unstated kind" do
      identifier = described_class.new(name: "x", identifiers: "AB-123 456").identifiers.first

      expect(identifier).to have_attributes(kind: :other, normalized_value: "ab123456")
    end

    it "reads an identifier hash" do
      subject = described_class.new(name: "x", identifiers: [{ kind: :passport, value: "AB123456" }])

      expect(subject.identifiers.first.kind).to eq(:passport)
    end

    it "keeps nationalities as the caller wrote them" do
      expect(described_class.new(name: "x", nationalities: "Russia").nationalities).to eq(["Russia"])
    end
  end

  describe "#countries" do
    it "resolves the caller's vocabulary to alpha-2 codes" do
      expect(described_class.new(name: "x", nationalities: %w[Russia EGY]).countries).to eq(%w[RU EG])
    end

    it "drops a country nobody can resolve rather than guessing" do
      expect(described_class.new(name: "x", nationalities: ["Ruritania"]).countries).to be_empty
    end

    it "deduplicates two spellings of one country" do
      expect(described_class.new(name: "x", nationalities: %w[Russia RUS]).countries).to eq(%w[RU])
    end
  end

  describe "#countries?" do
    # Only a subject whose every country resolved can contradict a record --
    # "these two strings differ" is not evidence that two countries do.
    it "is true when every nationality resolved" do
      expect(described_class.new(name: "x", nationalities: %w[RU EG])).to be_countries
    end

    it "is false when one did not" do
      expect(described_class.new(name: "x", nationalities: %w[RU Ruritania])).not_to be_countries
    end

    it "is false when the caller gave none" do
      expect(described_class.new(name: "x")).not_to be_countries
    end
  end

  describe "value semantics" do
    it "is frozen" do
      expect(described_class.new(name: "Abu Abbas")).to be_frozen
    end

    it "compares by value" do
      asked = described_class.new(name: "Abu Abbas", type: :individual)

      expect(asked).to eq(described_class.new(name: "Abu Abbas", type: :individual))
    end

    it "round-trips through #to_h" do
      subject = described_class.new(name: "Abu Abbas", type: :individual, dates_of_birth: "1948",
                                    nationalities: %w[RU], identifiers: "AB123456")

      expect(described_class.from_h(subject.to_h)).to eq(subject)
    end

    it "refuses an attribute it does not have" do
      expect { described_class.from_h(name: "x", threshold: 75) }
        .to raise_error(ArgumentError, /unknown Subject attribute/)
    end
  end
end
