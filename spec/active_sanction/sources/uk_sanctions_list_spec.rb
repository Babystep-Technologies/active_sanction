# frozen_string_literal: true

RSpec.describe ActiveSanction::Sources::UkSanctionsList do
  def raw = File.binread(File.expand_path("../../fixtures/uk_sanctions_list/uk-sanctions-list.xml", __dir__))

  let(:adapter) { described_class.new }
  let(:entities) { adapter.parse(raw) }

  def entity(ref) = entities.find { |candidate| candidate.source_ref == ref }

  def names_of(ref) = entity(ref).names.map { |name| [name.value, name.kind, name.quality] }

  def identifiers_of(ref) = entity(ref).identifiers.map { |id| [id.kind, id.value] }

  it_behaves_like "a sanction source", fixture: "uk_sanctions_list/uk-sanctions-list.xml"

  # The fixture is twenty-one real designations lifted verbatim from the
  # published list, chosen because between them they carry every quirk this
  # adapter exists to absorb: all three designation types, a name split across
  # five numbered parts, a name padded with trailing spaces, two names the FCDO
  # both calls primary, an empty <Name> element, a spelling published twice, a
  # graded primary name variation, both alias strengths on one record, a name
  # in Arabic and two in Cyrillic, a Latin string filed as a non-Latin name, a
  # full birth date, ten year-only ones written `dd/mm/1945`, a month written
  # `dd/09/1958`, a year written `00/00/1975`, a birth date with no year at
  # all, a passport with no number, a national identity "number" that is a
  # sentence, a registration number carrying three labelled numbers and two
  # newlines, an IMO number with the prefix and one without, an address that is
  # only a country, an address with no country, a nationality with no ISO code,
  # and a record on which the FCDO published no prose whatsoever.

  describe "what it declares" do
    it "registers itself, so requiring the gem is enough to reach it" do
      expect(ActiveSanction::Sources[:uk_sanctions_list]).to eq(described_class)
    end

    it "names the publisher the way a compliance report has to print it" do
      expect(described_class.authority).to eq("Foreign, Commonwealth and Development Office")
    end

    # The FCDO made these static in January 2026 precisely so that a screening
    # system does not have to re-discover the link on every refresh.
    it "declares the one static document the whole list arrives in" do
      expect(described_class.urls)
        .to eq(main: "https://sanctionslist.fcdo.gov.uk/docs/UK-Sanctions-List.xml")
    end

    # The list this adapter was scoped against was retired on 28 January 2026,
    # and the blob it was served from still answers 200 with a frozen file.
    it "does not read the retired OFSI consolidated list" do
      expect(described_class.urls.values.join).not_to include("ofsistorage")
    end
  end

  describe "reading one record shape out of 21.8 MB" do
    it "builds an entity from every Designation, in document order" do
      expect(entities.map(&:source_ref)).to eq(%w[AFG0001 AFG0006 AFG0007 AFG0009 AFG0038 AFG0043 AQD0030
                                                  AQD0190 AQD0260 AQD0262 BEL0004 BEL0108 BEL0174 DPR0075
                                                  DPR0076 GAC0072 GIM0029 GUB0009 RUS1683 RUS2701 RUS3379])
    end

    # 664 of the published records are ships, and a search for a person that
    # can rank a tanker is what the distinct type closes.
    it "types people, organizations and ships apart" do
      expect(entities.map(&:type).tally).to eq(individual: 14, organization: 5, vessel: 2)
    end

    it "identifies a record by the Unique ID that survives the OFSI retirement" do
      expect(entity("AFG0001").id).to eq("uk_sanctions_list:AFG0001")
    end

    # The generation date is an element sibling of the records rather than an
    # attribute of the document, so it is read on the one pass past it.
    it "reads the list version the FCDO stamps on the document" do
      entities
      expect(adapter.source_version).to eq("07/09/2026")
    end

    it "reads the whole fixture without a complaint" do
      entities
      expect(adapter.warnings).to be_empty
    end
  end

  describe "a name split across six numbered parts" do
    it "joins the parts in the order the name is said" do
      expect(entity("AFG0007").primary_name.value).to eq("Abdul Kabir MOHAMMAD JAN")
    end

    it "reads an organization whose whole name is in Name6 alone" do
      expect(entity("AFG0001").primary_name.value).to eq("HAJI KHAIRULLAH HAJI SATTAR MONEY EXCHANGE")
    end

    it "reads a person whose only part is Name1" do
      expect(entity("AFG0043").primary_name.value).to eq("MOHAMMAD YAQOUB")
    end

    # `<Name1>IADENA  </Name1><Name6>MOHAMMAD </Name6>`, which joined verbatim
    # is "IADENA   MOHAMMAD " -- a name nothing will ever match.
    it "collapses the whitespace the FCDO pads a part with" do
      expect(names_of("AFG0038").map(&:first)).to include("IADENA MOHAMMAD")
    end

    # 26 of the 15,677 published <Name> elements carry a NameType and no part.
    it "drops a Name element with no parts rather than building a blank name" do
      expect(names_of("BEL0174").map(&:first)).to eq(["Pavel Ivanovich KAZAKOV", "Pavel Ivanavich KAZAKOU",
                                                      "Павел Іванавіч Казакоў", "Павел Иванович Казаков"])
    end

    # 36 names across 35 records repeat a spelling already on the record.
    it "files one name per spelling, not one per NameType" do
      values = entities.flat_map { |record| record.names.map(&:value) }
      expect(values.size).to eq(values.uniq.size)
    end
  end

  describe "the primary name, which the FCDO marks itself" do
    it "takes the name the FCDO designated rather than choosing one" do
      expect(entity("AQD0260").primary_name.value).to eq("MUHAMMAD JAMAL ABD-AL RAHIM AHMAD AL-KASHIF")
    end

    # 5,513 names are Primary Name Variations -- alternative spellings of the
    # designated name, not alternative designations.
    it "files a primary name variation as an alias" do
      expect(names_of("AFG0038")).to eq([["DIN MOHAMMAD HANIF", :primary, nil],
                                         ["IADENA MOHAMMAD", :primary, nil],
                                         ["IADENAMOHAMMAD NAZRI MOHAMMAD", :aka, nil],
                                         ["QARI DIN MOHAMMAD", :aka, nil],
                                         ["دین محمد حنیف", :aka, nil]])
    end

    # Six records carry two. Passing both through is the FCDO's own marking;
    # picking one would be this adapter inventing a rule the publisher has.
    it "keeps both names on a record the FCDO marks primary twice" do
      expect(entity("AFG0038").names.count(&:primary?)).to eq(2)
    end
  end

  describe "the alias grading the FCDO publishes as a field" do
    it "reads good and low quality off AliasStrength" do
      expect(names_of("AFG0009")).to eq([["Muhammad Taher Anwari", :primary, nil],
                                         ["Mohammad Taher Anwari", :aka, :good],
                                         ["Mohammad Tahre Anwari", :aka, :good],
                                         ["Muhammad Tahir Anwari", :aka, :good],
                                         ["Mudir", :aka, :low],
                                         ["محمد طاهر أنوري", :aka, nil]])
    end

    # An ungraded name must not be penalized for a field the FCDO did not fill
    # in, and must not be credited for one either.
    it "leaves a name the FCDO did not grade ungraded, rather than calling it good" do
      expect(names_of("BEL0004").map(&:last).uniq).to eq([nil])
    end
  end

  describe "names in a script the FCDO does not romanize" do
    it "keeps the original-script name as an alias" do
      expect(names_of("AFG0043")).to eq([["MOHAMMAD YAQOUB", :primary, nil],
                                         ["محمد يعقوب", :aka, nil]])
    end

    # NonLatinScriptType agrees with the characters on 2,054 of the 2,057 names
    # that carry it. Three are Latin transliterations labelled Cyrillic, and
    # 185 of the 3,856 non-Latin names hold no non-Latin character at all.
    it "leaves the script unstated rather than declaring the FCDO's own label" do
      expect(entities.flat_map { |record| record.names.map(&:script) }.uniq).to eq([nil])
    end

    it "keeps a Latin string the FCDO filed as a non-Latin name, as published" do
      expect(names_of("RUS3379").map(&:first))
        .to include('OAO "STUPINSKAYA METALLURGICHESKAYA KOMPANIYA"')
    end

    it "records the FCDO's script label in remarks, where a reviewer can weigh it" do
      expect(entity("BEL0174").remarks).to include("Non-Latin script: Cyrillic")
    end
  end

  # The trap: a component the FCDO does not know is spelled out, not omitted.
  describe "dates of birth" do
    it "reads a full date" do
      expect(entity("BEL0174").dates_of_birth.map(&:to_s)).to eq(["1977-06-11"])
    end

    # 800 of the 3,788 published birth dates are written this way, and every
    # one of them reads as nil through an ordinary date parser.
    it "reads dd/mm/1945 as a year, not as the first of January" do
      expect(entity("AFG0006").dates_of_birth.first).to have_attributes(to_s: "1945", precision: :year)
    end

    it "keeps every date the FCDO listed rather than choosing between them" do
      expect(entity("AFG0006").dates_of_birth.map(&:to_s))
        .to eq(%w[1945 1946 1947 1948 1949 1950 1955 1956 1958 1957])
    end

    it "reads dd/09/1958 as a year and a month without inventing a day" do
      expect(entity("AQD0262").dates_of_birth.first).to have_attributes(to_s: "1958-09", precision: :month)
    end

    # One record spells the same absence with zeros instead of letters.
    it "reads 00/00/1975 as a year, never as a zeroth day of a zeroth month" do
      expect(entity("RUS1683").dates_of_birth.first).to have_attributes(to_s: "1975", precision: :year)
    end

    # `15/08/19yy` is a day and a month and a century. PartialDate has no shape
    # for a date with no year, and inventing one is the false precision it
    # exists to prevent.
    it "produces no date from a birth date that states no year" do
      expect(entity("RUS2701").dates_of_birth).to be_empty
    end

    it "keeps the date it could not read, rather than losing it" do
      expect(entity("RUS2701").remarks).to include("Date of birth as published: 15/08/19yy")
    end

    it "publishes no date twice, however many times the export repeated it" do
      dates = entity("AFG0038").dates_of_birth
      expect(dates.size).to eq(dates.uniq.size)
    end
  end

  describe "the date convention itself" do
    def read(text) = described_class::PublishedDate.call(text)

    it "reads a fully stated date at day precision" do
      expect(read("04/08/2026")).to have_attributes(to_s: "2026-08-04", precision: :day)
    end

    it "reads a bare year, which 40 birth dates are" do
      expect(read("1962")).to have_attributes(to_s: "1962", precision: :year)
    end

    # A day under a month the FCDO did not state is a day of an unknown month,
    # which PartialDate rightly refuses -- so the day goes with the month.
    it "drops a day the FCDO gave under a month it did not" do
      expect(read("15/mm/1975")).to have_attributes(to_s: "1975", precision: :year)
    end

    it "reads nothing from a date with no year" do
      expect(read("15/08/19yy")).to be_nil
    end

    it "reads nothing from an empty field" do
      expect(read(nil)).to be_nil
    end

    # The list publishes no 31 February today. A screening tool should not be
    # the thing that breaks on the day it does.
    it "reads nothing from an impossible date, rather than raising" do
      expect(read("31/02/1972")).to be_nil
    end
  end

  describe "documents" do
    it "reads a passport and keeps the FCDO's sentence about it" do
      expect(entity("GUB0009").identifiers.first)
        .to have_attributes(kind: :passport, value: "AAID00435",
                            note: a_string_including("Expires 18 February 2013"))
    end

    # The export repeats a passport once per birth date: this record publishes
    # the same number ten times.
    it "publishes one identifier per document, not one per repetition" do
      expect(identifiers_of("AFG0006")).to eq([[:passport, "P04581926"]])
    end

    # 8 of the 780 passport elements describe a document and give no number.
    it "drops a document with a description and no number to match on" do
      expect(identifiers_of("AQD0260")).to eq([[:passport, "6487"], [:passport, "388181"]])
    end

    # 340 of the 721 registration numbers open with a label, and a handful
    # carry several numbers, a country and a newline in one field. Every rule
    # that peeled off `INN: ` is a guess about the rest.
    it "keeps a registration number exactly as the FCDO wrote it, label and all" do
      expect(identifiers_of("GAC0072"))
        .to eq([[:registration_number, "OGRN: 1247700291200\nKPP: 770701001\nINN: 9707028663"]])
    end

    it "keeps a national identity number the FCDO wrote as a sentence" do
      expect(identifiers_of("AQD0190"))
        .to eq([[:passport, "1739010"], [:national_id, "Kuwait, number 260012001546"]])
    end
  end

  describe "a ship's IMO number" do
    # 635 of the 670 are published as `IMO9562233` and 35 as `9562233`. Left
    # alone, the FCDO's own two spellings of one registry number are two
    # different identifiers to the scorer.
    it "peels the prefix off, so the FCDO's two spellings are one number" do
      expect(entity("DPR0075").identifiers.first)
        .to have_attributes(kind: :other, value: "9562233", note: "IMO number")
    end

    it "reads a number the FCDO published without the prefix" do
      expect(identifiers_of("DPR0076")).to eq([[:other, "8628597"]])
    end

    it "keeps the flag, owner and tonnage the canonical model has no home for" do
      expect(entity("DPR0075").remarks)
        .to include("Current believed flag: Comoros", "Type of ship: Bulk Carrier", "Tonnage: 7078")
    end
  end

  describe "addresses" do
    # Lines 1 to 5 are the street and the locality detail, in order.
    it "joins the numbered address lines in the order they are written" do
      expect(entity("RUS3379").addresses.first.to_h)
        .to eq(street: "20A Stationnaya Street, Central District, Domodedovo City", city: "Moscow",
               state_province: nil, postal_code: "142000", country: "Russia", note: nil)
    end

    # 450 of the 3,816 addresses have line 6 as their only line.
    it "reads an address that is only a country, which many are" do
      expect(entity("AQD0190").addresses.map(&:to_h))
        .to eq([{ street: nil, city: nil, state_province: nil, postal_code: nil,
                  country: "Kuwait", note: nil }])
    end

    # Line 6 holds `Kabul` and `Dubai` on some records and `Helmand Province`
    # on others, so it is filed whole rather than split on a guess.
    it "files the last line before the country under city, whole" do
      expect(entity("AFG0006").addresses.first.city).to eq("Kabul")
    end

    it "keeps an address the FCDO gave no country for" do
      expect(entity("RUS2701").addresses.map(&:street)).to eq(["Moscow, Russia"])
    end
  end

  describe "nationalities, regimes and the OFSI reference" do
    # Prose, the way the UN publishes it. Country resolves it at scoring time.
    it "publishes the nationality as the FCDO wrote it" do
      expect(entity("AQD0260").nationalities).to eq(["Egypt"])
    end

    # Kosovo has no ISO 3166-1 code, and Scorer::Adjustments reads a country it
    # cannot resolve as absent rather than as a conflict.
    it "keeps a nationality no ISO code exists for" do
      expect(entity("GIM0029").nationalities).to eq(["Kosovo"])
    end

    it "reads the statutory instrument as the programme the designation is under" do
      expect(entity("RUS3379").programs).to eq(["The Russia (Sanctions) (EU Exit) Regulations 2019"])
    end

    it "reads the designation date every record carries" do
      expect(entity("GIM0029").listed_on.to_s).to eq("2025-10-22")
    end

    # The Group ID is retired for new designations but stays valid for a licence
    # application or a breach report, so a hit can still be reconciled with it.
    it "keeps the historic OFSI group id a pre-2026 designation carries" do
      expect(entity("AFG0001").remarks).to include("OFSI group id: 12703")
    end

    it "records which authority designated the entity" do
      expect(entity("BEL0174").remarks).to include("Designation source: UK")
    end

    # The regime is what a designation is made under; the measures actually
    # imposed are a separate field and go to remarks rather than to programs.
    it "keeps the measures imposed out of the programme list" do
      expect(entity("DPR0076").remarks).to include("Sanctions imposed: De-flag|Prohibition of port entry")
    end
  end

  describe "the FCDO's own prose" do
    it "keeps the note on the designation and the statement of reasons, in that order" do
      published = ActiveSanction::Sources::Remarks.published(entity("BEL0108").remarks)
      expect(published).to start_with("The Director Disqualification Sanction was imposed on 09/04/2025.")
        .and include("BELAERONAVIGATSIA Republican Unitary Air Navigation Services Enterprise is responsible")
    end

    # 127 of the 6,334 records carry neither field. What a consumer asking what
    # the FCDO said should get back is nothing, not a list of source fields.
    it "reports no published prose for a record the FCDO wrote none on" do
      expect(ActiveSanction::Sources::Remarks.published(entity("AQD0030").remarks)).to be_nil
    end

    it "keeps what it appended behind the marker, where it can be stripped again" do
      expect(entity("AQD0030").remarks).to start_with("#{ActiveSanction::Sources::Remarks::MARKER} ")
    end
  end
end
