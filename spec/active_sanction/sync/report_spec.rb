# frozen_string_literal: true

RSpec.describe ActiveSanction::Sync::Report do
  def result(source, status, **overrides)
    ActiveSanction::Sync::Result.new(
      source: source, status: status, duration: 1.5, record_count: overrides.key?(:error) ? nil : 100,
      checksum: overrides.key?(:error) ? nil : "sha256:#{"a" * 64}",
      fetched_at: overrides.key?(:error) ? nil : Time.utc(2026, 9, 5), age: overrides.key?(:error) ? nil : 3_600,
      **overrides
    )
  end

  def failure(source = :un_consolidated)
    result(source, :failed, error: ActiveSanction::FetchError.new("503", status: 503))
  end

  def report(*results, **overrides)
    described_class.new(results: results, started_at: Time.utc(2026, 9, 6), duration: 13.08, **overrides)
  end

  def mixed = report(result(:ofac_sdn, :updated), result(:canada_sema, :unchanged), failure)

  describe "what the run did" do
    it "groups the results by status" do
      expect(mixed).to have_attributes(updated: [result(:ofac_sdn, :updated)],
                                       unchanged: [result(:canada_sema, :unchanged)], failed: [failure])
    end

    it "answers for one source by name" do
      expect(mixed[:canada_sema].status).to eq(:unchanged)
    end

    # A caller asking about a source the run did not cover is asking a
    # question with an answer.
    it "answers nil for a source the run did not cover" do
      expect(mixed[:ofac_consolidated]).to be_nil
    end

    it "enumerates its results" do
      expect(mixed.map(&:source)).to eq(%i[ofac_sdn canada_sema un_consolidated])
    end

    it "counts the records stored across every source it covered" do
      expect(mixed.record_count).to eq(200)
    end

    it "reports the age of the stalest list it left behind" do
      expect(mixed.oldest_age).to eq(3_600)
    end

    it "lists the sources screening does not cover" do
      expect(mixed.unscreenable.map(&:source)).to eq(%i[un_consolidated])
    end
  end

  # So that cron mails somebody and CI goes red when a source is failing.
  describe "signalling a failure" do
    it "answers a non-zero exit code when any source failed" do
      expect(mixed).to have_attributes(failed?: true, success?: false, exit_code: 1)
    end

    it "answers zero when every source answered" do
      expect(report(result(:ofac_sdn, :updated))).to have_attributes(failed?: false, exit_code: 0)
    end

    it "raises for a caller that wants a failure fatal" do
      expect { mixed.success! }
        .to raise_error(ActiveSanction::Sync::Failed, /1 of 3 source\(s\) failed to sync: un_consolidated/)
    end

    it "carries the whole report on the exception it raises" do
      expect { mixed.success! }.to raise_error(an_instance_of(ActiveSanction::Sync::Failed)
        .and(having_attributes(report: mixed)))
    end

    it "returns itself when nothing failed" do
      clean = report(result(:ofac_sdn, :updated))

      expect(clean.success!).to be(clean)
    end
  end

  describe "serialization" do
    it "round-trips through JSON" do
      expect(described_class.from_h(JSON.parse(JSON.generate(mixed.to_h)))).to eq(mixed)
    end

    it "refuses an attribute it does not have" do
      expect { described_class.from_h(results: [], sources: []) }
        .to raise_error(ArgumentError, /unknown Sync::Report attribute\(s\): sources/)
    end
  end

  describe "reading it" do
    it "summarizes the run in one line" do
      expect(mixed.summary).to eq("3 sources in 13.08s: 1 updated, 1 unchanged, 1 failed")
    end

    # Columns rather than sentences: what an operator does with this is scan
    # down it for the row that is not like the others.
    it "prints a row per source, with what a failed source is still screening against" do
      expect(mixed.to_s.lines.last)
        .to eq("  un_consolidated  failed       - records  nothing stored    1.50s  ActiveSanction::FetchError: 503")
    end

    it "prints the age of a list that did not change" do
      expect(mixed.to_s).to include("100 records  1h old")
    end
  end

  it "is frozen on construction" do
    expect(mixed).to be_frozen
  end

  it "takes results as hashes, so a stored report reads back" do
    expect(described_class.from_h(mixed.to_h).results.first).to be_a(ActiveSanction::Sync::Result)
  end
end
