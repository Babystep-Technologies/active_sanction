# frozen_string_literal: true

require "tmpdir"

require_relative "../../canary/canary"

RSpec.describe Canary::Run do
  let(:directory) { Dir.mktmpdir("canary-run") }

  before do
    ActiveSanction::Sources.register(CanaryList)
    CanaryList.plan = { entities: entities(20) }
  end

  after do
    ActiveSanction::Sources.unregister(:canary_list)
    CanaryList.plan = nil
    FileUtils.remove_entry(directory, true)
  end

  def entities(count, **without)
    Array.new(count) { |at| FakeDoctorSource.entity(:canary_list, at + 1, **without) }
  end

  def commit(profile, tolerances: {})
    Canary::Baseline.new(source: :canary_list, profile: profile, tolerances: tolerances).write(directory: directory)
  end

  def run(**options) = described_class.new(sources: [:canary_list], baselines: directory, **options).call

  it "examines every registered source when it is told about none" do
    expect(described_class.new.sources).to eq(ActiveSanction::Sources.keys)
  end

  it "reports a list that still measures what the committed baseline says it should" do
    commit(run[:canary_list].profile)

    expect(run).to have_attributes(ok?: true, exit_code: 0)
  end

  it "reports a field every record used to carry and none carries now" do
    commit(run[:canary_list].profile)
    CanaryList.plan = { entities: entities(20, identifiers: []) }

    expect(run[:canary_list]).to have_attributes(status: :drift,
                                                 findings: include(an_object_having_attributes(
                                                                     check: :fill_identifiers, severity: :error
                                                                   )))
  end

  it "leaves a record count that moved less than its tolerance alone" do
    commit(run[:canary_list].profile)
    CanaryList.plan = { entities: entities(21) }

    expect(run[:canary_list].status).to eq(:ok)
  end

  it "reports a record count that moved further than its tolerance" do
    commit(run[:canary_list].profile)
    CanaryList.plan = { entities: entities(12) }

    expect(run[:canary_list].findings.map(&:check)).to include(:record_count)
  end

  it "reads the tolerance the committed baseline names rather than the doctor's default" do
    commit(run[:canary_list].profile, tolerances: { record_count: 0.5 })
    CanaryList.plan = { entities: entities(12) }

    expect(run[:canary_list].status).to eq(:ok)
  end

  it "separates a publisher having a bad afternoon from a list that changed" do
    CanaryList.plan = { entities: entities(20), error: ActiveSanction::FetchError.new("503", status: 503) }

    expect(run[:canary_list]).to have_attributes(status: :unreachable, profile: nil)
  end

  it "exits two for a source that could not be fetched, which is not the code drift exits with" do
    CanaryList.plan = { entities: entities(20), error: ActiveSanction::FetchError.new("503", status: 503) }

    expect(run.exit_code).to eq(2)
  end

  it "holds a source with no committed baseline to the floors its adapter declared" do
    expect(run[:canary_list]).to have_attributes(compared?: false, status: :ok)
  end

  it "confirms nothing when there is no previous run to agree with it" do
    commit(run[:canary_list].profile)
    CanaryList.plan = { entities: entities(12) }

    expect(run).to have_attributes(reportable: [], pending: [an_object_having_attributes(source: :canary_list)])
  end

  it "reports what the run before it agreed about" do
    commit(run[:canary_list].profile)
    CanaryList.plan = { entities: entities(12) }
    yesterday = run

    expect(run(previous: yesterday).reportable.map(&:source)).to eq(%i[canary_list])
  end

  # The doctor already promises to write nothing. What the canary adds is that
  # it reads nothing either: a run on a laptop that has synced these lists for
  # real must compare against the committed file rather than against whatever
  # that laptop happens to hold.
  it "hands the doctor an empty store of its own rather than the configured one" do
    allow(ActiveSanction::Doctor).to receive(:new).and_call_original

    run

    expect(ActiveSanction::Doctor)
      .to have_received(:new).with(hash_including(store: an_instance_of(ActiveSanction::Storage::Memory)))
  end

  it "asks the publisher for the bytes unconditionally, so a 304 cannot be mistaken for a parse" do
    built = []
    allow(CanaryList).to receive(:new).and_wrap_original do |original, **options|
      original.call(**options).tap { |adapter| built << adapter }
    end

    run

    expect(built).to all(be_forced)
  end
end
