# frozen_string_literal: true

RSpec.describe ActiveSanction::Scorer::Weights do
  describe ".default" do
    it "is one instance rather than one per call" do
      expect(Array.new(2) { described_class.default }.uniq(&:object_id).size).to eq(1)
    end

    # The property that makes the name score a percentage: two identical names
    # reach exactly 100 because every share agreed.
    it "ships name shares that sum to 1" do
      total = described_class::NAME_SHARES.sum { |share| described_class.default.fetch(share) }

      expect(total).to be_within(1e-9).of(1.0)
    end

    it "weights the token ratios above the character algorithms" do
      weights = described_class.default

      expect(weights.token_set + weights.token_sort).to be > weights.jaro_winkler + weights.levenshtein
    end

    # A name in the fifties plus the right passport number has to clear any
    # threshold this library would ship.
    it "makes a document number decisive" do
      expect(described_class.default.identifier_match).to eq(40.0)
    end

    # The acceptance criterion the issue pins down: a name-identical pair
    # scores 100 and a genuine date conflict has to put it under threshold.
    it "makes a date-of-birth conflict cost more than a threshold's worth" do
      expect(described_class.default.dob_conflict).to eq(-35.0)
    end

    it "moves nationality least in both directions" do
      weights = described_class.default

      expect([weights.nationality_match, weights.nationality_conflict.abs])
        .to all(be < weights.dob_exact)
    end
  end

  describe ".build" do
    it "takes the defaults for nil, so a caller can pass what it has" do
      expect(described_class.build(nil)).to be(described_class.default)
    end

    it "passes a Weights through" do
      weights = described_class.new(dob_conflict: -20.0)

      expect(described_class.build(weights)).to be(weights)
    end

    it "replaces only the numbers a Hash names" do
      weights = described_class.build(dob_conflict: -20.0)

      expect(weights).to have_attributes(dob_conflict: -20.0, identifier_match: 40.0)
    end

    it "accepts string keys, since a Hash may have been through JSON" do
      expect(described_class.build("dob_conflict" => -20.0).dob_conflict).to eq(-20.0)
    end

    it "refuses something that is neither" do
      expect { described_class.build(42) }.to raise_error(ArgumentError, /Weights or a Hash/)
    end
  end

  describe "validation" do
    it "refuses name shares that do not sum to 1" do
      expect { described_class.new(token_set: 0.9) }.to raise_error(ArgumentError, /must sum to 1\.0/)
    end

    it "names the shares and their values, so the arithmetic is visible" do
      expect { described_class.new(token_set: 0.9) }.to raise_error(ArgumentError, /token_set=0\.9/)
    end

    it "refuses a share outside 0..1" do
      expect { described_class.new(token_set: 2.0) }
        .to raise_error(ArgumentError, /token_set must be between 0 and 1/)
    end

    # A boost written negative silently inverts a signal -- a passport match
    # that lowers a score -- and looks exactly like a scorer bug from outside.
    it "refuses a boost written negative" do
      expect { described_class.new(identifier_match: -40.0) }
        .to raise_error(ArgumentError, /identifier_match is a boost/)
    end

    it "refuses a penalty written positive" do
      expect { described_class.new(dob_conflict: 35.0) }
        .to raise_error(ArgumentError, /dob_conflict is a penalty/)
    end

    it "refuses a weight it does not have" do
      expect { described_class.new(vibes: 1.0) }.to raise_error(ArgumentError, /unknown weight\(s\): vibes/)
    end

    it "refuses a weight that is not a number" do
      expect { described_class.new(dob_exact: "lots") }.to raise_error(ArgumentError, /must be a number/)
    end

    it "takes an Integer, since a host will write 40 rather than 40.0" do
      expect(described_class.new(identifier_match: 50).identifier_match).to eq(50.0)
    end
  end

  describe "#merge" do
    it "keeps everything it was not asked to change" do
      expect(described_class.default.merge(dob_exact: 20.0))
        .to have_attributes(dob_exact: 20.0, dob_overlap: 6.0)
    end

    it "leaves the original alone" do
      described_class.default.merge(dob_exact: 20.0)

      expect(described_class.default.dob_exact).to eq(15.0)
    end
  end

  describe "value semantics" do
    it "compares by value" do
      weights = described_class.new(dob_exact: 20.0)

      expect(weights).to eq(described_class.new(dob_exact: 20.0))
    end

    it "hashes with its equality, so two equal sets are one Hash key" do
      pair = [described_class.new(dob_exact: 20.0), described_class.new(dob_exact: 20.0)]

      expect(pair.uniq.size).to eq(1)
    end

    it "is frozen" do
      expect(described_class.default).to be_frozen
    end

    it "round-trips through #to_h" do
      weights = described_class.new(dob_exact: 20.0)

      expect(described_class.build(weights.to_h)).to eq(weights)
    end
  end
end
