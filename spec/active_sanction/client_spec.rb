# frozen_string_literal: true

require "openssl"
require "tmpdir"

RSpec.describe ActiveSanction::Client do
  after do
    ActiveSanction.reset!
    ActiveSanction::Sources.unregister(:demo_list)
  end

  def entity(source, id, name)
    ActiveSanction::Entity.new(
      id: "#{source}:#{id}", source: source, type: :individual,
      names: [ActiveSanction::Name.new(value: name)]
    )
  end

  def ntaganda(source = :ofac_sdn) = entity(source, 1, "NTAGANDA, Bosco")
  def gazprom(source = :un_consolidated) = entity(source, 2, "GAZPROM NEFT")

  # A store holding one snapshot per source it is given.
  def store(**lists)
    ActiveSanction::Storage::Memory.new.tap do |memory|
      lists.each do |source, entities|
        memory.write_snapshot(ActiveSanction::Snapshot.new(source: source, entities: entities))
      end
    end
  end

  def both = store(ofac_sdn: [ntaganda], un_consolidated: [gazprom])

  # A registered adapter with the network taken out, so that a sync given no
  # arguments has a list of its own to resolve `config.sources` against.
  def register_demo_list
    adapter = Class.new do
      def self.key = :demo_list
      def key = :demo_list
      def urls = { main: "https://example.test/demo_list.csv" }

      # Takes the `force:` a run passes and ignores it -- nothing here fetches.
      def sync(**)
        ActiveSanction::Snapshot.new(source: :demo_list, entities: [FakeSyncSource.entity(:demo_list)])
      end
    end
    ActiveSanction::Sources.register(adapter)
  end

  describe ".new" do
    it "freezes the configuration it built, so a client's settings cannot move under it" do
      expect(described_class.new(user_agent: "acme/1.0").configuration).to be_frozen
    end

    it "takes every setting `configure` takes as a keyword argument" do
      client = described_class.new(user_agent: "acme/1.0", screening_threshold: 90, sources: %i[ofac_sdn])

      expect(client.configuration)
        .to have_attributes(user_agent: "acme/1.0", screening_threshold: 90.0, sources: %i[ofac_sdn])
    end

    it "holds a setting to the same rule `configure` holds it to, and fails with the same message" do
      expect { described_class.new(user_agent: " ") }
        .to raise_error(ActiveSanction::ConfigurationError, /user_agent is required/)
    end

    # A setting that is quietly dropped is a client running on a default
    # somebody thinks they changed.
    it "raises on a setting it does not have rather than ignoring it" do
      expect { described_class.new(user_agnet: "acme/1.0") }
        .to raise_error(ActiveSanction::ConfigurationError, /unknown setting\(s\): user_agnet/)
    end

    it "freezes a configuration handed to it, so the object a `configure` block wrote to is the one held" do
      settings = ActiveSanction::Configuration.new

      expect(described_class.new(configuration: settings).configuration).to be(settings)
    end

    it "leaves a configuration it was given overrides for alone" do
      settings = ActiveSanction::Configuration.new
      described_class.new(configuration: settings, user_agent: "acme/1.0")

      expect(settings).to have_attributes(frozen?: false, user_agent: ActiveSanction::Configuration::DEFAULT_USER_AGENT)
    end

    it "records where screening happens, for the seam a hosted backend arrives at" do
      expect(described_class.new.backend).to eq(:local)
    end
  end

  describe "#with" do
    it "derives a client with one setting changed" do
      client = described_class.new(user_agent: "acme/1.0", sources: %i[ofac_sdn])

      expect(client.with(sources: %i[un_consolidated]).configuration)
        .to have_attributes(user_agent: "acme/1.0", sources: %i[un_consolidated])
    end

    it "leaves the client it came from as it was" do
      client = described_class.new(storage: both, sources: %i[ofac_sdn])
      client.with(sources: %i[un_consolidated])

      expect(client.sources).to eq(%i[ofac_sdn])
    end

    it "shares no matcher with it, which is what makes the pair independent" do
      client = described_class.new(storage: both, sources: %i[ofac_sdn])

      expect(client.with(sources: %i[un_consolidated]).matcher).not_to be(client.matcher)
    end
  end

  describe "#screen" do
    it "screens against its own store" do
      client = described_class.new(storage: both)

      expect(client.screen("Bosco Ntaganda").first.entity.id).to eq("ofac_sdn:1")
    end

    # The acceptance criterion this class exists for: one tenant's obligations
    # are not the next one's, and neither may answer out of the other's lists.
    it "screens two source sets over one store without either seeing the other's lists" do
      ofac = described_class.new(storage: both, sources: %i[ofac_sdn])
      un = described_class.new(storage: both, sources: %i[un_consolidated])

      expect([ofac.screen("Gazprom Neft"), un.screen("Bosco Ntaganda")]).to eq([[], []])
    end

    # The other half of the acceptance criterion, and the reason the hosted
    # service needs this: an audit re-run screens against the list version a
    # decision was actually made under, beside live traffic on today's.
    it "screens a pinned list version beside the current one" do
      current = described_class.new(storage: store(ofac_sdn: [ntaganda]))
      january = described_class.new(storage: store(ofac_sdn: [ntaganda, gazprom(:ofac_sdn)]))

      expect([current, january].map { |client| client.screen("Gazprom Neft").size }).to eq([0, 1])
    end

    # The proof that a client's settings reach the query path rather than only
    # its store: a threshold is read when a Query is built, three layers below
    # anything that was handed this client.
    it "defaults a query to its own threshold, not the default client's" do
      client = described_class.new(storage: both, screening_threshold: 99)

      expect(client.screen("Bosco Ntaganda")).to eq([])
    end

    it "leaves the default client's threshold where it found it" do
      described_class.new(storage: both, screening_threshold: 99).screen("Bosco Ntaganda")

      expect(ActiveSanction.config.screening_threshold)
        .to eq(ActiveSanction::Configuration::DEFAULT_SCREENING_THRESHOLD)
    end

    it "takes the search options a matcher takes" do
      expect(described_class.new(storage: both).screen(name: "Bosco Ntaganda", threshold: 99)).to eq([])
    end

    it "raises rather than reporting clear when nothing has been synced" do
      client = described_class.new(storage: ActiveSanction::Storage::Memory.new)

      expect { client.screen("Bosco Ntaganda") }.to raise_error(ActiveSanction::Matcher::NotSynced)
    end
  end

  describe "#screen_all" do
    it "returns one array of results per name" do
      client = described_class.new(storage: both)

      expect(client.screen_all(["Bosco Ntaganda", "Jane Wilson of Dorset"]).map(&:size)).to eq([1, 0])
    end
  end

  describe "#matcher" do
    # Building one indexes every stored list, so it happens once and is held.
    it "builds one and holds it" do
      client = described_class.new(storage: both)
      built = client.matcher

      expect(client.matcher).to be(built)
    end

    it "hands every thread the same matcher, so a race cannot build two" do
      client = described_class.new(storage: both)
      built = Array.new(8) { Thread.new { client.matcher } }.map(&:value)

      expect(built.uniq.size).to eq(1)
    end

    it "screens the same client from eight threads and gets one answer" do
      client = described_class.new(storage: both)
      answers = Array.new(8) { Thread.new { client.screen("Bosco Ntaganda").map(&:score) } }

      expect(answers.map(&:value).uniq.size).to eq(1)
    end

    # Concurrency and isolation together, which is the pair the hosted service
    # needs: eight threads through two clients, and no answer from the wrong one.
    it "screens two clients from eight threads at once with no cross-talk" do
      ofac = described_class.new(storage: both, sources: %i[ofac_sdn])
      un = described_class.new(storage: both, sources: %i[un_consolidated])
      answers = Array.new(8) do |at|
        Thread.new { at.even? ? ofac.screen("Bosco Ntaganda") : un.screen("Bosco Ntaganda") }
      end

      expect(answers.map { |thread| thread.value.map(&:source) }).to eq([%i[ofac_sdn], []] * 4)
    end

    it "screens two clients whose thresholds differ from eight threads without either reading the other's" do
      low = described_class.new(storage: both, screening_threshold: 10)
      high = described_class.new(storage: both, screening_threshold: 99)
      answers = Array.new(8) { |at| Thread.new { (at.even? ? low : high).screen("Bosco Ntaganda").any? } }

      expect(answers.map(&:value)).to eq([true, false] * 4)
    end
  end

  describe "#sync!" do
    def un(entities = [FakeSyncSource.entity(:un_consolidated)])
      FakeSyncSource.new(:un_consolidated, entities: entities)
    end

    it "stores what it fetched in its own store" do
      client = described_class.new(storage: store(ofac_sdn: [ntaganda]))
      client.sync!(un)

      expect(client.storage.read_snapshot(:un_consolidated).record_count).to eq(1)
    end

    it "leaves the default client's store alone" do
      described_class.new(storage: store(ofac_sdn: [ntaganda])).sync!(un)

      expect(ActiveSanction::Storage::Memory.new.sources).to eq([])
    end

    it "returns what each source did" do
      client = described_class.new(storage: store(ofac_sdn: [ntaganda]))

      expect(client.sync!(un).first).to have_attributes(source: :un_consolidated, status: :updated)
    end

    # The fetch layer reads its User-Agent from the configuration in force, so
    # this is what says a client's publisher identity is its own.
    it "runs under its own settings" do
      seen = []
      source = FakeSyncSource.new(:un_consolidated, entities: []) { seen << ActiveSanction.config.user_agent }
      described_class.new(storage: store(ofac_sdn: [ntaganda]), user_agent: "acme/1.0").sync!(source)

      expect(seen).to eq(["acme/1.0"])
    end

    # A configuration is fiber-local and `Thread.new` does not inherit one, so
    # a run that fans out has to carry it into each worker or a client's
    # identity would depend on `concurrency:`.
    it "runs under its own settings in every worker thread" do
      seen = Queue.new
      sources = Array.new(4) do |at|
        FakeSyncSource.new(:"source_#{at}", entities: [], host: "host-#{at}.test") do
          seen << ActiveSanction.config.user_agent
        end
      end
      described_class.new(storage: store(ofac_sdn: [ntaganda]), user_agent: "acme/1.0").sync!(*sources, concurrency: 4)

      expect(Array.new(seen.size) { seen.pop }).to eq(["acme/1.0"] * 4)
    end

    it "syncs the sources its configuration names when it is given none" do
      register_demo_list
      client = described_class.new(storage: store(ofac_sdn: [ntaganda]), sources: %i[demo_list])

      expect(client.sync!.sources).to eq(%i[demo_list])
    end

    # A matcher is built once and never updated, so a client that synced has to
    # drop its own or it goes on screening the version it booted with.
    it "drops its matcher when a list changed" do
      client = described_class.new(storage: store(ofac_sdn: [ntaganda]))
      client.screen("Bosco Ntaganda")
      client.sync!(un)

      expect(client.screen("Bosco Ntaganda").map(&:source)).to eq(%i[ofac_sdn un_consolidated])
    end

    it "captures a failing source rather than raising" do
      failing = FakeSyncSource.new(:un_consolidated, error: ActiveSanction::FetchError.new("503", status: 503))
      client = described_class.new(storage: store(ofac_sdn: [ntaganda]))

      expect(client.sync!(failing)).to have_attributes(failed?: true, exit_code: 1)
    end
  end

  describe "#doctor" do
    it "diagnoses against its own store" do
      client = described_class.new(storage: store(ofac_sdn: [ntaganda]))
      source = FakeDoctorSource.new(:un_consolidated, entities: [FakeDoctorSource.entity(:un_consolidated)])

      expect(client.doctor(source).sources).to eq(%i[un_consolidated])
    end

    it "stores nothing, so a diagnosis cannot change what is screened against" do
      client = described_class.new(storage: store(ofac_sdn: [ntaganda]))
      client.doctor(FakeDoctorSource.new(:un_consolidated, entities: [FakeDoctorSource.entity(:un_consolidated)]))

      expect(client.storage.sources).to eq(%i[ofac_sdn])
    end
  end

  describe "#diff" do
    it "reads the current snapshot from its own store" do
      client = described_class.new(storage: store(ofac_sdn: [ntaganda]))

      expect(client.diff(:ofac_sdn, from: ActiveSanction::Snapshot.new(source: :ofac_sdn, entities: [])).added.size)
        .to eq(1)
    end
  end

  describe "#rescreen" do
    def snapshot(entities) = ActiveSanction::Snapshot.new(source: :ofac_sdn, entities: entities)

    it "applies a diff to a book, and stamps the client's backend onto every alert" do
      client = described_class.new(storage: store(ofac_sdn: [ntaganda]), backend: :hosted)
      changes = ActiveSanction::Diff.new(from: snapshot([]), to: snapshot([ntaganda]))
      book = [ActiveSanction::Subject.new(id: "cust_1", name: "Bosco Ntaganda")]

      alerts = client.rescreen(book, diff: changes, threshold: 75)

      expect(alerts.map { |alert| [alert.subject_id, alert.change, alert.result.backend] })
        .to eq([["cust_1", :newly_listed, :hosted]])
    end

    # A rescreen indexes the diff and nothing else: applying one must not cost
    # an index build over the whole corpus.
    it "does not build the client's matcher" do
      client = described_class.new(storage: both)
      changes = ActiveSanction::Diff.new(from: snapshot([]), to: snapshot([ntaganda]))

      client.rescreen([ActiveSanction::Subject.new(id: "cust_1", name: "Bosco Ntaganda")], diff: changes)

      expect(client.loaded?).to be(false)
    end

    it "screens under its own configuration" do
      client = described_class.new(storage: both, screening_threshold: 99)
      changes = ActiveSanction::Diff.new(from: snapshot([]), to: snapshot([ntaganda]))

      expect(client.rescreen([ActiveSanction::Subject.new(id: "cust_1", name: "Bosco Ntaganda")], diff: changes))
        .to be_empty
    end
  end

  describe "#reload!" do
    it "drops the held matcher so the next call builds one over what is stored now" do
      client = described_class.new(storage: both)
      before = client.matcher

      expect(client.reload!.matcher).not_to be(before)
    end

    it "returns the client, so a caller can chain off it" do
      client = described_class.new(storage: both)

      expect(client.reload!).to be(client)
    end
  end

  describe "#supports?" do
    let(:client) { described_class.new(storage: both) }

    it "does everything a client can be asked to do" do
      expect(described_class::CAPABILITIES.map { |name| client.supports?(name) }.uniq).to eq([true])
    end

    it "takes a String as readily as a Symbol, since this is often config" do
      expect(client.supports?("sync")).to be(true)
    end

    # The whole point of asking rather than assuming: the caller is usually
    # written against a newer version than the one answering, so a name this
    # version has never heard of is `false` and a fallback path, not an
    # exception. Deliberately unlike Configuration, where an unknown setting
    # raises.
    it "is false for a capability it has never heard of, rather than raising" do
      expect(client.supports?(:teleport)).to be(false)
    end

    it "names only methods it actually has" do
      missing = described_class::CAPABILITIES.reject do |name|
        client.respond_to?(name) || client.respond_to?(:"#{name}!")
      end

      expect(missing).to be_empty
    end
  end

  describe "#loaded?" do
    it "is false until something has been screened" do
      expect(described_class.new(storage: both).loaded?).to be(false)
    end

    it "is true once a matcher has been built" do
      client = described_class.new(storage: both)
      client.matcher

      expect(client.loaded?).to be(true)
    end

    it "is false again after a reload" do
      client = described_class.new(storage: both)
      client.matcher

      expect(client.reload!.loaded?).to be(false)
    end
  end

  describe "#inspect" do
    it "names the lists and the store, which is what tells two clients apart in a console" do
      client = described_class.new(storage: both, sources: %i[ofac_sdn])

      expect(client.inspect).to eq("#<ActiveSanction::Client ofac_sdn in ActiveSanction::Storage::Memory>")
    end

    it "says when it is holding an index" do
      client = described_class.new(storage: both)
      client.matcher

      expect(client.inspect).to include("every registered source", "loaded")
    end
  end

  # The two halves of distribution: one machine writes a file, another loads
  # it and screens against it without ever reaching the publisher. See
  # Snapshot::Bundle, and docs/bundle_format.md.
  describe "#export and #import" do
    around do |example|
      Dir.mktmpdir("active_sanction-bundle") do |dir|
        @dir = dir
        example.run
      end
    end

    attr_reader :dir

    let(:key) { OpenSSL::PKey::EC.generate("prime256v1") }
    let(:path) { File.join(dir, "ofac_sdn.asb") }
    let(:exporter) { described_class.new(storage: store(ofac_sdn: [ntaganda])) }
    let(:importer) { described_class.new(storage: ActiveSanction::Storage::Memory.new) }

    it "writes the list a store holds, and answers what it wrote" do
      header = exporter.export(:ofac_sdn, to: path)

      expect([header.source, header.record_count]).to eq([:ofac_sdn, 1])
    end

    it "writes a snapshot it was handed, for a list that was just synced" do
      snapshot = exporter.storage.read_snapshot(:ofac_sdn)

      expect(exporter.export(snapshot, to: path).snapshot_checksum).to eq(snapshot.checksum)
    end

    it "raises for a list the store has never held" do
      expect { exporter.export(:eu_fsf, to: path) }.to raise_error(ActiveSanction::Storage::MissingSnapshot)
    end

    it "loads the same list on the other side" do
      exporter.export(:ofac_sdn, to: path)

      expect(importer.import(path).checksum).to eq(exporter.storage.read_snapshot(:ofac_sdn).checksum)
    end

    it "puts what it loaded into the store" do
      exporter.export(:ofac_sdn, to: path)
      importer.import(path)

      expect(importer.storage.sources).to eq(%i[ofac_sdn])
    end

    it "screens against what was imported" do
      exporter.export(:ofac_sdn, to: path)
      importer.import(path)

      expect(importer.screen(name: "Bosco Ntaganda").map(&:source)).to eq(%i[ofac_sdn])
    end

    it "drops a matcher built before the import" do
      exporter.export(:ofac_sdn, to: path)
      importer.import(path)

      expect(importer).not_to be_loaded
    end

    it "reports a bundle that verified as attested" do
      exporter.export(:ofac_sdn, to: path, sign_with: key)

      expect(importer.import(path, verify_with: key).trusted?).to be(true)
    end

    it "stamps every result off it as verified" do
      exporter.export(:ofac_sdn, to: path, sign_with: key)
      importer.import(path, verify_with: key)

      expect(importer.screen(name: "Bosco Ntaganda").map(&:verified?)).to eq([true])
    end

    it "refuses a bundle signed by somebody else" do
      exporter.export(:ofac_sdn, to: path, sign_with: key)

      expect { importer.import(path, verify_with: OpenSSL::PKey::EC.generate("prime256v1")) }
        .to raise_error(ActiveSanction::Snapshot::Bundle::UntrustedSignature)
    end

    # A list that failed a verification somebody asked for is not one to fall
    # back on quietly.
    it "stores nothing when verification fails" do
      exporter.export(:ofac_sdn, to: path, sign_with: key)
      begin
        importer.import(path, verify_with: OpenSSL::PKey::EC.generate("prime256v1"))
      rescue ActiveSanction::Snapshot::Bundle::UntrustedSignature
        nil
      end

      expect(importer.storage).to be_empty
    end

    it "loads an unsigned bundle, unattested" do
      exporter.export(:ofac_sdn, to: path)

      expect(importer.import(path).trusted?).to be(false)
    end

    # Verification attests to a bundle's bytes, not to the copy a store
    # rewrites into its own layout -- see Snapshot#trusted?.
    it "does not claim a list is attested once a store has rewritten it" do
      exporter.export(:ofac_sdn, to: path, sign_with: key)
      file_store = ActiveSanction::Storage::FileSystem.new(root: File.join(dir, "store"))
      described_class.new(storage: file_store).import(path, verify_with: key)

      expect(file_store.read_snapshot(:ofac_sdn).trusted?).to be(false)
    end

    it "is reachable from the module, through the default client" do
      ActiveSanction.configure { |config| config.storage = store(ofac_sdn: [ntaganda]) }
      ActiveSanction.export(:ofac_sdn, to: path)

      expect(ActiveSanction.import(path).record_count).to eq(1)
    end
  end
end
