# typed: ignore
# frozen_string_literal: true

# The contract every storage adapter must satisfy, written once.
#
# Loaded by `require "active_sanction/testing"` -- see ActiveSanction::Testing,
# which is where the entry point and the fixture root are documented.
#
#   RSpec.describe ActiveSanction::Storage::Memory do
#     it_behaves_like "a storage adapter"
#   end
#
# An adapter that needs something to be constructed -- a root directory, a
# connection -- says how in the customization block, which is evaluated after
# this group and so wins. It is a method rather than a `let` because a couple
# of the examples need a second, independent store:
#
#   RSpec.describe ActiveSanction::Storage::FileSystem do
#     it_behaves_like "a storage adapter" do
#       def build_store = described_class.new(root: Dir.mktmpdir)
#     end
#   end
#
# ### What this is for
#
# The matcher (#33) is written against Storage::Base and never against a
# concrete store, which is the whole point of the interface: an installation
# swaps gzipped JSON for Postgres without touching the code that decides
# whether two names are the same person. That only holds if every adapter
# really does mean the same thing by these five methods, and "the same thing"
# is otherwise a paragraph in a design document that each new adapter
# re-interprets. Here it is executable.
#
# Most of what it checks is a way of losing records quietly. A store that
# returns an empty snapshot for a source nobody ever synced, one that drops the
# third of four entities on the way back, one that reorders them, one that
# accumulates two writes of a list instead of replacing it -- none of those
# raise, all of them return something that looks like a sanctions list, and the
# report they produce says the name you screened is clear.
#
# ### What it does not do
#
# It says nothing about durability, concurrency or performance, which are the
# things the adapters genuinely differ on: that a FileSystem write is atomic
# (#24), that an ActiveRecord write is one transaction (#25), that a Memory
# store is safe to screen from on many threads. Those are properties of one
# implementation and each adapter's own spec has to make them.
RSpec.shared_examples "a storage adapter" do
  include ActiveSanction::Testing::StorageAdapterDefaults

  let(:store) { build_store }
  let(:ofac) { snapshot(:ofac_sdn, %w[2674 1234]) }
  let(:un) { snapshot(:un_consolidated, %w[QDi.001]) }

  # A record carrying every kind of member the canonical model has, because
  # what a store loses is usually nested: a store that persists names and drops
  # identifiers passes a contract written against bare strings.
  def entity(source, ref)
    ActiveSanction::Entity.new(
      source: source, source_ref: ref, type: :individual,
      names: [ActiveSanction::Name.new(value: "AL ZAWAHIRI #{ref}, Aiman", kind: :primary)],
      addresses: [ActiveSanction::Address.new(country: "EG", city: "Cairo")],
      identifiers: [ActiveSanction::Identifier.new(kind: :passport, value: ref, country: "EG")],
      dates_of_birth: [ActiveSanction::PartialDate.parse("1951-06-19")],
      nationalities: ["EG"], programs: ["SDGT"],
      listed_on: ActiveSanction::PartialDate.parse("2001-09-23"),
      remarks: "DOB 19 Jun 1951; POB Egypt"
    )
  end

  def snapshot(source, refs)
    ActiveSanction::Snapshot.new(
      source: source, entities: refs.map { |ref| entity(source, ref) },
      fetched_at: Time.utc(2026, 8, 28, 9, 30, 0), source_version: "Thu, 28 Aug 2026 09:00:00 GMT"
    )
  end

  def entity_refs(entities) = entities.map(&:source_ref)

  describe "a source that has never been synced" do
    # Nil says "we have never fetched this". An empty snapshot says "this list
    # has nobody on it", which no sanctions list has ever said, and a caller
    # that cannot tell them apart screens against nothing and reports clear.
    it "reads back as nil rather than as a list with nobody on it" do
      expect(store.read_snapshot(:ofac_sdn)).to be_nil
    end

    it "has no metadata to report" do
      expect(store.snapshot_meta(:ofac_sdn)).to be_nil
    end

    it "is not among the stored sources" do
      expect(store.sources).not_to include(:ofac_sdn)
    end

    it "is not reported as stored" do
      expect(store).not_to be_stored(:ofac_sdn)
    end

    # The other half of returning nil: a caller that named the list itself gets
    # an exception rather than an empty result it has to remember to check.
    it "raises when a caller asks for it by name" do
      expect { store.fetch_snapshot(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::MissingSnapshot)
    end

    it "deletes without complaint, and says there was nothing to delete" do
      expect(store.delete_snapshot(:ofac_sdn)).to be_falsey
    end
  end

  describe "what comes back out" do
    before { store.write_snapshot(ofac) }

    it "returns the snapshot that was written" do
      expect(store.read_snapshot(:ofac_sdn)).to eq(ofac)
    end

    # Snapshot#== compares checksums, so the example above passes for a store
    # that kept the checksum and lost the list. This is the one that does not.
    it "returns every record, field for field" do
      expect(store.read_snapshot(:ofac_sdn).entities.map(&:to_h)).to eq(ofac.entities.map(&:to_h))
    end

    # A store that hands back half-deserialized records makes every caller
    # downstream coerce before it can read a name.
    it "returns Entities, not the hashes they serialize to" do
      expect(store.read_snapshot(:ofac_sdn).entities).to all(be_an(ActiveSanction::Entity))
    end

    # Order is not in the checksum -- Snapshot sorts fingerprints before
    # folding them -- so nothing else catches a store that returns its rows in
    # whatever order the database felt like. A report whose rows move between
    # two runs against an unchanged list is a report an examiner cannot cite.
    it "returns the records in the order they were written" do
      expect(entity_refs(store.read_snapshot(:ofac_sdn).entities)).to eq(entity_refs(ofac.entities))
    end

    it "returns the checksum the snapshot was written with" do
      expect(store.read_snapshot(:ofac_sdn).checksum).to eq(ofac.checksum)
    end

    # To the second, which is what Snapshot#to_h serializes. An adapter that
    # loses it cannot answer how old the list it is screening against is (#34).
    it "returns the time the list was fetched" do
      expect(store.read_snapshot(:ofac_sdn).fetched_at).to eq(ofac.fetched_at)
    end

    it "returns the publisher's own version marker" do
      expect(store.read_snapshot(:ofac_sdn).source_version).to eq(ofac.source_version)
    end

    # Keys arrive as symbols from an adapter and as strings from anything that
    # has been through JSON or a command line.
    it "answers to the source name spelled as a string" do
      expect(store.read_snapshot("ofac_sdn")).to eq(ofac)
    end

    it "lists the source it stored" do
      expect(store.sources).to eq([:ofac_sdn])
    end
  end

  describe "what it refuses" do
    # A Hash of the right shape carries a checksum somebody typed; only a
    # Snapshot carries one computed over its own content, and that is the whole
    # basis on which a stored list can be cited months later.
    it "refuses to store something that is not a Snapshot" do
      expect { store.write_snapshot(ofac.to_h) }.to raise_error(ArgumentError)
    end

    # Source keys are typed by humans and are directory names to any adapter
    # that writes files, so they are held to one rule everywhere.
    it "refuses a name that is not a usable source key" do
      expect { store.read_snapshot("") }.to raise_error(ActiveSanction::Error)
    end
  end

  describe "writing" do
    it "returns the snapshot it stored" do
      expect(store.write_snapshot(ofac)).to eq(ofac)
    end

    # A sync replaces a list; it does not add to one. A store that accumulates
    # holds a delisted person forever, which is a false hit on every screening
    # run from then on.
    it "replaces a list rather than accumulating two of them" do
      store.write_snapshot(ofac)
      store.write_snapshot(snapshot(:ofac_sdn, %w[9999]))

      expect(entity_refs(store.read_snapshot(:ofac_sdn).entities)).to eq(%w[9999])
    end

    it "files a rewritten source once" do
      store.write_snapshot(ofac)
      store.write_snapshot(snapshot(:ofac_sdn, %w[9999]))

      expect(store.sources).to eq([:ofac_sdn])
    end

    # Per-source isolation is the rule sync orchestration (#34) is built on: one
    # list failing must leave the others exactly as they were.
    it "leaves the other lists alone" do
      store.write_snapshot(un)
      store.write_snapshot(ofac)

      expect(store.read_snapshot(:un_consolidated)).to eq(un)
    end

    it "sorts the sources it lists, so a summary does not reshuffle itself" do
      store.write_snapshot(un)
      store.write_snapshot(ofac)

      expect(store.sources).to eq(%i[ofac_sdn un_consolidated])
    end
  end

  describe "#snapshot_meta" do
    before { store.write_snapshot(ofac) }

    it "reports what was stored without being asked for the list" do
      expect(store.snapshot_meta(:ofac_sdn)).to eq(ActiveSanction::Storage::Meta.from_snapshot(ofac))
    end

    it "counts the records" do
      expect(store.snapshot_meta(:ofac_sdn).record_count).to eq(2)
    end

    # What a match result cites (#33). A meta whose checksum is not the stored
    # snapshot's cannot answer which list version cleared a customer.
    it "carries the stored snapshot's checksum" do
      expect(store.snapshot_meta(:ofac_sdn).checksum).to eq(ofac.checksum)
    end
  end

  describe "#each_entity" do
    before do
      store.write_snapshot(ofac)
      store.write_snapshot(un)
    end

    it "yields every record of every stored list" do
      expect(store.each_entity.to_a.size).to eq(3)
    end

    it "yields Entities" do
      expect(store.each_entity.to_a).to all(be_an(ActiveSanction::Entity))
    end

    # The index build (#31) walks every entity of every list. Handing it an
    # array of ~25,000 records built before the first one is yielded is a cost
    # nothing here needs to pay.
    it "returns an Enumerator rather than an array when given no block" do
      expect(store.each_entity).to be_an(Enumerator)
    end

    it "stops when the caller stops" do
      yielded = []
      store.each_entity do |entity|
        yielded << entity
        break if yielded.any?
      end

      expect(yielded.size).to eq(1)
    end

    it "yields only the lists it was asked for" do
      expect(entity_refs(store.each_entity(sources: %i[un_consolidated]).to_a)).to eq(%w[QDi.001])
    end

    it "takes one source named on its own" do
      expect(store.each_entity(sources: :un_consolidated).to_a.size).to eq(1)
    end

    # Screening two of the three lists an application configured, and saying
    # nothing about the third, is the failure this contract exists to prevent.
    it "refuses to quietly skip a named list that was never synced" do
      expect { store.each_entity(sources: %i[ofac_sdn eu_fsf]).to_a }
        .to raise_error(ActiveSanction::Storage::MissingSnapshot)
    end

    it "yields nothing from an empty store" do
      expect(build_store.each_entity.to_a).to be_empty
    end
  end

  describe "removing a list" do
    before { store.write_snapshot(ofac) }

    it "reports that there was one to remove" do
      expect(store.delete_snapshot(:ofac_sdn)).to be_truthy
    end

    it "forgets the snapshot" do
      store.delete_snapshot(:ofac_sdn)

      expect(store.read_snapshot(:ofac_sdn)).to be_nil
    end

    it "stops listing the source" do
      store.delete_snapshot(:ofac_sdn)

      expect(store.sources).to be_empty
    end

    it "leaves the other lists alone" do
      store.write_snapshot(un)
      store.delete_snapshot(:ofac_sdn)

      expect(store.read_snapshot(:un_consolidated)).to eq(un)
    end

    it "empties the whole store on #clear" do
      store.write_snapshot(un)
      store.clear

      expect(store).to be_empty
    end
  end
end
