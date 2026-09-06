# frozen_string_literal: true

RSpec.describe ActiveSanction::Scorer::Result do
  def reason(factor: :name, detail: "matched primary name \"ABBAS, Abu\"", contribution: 91.2)
    ActiveSanction::Scorer::Reason.new(factor: factor, detail: detail, contribution: contribution)
  end

  def name = ActiveSanction::Name.new(value: "ABBAS, Abu")

  def entity
    ActiveSanction::Entity.new(id: "sdn:1", source: :ofac_sdn, type: :individual, names: [name])
  end

  def result(explanation: [reason])
    described_class.new(entity: entity, name: name, form: ActiveSanction::Normalizer.call(name),
                        explanation: explanation)
  end

  describe "#score" do
    # The score is not stored beside the reasons, it is the sum of them. There
    # is no arithmetic anywhere that can move one without the other.
    it "is the sum of the explanation" do
      expect(result(explanation: [reason, reason(factor: :dob, detail: "year 1948 matches", contribution: 6.0)])
               .score).to eq(97.2)
    end

    it "sums the penalties too" do
      penalty = reason(factor: :nationality, detail: "query RU vs listed EG", contribution: -12.0)

      expect(result(explanation: [reason, penalty]).score).to eq(79.2)
    end

    it "sums the rounded contributions rather than rounding the sum" do
      thirds = Array.new(3) { reason(contribution: 0.05) }

      expect(result(explanation: thirds).score).to eq(0.3)
    end
  end

  describe "#initialize" do
    # A number a compliance officer cannot account for is a number they cannot
    # defend to an examiner.
    it "refuses a result with no explanation" do
      expect { result(explanation: []) }.to raise_error(ArgumentError, /at least one reason/)
    end

    it "is frozen" do
      expect(result).to be_frozen
    end
  end

  describe "what it carries" do
    it "names the list the entity came from" do
      expect(result.source).to eq(:ofac_sdn)
    end

    it "keeps the specific name that produced the score" do
      expect(result.name.value).to eq("ABBAS, Abu")
    end

    it "keeps that name folded, which is the string the comparison ran on" do
      expect(result.form.value).to eq("abbas abu")
    end

    it "picks out the reasons that lowered the score" do
      penalty = reason(factor: :nationality, detail: "query RU vs listed EG", contribution: -12.0)

      expect(result(explanation: [reason, penalty]).penalties).to eq([penalty])
    end
  end

  describe "#to_h" do
    it "carries the score, the entity, the name and every reason" do
      expect(result.to_h).to include(score: 91.2, entity_id: "sdn:1", source: :ofac_sdn)
    end

    it "serializes the explanation" do
      expect(result.to_h[:explanation]).to eq([reason.to_h])
    end
  end

  describe "value semantics" do
    it "compares by value" do
      expect(result).to eq(result(explanation: [reason]))
    end

    it "hashes with its equality, so two equal results are one Hash key" do
      expect([result, result].uniq.size).to eq(1)
    end

    it "differs when the explanation differs" do
      expect(result).not_to eq(result(explanation: [reason(contribution: 90.0)]))
    end
  end
end
