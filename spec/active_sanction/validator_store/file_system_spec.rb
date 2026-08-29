# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe ActiveSanction::ValidatorStore::FileSystem do
  let(:dir) { Dir.mktmpdir("active_sanction") }
  let(:path) { File.join(dir, "validators.json") }
  let(:url) { "https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV" }
  let(:validators) do
    ActiveSanction::Validators.new(url: url, etag: '"0953154d0fb5aff918c5ec1daf6e9c0e"',
                                   last_modified: "Fri, 28 Aug 2026 14:02:55 GMT")
  end
  let(:store) { described_class.new(path: path) }

  after do
    FileUtils.remove_entry(dir)
    ActiveSanction.reset_configuration!
  end

  # A second real endpoint, for the case where one source is updated and the
  # others have to survive it.
  def un_url = "https://scsanctions.un.org/resources/xml/en/consolidated.xml"

  it "survives the process, which is the whole reason it is on disk" do
    store[:ofac_sdn] = validators

    expect(described_class.new(path: path)[:ofac_sdn]).to eq(validators)
  end

  it "creates the cache directory rather than expecting one" do
    nested = File.join(dir, "deeper", "still", "validators.json")

    described_class.new(path: nested)[:ofac_sdn] = validators

    expect(File).to exist(nested)
  end

  it "defaults under the configured cache directory" do
    ActiveSanction.configure { |c| c.cache_dir = dir }

    expect(described_class.new.path).to eq(File.join(dir, "validators.json"))
  end

  # This file is the first thing somebody opens when a sync is downloading more
  # than it should.
  it "writes JSON a human can read" do
    store[:ofac_sdn] = validators

    expect(JSON.parse(File.read(path)))
      .to eq("ofac_sdn" => { "url" => url, "etag" => '"0953154d0fb5aff918c5ec1daf6e9c0e"',
                             "last_modified" => "Fri, 28 Aug 2026 14:02:55 GMT",
                             "checked_at" => validators.checked_at.iso8601,
                             "updated_at" => validators.updated_at.iso8601 })
  end

  describe "a missing or emptied file" do
    it "is an empty store, not an error -- it is what a first run sees" do
      expect(store).to be_empty
    end

    # The acceptance criterion: deleting stored validators forces a full
    # re-download, and nothing else is lost with them.
    it "loses only the validators when the file is deleted" do
      store[:ofac_sdn] = validators
      FileUtils.rm_f(path)

      expect(described_class.new(path: path)[:ofac_sdn]).to be_nil
    end

    it "tolerates a file truncated to nothing" do
      File.write(path, "")

      expect(store).to be_empty
    end
  end

  describe "a file that is not validators" do
    # Silently re-downloading tens of megabytes on every sync is the kind of
    # failure that hides for months.
    it "raises rather than pretending the store is empty" do
      File.write(path, "{ not json")

      expect { store[:ofac_sdn] }
        .to raise_error(ActiveSanction::ValidatorStore::CorruptStore, /not valid JSON/)
    end

    it "says how to fix it" do
      File.write(path, "{ not json")

      expect { store[:ofac_sdn] }.to raise_error(/Delete it to re-download in full/)
    end

    it "rejects JSON that is not an object of entries" do
      File.write(path, "[]")

      expect { store[:ofac_sdn] }.to raise_error(ActiveSanction::ValidatorStore::CorruptStore, /JSON object/)
    end

    it "rejects an entry written by something that did not agree on the shape" do
      File.write(path, JSON.generate("ofac_sdn" => { "url" => url, "sha256" => "abc" }))

      expect { store[:ofac_sdn] }.to raise_error(ActiveSanction::ValidatorStore::CorruptStore)
    end
  end

  describe "writing" do
    it "renames into place, leaving no temporary file behind" do
      store[:ofac_sdn] = validators

      expect(Dir.children(dir)).to eq(["validators.json"])
    end

    # A store that had to be reloaded to see another process's write would lie
    # to a sync running beside a CLI command.
    it "sees a write made by another instance without being reloaded" do
      described_class.new(path: path)[:ofac_sdn] = validators

      expect(store[:ofac_sdn]).to eq(validators)
    end

    it "keeps the other sources when one is updated" do
      store[:ofac_sdn] = validators
      store[:un_consolidated] = ActiveSanction::Validators.new(url: un_url, etag: '"0x8DF0558663FC719"')

      expect(described_class.new(path: path).keys).to contain_exactly("ofac_sdn", "un_consolidated")
    end
  end
end
