# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe ActiveSanction::Sources::OfacConsolidated do
  def fixtures = File.expand_path("../../fixtures/ofac_consolidated", __dir__)

  def raw
    { prim: File.binread("#{fixtures}/PRIM.CSV"),
      alt: File.binread("#{fixtures}/ALT.CSV"),
      add: File.binread("#{fixtures}/ADD.CSV") }
  end

  let(:adapter) { described_class.new }
  let(:entities) { adapter.parse(raw) }

  def entity(ref) = entities.find { |candidate| candidate.source_ref == ref }

  def lists(ref) = described_class.lists(entity(ref))

  it_behaves_like "a sanction source",
                  fixture: { prim: "ofac_consolidated/PRIM.CSV", alt: "ofac_consolidated/ALT.CSV",
                             add: "ofac_consolidated/ADD.CSV" }

  describe "what it declares" do
    it "registers under a key of its own, so a caller can screen one list or both" do
      expect(ActiveSanction::Sources[:ofac_consolidated]).to eq(described_class)
    end

    it "is a distinct source from the SDN list" do
      expect(described_class.key).not_to eq(ActiveSanction::Sources::OfacSdn.key)
    end

    it "declares the three consolidated files" do
      expect(described_class.urls.keys).to eq(%i[prim alt add])
    end

    it "inherits the publisher from the shared OFAC base rather than restating it" do
      expect(described_class.authority).to eq(ActiveSanction::Sources::OfacSdn.authority)
    end

    it "files its own cache entries, so the two lists' ALT files cannot evict each other" do
      expect(described_class.file_key(:alt)).to eq(:"ofac_consolidated-alt")
    end
  end

  # The point of the adapter. Everything above is plumbing the SDN list
  # already proved; which sub-list a record is on is the only thing this file
  # publishes that the SDN file does not, and it is the thing a compliance
  # decision turns on.
  describe "sub-list attribution" do
    it "reads the Palestinian Legislative Council list" do
      expect(lists("9640")).to eq([:ns_plc])
    end

    it "reads the CMIC list, which is an investment prohibition and not a block" do
      expect(lists("30882")).to eq([:cmic])
    end

    it "reads the CAPTA list" do
      expect(lists("15268")).to eq([:capta])
    end

    it "reads the menu-based sanctions list" do
      expect(lists("29242")).to eq([:ns_mbs])
    end

    it "reads the sectoral sanctions list" do
      expect(lists("19993")).to eq([:ssi])
    end

    it "ignores a program that names an SDN designation rather than a sub-list" do
      expect([entity("9647").programs, lists("9647")]).to eq([%w[SDGT NS-PLC], [:ns_plc]])
    end

    it "takes every sub-list a row's programs name, not just the first" do
      expect(described_class.lists(%w[CMIC-EO13959 NS-PLC])).to eq(%i[cmic ns_plc])
    end

    it "names each list the way OFAC spells it, which is what a report prints" do
      expect(described_class.names(entity("30882"))).to eq(["Non-SDN CMIC List"])
    end

    # The programs are a canonical Entity member, so the attribution survives
    # storage and serialization with no per-source column downstream.
    it "answers for an entity that has been through the serialized form" do
      restored = ActiveSanction::Entity.from_h(entity("30882").to_h)

      expect(described_class.lists(restored)).to eq([:cmic])
    end

    it "answers for the programs alone, without an entity" do
      expect(described_class.lists(%w[HKAA])).to eq([:ns_mbs])
    end
  end

  # EO 14024 is the authority behind both the SSI directives and several
  # menu-based determinations, and OFAC files both under one program code.
  describe "the one program that names two lists" do
    it "reads it alone as menu-based, which is what the Central Bank of Russia is on" do
      expect(lists("31695")).to eq([:ns_mbs])
    end

    it "reads it beside a sectoral program as sectoral" do
      expect(lists("17250")).to eq([:ssi])
    end

    # Gazprom is on both, and nothing in the CSVs separates it from the 89
    # rows carrying the identical program pair that are on SSI alone. The
    # record is still returned and still flagged; the second list is what is
    # lost, and this example is here so that stops being true silently.
    it "under-reports the three rows that are on both, rather than guessing them onto NS-MBS" do
      expect(lists("17250")).not_to include(:ns_mbs)
    end
  end

  describe "a program it has never seen" do
    it "still returns the entity, with the program OFAC published on it" do
      expect(entity("90001").programs).to eq(["NOVEL-EO99999"])
    end

    it "puts it on no list rather than guessing one" do
      expect(lists("90001")).to be_empty
    end

    # How a new OFAC authority surfaces: every other kind of drift in this
    # library is a parse warning, and so is this.
    it "warns, because an unattributed row means the list grew an authority" do
      entities
      expect(adapter.warnings.map(&:message))
        .to include(/row "90001" carries no program naming a consolidated sub-list \(NOVEL-EO99999\)/)
    end
  end

  describe "where the attribution is written" do
    it "appends the list names to remarks, ahead of the other source fields" do
      expect(entity("29242").remarks)
        .to include("[source fields] List: Non-SDN Menu-Based Sanctions List; Title: Commissioner of Police")
    end

    it "keeps OFAC's own remark verbatim and first" do
      expect(described_class.published_remarks(entity("9640").remarks)).to eq("DOB 1951; POB Umm Tuba.")
    end

    it "leaves nothing in the published remark that this adapter put there" do
      expect(described_class.published_remarks(entity("30882").remarks)).not_to include("Non-SDN CMIC List")
    end
  end

  # Not re-testing the join, the type mapping or the remarks parser -- they
  # are Ofac's, and the SDN spec exercises them against a fixture built for
  # them. What is worth checking here is that this adapter really does run
  # through them rather than around them.
  describe "the machinery it shares with the SDN list" do
    it "reads the same twelve columns with the same reader" do
      expect(described_class::PRIMARY).to equal(ActiveSanction::Sources::OfacSdn::PRIMARY)
    end

    it "joins the aliases on ent_num" do
      expect(entity("9640").names.map(&:value))
        .to eq(["ABU TEIR, Mohammed", "ABU TAIR, Mohammed Mahmud", "ABOU TAYR, Mohammad Mahmoud"])
    end

    it "joins the addresses on ent_num" do
      expect(entity("15268").addresses.map(&:city)).to eq(["Daqing 163453", "Beijing 100007"])
    end

    it "counts the child rows that belong to no entity" do
      entities
      expect(adapter.orphans).to eq(aliases: 1, addresses: 1)
    end

    it "reads the dates of birth out of the free text, which has no column here either" do
      expect(entity("29242").dates_of_birth.map(&:to_s)).to eq(["1965-07-04"])
    end

    it "reports how much of the free text it read" do
      entities
      expect(adapter.remarks_coverage.segments).to be > 0
    end

    it "stamps the entities with its own key and not the SDN list's" do
      expect(entities.map(&:source).uniq).to eq([:ofac_consolidated])
    end

    it "namespaces ids under its own key, so the two lists cannot collide" do
      expect(entity("9640").id).to eq("ofac_consolidated:9640")
    end
  end

  describe "syncing end to end" do
    let(:cache_dir) { Dir.mktmpdir("active_sanction_ofac_cons") }
    let(:fetcher) do
      ActiveSanction::Fetcher.new(client: ActiveSanction::HttpClient.new(retry_backoff: 0.001),
                                  store: ActiveSanction::ValidatorStore::Memory.new)
    end

    after { FileUtils.remove_entry(cache_dir) if File.directory?(cache_dir) }

    def stub_files
      %i[prim alt add].each do |name|
        stub_request(:get, described_class.url(name))
          .to_return(status: 200, body: raw[name], headers: { "ETag" => %("#{name}-1") })
      end
    end

    it "fetches all three files and checksums them into one Snapshot" do
      stub_files
      source = described_class.new(fetcher: fetcher, cache: ActiveSanction::PayloadCache.new(dir: cache_dir))

      expect(source.sync).to be_a(ActiveSanction::Snapshot)
        .and have_attributes(source: :ofac_consolidated, record_count: 10)
    end
  end

  # Excluded by default. The committed fixture is trimmed to one entity per
  # sub-list; only the published files say whether the program table still
  # covers what OFAC is putting on them.
  describe "against the published list", :live do
    let(:source) do
      described_class.new(fetcher: ActiveSanction::Fetcher.new(store: ActiveSanction::ValidatorStore::Memory.new),
                          cache: nil)
    end

    it "parses the whole consolidated list" do
      expect(source.sync.record_count).to be_within(150).of(481)
    end

    # The acceptance criterion for the attribution, and the only place it can
    # be checked. A row OFAC publishes under a program this adapter cannot
    # place is a row no caller can tell CMIC from SSI on, and the whole point
    # of the source is that they can.
    it "places every published row on a sub-list" do
      snapshot = source.sync

      expect(snapshot.entities.reject { |entity| described_class.lists(entity).any? }).to be_empty
    end
  end
end
