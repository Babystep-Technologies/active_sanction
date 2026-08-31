# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe ActiveSanction::Sources::CanadaSema do
  def raw = File.binread(File.expand_path("../../fixtures/canada_sema/sema.xml", __dir__))

  let(:adapter) { described_class.new }
  let(:entities) { adapter.parse(raw) }

  # Canada publishes no id, so a record is found the way a person would find
  # it: by the name printed on it.
  def entity(name) = entities.find { |candidate| candidate.primary_name.value.include?(name) }

  # Canada publishes no free text of its own anywhere in the file -- no
  # comment, no remarks, no note element -- so every word in a Canadian remark
  # was put there by this adapter, and the contract's check that the
  # publisher's own words survive has nothing to be true about here.
  it_behaves_like "a sanction source", fixture: "canada_sema/sema.xml", remarks: false

  # The fixture is sixteen real records lifted verbatim from the published
  # list, chosen because between them they carry every quirk this adapter
  # exists to absorb: all three record shapes, a bilingual value split on
  # ` / ` and another split on `|`, a value that is bilingual in neither, a
  # name padded with U+00A0, a vessel type wrapped across three lines, a
  # semicolon-separated alias field and a comma-separated one, a year-only
  # date, a full date, two candidate dates, a date nothing can read, a record
  # with no schedule, and a schedule and a country the publisher padded.
  describe "what it declares" do
    it "registers itself, so requiring the gem is enough to reach it" do
      expect(ActiveSanction::Sources[:canada_sema]).to eq(described_class)
    end

    it "names the publisher the way a compliance report has to print it" do
      expect(described_class.authority).to eq("Global Affairs Canada")
    end

    it "declares the one document the whole list arrives in" do
      expect(described_class.urls.keys).to eq([:main])
    end
  end

  describe "the three record shapes, read off one flat element set" do
    it "types a record with no entity name as a person" do
      expect(entity("Balaba").type).to eq(:individual)
    end

    it "types a record naming an entity and no ship number as an organization" do
      expect(entity("Lakhta Plaza").type).to eq(:organization)
    end

    it "types a record carrying an IMO number as a vessel" do
      expect(entity("Balitiyskiy").type).to eq(:vessel)
    end

    it "builds one entity from every record in the document" do
      expect(entities.size).to eq(16)
    end
  end

  # Canada publishes no identifier of any kind, so this is the whole basis on
  # which two syncs can be compared. See Sources::CanadaSema::SourceRef.
  describe "the synthetic identity" do
    it "namespaces ids so they stay unique across sources" do
      expect(entity("Balaba").id).to eq("canada_sema:#{entity("Balaba").source_ref}")
    end

    it "derives an id that depends on nothing but the record's own fields" do
      expect(entity("Balaba").source_ref).to eq(
        ActiveSanction::Sources::CanadaSema::SourceRef.for(
          country: "Belarus / Bélarus", schedule: "1, Part 1", item: "2",
          name: "Dmitry Vladimirovich Balaba"
        )
      )
    end

    it "produces byte-identical ids from a second parse of the same bytes" do
      expect(described_class.new.parse(raw).map(&:source_ref)).to eq(entities.map(&:source_ref))
    end

    it "gives every record its own id" do
      expect(entities.map(&:id).uniq.size).to eq(entities.size)
    end

    # Both are published in the file, on records that are otherwise identical
    # to ones published without them.
    it "does not let the publisher's stray padding change an id" do
      padded = ActiveSanction::Sources::CanadaSema::SourceRef
               .for(country: "Venezuela ", schedule: nil, item: "1 ", name: "Nicolás MADURO MOROS")
      expect(entity("MADURO").source_ref).to eq(padded)
    end

    # The citation alone is unique across the published list; the name is in
    # the hash so that a renumbered schedule cannot hand one person's id to
    # another. See SourceRef for the whole argument.
    it "gives two people at one citation two different ids" do
      one = ActiveSanction::Sources::CanadaSema::SourceRef
            .for(country: "Russia", schedule: "1, Part 1", item: "7", name: "Ivan Ivanov")
      other = ActiveSanction::Sources::CanadaSema::SourceRef
              .for(country: "Russia", schedule: "1, Part 1", item: "7", name: "Pyotr Petrov")
      expect(one).not_to eq(other)
    end
  end

  describe "names" do
    # Joined in filing order this reads "Balaba Dmitry Vladimirovich", which
    # is not how anyone types a name into a screening form.
    it "joins a person's parts the way the name is spoken, not the way it is filed" do
      expect(entity("Balaba").primary_name.value).to eq("Dmitry Vladimirovich Balaba")
    end

    it "reads an organization's whole name out of the one element it is in" do
      expect(entity("Lakhta Plaza").primary_name.value).to eq("Lakhta Plaza")
    end

    # 764 values in the published file are padded with U+00A0, which
    # String#strip does not touch: "Premier " would reach the matcher as
    # a name nothing types.
    it "strips the non-breaking space the publisher pads its names with" do
      expect(entities.map { |record| record.primary_name.value }).to include("Premier")
    end

    it "splits an alias field on the separator that is unambiguous" do
      expect(entity("Lakhta Plaza").names.map { |name| [name.value, name.kind] })
        .to eq([["Lakhta Plaza", :primary],
                ["Lakhta Plaza Limited Liability Company", :aka],
                ["Lakhta Plaza LLC", :aka],
                ["Общество c Ограниченной Ответственностью \"Лахта Плаза\"", :aka]])
    end

    # Splitting this one on its commas would produce "ООО"-shaped fragments
    # elsewhere in the list -- a bare Russian legal form as an alias matches
    # thousands of real companies. See the class comment.
    it "leaves a comma-separated alias field as one alias" do
      expect(entity("Islamic Revolutionary Guard Corps").names.reject(&:primary?).map(&:value))
        .to eq(["IRGC, Army of the Guardians of the Islamic Revolution, Iranian Revolutionary Guards, IRG, " \
                "Sepah-e Pasdaran-e Enghelab-e Eslami/GRI, CGRI, l'Armée des Gardiens de la Révolution islamique, " \
                "Gardiens de la Révolution iranienne, Sepah-e Pasdaran-e Enghelab-e Eslami et Pasdaran"])
    end

    # A name is never bilingual-split: this organization's name pairs its two
    # languages on a bare "/", and so does "Victory/Pobeda Political Bloc",
    # which is one name in one language.
    it "keeps a name whole even when it looks bilingual" do
      expect(entity("Islamic Revolutionary Guard Corps").primary_name.value)
        .to eq("Islamic Revolutionary Guard Corps/Corps des Gardiens de la Révolution islamique")
    end

    it "files every alias as an aka, because Canada publishes no alias kinds" do
      expect(entities.flat_map(&:names).reject(&:primary?).map(&:kind).uniq).to eq([:aka])
    end

    it "grades no alias, because Canada publishes no grades" do
      expect(entities.flat_map(&:names).map(&:quality).uniq).to eq([nil])
    end
  end

  describe "bilingual values" do
    it "keeps the English half of a country paired on a slash" do
      expect(entity("Balaba").programs).to eq(["Belarus"])
    end

    it "keeps a country published in one language whole" do
      expect(entity("AKSYONOV").programs).to eq(["Ukraine"])
    end

    it "keeps the whole of a country whose English half has its own brackets" do
      expect(entity("ABAHUSSAIN").programs)
        .to eq(["Justice for Victims of Corrupt Foreign Officials Regulations (JVCFOR)"])
    end

    it "retains the French the publisher wrote, which the canonical field drops" do
      expect(entity("Balaba").remarks).to include("Country: Belarus / Bélarus")
    end

    # Not a nationality: a Ukrainian official listed under the Special Economic
    # Measures (Russia) Regulations is published under "Russia / Russie", and
    # 80 records name a statute rather than a country at all.
    it "reads the country element as the regulation it names, not as a nationality" do
      expect(entity("Balaba")).to have_attributes(programs: ["Belarus"], nationalities: [])
    end
  end

  describe "dates" do
    it "reads a year-only date as a year, not as the first of January" do
      expect(entity("Balaba").dates_of_birth.first)
        .to have_attributes(to_s: "1972", precision: :year)
    end

    it "reads a full date" do
      expect(entity("Barsukov").dates_of_birth.map(&:to_s)).to eq(["1965-04-29"])
    end

    # Nine of the published dates are two candidate dates rather than one,
    # which is what dates_of_birth is plural for.
    it "keeps both dates the publisher gave rather than choosing between them" do
      expect(entity("ABAHUSSAIN").dates_of_birth.map(&:to_s)).to eq(%w[1972-08-10 1972-08-11])
    end

    it "reads the listing date, which every record carries" do
      expect(entity("Balaba").listed_on.to_s).to eq("2020-09-28")
    end

    it "gives a person with no date published none rather than a guess" do
      expect(entity("Atabekov").dates_of_birth).to be_empty
    end
  end

  describe "the element that means a birth date on a person and a build date on a ship" do
    it "gives a vessel no date of birth, because a hull has not got one" do
      expect(entity("Balitiyskiy").dates_of_birth).to be_empty
    end

    it "keeps the ship's build year, in the remark where it belongs" do
      expect(entity("Balitiyskiy").remarks).to include("Built: 1980")
    end

    it "reads the same element as a date of birth on a person" do
      expect(entity("Balaba").remarks).not_to include("Built:")
    end
  end

  describe "vessels" do
    it "keeps the IMO number, which is the most decisive thing this list publishes" do
      expect(entity("Balitiyskiy").identifiers.map { |id| [id.kind, id.value, id.note] })
        .to eq([[:registration_number, "7612448", "IMO number"]])
    end

    it "reads a ship type paired on a pipe rather than on a slash" do
      expect(entity("Premier").remarks).to include("Vessel type: Oil Products Tanker | Navire-citerne")
    end

    # Sixteen vessel types are published with a newline mid-phrase.
    it "takes the publisher's line wrapping out of a remark" do
      expect(entity("Dmitry Mendeleev").remarks)
        .to include("Vessel type: Bunkering Tanker (LNG) | Navire-citerne de soutage (GNL)")
    end
  end

  describe "what the canonical model has no home for" do
    it "keeps the citation the id was derived from, which is how a listing is looked up" do
      expect(entity("Balaba").remarks).to eq("[source fields] Country: Belarus / Bélarus; " \
                                             "Schedule: 1, Part 1; Item: 2")
    end

    it "keeps a rank, which is prose about a person and not a program" do
      expect(entity("Al-Ahmad").remarks).to include("Title: Major General | major-général")
    end

    it "leaves the schedule out for the 329 records published without one" do
      expect(entity("MADURO").remarks).to eq("[source fields] Country: Venezuela; Item: 1")
    end

    # The marker is what lets #19 tell the publisher's own words from ours.
    # Canada writes none, so a Canadian record has nothing before it.
    it "reports no published text, because Canada publishes none" do
      expect(entities.filter_map { |record| ActiveSanction::Sources::Remarks.published(record.remarks) })
        .to be_empty
    end
  end

  describe "dates that cannot be read" do
    it "keeps an unreadable date verbatim rather than dropping it" do
      expect(entity("Hamdan Dagalo").remarks).to include("Date of birth: born in the early 1970s")
    end

    it "says which record and which value, so a new spelling can be added" do
      entities
      expect(adapter.warnings.map(&:message))
        .to include(/"Kirill Alekseevich MORDASHOV" has a date this parser does not read \("Sep-99"\)/)
    end

    it "warns once per record rather than once per field that reads it" do
      entities
      expect(adapter.warnings.size).to eq(2)
    end

    it "does not print a date in the remark when it was read into the model" do
      expect(entity("Barsukov").remarks).not_to include("Date of birth:")
    end
  end

  describe "records that cannot be used" do
    it "skips a record with no name at all and says which one" do
      adapter.parse(<<~XML)
        <data-set>
          <record><Country-Pays>Russia / Russie</Country-Pays><Item-NumeroDarticle>4</Item-NumeroDarticle></record>
        </data-set>
      XML
      expect(adapter.warnings.map(&:message)).to include(/<record> at item "4" has no name and was skipped/)
    end
  end

  describe "the whole fixture, as the acceptance criteria state it" do
    it "produces no blank-valued name" do
      expect(entities.flat_map(&:names).map(&:value)).to all(match(/\S/))
    end

    it "leaves no non-breaking space inside a name" do
      expect(entities.flat_map(&:names).map(&:value)).to all(satisfy { |value| !value.include?("\u00A0") })
    end

    it "publishes every date as a PartialDate" do
      expect(entities.flat_map(&:dates_of_birth)).to all(be_a(ActiveSanction::PartialDate))
    end

    it "round-trips through the serialized form storage will use" do
      snapshot = adapter.snapshot(raw)
      expect(ActiveSanction::Snapshot.from_h(snapshot.to_h)).to eq(snapshot)
    end
  end

  describe "syncing end to end" do
    let(:cache_dir) { Dir.mktmpdir("active_sanction_canada") }
    let(:fetcher) do
      ActiveSanction::Fetcher.new(client: ActiveSanction::HttpClient.new(retry_backoff: 0.001),
                                  store: ActiveSanction::ValidatorStore::Memory.new)
    end

    after { FileUtils.remove_entry(cache_dir) if File.directory?(cache_dir) }

    def source = described_class.new(fetcher: fetcher, cache: ActiveSanction::PayloadCache.new(dir: cache_dir))

    # The document element carries no generation date -- it is
    # `<data-set xmlns:xsi="...">` and nothing else -- so Last-Modified, which
    # Global Affairs does serve, is the only version marker there is.
    it "fetches the document and checksums it into one Snapshot" do
      stub_request(:get, described_class.url(:main))
        .to_return(status: 200, body: raw, headers: { "Last-Modified" => "Mon, 24 Aug 2026 19:02:14 GMT" })

      expect(source.sync).to be_a(ActiveSanction::Snapshot)
        .and have_attributes(source: :canada_sema, record_count: 16,
                             source_version: "Mon, 24 Aug 2026 19:02:14 GMT")
    end

    it "returns nil when the publisher says nothing has changed" do
      stub_request(:get, described_class.url(:main)).to_return(status: 200, body: raw,
                                                               headers: { "ETag" => '"canada-1"' })
      client = source
      client.sync
      stub_request(:get, described_class.url(:main)).to_return(status: 304)

      expect(client.sync).to be_nil
    end
  end

  # Excluded by default. The committed fixture is sixteen records chosen to
  # cover every quirk; only the real document can confirm the counts the list
  # actually publishes.
  describe "against the published list", :live do
    it "parses every record Global Affairs has listed" do
      snapshot = described_class.new.sync

      expect(snapshot.record_count).to be_within(400).of(5_690)
    end
  end
end
