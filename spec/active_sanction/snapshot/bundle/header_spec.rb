# frozen_string_literal: true

require "json"

RSpec.describe ActiveSanction::Snapshot::Bundle::Header do
  def snapshot(**overrides)
    ActiveSanction::Snapshot.new(
      source: :ofac_sdn, entities: [], fetched_at: Time.utc(2026, 8, 28, 9, 30, 0),
      source_version: "2026-08-28", **overrides
    )
  end

  def build(**overrides)
    described_class.from_snapshot(snapshot, payload_digest: "sha256:#{"a" * 64}", payload_bytes: 4096, **overrides)
  end

  def build_without_source_version
    described_class.from_snapshot(snapshot(source_version: nil), payload_digest: "sha256:#{"a" * 64}",
                                                                 payload_bytes: 4096)
  end

  let(:header) { build }

  describe ".from_snapshot" do
    it "takes the list's own identity from the snapshot" do
      expect([header.source, header.snapshot_checksum, header.record_count])
        .to eq([:ofac_sdn, snapshot.checksum, 0])
    end

    it "stamps this gem as what serialized the records" do
      expect([header.format_version, header.gem_version]).to eq([1, ActiveSanction::VERSION])
    end

    # `generator` is who published the bundle and `gem_version` is what wrote
    # it. A mirror sets the first and cannot set the second.
    it "defaults the generator to this gem, and lets a publisher name itself" do
      expect([header.generator, build(generator: "acme-mirror/2.0").generator])
        .to eq(["active_sanction/#{ActiveSanction::VERSION}", "acme-mirror/2.0"])
    end

    it "carries the publisher's own version where there is one" do
      expect(header.source_version).to eq("2026-08-28")
    end
  end

  describe "#to_line" do
    it "is one line, so a bundle's header can be read with gets" do
      expect(header.to_line).not_to include("\n")
    end

    # The key order is part of the format: a reader in another language that
    # emits them in another order produces a different file.
    it "serializes its members in the documented order" do
      expect(JSON.parse(header.to_line).keys.map(&:to_sym)).to eq(described_class::MEMBERS)
    end

    it "writes a missing source version as null rather than dropping the key" do
      line = build_without_source_version.to_line

      expect(JSON.parse(line)).to include("source_version" => nil)
    end

    it "round-trips through .parse" do
      expect(described_class.parse(header.to_line)).to eq(header)
    end

    it "is the same line for the same header twice" do
      expect(build.to_line).to eq(header.to_line)
    end
  end

  describe ".parse" do
    it "refuses anything that is not a JSON object" do
      expect { described_class.parse("[1, 2]") }.to raise_error(ActiveSanction::InvalidArgument, /JSON object/)
    end

    it "refuses a field it does not know, rather than ignoring it" do
      line = JSON.generate(header.to_h.merge(published_by: "acme"))

      expect { described_class.parse(line) }.to raise_error(ActiveSanction::InvalidArgument, /published_by/)
    end

    it "refuses a header missing a field it needs" do
      line = JSON.generate(header.to_h.except(:payload_digest))

      expect { described_class.parse(line) }.to raise_error(ActiveSanction::InvalidArgument, /payload_digest/)
    end

    it "accepts a header with no source version, which plenty of lists have" do
      line = JSON.generate(header.to_h.except(:source_version))

      expect(described_class.parse(line).source_version).to be_nil
    end

    it "refuses a digest that is not one" do
      line = JSON.generate(header.to_h.merge(payload_digest: "sha256:nope"))

      expect { described_class.parse(line) }.to raise_error(ActiveSanction::InvalidArgument, /not a sha256 digest/)
    end

    it "refuses a source key nothing could be filed under" do
      line = JSON.generate(header.to_h.merge(source: "../etc"))

      expect { described_class.parse(line) }.to raise_error(ActiveSanction::Error, /not a usable source key/)
    end

    it "refuses a negative record count" do
      line = JSON.generate(header.to_h.merge(record_count: -1))

      expect { described_class.parse(line) }.to raise_error(ActiveSanction::InvalidArgument, /cannot be negative/)
    end
  end

  describe "immutability" do
    it "freezes the header" do
      expect(header).to be_frozen
    end

    it "compares by value" do
      expect(build).to eq(header)
    end

    it "is not equal to a header describing another payload" do
      expect(build(generator: "acme/1.0")).not_to eq(header)
    end
  end

  it "reads its fetched_at back at the precision it serializes" do
    expect(described_class.parse(header.to_line).fetched_at).to eq(Time.utc(2026, 8, 28, 9, 30, 0))
  end
end
