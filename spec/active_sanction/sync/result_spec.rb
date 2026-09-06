# frozen_string_literal: true

RSpec.describe ActiveSanction::Sync::Result do
  def fetched_at = Time.utc(2026, 9, 5, 12, 0, 0)

  def updated(**overrides)
    described_class.new(source: :ofac_sdn, status: :updated, duration: 12.41, record_count: 19_015,
                        checksum: "sha256:#{"a" * 64}", fetched_at: fetched_at, age: 0, **overrides)
  end

  def failed(**overrides)
    described_class.new(source: :un_consolidated, status: :failed, duration: 1.1,
                        error: Timeout::Error.new("execution expired"), **overrides)
  end

  describe "the three statuses" do
    it "answers which one it is" do
      expect(updated).to have_attributes(updated?: true, unchanged?: false, failed?: false)
    end

    it "refuses a status that is not one of them" do
      expect { updated(status: :skipped) }
        .to raise_error(ArgumentError, /status must be one of updated, unchanged, failed/)
    end

    it "requires a source" do
      expect { described_class.new(source: nil, status: :updated) }.to raise_error(ArgumentError, /source/)
    end
  end

  describe "what is stored now" do
    it "reports the snapshot behind it" do
      expect(updated).to have_attributes(record_count: 19_015, fetched_at: fetched_at, stored?: true)
    end

    # The behaviour the whole run is arranged around: a failure keeps the
    # previous list, and the age of what is being screened against is visible.
    it "reports a failure that kept its previous snapshot as retained" do
      expect(failed(record_count: 612, checksum: "sha256:#{"b" * 64}", fetched_at: fetched_at, age: 262_800))
        .to have_attributes(retained?: true, stored?: true, record_count: 612)
    end

    # Not stale, missing: screening does not cover this list at all.
    it "reports a failure with nothing behind it as unstored" do
      expect(failed).to have_attributes(retained?: false, stored?: false)
    end
  end

  describe "the captured failure" do
    it "keeps the exception for a caller that wants the backtrace" do
      expect(failed.exception).to be_a(Timeout::Error)
    end

    it "names the class and the message separately, as strings" do
      expect(failed).to have_attributes(error_class: "Timeout::Error", error_message: "execution expired")
    end

    it "reads back as one line for a log or a table" do
      expect(failed.error).to eq("Timeout::Error: execution expired")
    end

    it "has no error at all when nothing failed" do
      expect(updated).to have_attributes(error: nil, error_class: nil, exception: nil)
    end
  end

  describe "#age_in_words" do
    def aged(seconds) = updated(status: :unchanged, age: seconds)

    it "reads in the largest unit that fits" do
      expect([aged(0), aged(120), aged(7_200), aged(262_800)].map(&:age_in_words))
        .to eq(["just fetched", "2m old", "2h old", "3d old"])
    end

    # The age of a list that is not there is not the problem with it.
    it "says so when there is no snapshot behind the result" do
      expect(failed.age_in_words).to eq("nothing stored")
    end
  end

  describe "serialization" do
    it "round-trips through JSON" do
      round_tripped = described_class.from_h(JSON.parse(JSON.generate(failed(age: 90).to_h)))

      expect(round_tripped).to eq(failed(age: 90))
    end

    it "carries the failure into the round trip as strings" do
      round_tripped = described_class.from_h(JSON.parse(JSON.generate(failed.to_h)))

      expect(round_tripped).to have_attributes(error_class: "Timeout::Error", failed?: true)
    end

    # A backtrace is not something to put in a metrics pipeline.
    it "does not carry the exception object into the round trip" do
      expect(described_class.from_h(failed.to_h).exception).to be_nil
    end

    it "refuses an attribute it does not have" do
      expect { described_class.from_h(source: :ofac_sdn, status: :updated, entities: []) }
        .to raise_error(ArgumentError, /unknown Sync::Result attribute\(s\): entities/)
    end
  end

  it "is frozen on construction" do
    expect(updated).to be_frozen
  end

  it "compares by value" do
    expect(updated(record_count: 19_015)).to eq(updated)
  end

  it "reads as one line" do
    expect(updated.to_s).to eq("ofac_sdn updated in 12.41s: 19015 records, just fetched")
  end
end
