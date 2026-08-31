# frozen_string_literal: true

require "rspec/core/sandbox"

# The spec for the shared example group in spec/support/shared_examples.
#
# A conformance suite that passes everything is worse than none at all: it
# reads like a guarantee and stays one only until somebody relies on it. So
# each example here takes a single rule out of an otherwise conforming adapter
# -- Memory, which the contract passes -- and checks that the contract notices.
#
# Every store below is a way of losing records that raises nothing and returns
# something list-shaped. That is what makes them worth writing down: an adapter
# that crashes gets fixed the day it ships, and an adapter that quietly returns
# 8,000 of 19,015 names produces clean reports for months.
RSpec.describe "the storage adapter contract" do
  def conforming_store = ActiveSanction::Storage::Memory

  # The conforming adapter with one rule removed.
  def broken_store(&body) = Class.new(conforming_store, &body)

  # Runs the contract against an adapter and returns the examples it ran. The
  # sandbox swaps in a fresh RSpec world for the duration, so an inner example
  # group is neither reported to the outer run nor left behind in it; the
  # shared group is loaded again inside it because a shared example group lives
  # in the world the sandbox has just replaced.
  def conformance_examples(store, &customization)
    examples = nil
    RSpec::Core::Sandbox.sandboxed do
      load File.expand_path("../../support/shared_examples/storage_adapter.rb", __dir__)
      group = RSpec.describe(store) { it_behaves_like("a storage adapter", &customization) }
      group.run(RSpec::Core::NullReporter)
      examples = descendants(group)
    end
    examples
  end

  def descendants(group) = group.examples + group.children.flat_map { |child| descendants(child) }

  # What the contract complained about, named by the example that caught it --
  # which is the checklist item, worded as the failure.
  def failures(store, &customization)
    conformance_examples(store, &customization)
      .select { |example| example.execution_result.status == :failed }
      .map(&:description)
  end

  it "passes an adapter that meets it" do
    expect(failures(conforming_store)).to be_empty
  end

  # Guards the example above: an empty group passes everything too.
  it "runs the whole checklist while doing it" do
    expect(conformance_examples(conforming_store).count).to be >= 35
  end

  # The documented way for an adapter that cannot be built by `.new` alone --
  # #24 needs a root directory -- to be held to the same contract.
  it "runs against an adapter that has to be given something to be built" do
    store = broken_store do
      def initialize(root:)
        @root = root
        super()
      end
    end

    expect(failures(store) { def build_store = described_class.new(root: "/nowhere") }).to be_empty
  end

  # "Nothing was ever synced here" and "this list has nobody on it" are
  # different states, and a caller that cannot tell them apart screens against
  # an empty list and reports the name clear.
  it "catches a store that answers an empty list for a source never synced" do
    store = broken_store do
      def read_snapshot(source)
        super || ActiveSanction::Snapshot.new(source: source, entities: [])
      end
    end

    expect(failures(store)).to include(/reads back as nil/)
  end

  it "catches a store that loses a record on the way back" do
    store = broken_store do
      def read_snapshot(source)
        stored = super
        stored && ActiveSanction::Snapshot.new(source: stored.source, entities: stored.entities.first(1),
                                               fetched_at: stored.fetched_at)
      end
    end

    expect(failures(store)).to include(/returns the checksum the snapshot was written with/)
  end

  # Order is not in the checksum, so nothing else catches a store handing back
  # its rows in whatever order the database felt like.
  it "catches a store that reorders the records" do
    store = broken_store do
      def read_snapshot(source)
        stored = super
        stored && ActiveSanction::Snapshot.from_h(stored.to_h.merge(entities: stored.entities.reverse.map(&:to_h)))
      end
    end

    expect(failures(store)).to include(/returns the records in the order they were written/)
  end

  it "catches a store that hands back half-deserialized records" do
    store = broken_store do
      def read_snapshot(source)
        stored = super
        stored && ActiveSanction::Snapshot.new(source: stored.source, entities: stored.entities.map(&:to_h),
                                               fetched_at: stored.fetched_at)
      end
    end

    expect(failures(store)).to include(/returns Entities, not the hashes/)
  end

  # A sync replaces a list; a store that adds to one holds a delisted person
  # forever, which is a false hit on every run from then on.
  it "catches a store that accumulates two writes of one list" do
    store = broken_store do
      def write_snapshot(snapshot)
        stored = read_snapshot(snapshot.source)
        return super if stored.nil?

        super(ActiveSanction::Snapshot.new(source: snapshot.source, entities: stored.entities + snapshot.entities))
      end
    end

    expect(failures(store)).to include(/replaces a list rather than accumulating/)
  end

  it "catches a store that files its sources in no particular order" do
    store = broken_store { def sources = super.reverse }

    expect(failures(store)).to include(/sorts the sources it lists/)
  end

  it "catches a delete that does not delete" do
    store = broken_store { def delete_snapshot(source) = read_snapshot(source) }

    expect(failures(store)).to include(/forgets the snapshot/)
  end

  it "catches a store that stores something that is not a Snapshot" do
    store = broken_store do
      def write_snapshot(value)
        super(value.is_a?(Hash) ? ActiveSanction::Snapshot.from_h(value) : value)
      end
    end

    expect(failures(store)).to include(/refuses to store something that is not a Snapshot/)
  end

  it "catches a store that takes a name no source could have" do
    store = broken_store { def source_key!(value) = value.to_sym }

    expect(failures(store)).to include(/refuses a name that is not a usable source key/)
  end

  it "catches metadata that does not describe the stored list" do
    store = broken_store do
      def snapshot_meta(source)
        stored = super
        stored && ActiveSanction::Storage::Meta.from_h(stored.to_h.merge(record_count: 0))
      end
    end

    expect(failures(store)).to include(/counts the records/)
  end

  # #31 walks every entity of every list to build the index; an adapter that
  # materializes them all first makes that cost the whole store.
  it "catches an each_entity that hands back an array" do
    store = broken_store do
      def each_entity(sources: nil, &block)
        return super.to_a unless block

        super
      end
    end

    expect(failures(store)).to include(/returns an Enumerator rather than an array/)
  end

  # Screening two of the three lists an application named, and saying nothing
  # about the third, is the failure the contract exists to prevent.
  it "catches an each_entity that quietly skips a list that was never synced" do
    store = broken_store do
      def each_entity(sources: nil, &block)
        return enum_for(:each_entity, sources: sources) unless block

        Array(sources || self.sources).each { |key| read_snapshot(key)&.entities&.each(&block) }
        self
      end
    end

    expect(failures(store)).to include(/refuses to quietly skip a named list/)
  end
end
