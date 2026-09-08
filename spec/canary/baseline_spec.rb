# frozen_string_literal: true

require "tmpdir"

require_relative "../../canary/canary"

RSpec.describe Canary::Baseline do
  let(:directory) { Dir.mktmpdir("canary-baselines") }

  let(:profile) do
    ActiveSanction::Doctor::Profile.new(source: :ofac_sdn, record_count: 19_321, remarks_coverage: 0.973,
                                        cohorts: { all: 19_321, individual: 11_704 },
                                        fill: { identifiers: 0.341 })
  end

  after { FileUtils.remove_entry(directory, true) }

  def finding(check, observed, baseline, severity: :warn)
    ActiveSanction::Doctor::Finding.new(source: :ofac_sdn, severity: severity, check: check,
                                        message: "#{check} moved", observed: observed, baseline: baseline)
  end

  def write(hash, source: :ofac_sdn)
    File.write(described_class.path(source, directory: directory), JSON.generate(hash))
  end

  describe ".load" do
    it "reads a committed baseline into a profile" do
      write({ source: "ofac_sdn", captured_at: "2026-09-01T00:00:00Z", profile: profile.to_h })

      expect(described_class.load(:ofac_sdn, directory: directory))
        .to have_attributes(source: :ofac_sdn, present?: true, captured_at: "2026-09-01T00:00:00Z",
                            profile: profile)
    end

    it "answers with an empty baseline for a source nobody has committed one for" do
      baseline = described_class.load(:brand_new_list, directory: directory)

      expect(baseline).to have_attributes(source: :brand_new_list, present?: false, profile: nil)
    end

    it "raises rather than treating an unreadable baseline as no baseline" do
      File.write(described_class.path(:ofac_sdn, directory: directory), "{ not json")

      expect { described_class.load(:ofac_sdn, directory: directory) }
        .to raise_error(described_class::Malformed, /not readable JSON/)
    end

    it "raises for JSON that does not describe a profile" do
      write({ source: "ofac_sdn", profile: { record_count: 1, nonsense: true } })

      expect { described_class.load(:ofac_sdn, directory: directory) }
        .to raise_error(described_class::Malformed, /does not describe a profile/)
    end
  end

  describe "tolerances" do
    it "holds a record count looser than the free-text coverage, which does not move on its own" do
      baseline = described_class.new(source: :ofac_sdn)

      expect([baseline.tolerance(:record_count), baseline.tolerance(:remarks_coverage)]).to eq([0.05, 0.02])
    end

    it "gives every other check the doctor's own default" do
      expect(described_class.new(source: :ofac_sdn).tolerance(:fill_identifiers))
        .to eq(described_class::DEFAULT_TOLERANCE)
    end

    it "lets the committed file override any of them" do
      write({ source: "ofac_sdn", tolerances: { record_count: 0.2 }, profile: profile.to_h })

      expect(described_class.load(:ofac_sdn, directory: directory).tolerance(:record_count)).to eq(0.2)
    end

    it "runs the doctor at the tightest tolerance it names, so nothing is missed before it is filtered" do
      baseline = described_class.new(source: :ofac_sdn, tolerances: { fill_identifiers: 0.01 })

      expect(baseline.finest).to eq(0.01)
    end
  end

  describe "#allows?" do
    let(:baseline) { described_class.new(source: :ofac_sdn) }

    it "permits a record count that moved less than its tolerance" do
      expect(baseline.allows?(finding(:record_count, 19_400, 19_321))).to be(true)
    end

    it "reports a record count that moved more than its tolerance" do
      expect(baseline.allows?(finding(:record_count, 15_000, 19_321))).to be(false)
    end

    it "reports a remarks coverage drop that a record count of the same size would have been allowed" do
      expect(baseline.allows?(finding(:remarks_coverage, 0.94, 0.973))).to be(false)
    end

    it "never permits a column assertion, whatever the numbers say" do
      expect(baseline.allows?(finding(:column_ent_num, 0.98, 0.99, severity: :error))).to be(false)
    end

    it "never permits a list that parsed to nothing" do
      expect(baseline.allows?(finding(:empty, 0, nil, severity: :error))).to be(false)
    end

    it "permits a warning class that covers a small share of the list, as the doctor does" do
      expect(baseline.allows?(finding(:warnings, 400, 0), records: 19_321)).to be(true)
    end

    it "reports the same warning class on a list small enough for it to be a fifth of the file" do
      expect(baseline.allows?(finding(:warnings, 400, 0), records: 2_000)).to be(false)
    end

    it "reports anything it cannot put a number to" do
      expect(baseline.allows?(finding(:remarks_coverage, nil, nil))).to be(false)
    end
  end

  describe ".refresh" do
    let(:result) do
      Canary::Result.new(source: :ofac_sdn, status: :ok, profile: profile)
    end

    it "writes a baseline for a source that parsed, stamped with when it was measured" do
      described_class.refresh(Canary::Report.new(results: [result]), directory: directory)

      expect(described_class.load(:ofac_sdn, directory: directory))
        .to have_attributes(profile: profile, captured_at: a_string_matching(/\A\d{4}-\d{2}-\d{2}T/))
    end

    it "keeps the tolerances a human tuned" do
      write({ source: "ofac_sdn", tolerances: { record_count: 0.2 }, profile: profile.to_h })

      described_class.refresh(Canary::Report.new(results: [result]), directory: directory)

      expect(described_class.load(:ofac_sdn, directory: directory).tolerance(:record_count)).to eq(0.2)
    end

    it "leaves a source that could not be read alone, so its baseline is not overwritten with nothing" do
      unreachable = Canary::Result.new(source: :eu_fsf, status: :unreachable)

      described_class.refresh(Canary::Report.new(results: [unreachable]), directory: directory)

      expect(File).not_to exist(described_class.path(:eu_fsf, directory: directory))
    end

    it "answers with nothing when the file it would write is the file already there" do
      report = Canary::Report.new(results: [result])
      described_class.refresh(report, directory: directory)
      captured = described_class.load(:ofac_sdn, directory: directory).captured_at

      again = described_class.new(source: :ofac_sdn).with(profile: profile, captured_at: captured)

      expect(again.write(directory: directory)).to be_nil
    end
  end
end
