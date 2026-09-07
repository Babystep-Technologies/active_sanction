# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe ActiveSanction::Sources::EuFsf do
  def raw = File.binread(File.expand_path("../../fixtures/eu_fsf/fsf.xml", __dir__))

  let(:adapter) { described_class.new }
  let(:entities) { adapter.parse(raw) }

  def entity(ref) = entities.find { |candidate| candidate.source_ref == ref }

  def names_of(ref) = entity(ref).names.map { |name| [name.value, name.kind, name.quality] }

  it_behaves_like "a sanction source", fixture: "eu_fsf/fsf.xml"

  # The fixture is seventeen real records lifted verbatim from the published
  # list, chosen because between them they carry every quirk this adapter
  # exists to absorb: both subject types, a name graded in prose, a former
  # name, a paragraph that mentions a former name and does not mean this one,
  # a name padded with a double space, an exact date, a year, a year and a
  # month, a span, a Hijri year with a Gregorian equivalent and one without, a
  # birth place with no birth date, a document number written as `-`, an
  # address that is only a country, a phone number, the `00` country sentinel,
  # a UN cross-reference and a record with no designation date.
  describe "what it declares" do
    it "registers itself, so requiring the gem is enough to reach it" do
      expect(ActiveSanction::Sources[:eu_fsf]).to eq(described_class)
    end

    it "names the publisher the way a compliance report has to print it" do
      expect(described_class.authority).to eq("European Commission")
    end

    it "declares the one document the whole list arrives in" do
      expect(described_class.urls.keys).to eq([:main])
    end

    it "carries the public token the endpoint answers 403 without" do
      expect(described_class.url(:main)).to end_with("?token=dG9rZW4tMjAxNw")
    end

    # The token is not a credential and not expected to move, but a release of
    # this gem must not be what it takes to follow it if it does.
    it "lets a host re-point the list at a rotated token" do
      original = described_class.url(:main)
      described_class.token = "rotated"
      expect(described_class.url(:main)).to end_with("?token=rotated")
    ensure
      described_class.url :main, original
    end
  end

  describe "reading one record shape out of 25.7 MB" do
    it "builds an entity from every sanctionEntity, in document order" do
      expect(entities.map(&:source_ref)).to eq(%w[EU.27.28 EU.39.56 EU.367.96 EU.3672.18 EU.1905.90
                                                  EU.3092.36 EU.2417.3 EU.2909.48 EU.2797.3 EU.4198.83
                                                  EU.4801.12 EU.6002.12 EU.6131.26 EU.8060.95 EU.9786.78
                                                  EU.10436.68 EU.11094.30])
    end

    it "types people and organizations apart, which is all subjectType publishes" do
      expect(entities.map(&:type).tally).to eq(individual: 10, organization: 7)
    end

    # `logicalId` is unique too, but the reference number is what the
    # Commission prints in its own consolidated list.
    it "identifies a record by the reference number a person can look up" do
      expect(entity("EU.27.28").id).to eq("eu_fsf:EU.27.28")
    end

    it "reads the list version off the document element, to the millisecond" do
      entities
      expect(adapter.source_version).to eq("2026-08-05T16:47:04.449+02:00")
    end
  end

  # The first trap: the EU marks no name as the official one.
  describe "choosing a name to call primary" do
    it "promotes the first name the Commission did not annotate as an alias" do
      expect(entity("EU.27.28").primary_name.value).to eq("Saddam Hussein Al-Tikriti")
    end

    it "files every other name as an alias" do
      expect(names_of("EU.27.28")).to eq([["Saddam Hussein Al-Tikriti", :primary, nil],
                                          ["Abu Ali", :aka, nil],
                                          ["Abou Ali", :aka, nil]])
    end

    # 24 records lead with a name their own remark calls weak.
    it "passes over a name the Commission graded and takes the next one" do
      expect(entity("EU.367.96").primary_name.value).to eq("عبد المنان آغا")
    end

    it "leaves the script unstated rather than inferring it from nameLanguage" do
      expect(entity("EU.2797.3").names.map(&:script).uniq).to eq([nil])
    end

    # Record EU.2797.3 files a Cyrillic spelling under nameLanguage="EN", which
    # is why nothing here reads that attribute.
    it "keeps a name in its own script as an alias" do
      expect(names_of("EU.2797.3")).to eq([["Anatoliy Alekseevich SIDOROV", :primary, nil],
                                           ["Анатолий Алексеевич СИДОРОВ", :aka, nil]])
    end

    # 2,149 of the 31,053 published names carry a newline or a run of spaces.
    it "collapses the whitespace the Commission pads a name with" do
      expect(entity("EU.2417.3").primary_name.value).to eq("Taghtiran Kashan Company")
    end

    # 222 records file the same spelling twice under two nameLanguage values.
    it "files one name per spelling, not one per language" do
      values = entities.flat_map { |record| record.names.map(&:value) }
      expect(values.size).to eq(values.uniq.size)
    end
  end

  describe "the grading the EU writes as prose instead of as a column" do
    it "reads low and good quality off a name's own remark" do
      expect(names_of("EU.367.96").map { |_value, _kind, quality| quality })
        .to eq([nil, nil, :low, :low, :good])
    end

    it "reads a former name as a former name, which ranks below a current one" do
      expect(names_of("EU.8060.95")).to eq([["Sovcombank", :primary, nil],
                                            ["Buycombank", :fka, nil]])
    end

    # The reason the grading is anchored to the start of a clause: Zadna's own
    # remark says the company is "99 % owned by the Special Fund ..., formerly
    # known as the Charity Organisation", which is a sentence about the owner.
    it "does not read a former name out of a paragraph that names somebody else's" do
      expect(names_of("EU.11094.30").first)
        .to eq(["Zadna International Company for Investment Limited", :primary, nil])
    end
  end

  # The second trap: four birth dates are not in the Gregorian calendar.
  describe "dates of birth" do
    it "reads an exact full date" do
      expect(entity("EU.27.28").dates_of_birth.map(&:to_s)).to eq(["1937-04-28"])
    end

    it "reads a year-only date as a year, not as the first of January" do
      expect(entity("EU.39.56").dates_of_birth.first).to have_attributes(to_s: "1966", precision: :year)
    end

    it "reads a year and a month without inventing a day" do
      expect(entity("EU.2909.48").dates_of_birth.map(&:to_s)).to eq(%w[1960 1961-08])
    end

    it "reads a year range as a span rather than picking an end of it" do
      expect(entity("EU.10436.68").dates_of_birth.first)
        .to have_attributes(to_s: "1960 to 1979", precision: :range)
    end

    it "keeps every date the Council listed rather than choosing between them" do
      expect(entity("EU.39.56").dates_of_birth.map(&:to_s)).to eq(%w[1966 1965])
    end

    # `year="1402"` beside `birthdate="1982-04-19"`: the components are Hijri
    # and the attribute is the conversion.
    it "takes the Gregorian conversion where a Hijri date has one" do
      expect(entity("EU.3092.36").dates_of_birth.map(&:to_s)).to eq(%w[1982-04-18 1982-04-19])
    end

    # Three records publish a Hijri year and nothing else. Read as published,
    # 1343 conflicts with every real date and the scorer penalizes the record.
    it "produces no date at all from a Hijri year with no conversion" do
      expect(entity("EU.6131.26").dates_of_birth.map(&:to_s)).to eq(%w[1965 1964])
    end

    it "keeps the Hijri date it could not read, rather than losing it" do
      expect(entity("EU.6131.26").remarks).to include("Date of birth as published: 1343 (islamic calendar)")
    end

    # 110 birthdate elements are a place of birth and no date.
    it "produces no date from a birthdate element that gives only a place" do
      expect(entity("EU.6002.12").dates_of_birth).to be_empty
    end

    it "publishes no date more than once, however many ways it was written" do
      dates = entity("EU.3092.36").dates_of_birth
      expect(dates.size).to eq(dates.uniq.size)
    end
  end

  describe "documents" do
    it "maps the EU's type codes onto identifier kinds" do
      expect(entity("EU.9786.78").identifiers.map { |id| [id.kind, id.value] })
        .to eq([[:tax_id, "7811636632"], [:registration_number, "1177847044066"], [:other, "06513574"]])
    end

    it "keeps the Commission's own description for a kind it could not classify" do
      expect(entity("EU.4198.83").identifiers.first)
        .to have_attributes(kind: :other, value: "5342883", note: "IMO (vessel identification)")
    end

    it "keeps the issuing country and expiry, which are what make a hit decisive" do
      passport = entity("EU.3092.36").identifiers.find { |id| id.kind == :passport }
      expect(passport).to have_attributes(value: "F654645", country: "SAUDI ARABIA")
    end

    it "notes a document the Commission says has expired" do
      passport = entity("EU.3092.36").identifiers.find { |id| id.kind == :passport }
      expect(passport.note).to end_with("known expired")
    end

    # Six documents in the published file write `-` where a number goes.
    it "drops a document whose number is the Commission's placeholder" do
      expect(entity("EU.2417.3").identifiers).to be_empty
    end
  end

  describe "addresses, nationalities and programs" do
    it "reads an address that is only a country, which many are" do
      expect(entity("EU.3092.36").addresses.map(&:to_s)).to eq(["YEMEN"])
    end

    # contactInfo has no member on Address and is real locating detail.
    it "keeps a phone number the canonical model has no field for" do
      expect(entity("EU.3672.18").addresses.first.note).to eq("PHONE: +253 (0) 99 983 784")
    end

    it "keeps a PO box, which is also not a member" do
      expect(entity("EU.2417.3").addresses.first.note).to start_with("P.O. Box 14316")
    end

    it "reads citizenship as the ISO code the scorer compares on" do
      expect(entity("EU.27.28").nationalities).to eq(["IQ"])
    end

    # 1,743 birth dates and 1,352 documents carry it.
    it "drops the 00 country sentinel rather than filing it as a country" do
      expect(entity("EU.9786.78").identifiers.map(&:country)).to eq([nil, "RUSSIAN FEDERATION", nil])
    end

    it "reads the regulation's programme as the sanctions program" do
      expect(entity("EU.4198.83").programs).to eq(["PRK"])
    end

    it "reads the designation date, not the date of the amending regulation" do
      expect(entity("EU.2797.3").listed_on.to_s).to eq("2014-03-17")
    end

    # 580 of the 6,234 published records carry no designationDate at all.
    it "leaves the listing date unset where the Commission published none" do
      expect(entity("EU.27.28").listed_on).to be_nil
    end
  end

  describe "what the canonical model has no home for" do
    it "keeps the Commission's own comment verbatim and first" do
      expect(entity("EU.27.28").remarks).to start_with("UNSC RESOLUTION 1483 [source fields]")
    end

    it "keeps the internal id, so a record can be reconciled with the EU's own database" do
      expect(entity("EU.27.28").remarks).to include("EU logical id: 13")
    end

    it "keeps the regulation and the Official Journal it was published in" do
      expect(entity("EU.4198.83").remarks).to include("Regulation: 2022/1503 (OJ L235)")
    end

    it "keeps the UN cross-reference for a record the Council took from a UN listing" do
      expect(entity("EU.4801.12").remarks).to include("UN reference: LYi.28")
    end

    it "keeps a place of birth rather than dropping it to keep the schema tidy" do
      expect(entity("EU.6002.12").remarks).to include("Place of birth: Damascus, SYRIAN ARAB REPUBLIC")
    end

    it "names a place of birth once however many birth dates reported it" do
      expect(entity("EU.39.56").remarks.scan("Place of birth").size).to eq(1)
    end

    it "keeps a function, which is prose about a role and not a program" do
      expect(entity("EU.2797.3").remarks).to include("Function: Commander, Russia's Western Military District.")
    end
  end

  describe "the whole fixture, as the acceptance criteria state it" do
    it "produces no blank-valued name" do
      expect(entities.flat_map(&:names).map(&:value)).to all(match(/\S/))
    end

    it "gives every record exactly one primary name" do
      expect(entities.map { |record| record.names.count(&:primary?) }.uniq).to eq([1])
    end

    it "produces only PartialDates for dates of birth" do
      expect(entities.flat_map(&:dates_of_birth)).to all(be_a(ActiveSanction::PartialDate))
    end

    # The Hijri trap, stated as the property it protects: a date of birth on
    # this list is a date somebody could have been born on.
    it "publishes no birth year from before photography" do
      expect(entities.flat_map(&:dates_of_birth).map { |date| date.first_date.year }).to all(be > 1850)
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
        <export generationDate="2026-01-01T00:00:00.000+02:00">
          <sanctionEntity euReferenceNumber="EU.1.1" logicalId="1">
            <subjectType code="person" classificationCode="P"/>
            <nameAlias wholeName="" logicalId="2"/>
          </sanctionEntity>
        </export>
      XML
      expect(adapter.warnings.map(&:message)).to include(/<sanctionEntity> "EU.1.1" has no name and was skipped/)
    end
  end

  describe "syncing end to end" do
    let(:cache_dir) { Dir.mktmpdir("active_sanction_eu") }
    let(:fetcher) do
      ActiveSanction::Fetcher.new(client: ActiveSanction::HttpClient.new(retry_backoff: 0.001),
                                  store: ActiveSanction::ValidatorStore::Memory.new)
    end

    after { FileUtils.remove_entry(cache_dir) if File.directory?(cache_dir) }

    def source = described_class.new(fetcher: fetcher, cache: ActiveSanction::PayloadCache.new(dir: cache_dir))

    it "fetches the document and checksums it into one Snapshot" do
      stub_request(:get, described_class.url(:main)).to_return(status: 200, body: raw)

      expect(source.sync).to be_a(ActiveSanction::Snapshot)
        .and have_attributes(source: :eu_fsf, record_count: 17,
                             source_version: "2026-08-05T16:47:04.449+02:00")
    end

    # The endpoint does not honour If-Modified-Since today, so this is the
    # branch that runs the day it does rather than the one that runs now.
    it "returns nil when the publisher says nothing has changed" do
      headers = { "Last-Modified" => "Wed, 05 Aug 2026 14:50:10 GMT" }
      stub_request(:get, described_class.url(:main)).to_return(status: 200, body: raw, headers: headers)
      client = source
      client.sync
      stub_request(:get, described_class.url(:main)).to_return(status: 304)

      expect(client.sync).to be_nil
    end
  end

  # Excluded by default. The committed fixture is seventeen records chosen to
  # cover every quirk; only the real document can confirm the counts the list
  # actually publishes, and it is 25.7 MB.
  describe "against the published list", :live do
    it "parses every person and entity the Council has listed" do
      snapshot = described_class.new.sync

      expect(snapshot.record_count).to be_within(600).of(6_234)
    end
  end
end
