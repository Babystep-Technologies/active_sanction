# frozen_string_literal: true

require_relative "../../canary/canary"

RSpec.describe Canary::Result do
  let(:baseline_profile) do
    ActiveSanction::Doctor::Profile.new(source: :ofac_sdn, record_count: 19_321, remarks_coverage: 0.973,
                                        cohorts: { all: 19_321 }, fill: { identifiers: 0.341 })
  end

  let(:observed) do
    ActiveSanction::Doctor::Profile.new(source: :ofac_sdn, record_count: 19_402, remarks_coverage: 0.714,
                                        cohorts: { all: 19_402 }, fill: { identifiers: 0.339 })
  end

  let(:baseline) { Canary::Baseline.new(source: :ofac_sdn, profile: baseline_profile) }

  def finding(check, observed, was, severity: :warn, message: nil)
    ActiveSanction::Doctor::Finding.new(source: :ofac_sdn, severity: severity, check: check,
                                        message: message || "#{check} is #{observed}, was #{was}",
                                        observed: observed, baseline: was)
  end

  def diagnosis(findings, status: :checked, error: nil, profile: observed)
    ActiveSanction::Doctor::Diagnosis.new(source: :ofac_sdn, status: status, findings: findings,
                                          profile: status == :failed ? nil : profile,
                                          baseline: baseline_profile, error: error, duration: 1.5)
  end

  describe ".from" do
    it "reports a finding the baseline's tolerance does not cover" do
      result = described_class.from(diagnosis([finding(:remarks_coverage, 0.714, 0.973)]), baseline: baseline)

      expect(result).to have_attributes(source: :ofac_sdn, status: :drift, compared?: true,
                                        findings: [finding(:remarks_coverage, 0.714, 0.973)])
    end

    it "discards a finding inside what this source is allowed to move by" do
      result = described_class.from(diagnosis([finding(:record_count, 19_402, 19_321)]), baseline: baseline)

      expect(result).to have_attributes(status: :ok, findings: [])
    end

    it "keeps an info finding without calling the source drifted" do
      context = finding(:warnings, 41, 41, severity: :info)

      result = described_class.from(diagnosis([context]), baseline: baseline)

      expect(result).to have_attributes(status: :ok, findings: [context])
    end

    it "reads a fetch failure as a publisher having a bad afternoon rather than as drift" do
      failure = ActiveSanction::FetchError.new("ofac.test returned 503", status: 503)

      result = described_class.from(
        diagnosis([finding(:parse, nil, nil, severity: :error)], status: :failed, error: failure), baseline: baseline
      )

      expect(result).to have_attributes(
        status: :unreachable,
        error: a_hash_including("class" => "ActiveSanction::FetchError", "retryable" => true)
      )
    end

    it "reads a parse failure as drift, because the bytes arrived and we could not read them" do
      failure = ActiveSanction::ParseError.new("SDN.CSV has 12 columns, expected 11")

      result = described_class.from(
        diagnosis([finding(:parse, nil, nil, severity: :error)], status: :failed, error: failure), baseline: baseline
      )

      expect(result.status).to eq(:drift)
    end

    it "says it was held to the adapter's floors when there is no committed baseline" do
      result = described_class.from(diagnosis([]), baseline: Canary::Baseline.new(source: :ofac_sdn))

      expect(result.compared?).to be(false)
    end
  end

  describe "confirmation" do
    let(:drifting) { described_class.from(diagnosis([finding(:remarks_coverage, 0.714, 0.973)]), baseline: baseline) }

    it "reports nothing on the first sighting, because one bad afternoon looks exactly like this" do
      expect(drifting.confirmed_against(nil)).to have_attributes(reportable?: false, pending?: true)
    end

    it "reports a finding two consecutive runs agreed on" do
      yesterday = described_class.from(diagnosis([finding(:remarks_coverage, 0.711, 0.973)]), baseline: baseline)

      expect(drifting.confirmed_against(yesterday)).to have_attributes(reportable?: true, pending?: false)
    end

    it "identifies a finding by its check rather than by its numbers, which move between runs" do
      yesterday = described_class.from(diagnosis([finding(:remarks_coverage, 0.702, 0.973)]), baseline: baseline)

      expect(drifting.confirmed_against(yesterday).confirmed).to eq(%w[remarks_coverage])
    end

    it "does not let a different finding on the same source confirm this one" do
      yesterday = described_class.from(diagnosis([finding(:fill_identifiers, 0.10, 0.341)]), baseline: baseline)

      expect(drifting.confirmed_against(yesterday).reportable?).to be(false)
    end

    it "does not let yesterday's fetch failure confirm today's drift" do
      failure = ActiveSanction::FetchError.new("timed out", status: 504)
      yesterday = described_class.from(
        diagnosis([finding(:parse, nil, nil, severity: :error)], status: :failed, error: failure), baseline: baseline
      )

      expect(drifting.confirmed_against(yesterday).reportable?).to be(false)
    end

    it "tells two warning classes apart, so a new one is not confirmed by an old one" do
      passport = finding(:warnings, 4_880, 0, message: 'unknown document label "Passport No." (4,880 rows, new)')
      tax = finding(:warnings, 4_900, 0, message: 'unknown document label "Tax ID No." (4,900 rows, new)')

      today = described_class.from(diagnosis([passport]), baseline: baseline)
      yesterday = described_class.from(diagnosis([tax]), baseline: baseline)

      expect(today.confirmed_against(yesterday).reportable?).to be(false)
    end

    it "confirms a warning class the run before it also reported" do
      passport = finding(:warnings, 4_880, 0, message: 'unknown document label "Passport No." (4,880 rows, new)')
      seen = finding(:warnings, 4_910, 0, message: 'unknown document label "Passport No." (4,910 rows, new)')

      today = described_class.from(diagnosis([passport]), baseline: baseline)

      expect(today.confirmed_against(described_class.from(diagnosis([seen]), baseline: baseline)).reportable?)
        .to be(true)
    end

    it "leaves a healthy source unreportable however many runs agree it is healthy" do
      healthy = described_class.from(diagnosis([]), baseline: baseline)

      expect(healthy.confirmed_against(healthy)).to have_attributes(reportable?: false, pending?: false)
    end
  end

  describe "serialization" do
    it "round-trips through the JSON a workflow artifact holds" do
      result = described_class.from(diagnosis([finding(:remarks_coverage, 0.714, 0.973)]), baseline: baseline)
                              .confirmed_against(nil)

      restored = described_class.from_h(JSON.parse(JSON.generate(result.to_h)))

      expect(restored).to have_attributes(source: :ofac_sdn, status: :drift, confirmed: [],
                                          fingerprints: result.fingerprints)
    end

    it "carries the title and the reportable flag the workflow reads" do
      result = described_class.from(diagnosis([]), baseline: baseline)

      expect(result.to_h).to include(title: "Canary: ofac_sdn has drifted", reportable: false)
    end
  end
end
