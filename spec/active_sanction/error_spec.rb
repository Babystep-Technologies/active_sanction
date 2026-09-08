# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# The public error API. Everything here is a promise to a host application
# embedding this library in a request path, which is why it is tested as a
# whole rather than one class at a time: what a caller relies on is that
# *nothing* escapes the hierarchy, and that is not a property any single
# error's spec can hold.
RSpec.describe ActiveSanction::Error do
  after { ActiveSanction.reset! }

  # Whatever the block raised, for an example that has one thing to say about
  # it. `expect { }.to raise_error(Klass) { |e| ... }` is two expectations for
  # one claim, and the claim here is usually about the attributes.
  def raised
    yield
    nil
  rescue StandardError => e
    e
  end

  # Every module and class defined anywhere under ActiveSanction. Walked rather
  # than listed: a list would go stale the first time somebody added an error
  # without reading this file.
  def namespace(root = ActiveSanction, seen = {})
    root.constants.filter_map { |constant| resolve(root, constant) }.each do |value|
      name = Module.instance_method(:name).bind_call(value).to_s
      next if !name.start_with?("ActiveSanction") || seen.key?(name)

      seen[name] = value
      namespace(value, seen)
    end
    seen.values
  end

  # `name` through Module, and `const_get` guarded, because a class in here is
  # free to define either of its own -- a source declaration does exactly that.
  def resolve(root, constant)
    value = root.const_get(constant, false)
    value.is_a?(Module) ? value : nil
  rescue StandardError
    nil
  end

  describe "the hierarchy" do
    it "covers every exception class the library defines" do
      exceptions = namespace.grep(Class).select { |klass| klass <= Exception }

      expect(exceptions.reject { |klass| klass <= described_class }).to be_empty
    end

    # The point of the whole thing: one rescue, whatever went wrong.
    it "is one rescue" do
      classes = [
        ActiveSanction::ConfigurationError, ActiveSanction::SourceError, ActiveSanction::FetchError,
        ActiveSanction::ParseError, ActiveSanction::IntegrityError, ActiveSanction::StorageError,
        ActiveSanction::UnsupportedError, ActiveSanction::InvalidArgument, ActiveSanction::QueryError,
        ActiveSanction::MissingKey
      ]

      expect(classes.map { |klass| rescued(klass) }).to eq(classes)
    end

    # A caller who passed a bad threshold has made the mistake Ruby has had a
    # class for since 1995, and the code around this library already says
    # `rescue ArgumentError`. Being both is the reason Error is a module.
    it "keeps Ruby's own answer for a call that is simply wrong" do
      expect(ActiveSanction::QueryError.new("x")).to be_a(ArgumentError)
    end

    it "keeps Ruby's own answer for a field that does not exist" do
      expect(ActiveSanction::MissingKey.new("x")).to be_a(KeyError)
    end

    it "files a transport failure under fetching" do
      expect(ActiveSanction::HttpClient::TimeoutError.new("x")).to be_a(ActiveSanction::FetchError)
    end

    it "files a checksum mismatch under integrity" do
      expect(ActiveSanction::Snapshot::ChecksumMismatch.new("x")).to be_a(ActiveSanction::IntegrityError)
    end

    it "files an unreadable store under storage" do
      expect(ActiveSanction::Storage::MissingSnapshot.new("x")).to be_a(ActiveSanction::StorageError)
    end

    it "files a mistyped source key under configuration" do
      expect(ActiveSanction::Sources::UnknownSource.new("x")).to be_a(ActiveSanction::ConfigurationError)
    end

    # The toolkits raise it by their own name; a caller rescues the one class.
    it "gives the parser toolkits the same ParseError the rest of the library uses" do
      expect(ActiveSanction::Parsers::ParseError).to equal(ActiveSanction::ParseError)
    end

    def rescued(klass)
      raise klass, "x"
    rescue described_class => e
      e.class
    end
  end

  describe "structured attributes" do
    it "carries the list a failure belongs to" do
      expect(ActiveSanction::FetchError.new("down", source_id: "ofac_sdn").source_id).to eq(:ofac_sdn)
    end

    it "carries the status a server produced" do
      expect(ActiveSanction::FetchError.new("down", status: 503).status).to eq(503)
    end

    it "leaves both nil where there was neither" do
      expect(ActiveSanction::QueryError.new("bad")).to have_attributes(source_id: nil, status: nil)
    end

    # For the log line or the job record that has to outlive the process.
    it "renders as data" do
      error = ActiveSanction::FetchError.new("down", source_id: :ofac_sdn, status: 503)

      expect(error.to_h).to eq(error: "ActiveSanction::FetchError", message: "down",
                               source_id: :ofac_sdn, status: 503, retryable: true)
    end

    it "omits what it does not know rather than serializing nils" do
      expect(ActiveSanction::QueryError.new("bad").to_h.keys).to eq(%i[error message retryable])
    end
  end

  describe "#retryable?" do
    def fetch(status) = ActiveSanction::FetchError.new("x", status: status)

    it "says yes to a publisher having a bad afternoon" do
      expect([fetch(500), fetch(503), fetch(429), fetch(408)].map(&:retryable?)).to all(be(true))
    end

    # Repeating a request the server has already told us is wrong wastes the
    # publisher's capacity to make the same point.
    it "says no to a request that will be just as wrong in ten minutes" do
      expect([fetch(400), fetch(403), fetch(404)].map(&:retryable?)).to all(be(false))
    end

    it "says yes to a timeout and a refused connection, which produced no status" do
      expect([ActiveSanction::HttpClient::TimeoutError.new("x"),
              ActiveSanction::HttpClient::ConnectionError.new("x")].map(&:retryable?)).to all(be(true))
    end

    # A misrouted URL is routed the same way on the next attempt.
    it "says no to a redirect chain that does not terminate" do
      expect(ActiveSanction::HttpClient::RedirectLoop.new("x").retryable?).to be(false)
    end

    it "says no by default, since an unclassified failure is one to look at" do
      expect([ActiveSanction::ParseError.new("x"), ActiveSanction::StorageError.new("x"),
              ActiveSanction::QueryError.new("x")].map(&:retryable?)).to all(be(false))
    end

    it "lets the raising code override the classification" do
      expect(ActiveSanction::ParseError.new("x", retryable: true).retryable?).to be(true)
    end

    # Nothing about waiting changes an initializer.
    it "never says yes to a misconfiguration, even when told to" do
      expect(ActiveSanction::ConfigurationError.new("x", retryable: true).retryable?).to be(false)
    end
  end

  describe "a parse error points at where" do
    it "names the line" do
      expect(ActiveSanction::ParseError.new("not XML", line: 418_223).locator).to eq("line 418223")
    end

    # The locator that means something for a format with no lines.
    it "names the record for a format that has no lines" do
      expect(ActiveSanction::ParseError.new("x", record: 12_004).locator).to eq("record 12004")
    end

    it "names the byte for a payload that is not text" do
      expect(ActiveSanction::ParseError.new("x", offset: 8_388_608).locator).to eq("byte 8388608")
    end

    it "says nothing rather than pointing at the wrong line" do
      expect(ActiveSanction::ParseError.new("x").locator).to be_nil
    end

    # So that a log line carrying only the message still says where.
    it "appends the locator to the message" do
      expect(ActiveSanction::ParseError.new("no root element", line: 12).message)
        .to eq("no root element (at line 12)")
    end

    it "serializes the locator with the rest" do
      expect(ActiveSanction::ParseError.new("x", line: 12, record: 3).to_h).to include(line: 12, record: 3)
    end
  end

  describe "#in_source" do
    it "stamps the list onto a failure raised by a layer that could not know" do
      expect(ActiveSanction::FetchError.new("down").in_source(:ofac_sdn).source_id).to eq(:ofac_sdn)
    end

    # The innermost layer that knew is the one that was right.
    it "never overwrites a source already recorded" do
      error = ActiveSanction::FetchError.new("down", source_id: :ofac_sdn)

      expect(error.in_source(:un_consolidated).source_id).to eq(:ofac_sdn)
    end
  end

  # The half of the promise that cannot be tested by constructing errors: that
  # the exception classes of net/http, csv, rexml and json never reach a caller.
  describe "what a public method actually raises" do
    let(:cache_dir) { Dir.mktmpdir("active_sanction_errors") }
    let(:url) { "https://example.test/contract.csv" }

    let(:source) do
      client = ActiveSanction::HttpClient.new(retry_backoff: 0.001, max_retries: 0)
      fetcher = ActiveSanction::Fetcher.new(client: client, store: ActiveSanction::ValidatorStore::Memory.new)
      ContractExampleSource.new(fetcher: fetcher, cache: ActiveSanction::PayloadCache.new(dir: cache_dir))
    end

    after { FileUtils.remove_entry(cache_dir) if File.directory?(cache_dir) }

    def serve(status, body = "")
      stub_request(:get, url).to_return(status: status, body: body)
    end

    it "raises a retryable FetchError naming the list when the publisher is down" do
      serve(503)

      expect(raised { source.sync })
        .to be_a(ActiveSanction::FetchError)
        .and have_attributes(status: 503, retryable?: true, source_id: :contract_example)
    end

    it "raises a FetchError that is not retryable for a request the server refused" do
      serve(403)

      expect(raised { source.sync })
        .to be_a(ActiveSanction::FetchError).and have_attributes(status: 403, retryable?: false)
    end

    # The classic: a moved URL, and an error page served where a list used to
    # be. A sync that read that as "nobody is sanctioned today" is the most
    # expensive thing this library can do, so it raises -- as a ParseError
    # naming the list, rather than as whatever `csv` felt like raising.
    it "raises a ParseError naming the list for a payload that is not a list" do
      serve(200, "   ")

      expect(raised { source.sync })
        .to be_a(ActiveSanction::ParseError).and have_attributes(source_id: :contract_example)
    end

    it "raises a ParseError, not a CSV error, and says which line it gave up on" do
      table = ActiveSanction::Parsers::DelimitedTable.new(columns: %i[a b], liberal_parsing: false)
      body = (1..150).map { |i| %(#{i},ok"x) }.join("\n")

      expect(raised { table.read(body).to_a })
        .to be_a(ActiveSanction::ParseError).and have_attributes(locator: "line 1")
    end

    it "raises a ParseError, not a REXML error, for a payload that is not XML" do
      table = ActiveSanction::Parsers::XmlRecords.new(records: "INDIVIDUAL")

      expect(raised { table.read("<!DOCTYPE html><html><body>Access Denied<br>x</body></html>").to_a })
        .to be_a(ActiveSanction::ParseError)
    end

    it "raises a StorageError, not a JSON error, for a stored list that is not readable" do
      Dir.mktmpdir("active_sanction_store") do |dir|
        store = ActiveSanction::Storage::FileSystem.new(root: dir)
        store.write_snapshot(source.snapshot(File.read("spec/fixtures/contract_example/list.csv")))
        File.binwrite(Dir.glob(File.join(dir, "contract_example", "*.json")).first, "{")

        expect(raised { store.snapshot_meta(:contract_example) }).to be_a(ActiveSanction::StorageError)
      end
    end

    it "raises a QueryError for a screening call that cannot be run" do
      expect { ActiveSanction::Query.new(name: "Vladimir Putin", threshold: 300) }
        .to raise_error(ActiveSanction::QueryError, /between 0 and 100/)
    end
  end

  describe "a run that had failures in it" do
    let(:store) { ActiveSanction::Storage::Memory.new }

    def run(error)
      source = FakeSyncSource.new(:un_consolidated, error: error)
      ActiveSanction::Sync.new(sources: [source], store: store).call
    end

    it "names the source on the exception it captured" do
      report = run(ActiveSanction::FetchError.new("503", status: 503))

      expect(report.failed.first.exception.source_id).to eq(:un_consolidated)
    end

    # Worth re-running: nothing about the list was wrong, the publisher was.
    it "reports the run as retryable when every failure in it was" do
      report = run(ActiveSanction::FetchError.new("503", status: 503))

      expect(raised { report.success! })
        .to be_a(ActiveSanction::Sync::Failed).and have_attributes(retryable?: true)
    end

    # Re-running a parse failure five minutes later produces the same failure.
    it "reports the run as not retryable when any failure in it was not" do
      report = run(ActiveSanction::ParseError.new("half a file"))

      expect(raised { report.success! })
        .to be_a(ActiveSanction::Sync::Failed).and have_attributes(retryable?: false)
    end
  end
end
