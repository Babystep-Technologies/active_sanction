# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe ActiveSanction::PayloadCache::Checksum do
  let(:dir) { Dir.mktmpdir("active_sanction") }
  let(:csv) { "ent_num,SDN_Name\n36,\"AEROCARIBBEAN AIRLINES\"\n" }
  let(:hex) { Digest::SHA256.hexdigest(csv) }

  after { FileUtils.remove_entry(dir) }

  describe ".normalize!" do
    it "accepts the canonical form" do
      expect(described_class.normalize!("sha256:#{hex}")).to eq("sha256:#{hex}")
    end

    it "accepts the bare hex a publisher prints on a download page" do
      expect(described_class.normalize!(hex)).to eq("sha256:#{hex}")
    end

    it "accepts the filename form, which is the same address with a legible separator" do
      expect(described_class.normalize!("sha256-#{hex}")).to eq("sha256:#{hex}")
    end

    it "is case-insensitive, since hex is" do
      expect(described_class.normalize!(hex.upcase)).to eq("sha256:#{hex}")
    end

    # Every filename under the cache directory comes from here, so a checksum
    # out of a database column cannot become a directory traversal.
    it "refuses anything that is not a SHA-256" do
      ["", "  ", "sha256:", "deadbeef", "#{hex}x", "../../etc/passwd", "sha1:#{hex}", nil]
        .each do |value|
          expect { described_class.normalize!(value) }.to raise_error(ArgumentError, /not a sha256 checksum/)
        end
    end
  end

  describe ".of_file" do
    it "hashes what is on disk" do
      path = File.join(dir, "SDN.CSV")
      File.binwrite(path, csv)

      expect(described_class.of_file(path)).to eq("sha256:#{hex}")
    end

    it "hashes a payload larger than one chunk the same way a single pass would" do
      bytes = "AEROCARIBBEAN," * (described_class::CHUNK_SIZE / 4)
      path = File.join(dir, "SDN_ADVANCED.XML")
      File.binwrite(path, bytes)

      expect(described_class.of_file(path)).to eq("sha256:#{Digest::SHA256.hexdigest(bytes)}")
    end

    it "hashes an empty file rather than refusing one" do
      path = File.join(dir, "empty")
      File.binwrite(path, "")

      expect(described_class.of_file(path)).to eq("sha256:#{Digest::SHA256.hexdigest("")}")
    end
  end

  describe ".hex" do
    it "drops the algorithm prefix" do
      expect(described_class.hex("sha256:#{hex}")).to eq(hex)
    end
  end
end
