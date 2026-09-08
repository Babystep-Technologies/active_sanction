# frozen_string_literal: true

RSpec.describe ActiveSanction do
  after { described_class.reset_configuration! }

  def putin
    ActiveSanction::Entity.new(
      id: "ofac_sdn:1", source: :ofac_sdn, type: :individual,
      names: [ActiveSanction::Name.new(value: "PUTIN, Vladimir Vladimirovich")]
    )
  end

  def synced(*entities)
    ActiveSanction::Storage::Memory.new.tap do |store|
      store.write_snapshot(ActiveSanction::Snapshot.new(source: :ofac_sdn, entities: entities))
    end
  end

  it "has a version number" do
    expect(ActiveSanction::VERSION).not_to be_nil
  end

  # Bumped when a change could move a score, which is not the same question as
  # which release it shipped in. See MATCHER_VERSION.
  it "names the matching pipeline separately from the release" do
    expect(ActiveSanction::MATCHER_VERSION).not_to be_nil
  end

  describe ".storage" do
    it "is the configured store" do
      store = synced(putin)
      described_class.configure { |c| c.storage = store }

      expect(described_class.storage).to be(store)
    end
  end

  describe ".screen" do
    before { described_class.configure { |c| c.storage = synced(putin) } }

    it "screens a name against the configured lists" do
      expect(described_class.screen(name: "Vladimir Putin").first.entity.id).to eq("ofac_sdn:1")
    end

    it "takes the search options the matcher takes" do
      expect(described_class.screen(name: "Vladimir Putin", threshold: 99)).to eq([])
    end

    it "returns results stamped for an audit" do
      expect(described_class.screen("Vladimir Putin").first.snapshot_id).to start_with("sha256:")
    end

    it "raises rather than reporting clear when nothing has been synced" do
      described_class.configure { |c| c.storage = ActiveSanction::Storage::Memory.new }
      described_class.reload!

      expect { described_class.screen("Vladimir Putin") }.to raise_error(ActiveSanction::Matcher::NotSynced)
    end
  end

  describe ".screen_all" do
    before { described_class.configure { |c| c.storage = synced(putin) } }

    it "returns one array of results per name" do
      expect(described_class.screen_all(["Vladimir Putin", "Jane Wilson of Dorset"]).map(&:size)).to eq([1, 0])
    end
  end

  describe ".sync!" do
    def un(entities = [FakeSyncSource.entity(:un_consolidated)])
      FakeSyncSource.new(:un_consolidated, entities: entities)
    end

    before { described_class.configure { |c| c.storage = synced(putin) } }

    it "fetches, parses and stores the sources it is given" do
      described_class.sync!(un)

      expect(described_class.storage.read_snapshot(:un_consolidated).record_count).to eq(1)
    end

    it "returns what each source did" do
      expect(described_class.sync!(un).first).to have_attributes(source: :un_consolidated, status: :updated)
    end

    # A matcher is built once and never updated, so the sugar over the shared
    # one has to drop it when a list changes or a process goes on screening
    # against the version it booted with.
    it "drops the shared matcher when a list changed" do
      described_class.screen("Vladimir Putin")
      described_class.sync!(un)

      expect(described_class.screen("Vladimir Putin").map(&:source)).to eq(%i[ofac_sdn un_consolidated])
    end

    # The whole point of the run: it reports a failure rather than raising one.
    it "captures a failing source rather than raising" do
      failing = FakeSyncSource.new(:un_consolidated, error: ActiveSanction::FetchError.new("503", status: 503))

      expect(described_class.sync!(failing)).to have_attributes(failed?: true, exit_code: 1)
    end

    it "calls the block with each result as that source finishes" do
      seen = []
      described_class.sync!(un) { |result| seen << result.source }

      expect(seen).to eq(%i[un_consolidated])
    end

    it "passes its options to the run" do
      expect(described_class.sync!(un, force: true, concurrency: 2).first.status).to eq(:updated)
    end
  end

  describe ".doctor" do
    def un(entities = [FakeDoctorSource.entity(:un_consolidated)])
      FakeDoctorSource.new(:un_consolidated, entities: entities)
    end

    before { described_class.configure { |c| c.storage = synced(putin) } }

    it "diagnoses the sources it is given" do
      expect(described_class.doctor(un).sources).to eq(%i[un_consolidated])
    end

    it "reports rather than raising when a source cannot be read" do
      failing = FakeDoctorSource.new(:un_consolidated, error: ActiveSanction::FetchError.new("503", status: 503))

      expect(described_class.doctor(failing)).to have_attributes(ok?: false, exit_code: 1)
    end

    # Nothing about a diagnosis may change what is being screened against.
    it "stores nothing" do
      described_class.doctor(un)

      expect(described_class.storage.sources).to eq([:ofac_sdn])
    end

    it "passes its options to the run" do
      expect(described_class.doctor(un, tolerance: 0.5).first.status).to eq(:checked)
    end

    it "calls the block with each diagnosis as that source finishes" do
      seen = []
      described_class.doctor(un) { |diagnosis| seen << diagnosis.source }

      expect(seen).to eq(%i[un_consolidated])
    end
  end

  describe ".matcher" do
    before { described_class.configure { |c| c.storage = synced(putin) } }

    # Building one indexes every stored list, so it happens once and is held.
    it "builds one matcher and holds it" do
      built = described_class.matcher

      expect(described_class.matcher).to be(built)
    end

    it "screens the same matcher from many threads" do
      answers = Array.new(8) { Thread.new { described_class.screen("Vladimir Putin").map(&:score) } }

      expect(answers.map(&:value).uniq.size).to eq(1)
    end

    it "hands every thread the same matcher, so a race cannot build two" do
      described_class.reload!
      built = Array.new(8) { Thread.new { described_class.matcher } }.map(&:value)

      expect(built.uniq.size).to eq(1)
    end
  end

  describe ".reload!" do
    # A matcher is built once and never updated, which is what lets it be
    # screened from many threads without a lock. A sync replaces it.
    it "drops the held matcher so the next call builds one over what is stored now" do
      described_class.configure { |c| c.storage = synced(putin) }
      before = described_class.matcher

      expect(described_class.reload!.matcher).not_to be(before)
    end

    it "returns the module, so a sync can chain off it" do
      expect(described_class.reload!).to be(described_class)
    end
  end

  describe ".reset_configuration!" do
    it "drops the matcher too, which held the store the old configuration named" do
      described_class.configure { |c| c.storage = synced(putin) }
      described_class.matcher
      described_class.reset_configuration!

      expect(described_class.config.storage).to be_a(ActiveSanction::Storage::FileSystem)
    end
  end
end
