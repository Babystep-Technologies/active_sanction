# frozen_string_literal: true

RSpec.describe ActiveSanction::Sync do
  after { ActiveSanction.reset! }

  let(:store) { ActiveSanction::Storage::Memory.new }

  def listed(key, id = 1) = FakeSyncSource.entity(key, id)

  # A source that syncs to one record, and one that says nothing has changed.
  def ofac(**options, &block) = FakeSyncSource.new(:ofac_sdn, entities: [listed(:ofac_sdn)], **options, &block)

  def un(**options, &block)
    FakeSyncSource.new(:un_consolidated, entities: [listed(:un_consolidated)], **options, &block)
  end

  def sync(*sources, **options) = described_class.new(sources: sources, store: store, **options).call

  def stored(key) = store.read_snapshot(key)

  def collecting_logger
    Class.new do
      def lines = @lines ||= []
      def info(message) = lines << message
      def warn(message) = lines << message
    end.new
  end

  describe ".new" do
    it "resolves source keys through the registry" do
      expect(described_class.new(sources: %i[ofac_sdn], store: store).sources)
        .to eq([ActiveSanction::Sources::OfacSdn])
    end

    # At the start of the run rather than after the other lists have been
    # downloaded.
    it "raises for a key nothing is registered under" do
      expect { described_class.new(sources: %i[ofac_sdb], store: store) }
        .to raise_error(ActiveSanction::Sources::UnknownSource, /ofac_sdb/)
    end

    it "covers every configured source when it is given none" do
      ActiveSanction.configure { |c| c.sources = %i[un_consolidated] }

      expect(described_class.new(store: store).keys).to eq(%i[un_consolidated])
    end

    it "refuses a concurrency below one" do
      expect { described_class.new(sources: [ofac], store: store, concurrency: 0) }
        .to raise_error(ActiveSanction::ConfigurationError, /at least 1/)
    end
  end

  describe ".call" do
    it "builds a run and returns its report" do
      expect(described_class.call(sources: [ofac], store: store).first.status).to eq(:updated)
    end
  end

  describe "#call" do
    it "returns one result per source, in the order they were given" do
      expect(sync(un, ofac).sources).to eq(%i[un_consolidated ofac_sdn])
    end

    it "stores what each source parsed" do
      sync(ofac, un)

      expect(stored(:ofac_sdn).entities.map(&:id)).to eq(["ofac_sdn:1"])
    end

    it "reports a source that changed as updated, with what is now stored" do
      expect(sync(ofac).first)
        .to have_attributes(status: :updated, record_count: 1, checksum: stored(:ofac_sdn).checksum)
    end

    # The outcome to expect on most runs: these lists change daily at most, and
    # the whole saving of conditional GET is that the parse is skipped with the
    # download.
    it "reports a source whose publisher answered 304 as unchanged" do
      expect(sync(FakeSyncSource.new(:ofac_sdn)).first).to have_attributes(status: :unchanged, record_count: nil)
    end

    # A publisher regenerating an identical file with a new timestamp is not a
    # new list version, and rewriting tens of megabytes to say so would churn
    # the checksum every audit record cites.
    it "reports a source that re-served identical content as unchanged" do
      source = ofac
      sync(source)

      expect(sync(source).first).to have_attributes(status: :unchanged, record_count: 1)
    end

    it "leaves the stored snapshot alone when the content did not change" do
      source = ofac
      before = sync(source).first.fetched_at

      expect(sync(source).first.fetched_at).to eq(before)
    end

    it "counts the records stored across every source it covered" do
      expect(sync(ofac, un).record_count).to eq(2)
    end
  end

  # The reason this class exists. Government endpoints go down, change format,
  # and occasionally serve half a file.
  describe "per-source isolation" do
    def failing(key = :un_consolidated, message = "503 from the publisher")
      FakeSyncSource.new(key, error: ActiveSanction::FetchError.new(message, status: 503))
    end

    # A source whose constructor raises: a store it cannot open, a credential
    # it cannot read.
    def unbuildable(name)
      Class.new do
        define_singleton_method(:key) { name }
        def initialize = raise(ActiveSanction::ConfigurationError, "no credentials")
      end
    end

    it "completes the other sources when one fails" do
      expect(sync(failing, ofac).map(&:status)).to eq(%i[failed updated])
    end

    it "stores the sources that succeeded" do
      sync(failing, ofac)

      expect(stored(:ofac_sdn)).not_to be_nil
    end

    it "reports the failure with the class and message that caused it" do
      expect(sync(failing).first)
        .to have_attributes(status: :failed, error: "ActiveSanction::FetchError: 503 from the publisher")
    end

    it "keeps the exception itself for a caller that wants the backtrace" do
      expect(sync(failing).first.exception).to be_a(ActiveSanction::FetchError)
    end

    it "answers failed? and a non-zero exit code for the run" do
      expect(sync(failing, ofac)).to have_attributes(failed?: true, exit_code: 1)
    end

    it "answers a zero exit code when every source answered" do
      expect(sync(ofac, un)).to have_attributes(failed?: false, exit_code: 0)
    end

    # A source whose constructor raises -- a store it cannot open, a
    # credential it cannot read -- is that source's failure and not the run's,
    # which is why adapters are built inside the rescue rather than up front.
    it "isolates a source that cannot even be built" do
      expect(sync(unbuildable(:canada_sema), ofac).map(&:status)).to eq(%i[failed updated])
    end

    # Which means reading what is stored before building the adapter, so that
    # a constructor failure does not report a source as having nothing.
    it "reports what a source that cannot be built is still screening against" do
      sync(ofac)

      expect(sync(unbuildable(:ofac_sdn)).first).to have_attributes(status: :failed, retained?: true,
                                                                    record_count: 1)
    end

    # Isolation is StandardError. An Interrupt is somebody stopping this run on
    # purpose, and swallowing it to go on downloading three more lists is not
    # isolation, it is a job that will not die.
    it "does not swallow an interrupt" do
      expect { sync(FakeSyncSource.new(:ofac_sdn, error: Interrupt.new)) }.to raise_error(Interrupt)
    end
  end

  # Stale data with a visible age beats no data. This is the single most
  # important behaviour in the class.
  describe "a failed source keeps its previous snapshot" do
    def kept
      source = ofac
      sync(source)
      source.error = ActiveSanction::FetchError.new("503 from the publisher", status: 503)
      sync(source).first
    end

    it "leaves the stored list exactly as it was" do
      result = kept

      expect(stored(:ofac_sdn).checksum).to eq(result.checksum)
    end

    it "reports what is still being screened against" do
      expect(kept).to have_attributes(status: :failed, record_count: 1, retained?: true, stored?: true)
    end

    it "reports the age of what is still being screened against" do
      expect(kept.age).to be_a(Integer)
    end

    # Louder than a failure and rarer: a source that failed but kept its
    # previous list is stale, one with nothing stored is not screened at all.
    it "says when a failed source has nothing stored behind it" do
      report = sync(FakeSyncSource.new(:un_consolidated, error: ActiveSanction::FetchError.new("503", status: 503)))

      expect(report.unscreenable.map(&:source)).to eq(%i[un_consolidated])
    end
  end

  describe "conditional fetching" do
    it "fetches conditionally once a source has a stored snapshot" do
      source = ofac
      sync(source)
      sync(source)

      expect(source.calls).to eq([true, false])
    end

    # A conditional request asks the publisher whether the copy we hold is
    # current, and we do not hold one.
    it "fetches in full when nothing is stored for a source" do
      expect(ofac.tap { |source| sync(source) }.calls).to eq([true])
    end

    it "fetches in full when the stored snapshot cannot be read" do
      source = ofac
      sync(source)
      allow(store).to receive(:snapshot_meta).and_raise(ActiveSanction::Storage::CorruptSnapshot, "truncated")

      expect { sync(source) }.to change(source, :calls).to([true, true])
    end

    it "sends no validators for any source when the run is forced" do
      source = ofac
      sync(source)

      expect { sync(source, force: true) }.to change(source, :calls).to([true, true])
    end
  end

  describe "progress reporting" do
    it "calls the block with each result as that source finishes" do
      seen = []
      described_class.new(sources: [ofac, un], store: store).call { |result| seen << result.source }

      expect(seen).to eq(%i[ofac_sdn un_consolidated])
    end

    it "logs what each source did" do
      logger = collecting_logger
      described_class.new(sources: [ofac], store: store, logger: logger).call

      expect(logger.lines).to include(a_string_matching(/ofac_sdn updated in .*: 1 records/))
    end

    # The line an on-call engineer reads at three in the morning has to say
    # what is still being screened against, not merely that something broke.
    it "logs the snapshot a failed source kept" do
      logger = collecting_logger
      source = ofac
      described_class.new(sources: [source], store: store, logger: logger).call
      source.error = ActiveSanction::FetchError.new("503", status: 503)
      described_class.new(sources: [source], store: store, logger: logger).call

      expect(logger.lines).to include(a_string_matching(/keeping the previous snapshot of 1 records/))
    end
  end

  describe "parallel fetching" do
    # Counts how many sources are inside #sync at once rather than racing on a
    # rendezvous, so a run that turns out to be sequential fails the example
    # instead of hanging it.
    def peak_concurrency(*sources, **options)
      peak = 0
      active = 0
      lock = Mutex.new
      counter = lambda do |_source|
        lock.synchronize { peak = [peak, active += 1].max }
        sleep 0.05
        lock.synchronize { active -= 1 }
      end
      sync(*sources.map { |key, host| FakeSyncSource.new(key, host: host, &counter) }, **options)
      peak
    end

    it "fetches from two publishers at once" do
      expect(peak_concurrency([:ofac_sdn, "treasury.test"], [:un_consolidated, "un.test"], concurrency: 2)).to eq(2)
    end

    # Two of the built-in adapters are the same government file server, and
    # raising concurrency must not mean asking one publisher harder.
    it "never fetches two lists from one publisher at once" do
      expect(peak_concurrency([:ofac_sdn, "treasury.test"], [:ofac_consolidated, "treasury.test"],
                              concurrency: 4)).to eq(1)
    end

    it "runs sequentially by default" do
      expect(peak_concurrency([:ofac_sdn, "treasury.test"], [:un_consolidated, "un.test"])).to eq(1)
    end

    it "returns results in the order the sources were given" do
      report = described_class.new(sources: [un, ofac], store: store, concurrency: 2).call

      expect(report.sources).to eq(%i[un_consolidated ofac_sdn])
    end

    it "stores every source it covered" do
      described_class.new(sources: [un, ofac], store: store, concurrency: 2).call

      expect(store.sources).to eq(%i[ofac_sdn un_consolidated])
    end
  end

  # Everything above stands in for the network. This section runs the whole
  # path -- conditional GET, parse, checksum, store -- against WebMock and the
  # committed fixture, because the value of isolating sources is in what
  # happens when a real file server answers 500.
  describe "over the real fetch path" do
    let(:fetcher) do
      ActiveSanction::Fetcher.new(client: ActiveSanction::HttpClient.new(retry_backoff: 0.001),
                                  store: ActiveSanction::ValidatorStore::Memory.new)
    end

    def payload = File.read("spec/fixtures/contract_example/list.csv")

    def validators = { "ETag" => '"v1"' }

    def adapter(name, address)
      Class.new(ContractExampleSource) do
        key name
        url :main, address
      end.new(fetcher: fetcher, cache: nil)
    end

    def one = adapter(:example_one, "https://one.test/list.csv")

    def two = adapter(:example_two, "https://two.test/list.csv")

    it "stores the source that answered when the other server is down" do
      stub_request(:get, "https://one.test/list.csv").to_return(status: 200, body: payload, headers: validators)
      stub_request(:get, "https://two.test/list.csv").to_return(status: 500, body: "")

      expect(sync(one, two).map(&:status)).to eq(%i[updated failed])
    end

    it "parses the list it downloaded into the store" do
      stub_request(:get, "https://one.test/list.csv").to_return(status: 200, body: payload, headers: validators)

      expect(sync(one).first).to have_attributes(status: :updated, record_count: 3)
    end

    it "reports every source unchanged on a second consecutive sync" do
      stub_request(:get, "https://one.test/list.csv").to_return(status: 200, body: payload, headers: validators)
      source = one
      sync(source)
      stub_request(:get, "https://one.test/list.csv").with(headers: { "If-None-Match" => '"v1"' })
                                                     .to_return(status: 304)

      expect(sync(source).map(&:status)).to eq([:unchanged])
    end

    it "keeps the previous snapshot when a source starts failing" do
      stub_request(:get, "https://one.test/list.csv").to_return(status: 200, body: payload, headers: validators)
      source = one
      sync(source)
      stub_request(:get, "https://one.test/list.csv").to_return(status: 500, body: "")

      expect(sync(source).first).to have_attributes(status: :failed, record_count: 3, retained?: true)
    end
  end
end
