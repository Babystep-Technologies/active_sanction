# frozen_string_literal: true

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

  def putin(source = :ofac_sdn) = entity(source, 1, "PUTIN, Vladimir Vladimirovich")
  def gazprom(source = :un_consolidated) = entity(source, 2, "GAZPROM NEFT")

  # A store holding one snapshot per source it is given.
  def store(**lists)
    ActiveSanction::Storage::Memory.new.tap do |memory|
      lists.each do |source, entities|
        memory.write_snapshot(ActiveSanction::Snapshot.new(source: source, entities: entities))
      end
    end
  end

  def both = store(ofac_sdn: [putin], un_consolidated: [gazprom])

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

      expect(client.screen("Vladimir Putin").first.entity.id).to eq("ofac_sdn:1")
    end

    # The acceptance criterion this class exists for: one tenant's obligations
    # are not the next one's, and neither may answer out of the other's lists.
    it "screens two source sets over one store without either seeing the other's lists" do
      ofac = described_class.new(storage: both, sources: %i[ofac_sdn])
      un = described_class.new(storage: both, sources: %i[un_consolidated])

      expect([ofac.screen("Gazprom Neft"), un.screen("Vladimir Putin")]).to eq([[], []])
    end

    # The other half of the acceptance criterion, and the reason the hosted
    # service needs this: an audit re-run screens against the list version a
    # decision was actually made under, beside live traffic on today's.
    it "screens a pinned list version beside the current one" do
      current = described_class.new(storage: store(ofac_sdn: [putin]))
      january = described_class.new(storage: store(ofac_sdn: [putin, gazprom(:ofac_sdn)]))

      expect([current, january].map { |client| client.screen("Gazprom Neft").size }).to eq([0, 1])
    end

    # The proof that a client's settings reach the query path rather than only
    # its store: a threshold is read when a Query is built, three layers below
    # anything that was handed this client.
    it "defaults a query to its own threshold, not the default client's" do
      client = described_class.new(storage: both, screening_threshold: 99)

      expect(client.screen("Vladimir Putin")).to eq([])
    end

    it "leaves the default client's threshold where it found it" do
      described_class.new(storage: both, screening_threshold: 99).screen("Vladimir Putin")

      expect(ActiveSanction.config.screening_threshold)
        .to eq(ActiveSanction::Configuration::DEFAULT_SCREENING_THRESHOLD)
    end

    it "takes the search options a matcher takes" do
      expect(described_class.new(storage: both).screen(name: "Vladimir Putin", threshold: 99)).to eq([])
    end

    it "raises rather than reporting clear when nothing has been synced" do
      client = described_class.new(storage: ActiveSanction::Storage::Memory.new)

      expect { client.screen("Vladimir Putin") }.to raise_error(ActiveSanction::Matcher::NotSynced)
    end
  end

  describe "#screen_all" do
    it "returns one array of results per name" do
      client = described_class.new(storage: both)

      expect(client.screen_all(["Vladimir Putin", "Jane Wilson of Dorset"]).map(&:size)).to eq([1, 0])
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
      answers = Array.new(8) { Thread.new { client.screen("Vladimir Putin").map(&:score) } }

      expect(answers.map(&:value).uniq.size).to eq(1)
    end

    # Concurrency and isolation together, which is the pair the hosted service
    # needs: eight threads through two clients, and no answer from the wrong one.
    it "screens two clients from eight threads at once with no cross-talk" do
      ofac = described_class.new(storage: both, sources: %i[ofac_sdn])
      un = described_class.new(storage: both, sources: %i[un_consolidated])
      answers = Array.new(8) do |at|
        Thread.new { at.even? ? ofac.screen("Vladimir Putin") : un.screen("Vladimir Putin") }
      end

      expect(answers.map { |thread| thread.value.map(&:source) }).to eq([%i[ofac_sdn], []] * 4)
    end

    it "screens two clients whose thresholds differ from eight threads without either reading the other's" do
      low = described_class.new(storage: both, screening_threshold: 10)
      high = described_class.new(storage: both, screening_threshold: 99)
      answers = Array.new(8) { |at| Thread.new { (at.even? ? low : high).screen("Vladimir Putin").any? } }

      expect(answers.map(&:value)).to eq([true, false] * 4)
    end
  end

  describe "#sync!" do
    def un(entities = [FakeSyncSource.entity(:un_consolidated)])
      FakeSyncSource.new(:un_consolidated, entities: entities)
    end

    it "stores what it fetched in its own store" do
      client = described_class.new(storage: store(ofac_sdn: [putin]))
      client.sync!(un)

      expect(client.storage.read_snapshot(:un_consolidated).record_count).to eq(1)
    end

    it "leaves the default client's store alone" do
      described_class.new(storage: store(ofac_sdn: [putin])).sync!(un)

      expect(ActiveSanction::Storage::Memory.new.sources).to eq([])
    end

    it "returns what each source did" do
      client = described_class.new(storage: store(ofac_sdn: [putin]))

      expect(client.sync!(un).first).to have_attributes(source: :un_consolidated, status: :updated)
    end

    # The fetch layer reads its User-Agent from the configuration in force, so
    # this is what says a client's publisher identity is its own.
    it "runs under its own settings" do
      seen = []
      source = FakeSyncSource.new(:un_consolidated, entities: []) { seen << ActiveSanction.config.user_agent }
      described_class.new(storage: store(ofac_sdn: [putin]), user_agent: "acme/1.0").sync!(source)

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
      described_class.new(storage: store(ofac_sdn: [putin]), user_agent: "acme/1.0").sync!(*sources, concurrency: 4)

      expect(Array.new(seen.size) { seen.pop }).to eq(["acme/1.0"] * 4)
    end

    it "syncs the sources its configuration names when it is given none" do
      register_demo_list
      client = described_class.new(storage: store(ofac_sdn: [putin]), sources: %i[demo_list])

      expect(client.sync!.sources).to eq(%i[demo_list])
    end

    # A matcher is built once and never updated, so a client that synced has to
    # drop its own or it goes on screening the version it booted with.
    it "drops its matcher when a list changed" do
      client = described_class.new(storage: store(ofac_sdn: [putin]))
      client.screen("Vladimir Putin")
      client.sync!(un)

      expect(client.screen("Vladimir Putin").map(&:source)).to eq(%i[ofac_sdn un_consolidated])
    end

    it "captures a failing source rather than raising" do
      failing = FakeSyncSource.new(:un_consolidated, error: ActiveSanction::FetchError.new("503", status: 503))
      client = described_class.new(storage: store(ofac_sdn: [putin]))

      expect(client.sync!(failing)).to have_attributes(failed?: true, exit_code: 1)
    end
  end

  describe "#doctor" do
    it "diagnoses against its own store" do
      client = described_class.new(storage: store(ofac_sdn: [putin]))
      source = FakeDoctorSource.new(:un_consolidated, entities: [FakeDoctorSource.entity(:un_consolidated)])

      expect(client.doctor(source).sources).to eq(%i[un_consolidated])
    end

    it "stores nothing, so a diagnosis cannot change what is screened against" do
      client = described_class.new(storage: store(ofac_sdn: [putin]))
      client.doctor(FakeDoctorSource.new(:un_consolidated, entities: [FakeDoctorSource.entity(:un_consolidated)]))

      expect(client.storage.sources).to eq(%i[ofac_sdn])
    end
  end

  describe "#diff" do
    it "reads the current snapshot from its own store" do
      client = described_class.new(storage: store(ofac_sdn: [putin]))

      expect(client.diff(:ofac_sdn, from: ActiveSanction::Snapshot.new(source: :ofac_sdn, entities: [])).added.size)
        .to eq(1)
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
end
