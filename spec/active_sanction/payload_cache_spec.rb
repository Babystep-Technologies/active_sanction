# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

RSpec.describe ActiveSanction::PayloadCache do
  let(:root) { Dir.mktmpdir("active_sanction") }
  let(:dir) { File.join(root, "payloads") }
  let(:cache) { described_class.new(dir: dir, retain: 2) }

  # The real OFAC download URL, because the behaviour this class exists for --
  # a publisher overwriting one file forever -- was verified against it.
  let(:url) { "https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV" }
  let(:csv) { "ent_num,SDN_Name\n36,\"AEROCARIBBEAN AIRLINES\"\n" }

  after do
    FileUtils.remove_entry(root)
    ActiveSanction.reset!
  end

  def source_dir(source = :ofac_sdn) = File.join(dir, source.to_s)
  def files(source = :ofac_sdn) = Dir.children(source_dir(source)).sort
  def sha256(bytes) = "sha256:#{Digest::SHA256.hexdigest(bytes)}"

  # Written far enough apart that retention order is the order they were made,
  # regardless of how fast the machine running the suite is.
  def write_generations(count, source: :ofac_sdn)
    Array.new(count) do |index|
      cache.write(source, "generation #{index}\n", url: url, fetched_at: Time.now - ((count - index) * 60))
    end
  end

  describe "#write" do
    it "hands back the bytes it was given, unchanged" do
      entry = cache.write(:ofac_sdn, csv, url: url)

      expect(cache.read(:ofac_sdn, entry.checksum)).to eq(csv)
    end

    it "checksums what actually landed on disk" do
      expect(cache.write(:ofac_sdn, csv, url: url).checksum).to eq(sha256(csv))
    end

    it "records the byte size, which is what an operator compares against the publisher" do
      expect(cache.write(:ofac_sdn, csv, url: url).byte_size).to eq(csv.bytesize)
    end

    it "keeps the payload byte for byte, including an encoding we do not guess at" do
      bytes = "Ali\xC3\xA9".dup.force_encoding(Encoding::BINARY)

      expect(cache.write(:ofac_sdn, bytes, url: url).read.bytesize).to eq(5)
    end

    it "reads from anything IO-shaped, so a caller need not materialize a list twice" do
      entry = cache.write(:ofac_sdn, StringIO.new(csv), url: url)

      expect(entry.read).to eq(csv)
    end

    it "stores the publisher's validators beside the bytes" do
      entry = cache.write(:ofac_sdn, csv, url: url, etag: '"0953154d0fb5aff918c5ec1daf6e9c0e"',
                                          last_modified: "Fri, 28 Aug 2026 14:02:55 GMT")

      expect(entry).to have_attributes(etag: '"0953154d0fb5aff918c5ec1daf6e9c0e"',
                                       last_modified: "Fri, 28 Aug 2026 14:02:55 GMT")
    end

    # OFAC 302s to blob storage, and a bug report about a bad download is much
    # easier to read when it names the host that actually served the bytes.
    it "records where the bytes finally came from when that is not the URL asked for" do
      blob = "https://ofacblob.blob.core.windows.net/sdn/SDN.CSV"

      entry = cache.write(:ofac_sdn, csv, url: url, final_url: blob)

      expect(entry).to have_attributes(url: url, final_url: blob)
    end

    # Verified live: OFAC 302s to a presigned S3 URL and the UN to a blob SAS
    # link, both carrying an hour-long credential in the query string.
    it "does not write a publisher's presigned credential into the sidecar" do
      entry = cache.write(:ofac_sdn, csv, url: url,
                                          final_url: "https://ofacblob.s3.amazonaws.com/SDN.CSV" \
                                                     "?X-Amz-Security-Token=FwoDYXdzEKz")

      expect(entry.final_url).to eq("https://ofacblob.s3.amazonaws.com/SDN.CSV")
    end

    it "creates the cache directory rather than expecting one" do
      nested = described_class.new(dir: File.join(dir, "deeper", "still"), retain: 2)

      expect(nested.write(:ofac_sdn, csv, url: url).read).to eq(csv)
    end

    it "refuses a payload with no record of where it came from" do
      expect { cache.write(:ofac_sdn, csv) }
        .to raise_error(ArgumentError, /url: is required/)
    end

    # Checked before a byte is written, so a caller does not stream 126 MB to
    # learn it misspelled a keyword.
    it "rejects unknown metadata" do
      expect { cache.write(:ofac_sdn, csv, url: url, etagg: "typo") }
        .to raise_error(ArgumentError, /unknown payload metadata: etagg/)
    end

    it "rejects it before writing anything" do
      begin
        cache.write(:ofac_sdn, csv, url: url, etagg: "typo")
      rescue ArgumentError
        nil
      end

      expect(File).not_to exist(source_dir)
    end

    it "rejects a source name that would escape the cache directory" do
      expect { cache.write(:"../../etc", csv, url: url) }
        .to raise_error(ArgumentError, /not a usable source name/)
    end

    it "refuses both a payload and a block, which disagree about what to store" do
      expect { cache.write(:ofac_sdn, csv, url: url) { |sink| sink.write("other") } }
        .to raise_error(ArgumentError, /not both/)
    end

    it "refuses neither" do
      expect { cache.write(:ofac_sdn, url: url) }.to raise_error(ArgumentError, /payload or a block/)
    end
  end

  describe "#write with a block, which is how a 126 MB list is stored" do
    it "returns an entry for whatever the block wrote" do
      entry = cache.write(:ofac_sdn, url: url) { |sink| sink.write(csv) }

      expect(entry.read).to eq(csv)
    end

    # A streaming caller only learns the ETag once the response has been read.
    it "merges metadata the block only learns afterwards" do
      entry = cache.write(:ofac_sdn, url: url) do |sink|
        sink.write(csv)
        { etag: '"0953154d"', last_modified: "Fri, 28 Aug 2026 14:02:55 GMT" }
      end

      expect(entry).to have_attributes(etag: '"0953154d"', last_modified: "Fri, 28 Aug 2026 14:02:55 GMT")
    end

    it "still rejects metadata the block invents" do
      expect { cache.write(:ofac_sdn, url: url) { |sink| sink.write(csv) && { nonsense: 1 } } }
        .to raise_error(ArgumentError, /unknown payload metadata: nonsense/)
    end

    # `next false` is how a caller says the download failed: a 404 body is not
    # a sanctions list, and checksumming one as though it were is exactly the
    # failure this cache would otherwise hide.
    it "answers nil when the block abandons the write" do
      expect(abandoned_write).to be_nil
    end

    it "commits no entry when the block abandons the write" do
      abandoned_write

      expect(cache.entries(:ofac_sdn)).to be_empty
    end

    it "leaves no bytes on disk when the block abandons the write" do
      abandoned_write

      expect(files).to be_empty
    end

    def abandoned_write
      cache.write(:ofac_sdn, url: url) do |sink|
        sink.write("<html>404 Not Found</html>")
        false
      end
    end
  end

  # The first acceptance criterion: an interrupted write leaves no readable
  # cache entry.
  describe "an interrupted write" do
    it "raises rather than swallowing what went wrong" do
      expect { cache.write(:ofac_sdn, url: url) { |_sink| raise "connection reset" } }
        .to raise_error("connection reset")
    end

    it "leaves no entry behind" do
      interrupted_write

      expect(cache.entries(:ofac_sdn)).to be_empty
    end

    it "leaves no half-written bytes behind" do
      interrupted_write

      expect(files).to be_empty
    end

    it "does not disturb the payload already cached" do
      good = cache.write(:ofac_sdn, csv, url: url)

      interrupted_write

      expect(cache.latest(:ofac_sdn)).to eq(good)
    end

    it "leaves the cached payload readable" do
      good = cache.write(:ofac_sdn, csv, url: url)

      interrupted_write

      expect(good.read).to eq(csv)
    end

    # A process killed between the two renames leaves bytes with no sidecar.
    # Listing reads sidecars, so those bytes are not an entry -- which is what
    # makes "nothing partial is readable" true even for a SIGKILL.
    it "is not listed when the sidecar never landed" do
      orphan_payload

      expect(cache.entries(:ofac_sdn)).to be_empty
    end

    it "is not the latest payload when the sidecar never landed" do
      orphan_payload

      expect(cache.latest(:ofac_sdn)).to be_nil
    end

    it "cannot be found by checksum when the sidecar never landed" do
      entry = orphan_payload

      expect(cache.find(:ofac_sdn, entry.checksum)).to be_nil
    end

    def interrupted_write
      cache.write(:ofac_sdn, url: url) { |sink| sink.write("half a li") && raise("connection reset") }
    rescue RuntimeError
      nil
    end

    # What a process killed between the two renames leaves on disk.
    def orphan_payload
      cache.write(:ofac_sdn, csv, url: url).tap { |entry| FileUtils.rm_f(entry.metadata_path) }
    end
  end

  # The second acceptance criterion: a payload corrupted on disk is detected on
  # read and raises.
  describe "a corrupted payload" do
    it "raises rather than handing a parser bytes that are not what was fetched" do
      entry = cache.write(:ofac_sdn, csv, url: url)
      File.binwrite(entry.path, "ent_num,SDN_Name\n36,\"AEROCARIBBEAN AIRLINE\"\n")

      expect { entry.read }.to raise_error(described_class::ChecksumMismatch, /hashes to sha256:/)
    end

    it "raises through the cache as well as through the entry" do
      entry = cache.write(:ofac_sdn, csv, url: url)
      File.binwrite(entry.path, "tampered")

      expect { cache.read(:ofac_sdn, entry.checksum) }.to raise_error(described_class::ChecksumMismatch)
    end

    it "raises on a truncated payload, which a naive size check would also catch" do
      entry = cache.write(:ofac_sdn, csv, url: url)
      File.binwrite(entry.path, csv.byteslice(0, 10))

      expect { entry.read }.to raise_error(described_class::ChecksumMismatch, /#{csv.bytesize} recorded/)
    end

    it "reports it as invalid without raising, for a caller sweeping the cache" do
      entry = cache.write(:ofac_sdn, csv, url: url)
      File.binwrite(entry.path, "tampered")

      expect(entry).not_to be_valid
    end

    it "raises when the bytes are gone entirely" do
      entry = cache.write(:ofac_sdn, csv, url: url)
      FileUtils.rm_f(entry.path)

      expect { entry.read }.to raise_error(described_class::PayloadMissing)
    end

    # Silently treating an unreadable sidecar as an empty cache would re-fetch
    # tens of megabytes every night without ever saying why.
    it "raises on a sidecar that is not an entry, and says which file to delete" do
      entry = cache.write(:ofac_sdn, csv, url: url)
      File.write(entry.metadata_path, "{ not json")

      expect { cache.entries(:ofac_sdn) }
        .to raise_error(described_class::CorruptEntry, /#{Regexp.escape(entry.metadata_path)}/)
    end

    it "raises on a sidecar describing something that is not a payload" do
      entry = cache.write(:ofac_sdn, csv, url: url)
      File.write(entry.metadata_path, JSON.generate({ "colour" => "blue" }))

      expect { cache.entries(:ofac_sdn) }.to raise_error(described_class::CorruptEntry)
    end
  end

  # The third acceptance criterion: pruning keeps exactly N most recent per
  # source.
  describe "retention" do
    it "keeps exactly the configured number of payloads" do
      write_generations(5)

      expect(cache.entries(:ofac_sdn).size).to eq(2)
    end

    it "keeps the most recent ones" do
      generations = write_generations(5)

      expect(cache.entries(:ofac_sdn).map(&:read)).to eq(generations.last(2).reverse.map(&:read))
    end

    it "takes the pruned payloads off disk rather than merely hiding them" do
      write_generations(5)

      expect(files.size).to eq(4) # two payloads, two sidecars
    end

    it "has nothing left to discard once a write has pruned" do
      write_generations(3)

      expect(cache.prune(:ofac_sdn)).to be_empty
    end

    it "took the oldest payload off disk on the way" do
      expect(write_generations(3).first.exist?).to be(false)
    end

    it "counts per source, so a busy list does not evict a quiet one" do
      write_generations(5, source: :ofac_sdn)
      un = cache.write(:un_consolidated, "<consolidated/>", url: url)

      expect(cache.entries(:un_consolidated)).to eq([un])
    end

    it "returns what a newly lowered retention discarded" do
      write_generations(2)

      expect(described_class.new(dir: dir, retain: 1).prune(:ofac_sdn).size).to eq(1)
    end

    it "leaves a newly lowered retention's worth behind" do
      write_generations(2)
      described_class.new(dir: dir, retain: 1).prune(:ofac_sdn)

      expect(cache.entries(:ofac_sdn).size).to eq(1)
    end

    # A publisher that has not changed its file serves the same bytes again;
    # content addressing means that is the entry we already have.
    it "addresses identical bytes identically" do
      expect(rewrite.map(&:checksum).uniq.size).to eq(1)
    end

    it "does not spend a second slot on bytes it already holds" do
      rewrite

      expect(cache.entries(:ofac_sdn).size).to eq(1)
    end

    it "moves the fetch metadata forward instead" do
      rewrite

      expect(cache.latest(:ofac_sdn).etag).to eq('"two"')
    end

    def rewrite
      [cache.write(:ofac_sdn, csv, url: url, etag: '"one"'),
       cache.write(:ofac_sdn, csv, url: url, etag: '"two"')]
    end

    it "defaults to the configured retention" do
      ActiveSanction.configure { |c| c.retain_payloads = 4 }

      expect(described_class.new(dir: dir).retain).to eq(4)
    end

    it "refuses a retention that keeps nothing" do
      expect { described_class.new(dir: dir, retain: 0) }
        .to raise_error(ActiveSanction::ConfigurationError, /at least 1/)
    end
  end

  describe "sweeping what a crash left behind" do
    # A blob is renamed into place two syscalls before its sidecar is written,
    # so a very recent orphan may belong to a write still in flight.
    it "leaves a fresh orphan alone" do
      entry = cache.write(:ofac_sdn, csv, url: url)
      FileUtils.rm_f(entry.metadata_path)

      cache.prune(:ofac_sdn)

      expect(File).to exist(entry.path)
    end

    it "removes an orphaned payload once it is past the grace period" do
      entry = cache.write(:ofac_sdn, csv, url: url)
      FileUtils.rm_f(entry.metadata_path)
      backdate(entry.path)

      cache.prune(:ofac_sdn)

      expect(File).not_to exist(entry.path)
    end

    it "removes a sidecar whose payload is gone" do
      entry = cache.write(:ofac_sdn, csv, url: url)
      FileUtils.rm_f(entry.path)
      backdate(entry.metadata_path)

      cache.prune(:ofac_sdn)

      expect(File).not_to exist(entry.metadata_path)
    end

    it "removes a .part file a dead download left" do
      cache.write(:ofac_sdn, csv, url: url)
      abandoned = File.join(source_dir, "999-deadbeef.part")
      File.write(abandoned, "half a list")
      backdate(abandoned)

      cache.prune(:ofac_sdn)

      expect(File).not_to exist(abandoned)
    end

    def backdate(path)
      old = Time.now - described_class::ORPHAN_GRACE - 60
      File.utime(old, old, path)
    end
  end

  describe "reading back" do
    it "finds an entry by its checksum" do
      entry = cache.write(:ofac_sdn, csv, url: url)

      expect(cache.find(:ofac_sdn, entry.checksum)).to eq(entry)
    end

    it "accepts the bare hex a publisher prints on its download page" do
      entry = cache.write(:ofac_sdn, csv, url: url)

      expect(cache.find(:ofac_sdn, entry.hex)).to eq(entry)
    end

    it "rejects a checksum that is not one, rather than letting it become a path" do
      expect { cache.find(:ofac_sdn, "../../../etc/passwd") }
        .to raise_error(ArgumentError, /not a sha256 checksum/)
    end

    it "answers nil for a checksum it does not hold" do
      expect(cache.find(:ofac_sdn, "sha256:#{"0" * 64}")).to be_nil
    end

    it "raises from #fetch, for a caller that means to read the payload" do
      expect { cache.fetch(:ofac_sdn, "sha256:#{"0" * 64}") }
        .to raise_error(described_class::PayloadMissing, /no sha256:0{64} payload cached for ofac_sdn/)
    end

    it "reports what it holds" do
      entry = cache.write(:ofac_sdn, csv, url: url)

      expect(cache.include?(:ofac_sdn, entry.checksum)).to be(true)
    end

    it "reports what it does not" do
      cache.write(:ofac_sdn, csv, url: url)

      expect(cache.include?(:ofac_sdn, "sha256:#{"0" * 64}")).to be(false)
    end

    it "lists its sources" do
      cache.write(:ofac_sdn, csv, url: url)
      cache.write(:un_consolidated, "<consolidated/>", url: url)

      expect(cache.sources).to eq(%i[ofac_sdn un_consolidated])
    end

    it "is empty before anything is written, without a directory to its name" do
      expect(cache).to be_empty
    end

    it "has no sources before anything is written" do
      expect(cache.sources).to be_empty
    end

    it "lists every source's entries newest first when asked for none in particular" do
      old = cache.write(:ofac_sdn, csv, url: url, fetched_at: Time.now - 60)
      new = cache.write(:un_consolidated, "<consolidated/>", url: url)

      expect(cache.entries).to eq([new, old])
    end

    it "survives the process, which is the whole reason it is on disk" do
      entry = cache.write(:ofac_sdn, csv, url: url)

      expect(described_class.new(dir: dir, retain: 2).latest(:ofac_sdn)).to eq(entry)
    end
  end

  describe "the on-disk layout" do
    it "is one payload and one sidecar per entry, under the source's own directory" do
      entry = cache.write(:ofac_sdn, csv, url: url)

      expect(files).to eq(["#{entry.basename}.blob", "#{entry.basename}.json"])
    end

    it "names them after the content, so the same bytes are the same entry" do
      entry = cache.write(:ofac_sdn, csv, url: url)

      expect(entry.basename).to eq("sha256-#{Digest::SHA256.hexdigest(csv)}")
    end

    it "writes a sidecar a human can read" do
      entry = cache.write(:ofac_sdn, csv, url: url, etag: '"0953154d"')

      expect(JSON.parse(File.read(entry.metadata_path)))
        .to eq("source" => "ofac_sdn", "checksum" => entry.checksum, "byte_size" => csv.bytesize,
               "url" => url, "final_url" => nil, "fetched_at" => entry.fetched_at.iso8601(6),
               "etag" => '"0953154d"', "last_modified" => nil, "schema_version" => 1)
    end

    it "defaults under the configured cache directory" do
      ActiveSanction.configure { |c| c.cache_dir = dir }

      expect(described_class.new.dir).to eq(File.join(dir, "payloads"))
    end
  end

  describe "#delete and #clear" do
    it "returns the entry it removed" do
      entry = cache.write(:ofac_sdn, csv, url: url)

      expect(cache.delete(:ofac_sdn, entry.checksum)).to eq(entry)
    end

    it "removes bytes and sidecar together" do
      entry = cache.write(:ofac_sdn, csv, url: url)
      cache.delete(:ofac_sdn, entry.checksum)

      expect(files).to be_empty
    end

    it "answers nil when there was nothing to remove" do
      cache.write(:ofac_sdn, csv, url: url)

      expect(cache.delete(:ofac_sdn, "sha256:#{"0" * 64}")).to be_nil
    end

    it "drops one source without touching another" do
      cache.write(:ofac_sdn, csv, url: url)
      un = cache.write(:un_consolidated, "<consolidated/>", url: url)

      cache.clear(:ofac_sdn)

      expect(cache.entries).to eq([un])
    end

    it "drops everything" do
      cache.write(:ofac_sdn, csv, url: url)

      expect(cache.clear.entries).to be_empty
    end
  end

  # HttpClient#download takes any sink that responds to #write, which is what
  # lets the cache own the temporary file and so the atomicity guarantee.
  describe "streaming a real download into the cache" do
    # A tiny backoff rather than a stubbed #sleep: the delays are real, they
    # are sub-millisecond, and the client under test stays an ordinary object.
    def client = ActiveSanction::HttpClient.new(retry_backoff: 0.001)

    it "stores what the server sent" do
      stub_download

      expect(download.read).to eq(csv)
    end

    it "stores the validators the server sent with it" do
      stub_download

      expect(download).to have_attributes(etag: '"0953154d"', last_modified: "Fri, 28 Aug 2026 14:02:55 GMT")
    end

    it "answers nil when the download fails" do
      stub_request(:get, url).to_return(status: 404, body: "<html>Not Found</html>")

      expect(failed_download).to be_nil
    end

    it "caches nothing when the download fails" do
      stub_request(:get, url).to_return(status: 404, body: "<html>Not Found</html>")
      failed_download

      expect(cache.entries(:ofac_sdn)).to be_empty
    end

    def stub_download
      stub_request(:get, url)
        .to_return(status: 200, body: csv,
                   headers: { "ETag" => '"0953154d"', "Last-Modified" => "Fri, 28 Aug 2026 14:02:55 GMT" })
    end

    def download
      cache.write(:ofac_sdn, url: url) do |sink|
        response = client.download(url, to: sink)
        next false unless response.success?

        { etag: response.etag, last_modified: response.last_modified, final_url: response.uri.to_s }
      end
    end

    def failed_download
      cache.write(:ofac_sdn, url: url) { |sink| client.download(url, to: sink).success? || false }
    end

    # The client rewinds the sink before replaying a hop, so a retry stores the
    # list once rather than a truncated copy with a whole one appended.
    it "stores one copy when a retried read had already written part of it" do
      stub_request(:get, url).to_return({ status: 500, body: "upstream error" }, { status: 200, body: csv })

      entry = cache.write(:ofac_sdn, url: url) { |sink| client.download(url, to: sink) }

      expect(entry.read).to eq(csv)
    end
  end

  # Excluded from the default run; reachable only via `rspec --tag live`. The
  # guarantee this class sells is that the bytes it hands back months later are
  # the bytes a government server sent, so it is worth proving once against
  # real payloads -- megabytes, streamed, with whatever encoding and line
  # endings the publisher actually uses -- and not only against a stub of one.
  describe "against the real endpoints", :live do
    {
      ofac_sdn: "https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV",
      un_consolidated: "https://scsanctions.un.org/resources/xml/en/consolidated.xml",
      canada_sema: "https://www.international.gc.ca/world-monde/assets/office_docs/" \
                   "international_relations-relations_internationales/sanctions/sema-lmes.xml"
    }.each do |source, endpoint|
      it "stores a verifiable payload for #{source}, with the validators it came with" do
        entry = cache.write(source, url: endpoint) do |sink|
          response = ActiveSanction::HttpClient.new.download(endpoint, to: sink).success!
          { etag: response.etag, last_modified: response.last_modified, final_url: response.uri.to_s }
        end

        expect(entry).to have_attributes(valid?: true, etag: be_a(String), byte_size: be_positive)
      end
    end
  end
end
