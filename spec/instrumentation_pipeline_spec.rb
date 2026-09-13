# frozen_string_literal: true

# Not a spec for a class: this is #59's acceptance criterion, which is about
# the *sequence* rather than about any one emitter.
#
# A host subscribes once and expects to be able to answer the operational
# questions end to end -- is the data fresh, did a fetch fail, how long did
# screening take, which source is degrading. No single unit spec can show
# that, because the six events come from six classes that do not know about
# each other: the fetcher does not know it is inside a sync, and the matcher
# does not know a list was stored an hour ago. What a subscriber sees is a
# property of the assembled library, so it is asserted against the assembled
# library, over the real fetch path and a committed fixture.
RSpec.describe "the events a host sees across a sync and a screen" do
  after do
    ActiveSanction::Instrumentation.reset!
    ActiveSanction.reset!
  end

  let(:events) { [] }

  let(:store) { ActiveSanction::Storage::Memory.new }

  let(:url) { "https://example.test/contract.csv" }

  def payload = File.read("spec/fixtures/contract_example/list.csv")

  def subscribe
    ActiveSanction.configure { |c| c.instrumenter = ->(event) { events << event } }
  end

  # The contract example adapter, with the payload cache and the validator
  # store kept in memory so an example leaves nothing on the developer's disk.
  def source
    ContractExampleSource.new(
      fetcher: ActiveSanction::Fetcher.new(client: ActiveSanction::HttpClient.new(retry_backoff: 0.001),
                                           store: ActiveSanction::ValidatorStore::Memory.new),
      cache: nil
    )
  end

  def serve(status: 200, body: nil)
    stub_request(:get, url).to_return(status: status, body: body || payload, headers: { "ETag" => '"v1"' })
  end

  def sync(adapter = source) = ActiveSanction::Sync.new(sources: [adapter], store: store).call

  def named(name) = events.select { |event| event.name == name }

  def one(name) = named(name).first

  describe "a sync that downloads and stores a list" do
    before do
      subscribe
      serve
      sync
    end

    it "emits every stage of the run, in the order they happened" do
      expect(events.map(&:name)).to eq(%i[fetch parse store sync])
    end

    # Nothing here is an anonymous timing.
    it "puts a duration on every one of them" do
      expect(events.map(&:duration)).to all(be_a(Float))
    end

    it "names the list on every event that is about one" do
      expect(named(:fetch) + named(:parse) + named(:store)).to all(have_attributes(source: :contract_example))
    end

    describe "the fetch event" do
      it "says what the publisher answered and how much came back" do
        expect(one(:fetch)).to have_attributes(payload: include(status: 200, not_modified: false,
                                                                bytes: payload.bytesize))
      end

      it "names the URL that was actually asked for" do
        expect(one(:fetch)[:url]).to eq(url)
      end

      it "says the request carried no validators, because nothing was stored yet" do
        expect(one(:fetch)[:conditional]).to be(false)
      end
    end

    describe "the parse event" do
      it "counts the records that came out and the rows that could not be read" do
        expect(one(:parse)).to have_attributes(payload: include(records: 3, warnings: 0))
      end

      it "says how large the document was" do
        expect(one(:parse)[:bytes]).to eq(payload.bytesize)
      end
    end

    describe "the store event" do
      it "names the list version that was written" do
        expect(one(:store)[:snapshot_id]).to eq(store.read_snapshot(:contract_example).checksum)
      end

      it "counts what was written, and says where" do
        expect(one(:store)).to have_attributes(payload: include(entities: 3, store: "ActiveSanction::Storage::Memory"))
      end
    end

    describe "the sync event" do
      it "reports what each source did" do
        expect(one(:sync)[:outcomes]).to eq({ contract_example: :updated })
      end

      it "counts the run" do
        expect(one(:sync)).to have_attributes(payload: include(updated: 1, unchanged: 0, failed: 0, records: 3))
      end

      # The aggregate covers the stages inside it, which is what lets a host
      # ask what fraction of a run was spent downloading.
      it "lasts at least as long as the stages it contains" do
        expect(one(:sync).duration).to be >= named(:fetch).sum(&:duration)
      end
    end
  end

  describe "a sync whose publisher says nothing changed" do
    before do
      subscribe
      serve
      adapter = source
      sync(adapter)
      events.clear
      stub_request(:get, url).with(headers: { "If-None-Match" => '"v1"' }).to_return(status: 304)
      sync(adapter)
    end

    # The whole saving of conditional GET is that the parse is skipped along
    # with the download, and the events have to show that rather than reporting
    # a parse of nothing.
    it "emits a fetch and the run, and neither a parse nor a store" do
      expect(events.map(&:name)).to eq(%i[fetch sync])
    end

    it "says the publisher answered 304 and no bytes moved" do
      expect(one(:fetch)).to have_attributes(payload: include(status: 304, not_modified: true, bytes: 0))
    end

    it "reports the source unchanged" do
      expect(one(:sync)[:outcomes]).to eq({ contract_example: :unchanged })
    end
  end

  describe "a sync whose publisher is failing" do
    before do
      subscribe
      stub_request(:get, url).to_return(status: 500, body: "")
      sync
    end

    # Which source is degrading is most of what this exists for, so a failing
    # publisher is an event rather than a silence. It carries no `error`: the
    # round trip completed and the publisher answered, which is a different
    # fact from a connection that never opened, and the status is what says
    # the answer was not usable.
    it "still emits the fetch, saying what the publisher answered" do
      expect(one(:fetch)).to have_attributes(payload: include(status: 500), failed?: false)
    end

    it "still emits the run" do
      expect(one(:sync)[:outcomes]).to eq({ contract_example: :failed })
    end

    it "emits no store, because nothing was written" do
      expect(named(:store)).to be_empty
    end

    # The library's own exception is not swallowed by having been observed;
    # it is captured into the report exactly as it is without a subscriber.
    it "leaves the report saying what happened" do
      expect(sync).to have_attributes(failed?: true)
    end
  end

  describe "screening what was synced" do
    let(:client) do
      ActiveSanction::Client.new(storage: store, sources: %i[contract_example],
                                 instrumenter: ->(event) { events << event })
    end

    before do
      serve
      sync
      client.screen(name: "John Okoro", threshold: 0)
    end

    it "emits the index build and then the query" do
      expect(events.map(&:name)).to eq(%i[index.build screen])
    end

    describe "the index.build event" do
      it "counts the entities indexed and the names they carry" do
        expect(one(:"index.build")).to have_attributes(payload: include(entities: 3, names: be_positive))
      end

      it "counts the distinct keys across the three feature spaces" do
        expect(one(:"index.build")[:keys]).to be_positive
      end

      it "estimates what the index is holding" do
        expect(one(:"index.build")[:bytes]).to be_positive
      end

      it "names the lists it indexed, and the version of each" do
        stamped = { contract_example: store.read_snapshot(:contract_example).checksum }

        expect(one(:"index.build"))
          .to have_attributes(payload: include(sources: %i[contract_example], snapshots: stamped))
      end
    end

    describe "the screen event" do
      it "counts what was retrieved and what came back" do
        expect(one(:screen)).to have_attributes(payload: include(candidates: be_positive, results: be_positive))
      end

      it "records the threshold and the cap the query ran under" do
        expect(one(:screen)).to have_attributes(payload: include(threshold: 0.0, limit: be_positive))
      end

      # The same question every MatchResult is stamped with, and the only one
      # a result set of zero cannot answer for itself.
      it "names the list versions it consulted" do
        expect(one(:screen)[:snapshots]).to eq({ contract_example: store.read_snapshot(:contract_example).checksum })
      end

      it "emits one event per query in a batch" do
        events.clear
        client.screen_all(["John Okoro", "Jane Miller"])

        expect(events.map(&:name)).to eq(%i[screen screen])
      end
    end
  end

  # A client is what a server holds, and its subscriber has to be the one its
  # own work reports to -- not the default client's, and not nothing.
  describe "two clients with two subscribers" do
    let(:other) { [] }

    before do
      serve
      sync
    end

    it "reports each client's screening to its own subscriber" do
      ActiveSanction::Client.new(storage: store, instrumenter: ->(event) { events << event }).screen("John Okoro")
      ActiveSanction::Client.new(storage: store, instrumenter: ->(event) { other << event }).screen("John Okoro")

      expect([events.map(&:name), other.map(&:name)]).to eq([%i[index.build screen], %i[index.build screen]])
    end

    it "reports nothing for a client that named no subscriber" do
      ActiveSanction::Client.new(storage: store).screen("John Okoro")

      expect(events).to be_empty
    end
  end
end
