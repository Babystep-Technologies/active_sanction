# frozen_string_literal: true

require "rspec/core/sandbox"

# The spec for the shared example group in spec/support/shared_examples.
#
# A conformance suite that passes everything is worse than none at all: it
# reads like a guarantee and stays one only until somebody relies on it. So
# each example here takes a single rule out of an otherwise conforming adapter
# and checks that the contract notices -- which is also how a check written
# against something Entity already enforces, and which therefore can never
# fail, gets found.
RSpec.describe "the sanction source contract" do
  # The test adapters register into the real registry -- there is no other one
  # -- and hand their keys back at the end of the example, the way sources_spec
  # does.
  let(:registered) { [] }
  let(:silent_source) do
    broken_source(:contract_silent) { def entity(row) = rebuild(super, remarks: nil) }
  end

  after { registered.each { |key| ActiveSanction::Sources.unregister(key) } }

  def fixture = "contract_example/list.csv"

  def conforming_source = ContractExampleSource

  # The conforming adapter with one rule removed. Each declares a key of its
  # own, since a key is never inherited.
  def broken_source(key, &body)
    Class.new(conforming_source) do
      key(key)
      class_eval(&body)
    end
  end

  def register(source)
    registered << source.key
    ActiveSanction::Sources.register(source)
  end

  # Runs the contract against a source and returns the examples it ran. The
  # sandbox swaps in a fresh RSpec world for the duration, so an inner example
  # group is neither reported to the outer run nor left behind in it; the
  # shared group is loaded again inside it because a shared example group lives
  # in the world the sandbox has just replaced.
  def conformance_examples(source, **options)
    examples = nil
    RSpec::Core::Sandbox.sandboxed do
      load File.expand_path("../../support/shared_examples/sanction_source.rb", __dir__)
      group = RSpec.describe(source) { it_behaves_like "a sanction source", **options }
      group.run(RSpec::Core::NullReporter)
      examples = descendants(group)
    end
    examples
  end

  def descendants(group) = group.examples + group.children.flat_map { |child| descendants(child) }

  # What the contract complained about, named by the example that caught it --
  # which is the checklist item, worded as the failure.
  def failures(source, register: true, **options)
    register(source) if register
    conformance_examples(source, **options)
      .select { |example| example.execution_result.status == :failed }
      .map(&:description)
  end

  it "passes an adapter that meets it" do
    expect(failures(conforming_source, fixture: fixture)).to be_empty
  end

  # Guards the example above: an empty group passes everything too.
  it "runs the whole checklist while doing it" do
    register(conforming_source)
    expect(conformance_examples(conforming_source, fixture: fixture).count).to be >= 15
  end

  it "catches an adapter that never registered itself" do
    expect(failures(conforming_source, register: false, fixture: fixture)).to include(/registers itself/)
  end

  it "catches a missing declaration" do
    source = broken_source(:contract_no_authority) do
      def self.authority(*)
        raise(ActiveSanction::Sources::DeclarationError, "unset")
      end
    end
    expect(failures(source, fixture: fixture)).to include(/declares the authority/)
  end

  it "catches an adapter that returns something other than Entities" do
    source = broken_source(:contract_hashes) { def parse(raw) = super.map(&:to_h) }
    expect(failures(source, fixture: fixture)).to include(/returns Entities and nothing else/)
  end

  it "catches two records published under one id" do
    source = broken_source(:contract_duplicate_ids) { def entity(row) = rebuild(super, id: "#{key}:1") }
    expect(failures(source, fixture: fixture)).to include(/gives no two entities the same id/)
  end

  # The rule #35 cannot work without: an id that moves between two reads of the
  # same bytes reports the whole list as removed and re-added.
  it "catches an id that is not the same on the second read" do
    source = broken_source(:contract_unstable_ids) { def entity(row) = rebuild(super, id: "#{key}:#{rand}") }
    expect(failures(source, fixture: fixture)).to include(/produces the same ids/)
  end

  it "catches a date left as the string the publisher wrote it as" do
    source = broken_source(:contract_string_dates) { def entity(row) = rebuild(super, listed_on: row[:listed_on]) }
    expect(failures(source, fixture: fixture)).to include(/publishes every date as a PartialDate/)
  end

  it "catches an adapter that drops the publisher's own text" do
    expect(failures(silent_source, fixture: fixture)).to include(/keeps the publisher's own text in remarks/)
  end

  # The escape hatch for a list that genuinely publishes no free text at all.
  # It has to be asked for, so that dropping one by accident stays a failure.
  it "accepts a list with no remarks when told it publishes none" do
    expect(failures(silent_source, fixture: fixture, remarks: false)).to be_empty
  end

  # An empty payload is a failed download or a moved URL, and a list with
  # nobody on it is the one answer a screening run must never quietly accept.
  it "catches an adapter that reads an empty payload as an empty list" do
    source = broken_source(:contract_empty_payload) do
      def parse(raw)
        super
      rescue ActiveSanction::Error
        []
      end
    end
    expect(failures(source, fixture: fixture)).to include(/refuses an empty payload/)
  end

  it "catches an adapter that reports a truncated document as the whole list" do
    source = broken_source(:contract_truncated) do
      def parse(_raw) = super(File.binread(File.expand_path("../../fixtures/contract_example/list.csv", __dir__)))
    end
    expect(failures(source, fixture: fixture)).to include(/does not report a truncated document/)
  end
end
