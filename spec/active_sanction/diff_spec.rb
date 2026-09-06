# frozen_string_literal: true

require "json"

RSpec.describe ActiveSanction::Diff do
  after { ActiveSanction.reset_configuration! }

  def entity(ref, name: "ABBAS, Abu", source: :ofac_sdn, **overrides)
    ActiveSanction::Entity.new(
      source: source, source_ref: ref.to_s, type: :individual,
      names: [ActiveSanction::Name.new(value: name, kind: :primary)],
      programs: ["SDGT"],
      **overrides
    )
  end

  def snapshot(entities, source: :ofac_sdn)
    ActiveSanction::Snapshot.new(source: source, entities: entities)
  end

  def diff(from, to) = described_class.new(from: from, to: to)

  let(:listed) { [entity(36, name: "AEROCARIBBEAN AIRLINES"), entity(2674)] }
  let(:before) { snapshot(listed) }

  describe "the three lists" do
    it "reports an entity the new list has and the old did not as added" do
      after = snapshot(listed + [entity(9001, name: "IVANOV, Ivan")])

      expect(diff(before, after).added.map(&:id)).to eq(["ofac_sdn:9001"])
    end

    # Delistings matter as much as listings: a delisting is what lets a
    # customer back through the door.
    it "reports an entity the old list had and the new does not as removed" do
      after = snapshot([entity(36, name: "AEROCARIBBEAN AIRLINES")])

      expect(diff(before, after).removed.map(&:id)).to eq(["ofac_sdn:2674"])
    end

    # The acceptance criterion, and the reason the join is by id.
    it "reports a renamed entity as modified rather than as an addition and a removal" do
      after = snapshot([entity(36, name: "AEROCARIBBEAN AIRLINES"), entity(2674, name: "ZAYDAN, Muhammad")])

      expect(diff(before, after))
        .to have_attributes(added: [], removed: [], modified: [an_instance_of(described_class::Change)])
    end

    it "says which fields moved" do
      after = snapshot([entity(36, name: "AEROCARIBBEAN AIRLINES"), entity(2674, programs: %w[SDGT SDNTK])])

      expect(diff(before, after).modified.first.fields).to eq(%i[programs])
    end

    it "reports nothing for two snapshots of the same list" do
      expect(diff(before, snapshot(listed))).to be_empty
    end
  end

  describe "determinism" do
    # A publisher's file order is a fact about how it was emitted, not about
    # what it says -- the snapshot checksum already refuses to move for it.
    it "is empty when the publisher reordered its file" do
      expect(diff(before, snapshot(listed.reverse))).to be_empty
    end

    it "sorts what it reports by id, whatever order the file was in" do
      after = snapshot([entity(9001), entity(1), entity(500)] + listed)

      expect(diff(before, after).added.map(&:id)).to eq(%w[ofac_sdn:1 ofac_sdn:500 ofac_sdn:9001])
    end
  end

  describe "a first sync" do
    # Reporting 19,015 records as newly listed would be false: they were listed
    # over twenty years, and we are only now looking.
    it "reports a baseline rather than a list of additions" do
      expect(diff(nil, before)).to have_attributes(baseline?: true, added: [], removed: [], modified: [])
    end

    it "has nothing to re-screen against" do
      expect(diff(nil, before).changed).to eq([])
    end

    it "says so in its summary" do
      expect(diff(nil, before).summary).to eq("ofac_sdn: first snapshot, 2 records (baseline, nothing to re-screen)")
    end

    it "carries no previous list version" do
      expect(diff(nil, before).from).to be_nil
    end
  end

  describe "#changed" do
    let(:after) { snapshot([entity(36, name: "AEROCARIBBEAN AIRLINES"), entity(2674, programs: []), entity(9001)]) }

    it "is what to re-screen a book of business against: added and amended records" do
      expect(diff(before, after).changed.map(&:id)).to eq(["ofac_sdn:9001", "ofac_sdn:2674"])
    end

    # Delistings are not something to screen against; they are alerts to clear.
    it "leaves delistings out" do
      expect(diff(before, snapshot([entity(2674)])).changed).to eq([])
    end
  end

  describe "#churn" do
    it "is the fraction of the previous list that moved" do
      expect(diff(before, snapshot([entity(2674)])).churn).to eq(0.5)
    end

    it "is nil for a baseline, which has no previous list to have moved" do
      expect(diff(nil, before).churn).to be_nil
    end

    it "is nil rather than infinite when the previous list was empty" do
      expect(diff(snapshot([]), before).churn).to be_nil
    end
  end

  describe "what it holds" do
    # A diff of eleven records must not pin two lists in memory.
    it "keeps the metadata of each snapshot rather than the snapshot" do
      expect(diff(before, snapshot(listed)).from).to be_a(ActiveSanction::Storage::Meta)
    end

    it "cites the checksum of the list version it compared against" do
      expect(diff(before, snapshot(listed)).from.checksum).to eq(before.checksum)
    end

    it "is frozen" do
      expect(diff(before, snapshot(listed))).to be_frozen
    end
  end

  describe "refusals" do
    # Every record on both lists would otherwise report as having moved.
    it "refuses two different sources" do
      expect { diff(before, snapshot([entity(1, source: :un_consolidated)], source: :un_consolidated)) }
        .to raise_error(ArgumentError, /cannot diff a ofac_sdn snapshot against a un_consolidated one/)
    end

    it "refuses a source that is not the one the snapshots are" do
      expect { described_class.new(source: :un_consolidated, from: before, to: snapshot(listed)) }
        .to raise_error(ArgumentError, /asked for a un_consolidated diff/)
    end

    it "refuses anything that is not a snapshot" do
      expect { diff(before, before.to_h) }
        .to raise_error(ArgumentError, /to must be an ActiveSanction::Snapshot, got Hash/)
    end

    # The state Storage::Base warns about: a store that hands back records it
    # never rebuilt.
    it "refuses a snapshot of half-deserialized records" do
      expect { diff(before, snapshot(listed.map(&:to_h))) }
        .to raise_error(ArgumentError, /a diff compares entities, got Hash/)
    end
  end

  # Publishing an id twice violates the stable-id contract, but a list that
  # does it still screens, so a diff of one is computed rather than refused.
  describe "a duplicated id" do
    it "compares the first occurrence on each side, so a duplicate is not a change" do
      twice = snapshot([entity(2674), entity(2674, name: "ZAYDAN, Muhammad")])

      expect(diff(twice, snapshot([entity(2674)]))).to be_empty
    end
  end

  describe ".call" do
    let(:store) { ActiveSanction::Storage::Memory.new }

    it "reads the current snapshot from the store when it is given no `to:`" do
      store.write_snapshot(snapshot(listed + [entity(9001)]))

      expect(described_class.call(:ofac_sdn, from: before, store: store).added.map(&:id)).to eq(["ofac_sdn:9001"])
    end

    # Not "everything on it was delisted", which is a clean report for every
    # customer on the list.
    it "raises rather than diffing against a list that is not stored" do
      expect { described_class.call(:ofac_sdn, from: before, store: store) }
        .to raise_error(ActiveSanction::Storage::MissingSnapshot, /no snapshot stored/)
    end

    # The same rule the registry and every file-backed store hold a key to: it
    # is typed by a human and it names a directory.
    it "holds a source key to the naming rule before it reads anything" do
      expect { described_class.call("../etc", from: before, store: store) }
        .to raise_error(ActiveSanction::Sources::DeclarationError, /not a usable source key/)
    end

    it "takes the source from the snapshots when it is given none" do
      expect(described_class.call(from: before, to: snapshot(listed)).source).to eq(:ofac_sdn)
    end

    it "refuses to guess which list is meant when it is given neither a source nor a `to:`" do
      expect { described_class.call(from: before) }.to raise_error(ArgumentError, /needs a `to:` snapshot/)
    end
  end

  describe "ActiveSanction.diff" do
    it "is the sugar over .call that the README documents" do
      expect(ActiveSanction.diff(:ofac_sdn, from: before, to: snapshot(listed))).to eq(diff(before, snapshot(listed)))
    end

    it "reads the configured store when it is given no `to:`" do
      ActiveSanction.configure { |c| c.storage = ActiveSanction::Storage::Memory.new }
      ActiveSanction.storage.write_snapshot(snapshot(listed))

      expect(ActiveSanction.diff(:ofac_sdn, from: before)).to be_empty
    end
  end

  describe "#to_s" do
    let(:after) { snapshot([entity(36, name: "AEROCARIBBEAN AIRLINES"), entity(9001, name: "IVANOV, Ivan")]) }

    it "leads with the line a sync should log" do
      expect(diff(before, after).summary)
        .to eq("ofac_sdn: 2 -> 2 records, 1 added, 1 removed, 0 modified (100.0% of the previous list)")
    end

    it "marks each record that moved, with the programs a hit on it would report" do
      expect(diff(before, after).details).to eq(["  + ofac_sdn:9001  IVANOV, Ivan  [SDGT]",
                                                 "  - ofac_sdn:2674  ABBAS, Abu  [SDGT]"])
    end

    # A diff of thousands is a parse regression rather than a day's listings,
    # and dumping all of it into a terminal does not help anybody see that.
    it "caps how many lines it prints and says how many it did not" do
      wholesale = snapshot(Array.new(30) { |at| entity(9000 + at) })

      expect(diff(before, wholesale).details(limit: 2).last).to eq("  ... and 30 more")
    end

    it "says a list is unchanged rather than printing nothing" do
      expect(diff(before, snapshot(listed)).to_s).to eq("ofac_sdn: 2 records, unchanged")
    end
  end

  describe "#to_h" do
    let(:after) { snapshot([entity(36, name: "AEROCARIBBEAN AIRLINES"), entity(2674, programs: %w[SDGT SDNTK])]) }

    it "survives the trip through JSON, for a consumer that is not this process" do
      expect { JSON.generate(diff(before, after).to_h) }.not_to raise_error
    end

    it "carries the pair of list versions the diff was computed from" do
      expect(diff(before, after).to_h[:from][:checksum]).to eq(before.checksum)
    end

    it "serializes added and removed records the way a snapshot serializes them" do
      expect(diff(before, snapshot(listed + [entity(9001)])).to_h[:added])
        .to eq([entity(9001).to_h])
    end

    it "says null for the previous list of a baseline, which is how a consumer tells one" do
      expect(diff(nil, before).to_h[:from]).to be_nil
    end
  end

  # The acceptance criterion: two consecutive OFAC files, parsed by the real
  # adapter, produce a small and plausible diff. The amendment is the shape
  # OFAC publishes weekly -- one new listing, one delisting, one record whose
  # primary name was corrected.
  describe "two consecutive OFAC snapshots" do
    def fixtures = File.expand_path("../fixtures/ofac_sdn", __dir__)

    def raw
      { sdn: File.binread("#{fixtures}/SDN.CSV"),
        alt: File.binread("#{fixtures}/ALT.CSV"),
        add: File.binread("#{fixtures}/ADD.CSV") }
    end

    # One new listing, one delisting, and one record whose primary name was
    # corrected -- a week of OFAC.
    def amended
      listing = %(20004,"NEWLY LISTED LLC",-0- ,"SDGT",-0- ,-0- ,-0- ,-0- ,-0- ,-0- ,-0- ,-0- \n)
      raw.merge(sdn: raw[:sdn]
                     .sub('2674,"ABBAS, Abu"', '2674,"ABBAS, Abu Bakr"')
                     .gsub(/^12086,.*\n/, "")
                     .concat(listing))
    end

    def parse(files) = snapshot(ActiveSanction::Sources::OfacSdn.new.parse(files))

    let(:published) { diff(parse(raw), parse(amended)) }

    it "reports the new listing" do
      expect(published.added.map(&:id)).to eq(["ofac_sdn:20004"])
    end

    it "reports the delisting" do
      expect(published.removed.map(&:id)).to eq(["ofac_sdn:12086"])
    end

    it "reports the corrected name as an amendment to one record" do
      expect(published.modified.map(&:to_s)).to eq(["ofac_sdn:2674  names +1 -1"])
    end

    it "moves a plausible fraction of the list" do
      expect(published.churn).to be < 0.5
    end

    it "leaves every untouched record out of the diff" do
      expect(published.size).to eq(3)
    end
  end
end
