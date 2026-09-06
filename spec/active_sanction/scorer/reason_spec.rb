# frozen_string_literal: true

RSpec.describe ActiveSanction::Scorer::Reason do
  def reason(**overrides)
    described_class.new(factor: :dob, detail: "year 1948 matches", contribution: 6.0, **overrides)
  end

  describe "#initialize" do
    it "keeps the factor, the detail and the contribution" do
      expect(reason).to have_attributes(factor: :dob, detail: "year 1948 matches", contribution: 6.0)
    end

    it "takes a string factor, since a reason may have been through JSON" do
      expect(reason(factor: "nationality").factor).to eq(:nationality)
    end

    # A factor nothing renders would reach a compliance report as a blank.
    it "refuses a factor it does not have" do
      expect { reason(factor: :vibes) }.to raise_error(ArgumentError, /unknown factor :vibes/)
    end

    it "refuses a blank detail" do
      expect { reason(detail: "  ") }.to raise_error(ArgumentError, /nobody can read/)
    end

    # Rounding happens once, here, so that the score can be the sum of the
    # rounded contributions rather than the rounded sum.
    it "rounds the contribution to one decimal place" do
      expect(reason(contribution: 91.23456).contribution).to eq(91.2)
    end

    it "takes an Integer contribution" do
      expect(reason(contribution: 6).contribution).to eq(6.0)
    end

    it "is frozen" do
      expect(reason).to be_frozen
    end
  end

  describe "#penalty?" do
    it "is true for a contribution that lowers the score" do
      expect(reason(contribution: -8.0)).to be_penalty
    end

    it "is false for one that raises it" do
      expect(reason).not_to be_penalty
    end
  end

  describe "#to_s" do
    it "signs the contribution, so a reader can see which way it pushed" do
      penalty = reason(factor: :nationality, detail: "query RU vs listed EG", contribution: -8.0)

      expect(penalty.to_s).to eq("-8.0 nationality: query RU vs listed EG")
    end
  end

  describe "value semantics" do
    it "compares by value" do
      expect(reason).to eq(described_class.new(factor: :dob, detail: "year 1948 matches", contribution: 6.0))
    end

    it "hashes with its equality, so two equal reasons are one Hash key" do
      expect([reason, reason].uniq.size).to eq(1)
    end

    it "round-trips through #to_h" do
      expect(described_class.from_h(reason.to_h)).to eq(reason)
    end

    it "round-trips through string keys, which is what JSON leaves behind" do
      expect(described_class.from_h(reason.to_h.transform_keys(&:to_s))).to eq(reason)
    end

    it "refuses an attribute it does not have" do
      expect { described_class.from_h(reason.to_h.merge(weight: 1)) }
        .to raise_error(ArgumentError, /unknown Reason attribute/)
    end
  end
end
