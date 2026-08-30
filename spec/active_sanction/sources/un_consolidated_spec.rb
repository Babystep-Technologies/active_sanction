# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe ActiveSanction::Sources::UnConsolidated do
  def raw = File.binread(File.expand_path("../../fixtures/un_consolidated/consolidated.xml", __dir__))

  let(:adapter) { described_class.new }
  let(:entities) { adapter.parse(raw) }

  def entity(ref) = entities.find { |candidate| candidate.source_ref == ref }

  # The fixture is seven real records lifted verbatim from the published list,
  # chosen because between them they carry every quirk this adapter exists to
  # absorb: a four-part name, a name in Arabic wrapped across two lines, both
  # alias vocabularies, a placeholder alias, an exact date, a year, a span,
  # multiple dates for one person, a document with no number, and a country
  # published twice.
  describe "what it declares" do
    it "registers itself, so requiring the gem is enough to reach it" do
      expect(ActiveSanction::Sources[:un_consolidated]).to eq(described_class)
    end

    it "names the publisher the way a compliance report has to print it" do
      expect(described_class.authority).to eq("United Nations Security Council")
    end

    it "declares the one document the whole list arrives in" do
      expect(described_class.urls.keys).to eq([:main])
    end
  end

  describe "reading both sections of one document" do
    it "builds an entity from every INDIVIDUAL and every ENTITY, in one pass" do
      expect(entities.map(&:source_ref))
        .to eq(%w[6907993 6908049 6908021 6908841 6909617 6908402 6908024])
    end

    it "types people and organizations apart" do
      expect(entities.map(&:type).tally).to eq(individual: 5, organization: 2)
    end

    it "namespaces ids so they stay unique across sources" do
      expect(entity("6907993").id).to eq("un_consolidated:6907993")
    end

    it "reads the list version off the document element, not off a header" do
      entities
      expect(adapter.source_version).to eq("2026-08-29T23:00:02.417Z")
    end
  end

  describe "names split across numbered elements" do
    it "joins the parts a record happens to carry" do
      expect(entity("6907993").primary_name.value).to eq("ERIC BADEGE")
    end

    it "joins all four when all four are there" do
      expect(entity("6908049").primary_name.value).to eq("QUSAY SADDAM HUSSEIN AL-TIKRITI")
    end

    # Thirty-nine name parts in the published list are padded on one side.
    it "collapses the whitespace the UN pads its parts with" do
      expect(entity("6909617").primary_name.value).to eq("JOHN IMANI NZENZE")
    end

    it "keeps the name in its original script as an alias" do
      expect(entity("6908049").names.map(&:value)).to include("قصي صدام حسين التكريتي")
    end

    # The published file wraps this one across a line break and fifty spaces.
    it "collapses a name the UN wrapped across two lines" do
      expect(entity("6908841").names.map(&:value)).to include("أمیر محمد سعید عبد الرحمن السلبي")
    end

    it "leaves the script unstated rather than inferring it from the element" do
      arabic = entity("6908049").names.find { |name| name.value.start_with?("قصي") }
      expect(arabic).to have_attributes(kind: :aka, script: nil)
    end
  end

  # The trap in this list: one element name, two vocabularies, split by which
  # record it hangs off.
  describe "aliases" do
    it "grades an individual's aliases, because that is what QUALITY means there" do
      graded = entity("6908021").names.reject(&:primary?)
      expect(graded.map { |name| [name.value, name.quality] }.first(4))
        .to eq([["Bosco Ntaganda", :good], ["Bosco Ntagenda", :good], ["General Taganda", :good], ["Lydia", :low]])
    end

    it "files every individual alias as an aka, since QUALITY is not a kind there" do
      expect(entity("6908021").names.reject(&:primary?).map(&:kind).uniq).to eq([:aka])
    end

    it "reads an organization's QUALITY as the kind it actually is" do
      expect(entity("6908402").names.map { |name| [name.value, name.kind] })
        .to eq([["ADF", :primary],
                ["Allied Democratic Forces", :aka],
                ["Forces Démocratiques Alliées-Armée Nationale de Libération de l’Ouganda", :fka],
                ["ADF/NALU", :fka],
                ["NALU", :fka]])
    end

    it "does not grade an organization's aliases on a scale never applied to them" do
      expect(entity("6908402").names.map(&:quality).uniq).to eq([nil])
    end

    # 294 of the published list's 3,061 alias elements are placeholders.
    it "produces no name at all from a placeholder alias" do
      expect(entity("6907993").names.size).to eq(1)
    end
  end

  describe "dates of birth" do
    it "reads an exact full date" do
      expect(entity("6909617").dates_of_birth.map(&:to_s)).to eq(["1978-08-06"])
    end

    it "reads a year-only date as a year, not as the first of January" do
      expect(entity("6907993").dates_of_birth.first)
        .to have_attributes(to_s: "1971", precision: :year)
    end

    it "reads BETWEEN as a span rather than picking an end of it" do
      expect(entity("6908021").dates_of_birth.first)
        .to have_attributes(to_s: "1973 to 1974", precision: :range)
    end

    # 140 of the published individuals carry more than one, and one carries ten.
    it "keeps every date the Committee listed rather than choosing between them" do
      expect(entity("6908841").dates_of_birth.map(&:to_s)).to eq(%w[1976-10-05 1976-10-01 1976-01-06])
    end

    it "keeps two dates for a person the Committee gave two years for" do
      expect(entity("6908049").dates_of_birth.map(&:to_s)).to eq(%w[1965 1966])
    end

    it "gives an organization none, since the element does not exist there" do
      expect(entity("6908402").dates_of_birth).to be_empty
    end
  end

  describe "documents" do
    it "maps the UN's free-text document types onto identifier kinds" do
      expect(entity("6909617").identifiers.map { |id| [id.kind, id.value] })
        .to eq([[:passport, "OP0204168"], [:passport, "OB0072391"], [:national_id, "1 1978 8 0137555 3 27"]])
    end

    it "keeps the issuing country and expiry, which are what make a hit decisive" do
      expect(entity("6909617").identifiers.first)
        .to have_attributes(country: "Democratic Republic of the Congo", expires_on: ActiveSanction::PartialDate.parse("2022-07-05"))
    end

    # 447 of the published list's 954 document elements have no number.
    it "drops a document with no number rather than keeping an identifier with no identity" do
      expect(entity("6907993").identifiers).to be_empty
    end

    it "reads a document type the UN wrapped across two lines" do
      expect(entity("6908841").identifiers.map(&:kind)).to eq([:national_id])
    end
  end

  describe "addresses, nationalities and programs" do
    it "reads an address that is only a country and a note, which many are" do
      expect(entity("6907993").addresses.map(&:to_s)).to eq(["Rwanda (as of early 2016)"])
    end

    it "reads every address a record carries" do
      expect(entity("6908841").addresses.size).to eq(3)
    end

    it "reads every nationality, since one record can list two" do
      expect(entity("6909617").nationalities).to eq(["Democratic Republic of the Congo", "Rwanda"])
    end

    it "reads UN_LIST_TYPE as the sanctions program" do
      expect(entity("6908841").programs).to eq(["Al-Qaida"])
    end

    it "reads the listing date" do
      expect(entity("6908402").listed_on.to_s).to eq("2014-06-30")
    end
  end

  describe "what the canonical model has no home for" do
    it "keeps the UN's own comment verbatim and first" do
      expect(entity("6907993").remarks).to start_with("He fled to Rwanda in March 2013")
    end

    it "appends the version the issue asks be retained" do
      expect(entity("6907993").remarks).to include("[UN fields] Version: 1; Reference: CDi.001")
    end

    it "keeps a place of birth rather than dropping it to keep the schema tidy" do
      expect(entity("6908021").remarks).to include("Place of birth: Bigogwe, Rwanda")
    end

    it "keeps a designation, which is prose about a role and not a program" do
      expect(entity("6909617").remarks).to include("Designation: Colonel, M23 intelligence chief")
    end
  end

  describe "the whole fixture, as the acceptance criteria state it" do
    it "produces no blank-valued name" do
      expect(entities.flat_map(&:names).map(&:value)).to all(match(/\S/))
    end

    it "produces only PartialDates for dates of birth" do
      expect(entities.flat_map(&:dates_of_birth)).to all(be_a(ActiveSanction::PartialDate))
    end

    it "reads every record without a warning, because the fixture is real data" do
      entities
      expect(adapter.warnings).to be_empty
    end

    it "round-trips through the serialized form storage will use" do
      snapshot = adapter.snapshot(raw)
      expect(ActiveSanction::Snapshot.from_h(snapshot.to_h)).to eq(snapshot)
    end
  end

  describe "records that cannot be used" do
    it "skips a record with no name and says which one" do
      adapter.parse(<<~XML)
        <CONSOLIDATED_LIST dateGenerated="2026-01-01">
          <INDIVIDUALS><INDIVIDUAL><DATAID>1</DATAID><FIRST_NAME/></INDIVIDUAL></INDIVIDUALS>
        </CONSOLIDATED_LIST>
      XML
      expect(adapter.warnings.map(&:message)).to include(/<INDIVIDUAL> "1" has no name and was skipped/)
    end
  end

  describe "syncing end to end" do
    let(:cache_dir) { Dir.mktmpdir("active_sanction_un") }
    let(:fetcher) do
      ActiveSanction::Fetcher.new(client: ActiveSanction::HttpClient.new(retry_backoff: 0.001),
                                  store: ActiveSanction::ValidatorStore::Memory.new)
    end

    after { FileUtils.remove_entry(cache_dir) if File.directory?(cache_dir) }

    def source = described_class.new(fetcher: fetcher, cache: ActiveSanction::PayloadCache.new(dir: cache_dir))

    it "fetches the document and checksums it into one Snapshot" do
      stub_request(:get, described_class.url(:main)).to_return(status: 200, body: raw, headers: { "ETag" => '"un-1"' })

      expect(source.sync).to be_a(ActiveSanction::Snapshot)
        .and have_attributes(source: :un_consolidated, record_count: 7,
                             source_version: "2026-08-29T23:00:02.417Z")
    end

    it "returns nil when the publisher says nothing has changed" do
      stub_request(:get, described_class.url(:main)).to_return(status: 200, body: raw, headers: { "ETag" => '"un-1"' })
      client = source
      client.sync
      stub_request(:get, described_class.url(:main)).to_return(status: 304)

      expect(client.sync).to be_nil
    end
  end

  # Excluded by default. The committed fixture is seven records chosen to cover
  # every quirk; only the real document can confirm the counts the list
  # actually publishes.
  describe "against the published list", :live do
    it "parses every individual and entity the Committee has listed" do
      snapshot = described_class.new.sync

      expect(snapshot.record_count).to be_within(150).of(1_011)
    end
  end
end
