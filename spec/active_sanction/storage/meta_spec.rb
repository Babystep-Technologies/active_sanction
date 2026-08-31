# frozen_string_literal: true

require "json"

RSpec.describe ActiveSanction::Storage::Meta do
  let(:fetched_at) { Time.utc(2026, 8, 28, 9, 30, 0) }
  let(:snapshot) do
    ActiveSanction::Snapshot.new(
      source: :ofac_sdn, fetched_at: fetched_at, source_version: "Thu, 28 Aug 2026 09:00:00 GMT",
      entities: [ActiveSanction::Entity.new(source: :ofac_sdn, source_ref: "2674", type: :individual,
                                            names: [ActiveSanction::Name.new(value: "AL ZAWAHIRI, Aiman")])]
    )
  end
  let(:meta) { described_class.from_snapshot(snapshot) }

  describe ".from_snapshot" do
    it "carries the checksum a match result will cite" do
      expect(meta.checksum).to eq(snapshot.checksum)
    end

    it "carries the record count" do
      expect(meta.record_count).to eq(1)
    end

    it "carries when the list was fetched" do
      expect(meta.fetched_at).to eq(fetched_at)
    end

    it "carries the publisher's own version marker" do
      expect(meta.source_version).to eq("Thu, 28 Aug 2026 09:00:00 GMT")
    end

    # Stored beside the snapshot so a reader can refuse a list written by a
    # serializer it does not agree with, rather than misreading it.
    it "carries the schema version the snapshot was written under" do
      expect(meta.schema_version).to eq(ActiveSanction::Snapshot::SCHEMA_VERSION)
    end
  end

  describe "serialization" do
    # #24 writes this as `meta.json` beside each snapshot, so the round trip
    # that has to hold is the one through JSON and its string keys.
    it "survives the round trip through JSON" do
      expect(described_class.from_h(JSON.parse(JSON.generate(meta.to_h)))).to eq(meta)
    end

    it "writes the time in a form that reads back unchanged" do
      expect(described_class.from_h(meta.to_h).fetched_at).to eq(fetched_at)
    end

    it "refuses a key it does not know, rather than dropping it" do
      expect { described_class.from_h(meta.to_h.merge(entities: [])) }
        .to raise_error(ArgumentError, /unknown Meta attribute/)
    end
  end

  describe "#age" do
    # Sync (#34) keeps the previous snapshot when a list fails to refresh,
    # which is the right call only if how old it is stays visible.
    it "reports how long ago the list was fetched" do
      expect(meta.age(fetched_at + 3600)).to eq(3600)
    end
  end

  describe "#same_content?" do
    it "is true of the snapshot it came from" do
      expect(meta).to be_same_content(snapshot)
    end

    # A re-fetch of an unchanged list is not a new version of it, so the
    # comparison follows the checksum and ignores when either was fetched.
    it "ignores when either was fetched" do
      refetched = ActiveSanction::Snapshot.new(source: :ofac_sdn, entities: snapshot.entities, fetched_at: Time.now)

      expect(meta).to be_same_content(refetched)
    end

    it "is false of nothing at all" do
      expect(meta).not_to be_same_content(nil)
    end
  end

  describe "the value it is" do
    it "is frozen" do
      expect(meta).to be_frozen
    end

    it "compares by value" do
      expect(described_class.from_snapshot(snapshot)).to eq(meta)
    end

    it "hashes by value" do
      expect([meta, described_class.from_snapshot(snapshot)].uniq.size).to eq(1)
    end

    it "requires a checksum, since a stored list that cannot be cited is not stored" do
      expect { described_class.new(source: :ofac_sdn, fetched_at: fetched_at, checksum: "", record_count: 1) }
        .to raise_error(ArgumentError, /checksum is required/)
    end

    it "requires a source" do
      expect { described_class.new(source: nil, fetched_at: fetched_at, checksum: "sha256:x", record_count: 1) }
        .to raise_error(ArgumentError, /source is required/)
    end

    it "refuses a negative record count" do
      expect { described_class.new(source: :ofac_sdn, fetched_at: fetched_at, checksum: "sha256:x", record_count: -1) }
        .to raise_error(ArgumentError, /record_count cannot be negative/)
    end
  end
end
