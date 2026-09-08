# frozen_string_literal: true

RSpec.describe ActiveSanction::Parsers::ColumnShape do
  def numeric(**options) = described_class.new(name: :ent_num, matches: /\A\d+\z/, **options)

  def typed(**options) = described_class.new(name: :sdn_type, allowing: %w[individual vessel], **options)

  describe ".new" do
    it "refuses a shape with no rule to check" do
      expect { described_class.new(name: :ent_num) }
        .to raise_error(ActiveSanction::InvalidArgument, /matches:|allowing:|satisfying:/)
    end

    it "refuses a threshold that is not a share" do
      expect { numeric(at_least: 40) }.to raise_error(ActiveSanction::InvalidArgument, /between 0 and 1/)
    end

    it "refuses a shape with no column to check" do
      expect { described_class.new(name: " ", matches: /x/) }
        .to raise_error(ActiveSanction::InvalidArgument, /column name/)
    end

    it "describes a value list in words when it is given none" do
      expect(typed.description).to eq("one of individual, vessel")
    end
  end

  describe "#tally" do
    it "counts the values that satisfy the rule" do
      expect(numeric.tally(%w[36 2674 7157])).to have_attributes(checked: 3, matched: 3, ratio: 1.0, ok?: true)
    end

    it "fails a column holding something else entirely" do
      expect(numeric.tally(["AEROCARIBBEAN AIRLINES", "ABBAS, Abu"]))
        .to have_attributes(matched: 0, ratio: 0.0, ok?: false)
    end

    # What a failure is for: naming what moved into the column instead.
    it "keeps a sample of what did not satisfy it" do
      expect(numeric.tally(%w[ACME BETA GAMMA DELTA]).sample).to eq(%w[ACME BETA GAMMA])
    end

    # A published file is not a validated one, and one row where somebody typed
    # a letter into a numeric column is a curiosity rather than a format change.
    it "tolerates a stray row under the threshold" do
      expect(numeric(at_least: 0.9).tally(%w[1 2 3 4 5 6 7 8 9 x])).to be_ok
    end

    it "holds the file to the threshold it was given" do
      expect(numeric(at_least: 1.0).tally(%w[1 2 3 4 5 6 7 8 9 x])).not_to be_ok
    end

    # OFAC writes its null sentinel roughly a quarter of a million times, and a
    # column the publisher left empty says nothing about its own shape.
    it "does not count blank values against the column" do
      expect(typed.tally(["individual", nil, "  ", "vessel"]))
        .to have_attributes(checked: 2, blank: 2, ok?: true)
    end

    it "matches a value list without regard to case or surrounding space" do
      expect(typed.tally([" Individual ", "VESSEL"])).to be_ok
    end

    # A column that is blank on every row is a fill rate that fell to zero,
    # which is a different complaint and is already made elsewhere.
    it "passes a column with nothing in it to measure" do
      expect(numeric.tally([nil, nil])).to have_attributes(checked: 0, ratio: 1.0, ok?: true)
    end

    it "takes a callable for a rule a pattern cannot express" do
      shape = described_class.new(name: :tonnage, satisfying: ->(value) { value.delete(",").to_i.positive? })

      expect(shape.tally(["1,977", "0"])).to have_attributes(matched: 1)
    end
  end

  describe "a tally" do
    it "says what the column holds, on how many rows, against what was expected" do
      expect(numeric.tally(%w[ACME 2674]).to_s)
        .to eq('ent_num matching /\\A\\d+\\z/ on 50% of 2 rows (expected 99%): "ACME"')
    end

    it "serializes to something a profile can keep" do
      expect(numeric.tally(%w[36 x]).to_h)
        .to include(column: :ent_num, checked: 2, matched: 1, ratio: 0.5, at_least: 0.99)
    end
  end
end
