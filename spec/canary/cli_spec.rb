# frozen_string_literal: true

require "tmpdir"

require_relative "../../canary/canary"

RSpec.describe Canary::CLI do
  let(:directory) { Dir.mktmpdir("canary-cli") }
  let(:out) { File.join(directory, "out") }
  let(:baselines) { File.join(directory, "baselines") }
  let(:io) { StringIO.new }

  before do
    FileUtils.mkdir_p(baselines)
    ActiveSanction::Sources.register(CanaryList)
    CanaryList.plan = { entities: entities(20) }
  end

  after do
    ActiveSanction::Sources.unregister(:canary_list)
    CanaryList.plan = nil
    ActiveSanction.reset!
    FileUtils.remove_entry(directory, true)
  end

  def entities(count, **without)
    Array.new(count) { |at| FakeDoctorSource.entity(:canary_list, at + 1, **without) }
  end

  def env(**overrides)
    { "CANARY_SOURCES" => "canary_list", "CANARY_BASELINES" => baselines,
      "CANARY_OUT" => out }.merge(overrides.transform_keys(&:to_s))
  end

  def report = JSON.parse(File.read(File.join(out, "report.json")))

  describe ".canary" do
    it "answers with the exit code" do
      expect(described_class.canary(env: env, io: io)).to eq(0)
    end

    it "writes the report the next run reads" do
      described_class.canary(env: env, io: io)

      expect(report["results"].first).to include("source" => "canary_list", "status" => "ok")
    end

    it "identifies the canary to the publishers, so a format check is not mistaken for a sync" do
      described_class.canary(env: env, io: io)

      expect(ActiveSanction.config.user_agent).to eq(Canary::Run::USER_AGENT)
    end

    it "exits non-zero on drift" do
      described_class.canary(env: env, io: io)
      described_class.refresh(env: env(CANARY_REPORT: File.join(out, "report.json")), io: io)
      CanaryList.plan = { entities: entities(20, identifiers: []) }

      expect(described_class.canary(env: env, io: io)).to eq(1)
    end

    it "writes an issue body for a source with something wrong with it" do
      described_class.canary(env: env, io: io)
      described_class.refresh(env: env(CANARY_REPORT: File.join(out, "report.json")), io: io)
      CanaryList.plan = { entities: entities(20, identifiers: []) }
      described_class.canary(env: env, io: io)

      expect(File.read(File.join(out, "canary_list.md"))).to include("<!-- canary:canary_list -->")
    end

    it "writes no issue body for a source that is as committed" do
      described_class.canary(env: env, io: io)

      expect(File).not_to exist(File.join(out, "canary_list.md"))
    end

    it "opens nothing on the first sighting, and says in the job summary that it has not" do
      described_class.canary(env: env, io: io)
      described_class.refresh(env: env(CANARY_REPORT: File.join(out, "report.json")), io: io)
      CanaryList.plan = { entities: entities(20, identifiers: []) }
      described_class.canary(env: env, io: io)

      expect(File.read(File.join(out, "summary.md"))).to include("Nothing is opened until a second run agrees")
    end

    it "opens nothing on the first sighting of a change" do
      described_class.canary(env: env, io: io)
      described_class.refresh(env: env(CANARY_REPORT: File.join(out, "report.json")), io: io)
      CanaryList.plan = { entities: entities(20, identifiers: []) }
      described_class.canary(env: env, io: io)

      expect(report["results"].first).to include("reportable" => false, "pending" => true)
    end

    it "reports a finding the previous run's artifact agrees with" do
      described_class.canary(env: env, io: io)
      described_class.refresh(env: env(CANARY_REPORT: File.join(out, "report.json")), io: io)
      CanaryList.plan = { entities: entities(20, identifiers: []) }
      described_class.canary(env: env, io: io)
      previous = File.join(directory, "previous.json")
      FileUtils.cp(File.join(out, "report.json"), previous)

      described_class.canary(env: env(CANARY_PREVIOUS: previous), io: io)

      expect(report["results"].first).to include("reportable" => true)
    end
  end

  describe ".refresh" do
    it "rewrites the committed baselines from a report, without fetching anything again" do
      described_class.canary(env: env, io: io)

      described_class.refresh(env: env(CANARY_REPORT: File.join(out, "report.json")), io: io)

      expect(Canary::Baseline.load(:canary_list, directory: baselines).profile.record_count).to eq(20)
    end

    it "leaves a baseline that already says what the run measured alone" do
      described_class.canary(env: env, io: io)
      path = File.join(out, "report.json")
      described_class.refresh(env: env(CANARY_REPORT: path), io: StringIO.new)

      again = StringIO.new
      described_class.refresh(env: env(CANARY_REPORT: path), io: again)

      expect(again.string).to include("baselines unchanged")
    end
  end
end
