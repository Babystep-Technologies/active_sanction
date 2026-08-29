# frozen_string_literal: true

require "json"

RSpec.describe ActiveSanction::Snapshot do
  def entity(source_ref, **overrides)
    ActiveSanction::Entity.new(
      source: :ofac_sdn, source_ref: source_ref, type: :individual,
      names: [ActiveSanction::Name.new(value: "AL ZAWAHIRI, Aiman", kind: :primary)],
      programs: ["SDGT"],
      **overrides
    )
  end

  let(:entities) { [entity("2674"), entity("1234")] }
  let(:fetched_at) { Time.utc(2026, 8, 28, 9, 30, 0) }
  let(:snapshot) do
    described_class.new(source: :ofac_sdn, entities: entities, fetched_at: fetched_at, source_version: "2026-08-28")
  end

  describe "immutability" do
    it "freezes the snapshot" do
      expect(snapshot).to be_frozen
    end

    it "freezes its entities" do
      expect(snapshot.entities).to be_frozen
    end

    it "does not share the caller's array" do
      given = [entity("2674")]
      built = described_class.new(source: :ofac_sdn, entities: given)
      given << entity("1234")

      expect(built.entities.size).to eq(1)
    end
  end

  describe "#checksum" do
    it "names the algorithm it used" do
      expect(snapshot.checksum).to match(/\Asha256:\h{64}\z/)
    end

    # The acceptance criterion: a publisher reordering its file is not a new
    # list version, and a snapshot that said so would churn every stored result.
    it "is unchanged when the same entities arrive in a different order" do
      reordered = described_class.new(source: :ofac_sdn, entities: entities.reverse, fetched_at: fetched_at)

      expect(reordered.checksum).to eq(snapshot.checksum)
    end

    it "changes when a single field of a single entity changes" do
      edited = described_class.new(source: :ofac_sdn, entities: [entity("2674"), entity("1234", programs: ["SDT"])])

      expect(edited.checksum).not_to eq(snapshot.checksum)
    end

    it "changes when an entity is added" do
      grown = described_class.new(source: :ofac_sdn, entities: entities + [entity("999")])

      expect(grown.checksum).not_to eq(snapshot.checksum)
    end

    # Sorting fingerprints must not collapse them: a list carrying one record
    # twice is a different list from one carrying it once.
    it "changes when an entity is duplicated" do
      doubled = described_class.new(source: :ofac_sdn, entities: entities + [entity("2674")])

      expect(doubled.checksum).not_to eq(snapshot.checksum)
    end

    it "distinguishes the same entities published by different sources" do
      other = described_class.new(source: :uk_hmt, entities: entities, fetched_at: fetched_at)

      expect(other.checksum).not_to eq(snapshot.checksum)
    end

    it "distinguishes content serialized under a different schema_version" do
      migrated = described_class.new(source: :ofac_sdn, entities: entities, schema_version: 2)

      expect(migrated.checksum).not_to eq(snapshot.checksum)
    end

    # This is what makes "has the list changed since we last screened?"
    # answerable: refetching unchanged content has to reproduce the checksum.
    it "ignores when the list was fetched and what the publisher called it" do
      refetched = described_class.new(source: :ofac_sdn, entities: entities.reverse, source_version: "2026-09-01")

      expect(refetched.checksum).to eq(snapshot.checksum)
    end

    it "is defined for an empty snapshot" do
      expect(described_class.new(source: :ofac_sdn, entities: []).checksum).to match(/\Asha256:\h{64}\z/)
    end
  end

  describe "#record_count" do
    it "counts the entities" do
      expect(snapshot.record_count).to eq(2)
    end

    it "accepts a supplied count that agrees" do
      built = described_class.new(source: :ofac_sdn, entities: entities, record_count: 2)

      expect(built.record_count).to eq(2)
    end

    # A stored count that disagrees means rows were lost between writing and
    # reading, which is exactly the corruption this type exists to catch.
    it "rejects a supplied count that disagrees" do
      expect { described_class.new(source: :ofac_sdn, entities: entities, record_count: 19_321) }
        .to raise_error(ArgumentError, /record_count 19321 does not match the 2 entities/)
    end
  end

  describe "#fetched_at" do
    it "defaults to now" do
      expect(described_class.new(source: :ofac_sdn, entities: []).fetched_at).to be_within(5).of(Time.now)
    end

    it "converts to UTC, so two adapters on different hosts stamp comparably" do
      chicago = Time.new(2026, 8, 28, 4, 30, 0, "-05:00")
      built = described_class.new(source: :ofac_sdn, entities: [], fetched_at: chicago)

      expect(built.fetched_at).to eq(Time.utc(2026, 8, 28, 9, 30, 0))
    end

    # #to_h serializes to the second; truncating on the way in is what makes a
    # stored snapshot reload to the value that was written.
    it "truncates sub-second precision" do
      built = described_class.new(source: :ofac_sdn, entities: [], fetched_at: Time.utc(2026, 8, 28, 9, 30, 0.75))

      expect(built.fetched_at).to eq(Time.utc(2026, 8, 28, 9, 30, 0))
    end

    it "parses a timestamp string" do
      built = described_class.new(source: :ofac_sdn, entities: [], fetched_at: "2026-08-28T09:30:00Z")

      expect(built.fetched_at).to eq(fetched_at)
    end

    it "rejects a value that is not a time" do
      expect { described_class.new(source: :ofac_sdn, entities: [], fetched_at: 1) }
        .to raise_error(ArgumentError, /fetched_at is not a time/)
    end
  end

  describe "validation" do
    it "requires a source" do
      expect { described_class.new(source: nil, entities: []) }.to raise_error(ArgumentError, /source is required/)
    end

    it "requires entities to be an Array" do
      expect { described_class.new(source: :ofac_sdn, entities: nil) }
        .to raise_error(ArgumentError, /entities must be an Array/)
    end

    it "requires entities to serialize" do
      expect { described_class.new(source: :ofac_sdn, entities: [Object.new]) }
        .to raise_error(ArgumentError, /entities must respond to #to_h/)
    end

    it "rejects a non-positive schema_version" do
      expect { described_class.new(source: :ofac_sdn, entities: [], schema_version: 0) }
        .to raise_error(ArgumentError, /schema_version must be positive/)
    end

    it "defaults schema_version to the current one" do
      expect(snapshot.schema_version).to eq(described_class::SCHEMA_VERSION)
    end
  end

  describe "#to_h" do
    it "lays keys out in canonical member order" do
      expect(snapshot.to_h.keys).to eq(described_class::MEMBERS)
    end

    it "serializes its entities" do
      expect(snapshot.to_h[:entities]).to eq(entities.map(&:to_h))
    end

    it "serializes fetched_at as an ISO 8601 instant" do
      expect(snapshot.to_h[:fetched_at]).to eq("2026-08-28T09:30:00Z")
    end

    it "carries the checksum, so a stored snapshot can be verified on load" do
      expect(snapshot.to_h[:checksum]).to eq(snapshot.checksum)
    end
  end

  describe ".from_h" do
    it "round-trips" do
      expect(described_class.from_h(snapshot.to_h).to_h).to eq(snapshot.to_h)
    end

    it "rebuilds its entities as Entities" do
      expect(described_class.from_h(snapshot.to_h).entities).to eq(entities)
    end

    it "round-trips an empty snapshot" do
      empty = described_class.new(source: :ofac_sdn, entities: [], fetched_at: fetched_at)

      expect(described_class.from_h(empty.to_h).to_h).to eq(empty.to_h)
    end

    # Storage (#24) persists gzipped JSON, which loses symbol keys entirely.
    it "round-trips through JSON" do
      revived = described_class.from_h(JSON.parse(JSON.generate(snapshot.to_h)))

      expect(revived.to_h).to eq(snapshot.to_h)
    end

    it "accepts entities that are already objects" do
      revived = described_class.from_h(snapshot.to_h.merge(entities: entities))

      expect(revived).to eq(snapshot)
    end

    it "rejects unknown attributes rather than dropping them" do
      expect { described_class.from_h(snapshot.to_h.merge(source_url: "https://example.gov")) }
        .to raise_error(ArgumentError, /unknown Snapshot attribute\(s\): source_url/)
    end
  end

  describe "checksum verification" do
    it "raises when the stored content no longer hashes to the stored checksum" do
      tampered = snapshot.to_h
      tampered[:entities].first[:programs] = ["SDT"]

      expect { described_class.from_h(tampered) }
        .to raise_error(described_class::ChecksumMismatch, /ofac_sdn snapshot content hashes to/)
    end

    it "raises when an entity has been dropped from a stored snapshot" do
      tampered = snapshot.to_h.merge(entities: [snapshot.to_h[:entities].first], record_count: 1)

      expect { described_class.from_h(tampered) }.to raise_error(described_class::ChecksumMismatch)
    end

    it "raises a rescuable ActiveSanction::Error" do
      expect { described_class.new(source: :ofac_sdn, entities: entities, checksum: "sha256:0") }
        .to raise_error(ActiveSanction::Error)
    end
  end

  describe "equality" do
    it "compares by content, not by when the list was fetched" do
      refetched = described_class.new(source: :ofac_sdn, entities: entities.reverse, fetched_at: Time.now)

      expect(refetched).to eq(snapshot)
    end

    it "distinguishes snapshots differing in a single nested field" do
      edited = described_class.new(source: :ofac_sdn, entities: [entity("2674"), entity("1234", programs: [])])

      expect(edited).not_to eq(snapshot)
    end

    it "hashes equal values alike, so snapshots can key a Hash or join a Set" do
      expect({ snapshot => :screened }[described_class.from_h(snapshot.to_h)]).to eq(:screened)
    end
  end
end
