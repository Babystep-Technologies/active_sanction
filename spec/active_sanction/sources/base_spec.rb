# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe ActiveSanction::Sources::Base do
  let(:store) { ActiveSanction::ValidatorStore::Memory.new }
  let(:client) { ActiveSanction::HttpClient.new(retry_backoff: 0.001) }
  let(:fetcher) { ActiveSanction::Fetcher.new(client: client, store: store) }
  let(:cache_dir) { Dir.mktmpdir("active_sanction_sources") }
  let(:cache) { ActiveSanction::PayloadCache.new(dir: cache_dir) }

  after { FileUtils.remove_entry(cache_dir) if File.directory?(cache_dir) }

  # A logger here is anything that responds to #info, so the suite collects the
  # lines rather than parsing a formatted stream.
  def collecting_logger
    Class.new do
      def lines = @lines ||= []
      def info(message) = lines << message
    end.new
  end

  def url = "https://scsanctions.un.org/resources/xml/en/consolidated.xml"
  def etag = '"0x8DF0558663FC719"'
  def last_modified = "Fri, 28 Aug 2026 23:02:14 GMT"
  def list = "ABDUL AZIZ\nMOHAMMED OMAR\n"

  def validators = { "ETag" => etag, "Last-Modified" => last_modified }

  # A whole adapter: five declarations and a #parse. Everything else -- the
  # conditional GET, the payload cache, the checksum -- comes from Base.
  def un
    Class.new(described_class) do
      key :un_consolidated
      jurisdiction :un
      authority "United Nations Security Council"
      format :xml
      url :main, "https://scsanctions.un.org/resources/xml/en/consolidated.xml"

      def parse(raw)
        raw.to_s.lines.map(&:strip).reject(&:empty?).map do |line|
          ActiveSanction::Entity.new(id: "un:#{line}", source: :un_consolidated, type: :individual,
                                     names: [ActiveSanction::Name.new(value: line)])
        end
      end
    end
  end

  def source(klass = un) = klass.new(fetcher: fetcher, cache: cache)

  describe "the contract" do
    it "tells an adapter that has not written one what #parse must return" do
      expect { Class.new(described_class).new.parse("<xml/>") }
        .to raise_error(ActiveSanction::UnsupportedError, /must implement #parse\(raw\).*Array of ActiveSanction::Entity/)
    end

    it "names the adapter, not the base class" do
      expect { source.class.superclass.new.parse("") }
        .to raise_error(ActiveSanction::UnsupportedError, /ActiveSanction::Sources::Base must implement/)
    end

    it "reads the class declarations from an instance" do
      expect(source).to have_attributes(key: :un_consolidated, jurisdiction: :un, format: :xml,
                                        authority: "United Nations Security Council", url: url)
    end
  end

  describe "syncing a single-file source" do
    it "fetches, parses and checksums into a Snapshot" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)

      snapshot = source.sync

      expect(snapshot).to be_a(ActiveSanction::Snapshot)
        .and have_attributes(source: :un_consolidated, record_count: 2)
    end

    it "hands #parse the bytes, not a Hash, when one file was declared" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)

      expect(source.sync.entities.map(&:id)).to eq(["un:ABDUL AZIZ", "un:MOHAMMED OMAR"])
    end

    it "stamps the publisher's own version marker onto the snapshot" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)

      expect(source.sync.source_version).to eq(last_modified)
    end

    # The outcome to expect on most runs: these lists change daily at most, and
    # a sync that runs hourly should transfer nothing twenty-three times a day.
    it "returns nil when the publisher answers 304" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      stub_request(:get, url).with(headers: { "If-None-Match" => etag }).to_return(status: 304)
      adapter = source
      adapter.sync

      expect(adapter.sync).to be_nil
    end

    it "does not parse a list it did not download" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      adapter = source
      adapter.sync
      stub_request(:get, url).to_return(status: 304)
      allow(adapter).to receive(:parse)

      adapter.sync

      expect(adapter).not_to have_received(:parse)
    end

    it "downloads in full when forced, whatever the ETag says" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      adapter = source
      adapter.sync
      WebMock.reset!
      forced = stub_request(:get, url).with { |request| !request.headers.key?("If-None-Match") }
                                      .to_return(status: 200, body: list, headers: validators)
      adapter.sync(force: true)

      expect(forced).to have_been_made
    end

    # One list failing is a decision about a run, not about a list: #34 needs
    # an exception here to notice it and keep the other sources going.
    it "raises rather than swallowing a failed fetch" do
      stub_request(:get, url).to_return(status: 403)

      expect { source.sync }.to raise_error(ActiveSanction::HttpClient::ResponseError)
    end
  end

  describe "the payload cache" do
    it "keeps the bytes the publisher served, with their provenance" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      source.sync

      expect(cache.latest(:un_consolidated))
        .to have_attributes(url: url, etag: etag, last_modified: last_modified, byte_size: list.bytesize)
    end

    it "does not require one" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)

      expect(un.new(fetcher: fetcher, cache: nil).sync.record_count).to eq(2)
    end
  end

  describe "syncing a multi-file source" do
    # OFAC's SDN list is three files that only mean anything joined.
    def ofac
      Class.new(described_class) do
        key :ofac_sdn
        jurisdiction :us
        authority "Office of Foreign Assets Control"
        format :csv
        url :sdn, "https://ofac.test/SDN.CSV"
        url :alt, "https://ofac.test/ALT.CSV"

        def parse(raw)
          raw.map do |name, body|
            ActiveSanction::Entity.new(id: "#{name}:#{body.strip}", source: :ofac_sdn, type: :individual)
          end
        end
      end
    end

    # What the publisher does when it still holds our ETag but the cache no
    # longer holds the payload: 304 to the conditional request, then the bytes
    # to the unconditional one that follows it.
    def stub_uncached_sdn
      stub_request(:get, "https://ofac.test/SDN.CSV")
        .to_return({ status: 304 }, { status: 200, body: "sdn refetched", headers: validators })
      stub_request(:get, "https://ofac.test/ALT.CSV").to_return(status: 200, body: "alt body", headers: validators)
    end

    def stub_files(sdn: 200, alt: 200)
      stub_request(:get, "https://ofac.test/SDN.CSV")
        .to_return(status: sdn, body: sdn == 200 ? "sdn body" : nil, headers: validators)
      stub_request(:get, "https://ofac.test/ALT.CSV")
        .to_return(status: alt, body: alt == 200 ? "alt body" : nil, headers: validators)
    end

    it "hands #parse a Hash keyed by the names the adapter declared" do
      stub_files

      expect(source(ofac).sync.entities.map(&:id)).to eq(["sdn:sdn body", "alt:alt body"])
    end

    it "files each file separately, so one ETag cannot answer for another" do
      stub_files
      source(ofac).sync

      expect(store.keys).to contain_exactly("ofac_sdn-sdn", "ofac_sdn-alt")
    end

    it "caches each file separately, so two files do not evict each other" do
      stub_files
      source(ofac).sync

      expect(cache.sources).to contain_exactly(:"ofac_sdn-alt", :"ofac_sdn-sdn")
    end

    # The point of caching payloads: a sync where only ALT.CSV moved should
    # download ALT.CSV and not all three files.
    it "serves an unchanged file from the cache when another one changed" do
      stub_files
      adapter = source(ofac)
      adapter.sync
      WebMock.reset!
      stub_request(:get, "https://ofac.test/SDN.CSV").to_return(status: 304)
      stub_request(:get, "https://ofac.test/ALT.CSV").to_return(status: 200, body: "alt body 2", headers: validators)

      expect(adapter.sync.entities.map(&:id)).to eq(["sdn:sdn body", "alt:alt body 2"])
    end

    it "downloads only the file that moved" do
      stub_files
      adapter = source(ofac)
      adapter.sync
      WebMock.reset!
      unchanged = stub_request(:get, "https://ofac.test/SDN.CSV").to_return(status: 304)
      stub_request(:get, "https://ofac.test/ALT.CSV").to_return(status: 200, body: "alt body 2", headers: validators)
      adapter.sync

      expect(unchanged).to have_been_made.once
    end

    it "returns nil only when every file came back unchanged" do
      stub_files
      adapter = source(ofac)
      adapter.sync
      WebMock.reset!
      stub_files(sdn: 304, alt: 304)

      expect(adapter.sync).to be_nil
    end

    # A cache directory the user deleted, or a first run against a validator
    # store that outlived it. One file is re-fetched, not all of them.
    it "re-fetches a file it has validators for but no payload" do
      stub_files
      adapter = source(ofac)
      adapter.sync
      cache.clear(:"ofac_sdn-sdn")
      WebMock.reset!
      stub_uncached_sdn

      expect(adapter.sync.entities.map(&:id)).to eq(["sdn:sdn refetched", "alt:alt body"])
    end

    # Not repaired, not used, and not fatal either: the bytes it failed to
    # prove are a download away, and the entry stays on disk to be looked at.
    it "re-fetches around a cached payload that no longer matches its checksum" do
      stub_files
      adapter = source(ofac)
      adapter.sync
      File.write(cache.latest(:"ofac_sdn-sdn").path, "tampered")
      WebMock.reset!
      stub_uncached_sdn

      expect(adapter.sync.entities.map(&:id)).to eq(["sdn:sdn refetched", "alt:alt body"])
    end

    it "says which file it could not get the bytes for when even that fails" do
      stub_files
      adapter = source(ofac)
      adapter.sync
      cache.clear(:"ofac_sdn-sdn")
      WebMock.reset!
      stub_files(sdn: 304)

      expect { adapter.sync }
        .to raise_error(ActiveSanction::Sources::MissingPayload, %r{ofac_sdn sdn.*https://ofac.test/SDN.CSV}m)
    end

    it "logs that it is downloading a file the publisher said had not changed" do
      logger = collecting_logger
      adapter = ofac.new(fetcher: fetcher, cache: cache, logger: logger)
      stub_files
      adapter.sync
      cache.clear(:"ofac_sdn-sdn")
      WebMock.reset!
      stub_uncached_sdn
      adapter.sync

      expect(logger.lines.join("\n")).to include("ofac_sdn sdn unchanged but not cached")
    end

    it "cannot recover an unchanged file with no cache to recover it from" do
      stub_files
      adapter = ofac.new(fetcher: fetcher, cache: nil)
      adapter.sync
      WebMock.reset!
      full = stub_request(:get, "https://ofac.test/SDN.CSV")
             .to_return({ status: 304 }, { status: 200, body: "sdn body", headers: validators })
      stub_request(:get, "https://ofac.test/ALT.CSV").to_return(status: 200, body: "alt", headers: validators)

      adapter.sync

      expect(full).to have_been_made.twice
    end
  end

  describe "parsing payloads already in hand" do
    # What a conformance spec (#16) and an adapter's own spec do: no network,
    # no cache, a committed fixture.
    it "builds a snapshot from a fixture" do
      snapshot = un.new(fetcher: fetcher, cache: nil).snapshot(main: list)

      expect(snapshot).to have_attributes(source: :un_consolidated, record_count: 2)
    end

    it "takes the bytes on their own for a source that reads one file" do
      snapshot = un.new(fetcher: fetcher, cache: nil).snapshot(list)

      expect(snapshot.record_count).to eq(2)
    end

    it "reproduces the same checksum from the same bytes" do
      adapter = un.new(fetcher: fetcher, cache: nil)

      first = adapter.snapshot(main: list).checksum

      expect(adapter.snapshot(main: list).checksum).to eq(first)
    end
  end

  describe "staleness" do
    it "is stale before anything has been fetched" do
      expect(source).to be_stale
    end

    it "is fresh once every file has been confirmed" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      adapter = source
      adapter.sync

      expect(adapter).to be_fresh
    end
  end

  describe "a source that is not fetched over HTTP" do
    it "says so rather than fetching nothing" do
      internal = Class.new(described_class) { key :my_internal_watchlist }

      expect { internal.new(cache: nil).retrieve }
        .to raise_error(ActiveSanction::Sources::DeclarationError, /declares no URL/)
    end
  end

  # The acceptance criterion for the milestone, end to end: an adapter defined
  # in somebody else's namespace, registered from outside the gem, resolved
  # through the registry and synced -- without any of it having been named in
  # this codebase.
  describe "a source defined entirely outside the gem" do
    after { ActiveSanction::Sources.unregister(:my_internal_watchlist) }

    def watchlist
      Class.new(described_class) do
        key :my_internal_watchlist
        jurisdiction :internal
        authority "MyCompany Financial Crime"
        format :csv
        url :main, "https://lists.mycompany.test/watchlist.csv"

        def parse(raw)
          raw.to_s.lines.map do |line|
            ActiveSanction::Entity.new(id: line.strip, source: key, type: :organization)
          end
        end
      end
    end

    it "registers and syncs" do
      ActiveSanction::Sources.register(watchlist)
      stub_request(:get, "https://lists.mycompany.test/watchlist.csv")
        .to_return(status: 200, body: "ACME TRADING LLC\n", headers: validators)

      snapshot = ActiveSanction::Sources[:my_internal_watchlist].new(fetcher: fetcher, cache: cache).sync

      expect(snapshot).to have_attributes(source: :my_internal_watchlist, record_count: 1)
    end
  end

  describe "#inspect" do
    it "names the key and how many files it reads" do
      expect(source.inspect).to include("un_consolidated", "1 url(s)")
    end

    it "does not raise on an adapter that declared nothing" do
      expect(Class.new(described_class).new(cache: nil).inspect).to include("(no key)")
    end
  end
end
