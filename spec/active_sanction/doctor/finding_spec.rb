# frozen_string_literal: true

RSpec.describe ActiveSanction::Doctor::Finding do
  def finding(**overrides)
    described_class.new(source: :ofac_sdn, severity: :warn, check: :record_count,
                        message: "12,433 records, was 19,015 (down 34.6%)", **overrides)
  end

  describe ".new" do
    it "refuses a severity outside the three" do
      expect { finding(severity: :critical) }
        .to raise_error(ActiveSanction::InvalidArgument, /info, warn, error/)
    end

    it "refuses a finding with nothing to say" do
      expect { finding(message: "  ") }.to raise_error(ActiveSanction::InvalidArgument, /message is required/)
    end

    it "freezes on construction" do
      expect(finding).to be_frozen
    end
  end

  describe "severity" do
    it "answers which one it is" do
      expect([finding.warn?, finding.error?, finding.info?]).to eq([true, false, false])
    end

    it "compares against a level a monitoring rule alerts at" do
      expect([finding.at_least?(:info), finding.at_least?(:warn), finding.at_least?(:error)])
        .to eq([true, true, false])
    end
  end

  # `message` is for a person reading a terminal; these two are for everything
  # else -- a threshold in a monitoring rule, a graph of a fill rate.
  describe "the measurement" do
    it "carries what was measured and what it was measured against" do
      expect(finding(observed: 0.12, baseline: 0.61)).to have_attributes(observed: 0.12, baseline: 0.61)
    end

    # The difference between "this drifted" and "this is the first look at it".
    it "says whether there was anything to compare with" do
      expect([finding(baseline: 0.61).compared?, finding(baseline: nil).compared?]).to eq([true, false])
    end
  end

  describe "serialization" do
    it "rebuilds from its own hash" do
      original = finding(observed: 12_433, baseline: 19_015)

      expect(described_class.from_h(original.to_h)).to eq(original)
    end

    it "survives the trip through JSON" do
      original = finding(observed: 0.12, baseline: 0.61)

      expect(described_class.from_h(JSON.parse(JSON.generate(original.to_h)))).to eq(original)
    end

    it "refuses a hash carrying an attribute it does not have" do
      expect { described_class.from_h(finding.to_h.merge(severity_level: :warn)) }
        .to raise_error(ActiveSanction::InvalidArgument, /severity_level/)
    end
  end

  describe "#to_line" do
    it "prints the severity beside the message, for the report" do
      expect(finding.to_line).to eq("  warn   12,433 records, was 19,015 (down 34.6%)")
    end
  end
end
