# frozen_string_literal: true

require "tmpdir"

require_relative "../../canary/canary"

RSpec.describe Canary::Report do
  def profile(source, records)
    ActiveSanction::Doctor::Profile.new(source: source, record_count: records, cohorts: { all: records })
  end

  def finding(source, check)
    ActiveSanction::Doctor::Finding.new(source: source, severity: :warn, check: check,
                                        message: "#{check} moved", observed: 1, baseline: 2)
  end

  def result(source, status, checks: [], records: 1_000)
    Canary::Result.new(source: source, status: status, findings: checks.map { |check| finding(source, check) },
                       profile: status == :unreachable ? nil : profile(source, records),
                       baseline: profile(source, records - 3), compared: true,
                       error: status == :unreachable ? { "class" => "ActiveSanction::FetchError" } : nil)
  end

  let(:drifting) { result(:ofac_sdn, :drift, checks: %i[remarks_coverage]) }
  let(:healthy) { result(:un_consolidated, :ok) }
  let(:down) { result(:eu_fsf, :unreachable) }

  describe "#exit_code" do
    it "is zero when every source parsed into what its baseline says it should" do
      expect(described_class.new(results: [healthy]).exit_code).to eq(0)
    end

    it "is one on drift" do
      expect(described_class.new(results: [healthy, drifting]).exit_code).to eq(1)
    end

    it "is two when a source could not be fetched and nothing drifted" do
      expect(described_class.new(results: [healthy, down]).exit_code).to eq(2)
    end

    it "reports drift ahead of a fetch failure, because only one of the two is ever certain" do
      expect(described_class.new(results: [down, drifting]).exit_code).to eq(1)
    end

    it "is non-zero for drift nobody has confirmed yet, because the list is wrong either way" do
      report = described_class.new(results: [drifting]).confirmed_against(nil)

      expect(report).to have_attributes(exit_code: 1, reportable: [], pending: [report[:ofac_sdn]])
    end
  end

  describe "#confirmed_against" do
    it "reports what two consecutive runs agreed on" do
      today = described_class.new(results: [drifting, healthy])
      yesterday = described_class.new(results: [result(:ofac_sdn, :drift, checks: %i[remarks_coverage])])

      confirmed = today.confirmed_against(yesterday)

      expect(confirmed).to have_attributes(reportable: [confirmed[:ofac_sdn]], pending: [])
    end

    it "confirms nothing against a run that did not cover the source" do
      today = described_class.new(results: [drifting])

      expect(today.confirmed_against(described_class.new(results: [healthy])).reportable).to be_empty
    end
  end

  describe ".read" do
    let(:directory) { Dir.mktmpdir("canary-report") }

    after { FileUtils.remove_entry(directory, true) }

    it "round-trips a report through the artifact the next run reads" do
      path = described_class.new(results: [drifting, down], duration: 3.5).write(File.join(directory, "report.json"))

      expect(described_class.read(path)).to have_attributes(sources: %i[ofac_sdn eu_fsf], duration: 3.5)
    end

    it "answers with nothing for an artifact that is not there" do
      expect(described_class.read(File.join(directory, "absent.json"))).to be_nil
    end

    it "answers with nothing rather than raising for an artifact that never finished being written" do
      path = File.join(directory, "truncated.json")
      File.write(path, '{"results": [{"source": "ofac_sdn", "st')

      expect(described_class.read(path)).to be_nil
    end

    it "answers with nothing when no previous run was found at all" do
      expect(described_class.read(nil)).to be_nil
    end
  end

  describe "#to_s" do
    it "puts the status and the record count where an eye runs down them" do
      report = described_class.new(results: [drifting, healthy, down]).confirmed_against(nil)

      expect(report.to_s.lines.map(&:rstrip)).to include(
        a_string_matching(/\Aofac_sdn\s+DRIFT \(pending\)\s+1,000 records \(baseline 997\)\z/),
        a_string_matching(/\Aeu_fsf\s+UNREACHABLE \(pending\)\s+ActiveSanction::FetchError\z/)
      )
    end

    it "names what is still waiting for a second run to agree with it" do
      report = described_class.new(results: [drifting, down]).confirmed_against(nil)

      expect(report.summary).to eq("2 sources in 0.00s: 1 drifting, 1 unreachable, 2 pending confirmation")
    end
  end
end
