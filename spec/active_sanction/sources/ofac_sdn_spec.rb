# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe ActiveSanction::Sources::OfacSdn do
  def fixtures = File.expand_path("../../fixtures/ofac_sdn", __dir__)

  def raw
    { sdn: File.binread("#{fixtures}/SDN.CSV"),
      alt: File.binread("#{fixtures}/ALT.CSV"),
      add: File.binread("#{fixtures}/ADD.CSV") }
  end

  let(:adapter) { described_class.new }
  let(:entities) { adapter.parse(raw) }

  def entity(ref) = entities.find { |candidate| candidate.source_ref == ref }

  it_behaves_like "a sanction source",
                  fixture: { sdn: "ofac_sdn/SDN.CSV", alt: "ofac_sdn/ALT.CSV", add: "ofac_sdn/ADD.CSV" }

  describe "what it declares" do
    it "registers itself, so requiring the gem is enough to reach it" do
      expect(ActiveSanction::Sources[:ofac_sdn]).to eq(described_class)
    end

    it "declares the three files OFAC splits the list across" do
      expect(described_class.urls.keys).to eq(%i[sdn alt add])
    end

    it "names the publisher the way a compliance report has to print it" do
      expect(described_class.authority).to eq("U.S. Department of the Treasury, Office of Foreign Assets Control")
    end

    it "files each file separately in the cache, since they change separately" do
      expect(described_class.file_key(:alt)).to eq(:"ofac_sdn-alt")
    end
  end

  describe "the join" do
    it "builds one entity per SDN row that has a name" do
      expect(entities.map(&:source_ref)).to eq(%w[36 2674 7157 12086 15007 20001 20003])
    end

    it "namespaces ids so they stay unique across sources" do
      expect(entity("36").id).to eq("ofac_sdn:36")
    end

    it "attaches aliases from ALT.CSV" do
      expect(entity("36").names.map(&:value))
        .to eq(["AEROCARIBBEAN AIRLINES", "AERO-CARIBBEAN", "AEROCARIBBEAN"])
    end

    it "attaches addresses from ADD.CSV" do
      expect(entity("36").addresses.map(&:city)).to eq(["Buenos Aires", "London EC3N 1DY"])
    end

    it "counts child rows that belong to no entity, which means the files disagree" do
      entities
      expect(adapter.orphans).to eq(aliases: 1, addresses: 1)
    end
  end

  describe "type mapping" do
    it "reads a blank SDN_Type as an organization, the largest group in the list" do
      expect(entity("36").type).to eq(:organization)
    end

    it "maps the three types OFAC spells out" do
      expect([entity("2674").type, entity("7157").type, entity("12086").type])
        .to eq(%i[individual vessel aircraft])
    end

    it "treats a type it has never seen as an organization but says so" do
      entities
      expect(adapter.warnings.map(&:message))
        .to include(%(unknown SDN_Type "syndicate"; treated as an organization))
    end
  end

  describe "names" do
    it "marks the SDN_Name primary and everything from ALT an alias" do
      expect(entity("36").names.map(&:kind)).to eq(%i[primary aka fka])
    end

    # Three from ALT.CSV, and then the one OFAC wrote into the remark instead
    # of filing it as a row.
    it "carries OFAC's own aka/fka/nka distinction through" do
      expect(entity("2674").names.map(&:kind)).to eq(%i[primary aka nka aka])
    end

    it "decodes the Windows-1252 OFAC serves, which UTF-8 would turn into noise" do
      expect(entity("15007").primary_name.value).to eq("MUÑOZ HERMANOS S.A.")
    end

    it "skips a row published with no name, which could never match anything" do
      expect(entities.map(&:source_ref)).not_to include("20002")
    end

    it "says which row it skipped" do
      entities
      expect(adapter.warnings.map(&:message)).to include(%(row "20002" has no SDN_Name and was skipped))
    end
  end

  describe "programs" do
    it "reads a single program" do
      expect(entity("36").programs).to eq(["CUBA"])
    end

    it "splits the several OFAC packs into one field separated by `] [`" do
      expect(entity("7157").programs).to eq(%w[IRAQ2 IRGC])
    end
  end

  describe "the columns with no home in the canonical model" do
    it "files a vessel's call sign as an identifier, since it is a registered string" do
      expect(entity("7157").identifiers.map { |id| [id.kind, id.value, id.note] })
        .to eq([[:other, "J8B4023", "call sign"]])
    end

    it "keeps the vessel columns rather than dropping them" do
      expect(entity("7157").remarks).to include("Vessel flag: Panama", "GRT: 1,977")
    end

    it "keeps OFAC's own remark verbatim and first" do
      expect(entity("2674").remarks).to start_with("DOB 10 Dec 1948; alt. DOB 1948; POB Egypt;")
    end

    it "appends a title, which OFAC publishes as a column rather than in the remark" do
      expect(entity("2674").remarks).to include("[source fields] Title: Director of the Palestine Liberation Front")
    end

    it "hands #19 back the published remark with the appended columns stripped" do
      expect(described_class.published_remarks(entity("7157").remarks)).to eq("Vessel registered in Panama")
    end

    it "leaves a remark with nothing appended untouched by that stripping" do
      expect(described_class.published_remarks(entity("12086").remarks)).to eq("Aircraft Manufacture Date 1994")
    end
  end

  # All of it lives in free-text Remarks. RemarksParser is what reads it, and
  # is specced on its own; what matters here is that the adapter wires what it
  # produced onto the entity, and that nothing was taken out of the remark to
  # get it there.
  describe "the fields OFAC has no columns for" do
    it "reads the dates of birth out of the remark, all of them" do
      expect(entity("2674").dates_of_birth.map(&:to_s)).to eq(%w[1948-12-10 1948])
    end

    it "reads the nationality" do
      expect(entity("2674").nationalities).to eq(["Egypt"])
    end

    it "reads a passport, which is the strongest signal the matcher gets" do
      expect(entity("2674").identifiers.map { |id| [id.kind, id.value, id.country] })
        .to eq([[:passport, "123456", "Egypt"]])
    end

    it "adds the aliases OFAC publishes only inside the remark" do
      expect(entity("2674").names.map(&:value)).to include("ABU ABBAS")
    end

    it "leaves the whole remark in place, the segments it could not read included" do
      expect(described_class.published_remarks(entity("2674").remarks))
        .to end_with("a.k.a. 'ABU ABBAS'; Member of the Palestine Liberation Front")
    end

    it "keeps the vessel call sign alongside anything the remark named" do
      expect(entity("7157").identifiers.map(&:note)).to eq(["call sign"])
    end
  end

  describe "how much of the free text it read" do
    it "counts the segments of every row, the nameless ones included" do
      entities
      expect(adapter.remarks_coverage.segments).to eq(12)
    end

    it "ranks the shapes it did not recognize, which is where a new OFAC label shows up" do
      entities
      expect(adapter.remarks_coverage.top(1)).to eq([["Member of the", 1]])
    end

    it "starts over on the next parse rather than accumulating across syncs" do
      2.times { adapter.parse(raw) }
      expect(adapter.remarks_coverage.segments).to eq(12)
    end
  end

  describe "malformed rows" do
    it "keeps a short row rather than losing the entity" do
      expect(entity("20003").primary_name.value).to eq("SHORT ROW LTD")
    end

    it "reports it with the line number" do
      entities
      expect(adapter.warnings.map(&:to_s)).to include(/line 8: expected 12 columns, got only 2/)
    end
  end

  describe "syncing end to end" do
    let(:cache_dir) { Dir.mktmpdir("active_sanction_ofac") }
    let(:fetcher) do
      ActiveSanction::Fetcher.new(client: ActiveSanction::HttpClient.new(retry_backoff: 0.001),
                                  store: ActiveSanction::ValidatorStore::Memory.new)
    end

    after { FileUtils.remove_entry(cache_dir) if File.directory?(cache_dir) }

    def stub_files
      %i[sdn alt add].each do |name|
        stub_request(:get, described_class.url(name))
          .to_return(status: 200, body: raw[name], headers: { "ETag" => %("#{name}-1") })
      end
    end

    it "fetches all three files and checksums them into one Snapshot" do
      stub_files
      source = described_class.new(fetcher: fetcher, cache: ActiveSanction::PayloadCache.new(dir: cache_dir))

      expect(source.sync).to be_a(ActiveSanction::Snapshot)
        .and have_attributes(source: :ofac_sdn, record_count: 7)
    end

    it "returns nil when every file comes back unchanged" do
      stub_files
      source = described_class.new(fetcher: fetcher, cache: ActiveSanction::PayloadCache.new(dir: cache_dir))
      source.sync
      %i[sdn alt add].each { |name| stub_request(:get, described_class.url(name)).to_return(status: 304) }

      expect(source.sync).to be_nil
    end
  end

  # Excluded by default. The committed fixtures are trimmed to a handful of
  # entities that cover every quirk; only the real files can confirm the counts
  # the list actually publishes.
  describe "against the published list", :live do
    it "parses the whole SDN list" do
      snapshot = described_class.new.sync

      expect(snapshot.record_count).to be_within(2_000).of(19_321)
    end

    # The acceptance criterion for #19, and the only place it can be checked:
    # a committed fixture proves the patterns work, and only the published file
    # says how much of what OFAC writes they actually cover. The floor is set
    # well below the ~97% the current file reads so that this fails on drift
    # rather than on a quarter's worth of new designations.
    it "reads most of the free text OFAC packs its identifiers into" do
      # Its own validator store, so this downloads rather than being handed a
      # 304 by whatever the example before it left in the shared cache.
      source = described_class.new(fetcher: ActiveSanction::Fetcher.new(store: ActiveSanction::ValidatorStore::Memory.new),
                                   cache: nil)
      source.sync

      expect(source.remarks_coverage.percentage).to be > 90
    end
  end
end
