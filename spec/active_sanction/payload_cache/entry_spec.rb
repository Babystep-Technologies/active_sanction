# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe ActiveSanction::PayloadCache::Entry do
  let(:dir) { Dir.mktmpdir("active_sanction") }
  let(:url) { "https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV" }
  let(:csv) { "ent_num,SDN_Name\n36,\"AEROCARIBBEAN AIRLINES\"\n" }
  let(:checksum) { "sha256:#{Digest::SHA256.hexdigest(csv)}" }
  let(:entry) do
    described_class.new(dir: dir, source: :ofac_sdn, checksum: checksum, byte_size: csv.bytesize, url: url,
                        etag: '"0953154d0fb5aff918c5ec1daf6e9c0e"',
                        last_modified: "Fri, 28 Aug 2026 14:02:55 GMT")
  end

  after { FileUtils.remove_entry(dir) }

  def write_payload(bytes = csv) = File.binwrite(entry.path, bytes)

  it "is frozen on construction" do
    expect(entry).to be_frozen
  end

  it "names its payload after the content, so the same bytes are the same entry" do
    expect(entry.path).to eq(File.join(dir, "sha256-#{Digest::SHA256.hexdigest(csv)}.blob"))
  end

  it "puts the sidecar beside it under the same name" do
    expect(entry.metadata_path).to eq(File.join(dir, "sha256-#{Digest::SHA256.hexdigest(csv)}.json"))
  end

  it "accepts a bare hex checksum and stores the canonical form" do
    bare = described_class.new(dir: dir, source: :ofac_sdn, url: url, byte_size: 1,
                               checksum: Digest::SHA256.hexdigest(csv).upcase)

    expect(bare.checksum).to eq(checksum)
  end

  it "offers the hex on its own, for comparing against a publisher's download page" do
    expect(entry.hex).to eq(Digest::SHA256.hexdigest(csv))
  end

  describe "#read" do
    it "returns the bytes when they still hash to the checksum" do
      write_payload

      expect(entry.read).to eq(csv)
    end

    it "raises rather than returning bytes that are not what was fetched" do
      write_payload("tampered")

      expect { entry.read }.to raise_error(ActiveSanction::PayloadCache::ChecksumMismatch)
    end

    it "raises when the payload is not there at all" do
      expect { entry.read }.to raise_error(ActiveSanction::PayloadCache::PayloadMissing, /is not at/)
    end
  end

  # A parser cannot un-parse the first half of a payload once the second half
  # turns out to be corrupt, so verification happens before the handle is
  # yielded rather than as the bytes go past.
  describe "#open" do
    it "yields a handle for a caller that would rather stream 126 MB than hold it" do
      write_payload

      expect(entry.open(&:read)).to eq(csv)
    end

    it "raises before yielding anything when the payload is corrupt" do
      write_payload("tampered")

      expect { |probe| entry.open(&probe) }.to raise_error(ActiveSanction::PayloadCache::ChecksumMismatch)
    end
  end

  describe "#valid?" do
    it "is true for bytes that match" do
      write_payload

      expect(entry).to be_valid
    end

    it "is false rather than fatal, for a caller sweeping the cache" do
      write_payload("tampered")

      expect(entry).not_to be_valid
    end
  end

  describe "serialization" do
    it "round-trips through its sidecar" do
      expect(described_class.from_h(entry.to_h, dir: dir)).to eq(entry)
    end

    it "round-trips through JSON, which is what the sidecar actually is" do
      restored = described_class.from_h(JSON.parse(JSON.generate(entry.to_h)), dir: dir)

      expect(restored).to eq(entry)
    end

    it "keeps fetched_at to the microsecond, because retention orders by it" do
      at = Time.at(1_780_000_000, 123_456, :usec).utc
      written = described_class.new(dir: dir, source: :ofac_sdn, checksum: checksum, byte_size: 1,
                                    url: url, fetched_at: at)

      expect(described_class.from_h(written.to_h, dir: dir).fetched_at).to eq(at)
    end

    it "refuses attributes it does not know, rather than dropping them silently" do
      expect { described_class.from_h(entry.to_h.merge(colour: "blue"), dir: dir) }
        .to raise_error(ArgumentError, /unknown Entry attribute\(s\): colour/)
    end

    it "carries the schema version, so an older entry can be recognized as one" do
      expect(entry.to_h[:schema_version]).to eq(described_class::SCHEMA_VERSION)
    end
  end

  describe "validation" do
    it "requires a source" do
      expect { described_class.new(dir: dir, source: nil, checksum: checksum, byte_size: 1, url: url) }
        .to raise_error(ArgumentError, /source is required/)
    end

    it "requires a URL, because a payload with no provenance cannot be audited" do
      expect { described_class.new(dir: dir, source: :ofac_sdn, checksum: checksum, byte_size: 1, url: " ") }
        .to raise_error(ArgumentError, /url is required/)
    end

    it "refuses anything that is not a SHA-256" do
      expect { described_class.new(dir: dir, source: :ofac_sdn, checksum: "nope", byte_size: 1, url: url) }
        .to raise_error(ArgumentError, /not a sha256 checksum/)
    end

    it "refuses a negative size" do
      expect { described_class.new(dir: dir, source: :ofac_sdn, checksum: checksum, byte_size: -1, url: url) }
        .to raise_error(ArgumentError, /byte_size cannot be negative/)
    end

    # OFAC's 302 lands on an S3 URL carrying an X-Amz-Security-Token and the
    # UN's on a blob SAS signature. A cache file outlives the token, is copied
    # into bug reports, and is readable by anything that can read the cache.
    it "cuts the presigned credential out of the URL that finally answered" do
      presigned = "https://wc2h-sls-prod-public-published.s3.us-gov-west-1.amazonaws.com/Published/SDN.CSV" \
                  "?X-Amz-Security-Token=FwoDYXdzEKz&X-Amz-Signature=5e9d3a06d8cb"

      redacted = described_class.new(dir: dir, source: :ofac_sdn, checksum: checksum, byte_size: 1,
                                     url: url, final_url: presigned)

      expect(redacted.final_url)
        .to eq("https://wc2h-sls-prod-public-published.s3.us-gov-west-1.amazonaws.com/Published/SDN.CSV")
    end

    it "keeps a final URL that carries no query, which is most publishers" do
      plain = described_class.new(dir: dir, source: :ofac_sdn, checksum: checksum, byte_size: 1,
                                  url: url, final_url: "https://www.international.gc.ca/sema-lmes.xml")

      expect(plain.final_url).to eq("https://www.international.gc.ca/sema-lmes.xml")
    end

    it "does not mutate a Time it is handed" do
      at = Time.now.getlocal("+05:30")

      described_class.new(dir: dir, source: :ofac_sdn, checksum: checksum, byte_size: 1, url: url, fetched_at: at)

      expect(at.utc_offset).to eq(19_800)
    end
  end

  describe "equality" do
    it "compares by value" do
      expect(described_class.from_h(entry.to_h, dir: dir)).to eql(entry)
    end

    it "hashes by value, so two reads of one entry are one key" do
      expect(described_class.from_h(entry.to_h, dir: dir).hash).to eq(entry.hash)
    end

    # Two caches may hold the same bytes; they are not the same cached payload,
    # and reading one does not read the other.
    it "distinguishes entries in different directories" do
      elsewhere = described_class.from_h(entry.to_h, dir: File.join(dir, "elsewhere"))

      expect(elsewhere).not_to eq(entry)
    end
  end
end
