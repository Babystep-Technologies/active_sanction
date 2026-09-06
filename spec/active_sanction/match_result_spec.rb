# frozen_string_literal: true

RSpec.describe ActiveSanction::MatchResult do
  def checksum = "sha256:#{"9f86d081884c7d65" * 4}"

  def listed(id: "ofac_sdn:1", source: :ofac_sdn, **rest)
    ActiveSanction::Entity.new(
      id: id, source: source, type: :individual,
      names: [ActiveSanction::Name.new(value: "PUTIN, Vladimir Vladimirovich")], **rest
    )
  end

  def reason(factor: :name, detail: "matched primary name", contribution: 91.2)
    ActiveSanction::Scorer::Reason.new(factor: factor, detail: detail, contribution: contribution)
  end

  def result(**overrides)
    described_class.new(
      entity: listed, matched_name: listed.names.first, explanation: [reason],
      query: { name: "Vladimir Putin" }, weights: ActiveSanction::Scorer::Weights.default,
      snapshot_id: checksum, **overrides
    )
  end

  describe "the score" do
    # The score is not stored beside the reasons, it is the sum of them. See
    # Scorer::Reason.
    it "is the sum of the explanation" do
      expect(result(explanation: [reason(contribution: 91.2), reason(factor: :dob, contribution: 6.0)]).score)
        .to eq(97.2)
    end

    it "is rounded to the precision a screening score is read at" do
      expect(result(explanation: [reason(contribution: 91.24)]).score).to eq(91.2)
    end

    it "accepts a score that agrees with its explanation, which is what a stored record asserts" do
      expect(result(score: 91.2).score).to eq(91.2)
    end

    # A remote scorer that has drifted from its own explanation is exactly the
    # thing this library must not launder into an audit record.
    it "refuses a score its explanation does not come to" do
      expect { result(score: 99.9) }.to raise_error(ArgumentError, /not what this explanation comes to/)
    end

    it "refuses an empty explanation" do
      expect { result(explanation: []) }.to raise_error(ArgumentError, /at least one reason/)
    end
  end

  describe "what a report reads off it" do
    it "names the specific spelling that produced the score" do
      expect(result.matched_name.value).to eq("PUTIN, Vladimir Vladimirovich")
    end

    # Read off the entity rather than stored beside it: a source that could
    # disagree with the record it describes is a field nobody can trust.
    it "names the list the hit came from" do
      expect(result.source).to eq(:ofac_sdn)
    end

    it "reports the threshold the run was willing to report at" do
      expect(result(query: { name: "Putin", threshold: 85 }).threshold).to eq(85.0)
    end

    it "singles out the reasons that lowered the score" do
      lowered = reason(factor: :nationality, detail: "query RU vs listed EG", contribution: -12.0)

      expect(result(explanation: [reason, lowered]).penalties).to eq([lowered])
    end
  end

  describe "the reproducibility stamp" do
    it "carries the checksum of the list version that answered" do
      expect(result.snapshot_id).to eq(checksum)
    end

    it "carries the matching pipeline that scored it" do
      expect(result.matcher_version).to eq(ActiveSanction::MATCHER_VERSION)
    end

    it "carries the weights it was scored under" do
      expect(result(weights: { dob_conflict: -20.0 }).weights.dob_conflict).to eq(-20.0)
    end

    it "carries what was screened, which a record of what was found does not say" do
      expect(result.query.name).to eq("Vladimir Putin")
    end

    it "says which backend answered" do
      expect(result.backend).to eq(:local)
    end

    it "takes a backend that is not this gem, which is the seam #56 opens" do
      expect(result(backend: :hosted).backend).to eq(:hosted)
    end

    it "stamps the time in UTC, truncated to the second #to_h serializes" do
      expect(result(screened_at: Time.at(1_757_160_000.9)).screened_at).to eq(Time.at(1_757_160_000).utc)
    end

    it "refuses a result that cannot name its list version" do
      expect { result(snapshot_id: nil) }.to raise_error(ArgumentError, /snapshot_id is required/)
    end

    it "refuses a result that cannot say what was screened" do
      expect { result(query: nil) }.to raise_error(ArgumentError, /query is required/)
    end
  end

  describe "serialization" do
    it "round-trips through to_h" do
      original = result

      expect(described_class.from_h(original.to_h)).to eq(original)
    end

    # The shape auditors read years later, out of whatever a host stored it in.
    it "round-trips through JSON" do
      original = result(query: { name: "Putin", type: :individual, dob: "1952", sources: %i[ofac_sdn] },
                        weights: { dob_conflict: -20.0 }, backend: :hosted)

      expect(described_class.from_h(JSON.parse(JSON.generate(original.to_h)))).to eq(original)
    end

    it "keeps the entity whole through the round trip" do
      expect(described_class.from_h(JSON.parse(JSON.generate(result.to_h))).entity).to eq(listed)
    end

    it "keeps the explanation adding up through the round trip" do
      restored = described_class.from_h(JSON.parse(JSON.generate(result.to_h)))

      expect(restored.explanation.sum(&:contribution)).to eq(restored.score)
    end

    it "emits only what JSON can carry" do
      expect { JSON.generate(result.to_h) }.not_to raise_error
    end

    it "emits the members in the documented order" do
      expect(result.to_h.keys).to eq(described_class::MEMBERS)
    end

    it "refuses an attribute it does not have" do
      expect { described_class.from_h(result.to_h.merge(confidence: 0.9)) }
        .to raise_error(ArgumentError, /unknown MatchResult attribute/)
    end

    # A record whose weights were dropped would silently be read back under
    # today's, which is the one thing a stamp exists to prevent.
    it "refuses a record that lost its weights rather than defaulting them" do
      expect { described_class.from_h(result.to_h.except(:weights)) }
        .to raise_error(ArgumentError, /weights/)
    end
  end

  describe ".from_scorer" do
    def scored
      ActiveSanction::Scorer.call(
        ActiveSanction::Scorer::Subject.new(name: "Vladimir Putin", type: :individual), listed
      )
    end

    it "carries the scorer's score across unchanged" do
      stamped = described_class.from_scorer(scored, query: ActiveSanction::Query.build("Vladimir Putin"),
                                                    snapshot_id: checksum,
                                                    weights: ActiveSanction::Scorer::Weights.default)

      expect(stamped.score).to eq(scored.score)
    end

    it "carries the scorer's explanation across unchanged" do
      stamped = described_class.from_scorer(scored, query: ActiveSanction::Query.build("Vladimir Putin"),
                                                    snapshot_id: checksum,
                                                    weights: ActiveSanction::Scorer::Weights.default)

      expect(stamped.explanation).to eq(scored.explanation)
    end
  end

  describe "the value semantics" do
    it "is frozen on construction" do
      expect(result).to be_frozen
    end

    it "compares by value" do
      same = result(screened_at: Time.at(0), score: 91.2)

      expect(result(screened_at: Time.at(0))).to eq(same)
    end

    it "is not equal to the same hit stamped against a different list version" do
      expect(result(screened_at: Time.at(0))).not_to eq(result(screened_at: Time.at(0), snapshot_id: "sha256:0"))
    end

    it "says what it is" do
      expect(result.inspect).to include("91.2", "PUTIN, Vladimir Vladimirovich", "ofac_sdn:1")
    end
  end
end
