# frozen_string_literal: true

require "json"

RSpec.describe ActiveSanction::Rescreen::Alert do
  after { ActiveSanction.reset! }

  def entity(ref, name)
    ActiveSanction::Entity.new(source: :ofac_sdn, source_ref: ref.to_s, type: :individual,
                               names: [ActiveSanction::Name.new(value: name, kind: :primary)],
                               programs: ["SDGT"])
  end

  def match_result(name: "PUTIN, Vladimir Vladimirovich", snapshot_id: "sha256:new")
    scored = ActiveSanction::Scorer.call(
      ActiveSanction::Scorer::Subject.new(name: "Vladimir Putin"), entity(41_234, name), threshold: 0
    )
    ActiveSanction::MatchResult.from_scorer(scored, query: ActiveSanction::Query.build("Vladimir Putin"),
                                                    snapshot_id: snapshot_id,
                                                    weights: ActiveSanction::Scorer::Weights.build(nil))
  end

  let(:book_entry) { ActiveSanction::Subject.new(id: "cust_1", name: "Vladimir Putin") }

  def alert(change: :newly_listed, result: match_result, previous_result: nil, fields: [],
            subject: book_entry, snapshot_id: "sha256:new", previous_snapshot_id: "sha256:old")
    described_class.new(subject: subject, change: change, result: result, previous_result: previous_result,
                        fields: fields, snapshot_id: snapshot_id, previous_snapshot_id: previous_snapshot_id)
  end

  describe "what an alert is about" do
    it "names the subject by the caller's own id" do
      expect(alert.subject_id).to eq("cust_1")
    end

    it "reads the record and the source off the side that was raised" do
      expect(alert).to have_attributes(entity_id: "ofac_sdn:41234", source: :ofac_sdn)
    end

    it "answers its change as a predicate" do
      expect(alert).to have_attributes(newly_listed?: true, delisted?: false, details_changed?: false)
    end

    it "refuses a change it does not know" do
      expect { alert(change: :amended) }.to raise_error(ActiveSanction::InvalidArgument, /unknown change/)
    end

    it "refuses a subject that is not one" do
      expect { alert(subject: "cust_1") }.to raise_error(ActiveSanction::InvalidArgument, /must be an/)
    end
  end

  describe "the two sides" do
    it "reads the current score off the current side" do
      expect(alert.score).to eq(alert.result.score)
    end

    it "has no previous score when nothing was there before" do
      expect(alert.previous_score).to be_nil
    end

    # A delisting is the one where the previous side is the one that matched,
    # so that is the record an alert describes.
    it "describes a delisting from the previous side" do
      built = alert(change: :delisted, result: nil,
                    previous_result: match_result(name: "ABBAS, Abu", snapshot_id: "sha256:old"))

      expect(built.entity.primary_name.value).to eq("ABBAS, Abu")
    end

    # An alert that scored against neither list version is not a change, and
    # cannot say what it is about.
    it "refuses an alert with no side at all" do
      expect { alert(result: nil) }.to raise_error(ActiveSanction::InvalidArgument, /at least one side/)
    end
  end

  describe "both snapshot ids" do
    it "cites the pair of list versions the diff was computed over" do
      expect(alert).to have_attributes(snapshot_id: "sha256:new", previous_snapshot_id: "sha256:old")
    end

    it "refuses an alert that cannot cite both" do
      expect { alert(previous_snapshot_id: " ") }
        .to raise_error(ActiveSanction::InvalidArgument, /previous_snapshot_id is required/)
    end
  end

  describe "the summary a human reads" do
    it "prints the subject, what changed, the record and the score" do
      expect(alert.to_s).to match(/\Acust_1 {2}newly listed {2}ofac_sdn:41234 {2}PUTIN, Vladimir Vladimirovich/)
    end

    it "prints a movement when both sides scored" do
      built = alert(change: :details_changed,
                    previous_result: match_result(name: "PUTIN, Vladimir", snapshot_id: "sha256:old"))

      expect(built.to_s).to include("#{built.previous_score} -> #{built.score}")
    end

    it "says so when a record went away" do
      built = alert(change: :delisted, result: nil, previous_result: match_result(snapshot_id: "sha256:old"))

      expect(built.to_s).to end_with("-> delisted")
    end
  end

  describe "serialization" do
    it "round-trips through JSON" do
      built = alert(change: :details_changed, fields: %i[names programs],
                    previous_result: match_result(name: "PUTIN, Vladimir", snapshot_id: "sha256:old"))

      expect(described_class.from_h(JSON.parse(JSON.generate(built.to_h)))).to eq(built)
    end

    it "refuses an attribute it does not have" do
      expect { described_class.from_h(alert.to_h.merge(disposition: :cleared)) }
        .to raise_error(ActiveSanction::InvalidArgument, /unknown Alert attribute/)
    end
  end

  describe "value semantics" do
    it "compares by value" do
      expect(alert).to eq(described_class.from_h(alert.to_h))
    end

    it "is frozen" do
      expect(alert).to be_frozen
    end
  end
end
