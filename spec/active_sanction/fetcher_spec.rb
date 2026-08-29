# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

RSpec.describe ActiveSanction::Fetcher do
  let(:store) { ActiveSanction::ValidatorStore::Memory.new }
  let(:client) { ActiveSanction::HttpClient.new(retry_backoff: 0.001) }
  let(:fetcher) { described_class.new(client: client, store: store) }

  after { ActiveSanction.reset_configuration! }

  # The real OFAC download URL, and the validators it really served, since
  # every behaviour here exists for what these endpoints actually do.
  def url = "https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV"
  def blob = "https://ofacblob.blob.core.windows.net/sdn/SDN.CSV"
  def etag = '"0953154d0fb5aff918c5ec1daf6e9c0e"'
  def last_modified = "Fri, 28 Aug 2026 14:02:55 GMT"
  def list = "ent_num,SDN_Name\n36,AEROCARIBBEAN AIRLINES\n"

  def validators
    { "ETag" => etag, "Last-Modified" => last_modified }
  end

  describe "the first fetch" do
    it "sends no conditional headers, having nothing to be conditional about" do
      stub = stub_request(:get, url).with { |request| !request.headers.key?("If-None-Match") }
                                    .to_return(status: 200, body: list, headers: validators)

      fetcher.fetch(url, key: :ofac_sdn)

      expect(stub).to have_been_made
    end

    it "reports a changed list with a body to parse" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)

      result = fetcher.fetch(url, key: :ofac_sdn)

      expect(result).to be_changed.and have_attributes(status: 200, body: list)
    end

    it "stores both validators the publisher served" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)

      fetcher.fetch(url, key: :ofac_sdn)

      expect(store[:ofac_sdn]).to have_attributes(etag: etag, last_modified: last_modified)
    end

    it "files them under the URL when the caller names no key" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)

      fetcher.fetch(url)

      expect(store[url]).not_to be_nil
    end

    # OFAC 302s to blob storage, and the hop that answers is not stable enough
    # to key a cache by.
    it "stores them against the URL asked for, not the redirect that answered" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => blob })
      stub_request(:get, blob).to_return(status: 200, body: list, headers: validators)

      fetcher.fetch(url, key: :ofac_sdn)

      expect(store[:ofac_sdn].url).to eq(url)
    end
  end

  describe "the second fetch" do
    before { stub_request(:get, url).to_return(status: 200, body: list, headers: validators) }

    it "sends back the ETag the publisher gave it" do
      fetcher.fetch(url, key: :ofac_sdn)
      conditional = stub_request(:get, url).with(headers: { "If-None-Match" => etag }).to_return(status: 304)

      fetcher.fetch(url, key: :ofac_sdn)

      expect(conditional).to have_been_made
    end

    it "sends back the Last-Modified date too" do
      fetcher.fetch(url, key: :ofac_sdn)
      conditional = stub_request(:get, url).with(headers: { "If-Modified-Since" => last_modified })
                                           .to_return(status: 304)

      fetcher.fetch(url, key: :ofac_sdn)

      expect(conditional).to have_been_made
    end

    # The acceptance criterion: the first run downloads, the second does not.
    it "reports 304 as unchanged, with no body to parse" do
      fetcher.fetch(url, key: :ofac_sdn)
      stub_request(:get, url).to_return(status: 304)

      result = fetcher.fetch(url, key: :ofac_sdn)

      expect(result).to be_unchanged.and have_attributes(status: 304, body: nil)
    end

    it "is not a changed list, so a caller keeps the snapshot it has" do
      fetcher.fetch(url, key: :ofac_sdn)
      stub_request(:get, url).to_return(status: 304)

      expect(fetcher.fetch(url, key: :ofac_sdn)).not_to be_changed
    end

    it "counts as a successful fetch even though nothing was transferred" do
      fetcher.fetch(url, key: :ofac_sdn)
      stub_request(:get, url).to_return(status: 304)

      expect(fetcher.fetch(url, key: :ofac_sdn)).to be_ok
    end

    it "keeps the stored validators across a 304" do
      fetcher.fetch(url, key: :ofac_sdn)
      stub_request(:get, url).to_return(status: 304)

      fetcher.fetch(url, key: :ofac_sdn)

      expect(store[:ofac_sdn].etag).to eq(etag)
    end

    it "adopts the new validators when the publisher did change the list" do
      fetcher.fetch(url, key: :ofac_sdn)
      stub_request(:get, url).to_return(status: 200, body: list, headers: { "ETag" => '"7ac1"' })

      fetcher.fetch(url, key: :ofac_sdn)

      expect(store[:ofac_sdn].etag).to eq('"7ac1"')
    end

    it "records that the list changed, not merely that we looked" do
      fetcher.fetch(url, key: :ofac_sdn)
      stub_request(:get, url).to_return(status: 304)
      fetcher.fetch(url, key: :ofac_sdn)

      expect(store[:ofac_sdn].updated_at).to be <= store[:ofac_sdn].checked_at
    end
  end

  describe "a publisher that serves no validators" do
    before { stub_request(:get, url).to_return(status: 200, body: list) }

    it "still comes back as a changed list" do
      expect(fetcher.fetch(url, key: :ofac_sdn)).to be_changed
    end

    # A record with nothing to be conditional about would make #stale? report a
    # usable copy for a source that has to be downloaded in full every time.
    it "stores nothing, having nothing worth storing" do
      fetcher.fetch(url, key: :ofac_sdn)

      expect(store[:ofac_sdn]).to be_nil
    end

    it "reports no validators on the result" do
      expect(fetcher.fetch(url, key: :ofac_sdn).validators).to be_nil
    end

    it "leaves the source stale, which is the truth about it" do
      fetcher.fetch(url, key: :ofac_sdn)

      expect(fetcher).to be_stale(:ofac_sdn)
    end
  end

  describe "a publisher that moves its file" do
    # Sending the old file's ETag to a new address invites a 304 that means
    # nothing at all.
    it "does not send validators stored against a different URL" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      fetcher.fetch(url, key: :ofac_sdn)
      moved = stub_request(:get, "#{url}?v=2").with { |request| !request.headers.key?("If-None-Match") }
                                              .to_return(status: 200, body: list, headers: validators)

      fetcher.fetch("#{url}?v=2", key: :ofac_sdn)

      expect(moved).to have_been_made
    end

    it "re-files the key against the new URL, so only one fetch pays for the move" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      fetcher.fetch(url, key: :ofac_sdn)
      stub_request(:get, "#{url}?v=2").to_return(status: 200, body: list, headers: validators)

      fetcher.fetch("#{url}?v=2", key: :ofac_sdn)

      expect(store[:ofac_sdn].url).to eq("#{url}?v=2")
    end
  end

  describe "force" do
    before do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      fetcher.fetch(url, key: :ofac_sdn)
      WebMock.reset_executed_requests!
    end

    # The acceptance criterion: --force re-downloads even when validators match.
    it "sends no conditional headers, so the publisher cannot answer 304" do
      forced = stub_request(:get, url).with { |request| !request.headers.key?("If-None-Match") }
                                      .to_return(status: 200, body: list, headers: validators)

      fetcher.fetch(url, key: :ofac_sdn, force: true)

      expect(forced).to have_been_made
    end

    it "comes back with a body to parse" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)

      expect(fetcher.fetch(url, key: :ofac_sdn, force: true)).to be_changed
    end

    it "still records what the publisher said, so the next fetch is conditional again" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: { "ETag" => '"7ac1"' })

      fetcher.fetch(url, key: :ofac_sdn, force: true)

      expect(store[:ofac_sdn].etag).to eq('"7ac1"')
    end
  end

  describe "#forget" do
    # The acceptance criterion: deleting stored validators forces a full
    # re-download.
    it "makes the next fetch unconditional" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      fetcher.fetch(url, key: :ofac_sdn)
      fetcher.forget(:ofac_sdn)
      WebMock.reset_executed_requests!
      unconditional = stub_request(:get, url).with { |request| !request.headers.key?("If-None-Match") }
                                             .to_return(status: 200, body: list, headers: validators)

      fetcher.fetch(url, key: :ofac_sdn)

      expect(unconditional).to have_been_made
    end
  end

  describe "statuses the publisher stands behind, and ones it does not" do
    before do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      fetcher.fetch(url, key: :ofac_sdn)
    end

    it "reports a 403 as failed rather than raising" do
      stub_request(:get, url).to_return(status: 403, body: "Forbidden")

      expect(fetcher.fetch(url, key: :ofac_sdn)).to be_failed
    end

    # A bad afternoon at a government file server should not turn into a full
    # re-download of every list.
    it "reports the validators it kept, so a caller can log what is still held" do
      stub_request(:get, url).to_return(status: 403)

      expect(fetcher.fetch(url, key: :ofac_sdn).validators.etag).to eq(etag)
    end

    it "keeps the stored validators through a 403" do
      stub_request(:get, url).to_return(status: 403)

      fetcher.fetch(url, key: :ofac_sdn)

      expect(store[:ofac_sdn].etag).to eq(etag)
    end

    it "keeps them through a 500 the retries could not get past" do
      stub_request(:get, url).to_return(status: 500)

      fetcher.fetch(url, key: :ofac_sdn)

      expect(store[:ofac_sdn].etag).to eq(etag)
    end

    it "leaves a failure fatal for callers that want it to be" do
      stub_request(:get, url).to_return(status: 404)

      expect { fetcher.fetch(url, key: :ofac_sdn).success! }
        .to raise_error(ActiveSanction::HttpClient::ResponseError, /404/)
    end

    it "lets a 304 through #success!, unlike the bare response" do
      stub_request(:get, url).to_return(status: 304)

      expect { fetcher.fetch(url, key: :ofac_sdn).success! }.not_to raise_error
    end
  end

  describe "caller headers" do
    it "passes them through alongside the stored validators" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      fetcher.fetch(url, key: :ofac_sdn)
      stub = stub_request(:get, url).with(headers: { "If-None-Match" => etag, "Accept" => "text/csv" })
                                    .to_return(status: 304)

      fetcher.fetch(url, key: :ofac_sdn, headers: { "Accept" => "text/csv" })

      expect(stub).to have_been_made
    end

    # A caller doing its own conditional request has a reason we do not know.
    it "does not layer a stored ETag on top of one the caller sent" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      fetcher.fetch(url, key: :ofac_sdn)
      stub = stub_request(:get, url).with(headers: { "If-None-Match" => '"theirs"' }).to_return(status: 304)

      fetcher.fetch(url, key: :ofac_sdn, headers: { "if-none-match" => '"theirs"' })

      expect(stub).to have_been_made
    end

    it "learns the validators from a 304 the caller's own headers earned" do
      stub_request(:get, url).with(headers: { "If-None-Match" => '"theirs"' })
                             .to_return(status: 304, headers: { "ETag" => '"theirs"' })

      fetcher.fetch(url, key: :ofac_sdn, headers: { "If-None-Match" => '"theirs"' })

      expect(store[:ofac_sdn].etag).to eq('"theirs"')
    end
  end

  describe "#download" do
    let(:dir) { Dir.mktmpdir("active_sanction") }
    let(:path) { File.join(dir, "SDN.CSV") }

    after { FileUtils.remove_entry(dir) }

    it "streams a changed list to disk" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)

      fetcher.download(url, to: path, key: :ofac_sdn)

      expect(File.read(path)).to eq(list)
    end

    it "sends the stored validators on the next download" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      fetcher.download(url, to: path, key: :ofac_sdn)
      conditional = stub_request(:get, url).with(headers: { "If-None-Match" => etag }).to_return(status: 304)

      fetcher.download(url, to: path, key: :ofac_sdn)

      expect(conditional).to have_been_made
    end

    # The 126 MB file already on disk is the point of asking.
    it "leaves the file alone when the publisher answers 304" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      fetcher.download(url, to: path, key: :ofac_sdn)
      stub_request(:get, url).to_return(status: 304)

      fetcher.download(url, to: path, key: :ofac_sdn)

      expect(File.read(path)).to eq(list)
    end

    it "reports the 304 as unchanged" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      fetcher.download(url, to: path, key: :ofac_sdn)
      stub_request(:get, url).to_return(status: 304)

      expect(fetcher.download(url, to: path, key: :ofac_sdn)).to be_unchanged
    end
  end

  describe "#stale?" do
    it "is true for a source never fetched" do
      expect(fetcher).to be_stale(:ofac_sdn)
    end

    it "is false just after a fetch" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      fetcher.fetch(url, key: :ofac_sdn)

      expect(fetcher).not_to be_stale(:ofac_sdn)
    end

    it "is true once nothing has confirmed the copy within stale_after" do
      store[:ofac_sdn] = ActiveSanction::Validators.new(url: url, etag: etag, checked_at: Time.now - 90_000)

      expect(fetcher).to be_stale(:ofac_sdn)
    end

    # A 304 is the publisher confirming the copy, so it resets the clock even
    # though nothing was transferred.
    it "is false after a 304 refreshed the moment we last asked" do
      store[:ofac_sdn] = ActiveSanction::Validators.new(url: url, etag: etag, checked_at: Time.now - 90_000)
      stub_request(:get, url).to_return(status: 304)
      fetcher.fetch(url, key: :ofac_sdn)

      expect(fetcher).not_to be_stale(:ofac_sdn)
    end

    it "is true when the validators were stored against a different URL" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      fetcher.fetch(url, key: :ofac_sdn)

      expect(fetcher).to be_stale(:ofac_sdn, url: "#{url}?v=2")
    end

    it "honours a caller's own window" do
      store[:ofac_sdn] = ActiveSanction::Validators.new(url: url, etag: etag, checked_at: Time.now - 3600)

      expect(described_class.new(client: client, store: store, stale_after: 60)).to be_stale(:ofac_sdn)
    end

    it "never goes stale on the clock when the window is nil" do
      store[:ofac_sdn] = ActiveSanction::Validators.new(url: url, etag: etag, checked_at: Time.at(0))

      expect(described_class.new(client: client, store: store, stale_after: nil)).not_to be_stale(:ofac_sdn)
    end

    it "answers #fresh? as the inverse, for callers that read better that way" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      fetcher.fetch(url, key: :ofac_sdn)

      expect(fetcher).to be_fresh(:ofac_sdn)
    end

    it "asks the network nothing" do
      expect { fetcher.stale?(:ofac_sdn) }.not_to raise_error
    end
  end

  describe "logging" do
    # A logger here is anything that responds to #info, so the suite collects
    # the lines rather than parsing a formatted stream.
    let(:logger) do
      Class.new do
        def lines
          @lines ||= []
        end

        def info(message) = lines << message
      end.new
    end
    let(:fetcher) { described_class.new(client: client, store: store, logger: logger) }

    # The acceptance criterion: the second sync logs 304. A sync that transfers
    # nothing otherwise looks identical to a sync that did not run.
    it "says so when a list came back unchanged" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)
      fetcher.fetch(url, key: :ofac_sdn)
      stub_request(:get, url).to_return(status: 304)

      fetcher.fetch(url, key: :ofac_sdn)

      expect(logger.lines.join("\n")).to include("ofac_sdn 304 Not Modified")
    end

    it "says so when a list did change" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)

      fetcher.fetch(url, key: :ofac_sdn)

      expect(logger.lines.join("\n")).to include("ofac_sdn 200 changed")
    end

    it "names the failure that kept the stored validators" do
      stub_request(:get, url).to_return(status: 500)

      fetcher.fetch(url, key: :ofac_sdn)

      expect(logger.lines.join("\n")).to include("ofac_sdn 500")
    end

    it "logs nothing at all when none is configured" do
      stub_request(:get, url).to_return(status: 200, body: list, headers: validators)

      expect(described_class.new(client: client, store: store).fetch(url, key: :ofac_sdn)).to be_changed
    end
  end

  describe "defaults" do
    it "persists to disk, so a cron job benefits and not merely a long process" do
      expect(described_class.new.store).to be_a(ActiveSanction::ValidatorStore::FileSystem)
    end

    it "reads its staleness window from the configuration" do
      ActiveSanction.configure { |c| c.stale_after = 3600 }

      expect(described_class.new.stale_after).to eq(3600)
    end

    it "reads its logger from the configuration" do
      logger = Object.new.tap { |object| def object.info(message) = message }
      ActiveSanction.configure { |c| c.logger = logger }

      expect(described_class.new.logger).to be(logger)
    end
  end

  # Excluded from the default run; reachable only via `rspec --tag live`. This
  # is the claim the whole issue rests on -- that every launch source really
  # does honour a conditional GET -- so it is re-verified against the endpoints
  # rather than only against a stub of them.
  describe "against the real endpoints", :live do
    let(:dir) { Dir.mktmpdir("active_sanction") }
    let(:live) { described_class.new(store: ActiveSanction::ValidatorStore::Memory.new) }

    after { FileUtils.remove_entry(dir) }

    {
      ofac_sdn: "https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV",
      un_consolidated: "https://scsanctions.un.org/resources/xml/en/consolidated.xml",
      canada_sema: "https://www.international.gc.ca/world-monde/assets/office_docs/" \
                   "international_relations-relations_internationales/sanctions/sema-lmes.xml"
    }.each do |source, endpoint|
      it "serves both validators for #{source}" do
        path = File.join(dir, source.to_s)

        expect(live.download(endpoint, to: path, key: source).success!)
          .to have_attributes(etag: be_a(String), last_modified: be_a(String))
      end

      it "answers 304 to the second fetch of #{source}" do
        path = File.join(dir, source.to_s)
        live.download(endpoint, to: path, key: source).success!

        expect(live.download(endpoint, to: path, key: source)).to be_unchanged
      end
    end
  end
end
