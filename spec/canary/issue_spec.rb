# frozen_string_literal: true

require_relative "../../canary/canary"

RSpec.describe Canary::Issue do
  let(:observed) do
    ActiveSanction::Doctor::Profile.new(source: :ofac_sdn, record_count: 19_402, remarks_coverage: 0.714,
                                        cohorts: { all: 19_402, individual: 11_704 },
                                        fill: { identifiers: 0.339 })
  end

  let(:baseline) do
    ActiveSanction::Doctor::Profile.new(source: :ofac_sdn, record_count: 19_321, remarks_coverage: 0.973,
                                        cohorts: { all: 19_321, individual: 11_690 },
                                        fill: { identifiers: 0.341 })
  end

  let(:coverage) do
    ActiveSanction::Doctor::Finding.new(
      source: :ofac_sdn, severity: :warn, check: :remarks_coverage,
      message: 'remarks coverage 71.4% (was 97.3%): "Passport No." x 1,880 unrecognized',
      observed: 0.714, baseline: 0.973
    )
  end

  let(:drift) do
    Canary::Result.new(source: :ofac_sdn, status: :drift, findings: [coverage], profile: observed,
                       baseline: baseline, compared: true, confirmed: %w[remarks_coverage])
  end

  let(:down) do
    Canary::Result.new(source: :eu_fsf, status: :unreachable, confirmed: %w[parse],
                       error: { "class" => "ActiveSanction::HttpClient::ResponseError",
                                "message" => "returned 403", "retryable" => false })
  end

  describe "#body, for drift" do
    subject(:body) { described_class.new(drift, run_url: "https://runs.test/1").body }

    it "opens with the marker the next run finds the issue by" do
      expect(body.lines.first.strip).to eq("<!-- canary:ofac_sdn -->")
    end

    it "says the finding, its check and its severity" do
      expect(body).to include("| warn | `remarks_coverage` |", "Passport No.")
    end

    it "puts the numbers that did not move next to the one that did" do
      expect(body).to include("| records | 19,402 | 19,321 |", "| remarks coverage | 71.4% | 97.3% |",
                              "| records with an identifier | 33.9% | 34.1% |")
    end

    it "says a second run agreed, because an issue that claimed it wrongly would be worth nothing" do
      expect(body).to include("Two consecutive canary runs agreed")
    end

    it "names both ways out: adapt the parser, or accept the numbers" do
      expect(body).to include("bundle exec rake canary:refresh", ".github/baselines/ofac_sdn.json")
    end

    it "links back to the run that opened it" do
      expect(body).to include("https://runs.test/1")
    end
  end

  describe "#body, for a source that could not be fetched" do
    subject(:body) { described_class.new(down).body }

    it "says plainly that this is not drift" do
      expect(body).to include("**This is a fetch failure, not drift.**")
    end

    it "quotes the error and what the library thinks of it" do
      expect(body).to include("ActiveSanction::HttpClient::ResponseError: returned 403", "**not retryable**")
    end

    it "names the first thing to establish, which is whether the runner is being blocked" do
      expect(body).to include("403 a non-browser user agent")
    end

    it "is titled as a fetch failure rather than as drift" do
      expect(described_class.new(down).title).to eq("Canary: eu_fsf could not be fetched")
    end
  end

  it "says so rather than claiming agreement when only one run has seen this" do
    once = drift.with(confirmed: [])

    expect(described_class.new(once).body).to include("It has been seen once so far.")
  end

  it "reports the source's published URLs, since the list is the record and this is a reading of it" do
    expect(described_class.new(drift).body).to include(ActiveSanction::Sources[:ofac_sdn].urls.values.first)
  end
end
