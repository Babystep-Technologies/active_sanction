# frozen_string_literal: true

require "json"

RSpec.describe ActiveSanction::Subject do
  after { ActiveSanction.reset! }

  def subject_for(id: "cust_1", name: "Bosco Ntaganda", **overrides)
    described_class.new(id: id, name: name, **overrides)
  end

  describe "the id" do
    # A book screened by position cannot survive being filtered or streamed,
    # and two customers called Jane Miller is not a corner case.
    it "carries the caller's own id, unedited" do
      expect(subject_for(id: "  cust_1  ").id).to eq("cust_1")
    end

    it "accepts an id that is not a String" do
      expect(subject_for(id: 4_112).id).to eq("4112")
    end

    it "refuses a subject with no id" do
      expect { subject_for(id: "  ") }.to raise_error(ActiveSanction::InvalidArgument, /needs an id/)
    end

    it "refuses a subject with no name" do
      expect { described_class.new(id: "cust_1") }.to raise_error(ActiveSanction::InvalidArgument, /name is required/)
    end
  end

  describe "the evidence" do
    it "takes every field a screening call takes" do
      built = subject_for(type: :individual, dates_of_birth: ["1973"],
                          nationalities: %w[CD], identifiers: [{ kind: :passport, value: "AB-1" }])

      expect(built).to have_attributes(name: "Bosco Ntaganda", type: :individual,
                                       dates_of_birth: [ActiveSanction::PartialDate.parse("1973")],
                                       nationalities: %w[CD])
    end

    # A caller with one date writes the singular and should not have to
    # remember which spelling this library prefers.
    it "takes the singular spelling of every collection" do
      built = subject_for(date_of_birth: "1973", country: "CD",
                          identifier: { kind: :passport, value: "AB-1" })

      expect(built).to have_attributes(dates_of_birth: [ActiveSanction::PartialDate.parse("1973")],
                                       nationalities: %w[CD], identifiers: [an_instance_of(ActiveSanction::Identifier)])
    end

    it "folds the name once, at construction" do
      expect(subject_for.form.value).to eq("bosco ntaganda")
    end

    it "refuses an attribute it does not have" do
      expect { subject_for(favourite_colour: :blue) }
        .to raise_error(ActiveSanction::InvalidArgument, /unknown Subject attribute/)
    end
  end

  describe "the search options a rescreen settles for itself" do
    # Refused rather than ignored: a search option silently dropped is a
    # caller screening under a rule they think they set.
    it "refuses sources, which the diff being applied names" do
      expect { subject_for(sources: %i[ofac_sdn]) }
        .to raise_error(ActiveSanction::InvalidArgument, /does not take sources/)
    end

    it "refuses limit, since an alert dropped for being eleventh is a hit nobody sees" do
      expect { subject_for(limit: 5) }.to raise_error(ActiveSanction::InvalidArgument, /does not take limit/)
    end
  end

  describe "the threshold" do
    # Risk-based screening is ordinary: a correspondent bank at 70 and a
    # retail customer at 85 belong in one book.
    it "carries a threshold of its own" do
      expect(subject_for(threshold: 85).threshold).to eq(85.0)
    end

    # nil rather than the configured default, so a run can override it and so
    # "asked for 75" can be told from "did not ask".
    it "is nil when the subject does not name one" do
      expect(subject_for.threshold).to be_nil
    end

    it "refuses a threshold off the 0..100 scale" do
      expect { subject_for(threshold: 101) }.to raise_error(ActiveSanction::QueryError)
    end

    it "refuses a threshold that is not a number" do
      expect { subject_for(threshold: "high") }.to raise_error(ActiveSanction::InvalidArgument)
    end
  end

  describe "#query" do
    it "is the screening call this subject is, at the threshold given" do
      built = subject_for(date_of_birth: "1952").query(threshold: 80, sources: %i[ofac_sdn])

      expect(built).to have_attributes(name: "Bosco Ntaganda", threshold: 80.0, sources: %i[ofac_sdn])
    end

    it "falls back to the subject's own threshold" do
      expect(subject_for(threshold: 85).query.threshold).to eq(85.0)
    end
  end

  describe "serialization" do
    it "round-trips through JSON" do
      built = subject_for(type: :individual, date_of_birth: "1973", country: "CD", threshold: 85)

      expect(described_class.from_h(JSON.parse(JSON.generate(built.to_h)))).to eq(built)
    end

    it "builds from a Hash with string keys, which is what a database row is" do
      expect(described_class.build("id" => "cust_1", "name" => "Bosco Ntaganda")).to eq(subject_for)
    end

    it "passes a Subject through" do
      built = subject_for
      expect(described_class.build(built)).to equal(built)
    end

    it "refuses a bare name, which cannot say which record an alert is about" do
      expect { described_class.build("Bosco Ntaganda") }
        .to raise_error(ActiveSanction::InvalidArgument, /alerts against a caller's own id/)
    end
  end

  describe "value semantics" do
    it "compares by value" do
      expect(subject_for).to eq(described_class.from_h(subject_for.to_h))
    end

    it "differs when the id differs, whatever the name says" do
      expect(subject_for(id: "cust_2")).not_to eq(subject_for)
    end

    it "is frozen" do
      expect(subject_for).to be_frozen
    end

    it "inspects as its id and name" do
      expect(subject_for.inspect).to eq('#<ActiveSanction::Subject cust_1 "Bosco Ntaganda">')
    end
  end
end
