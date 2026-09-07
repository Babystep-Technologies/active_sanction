# frozen_string_literal: true

RSpec.describe ActiveSanction::Sources::AustraliaDfat do
  def raw = File.binread(File.expand_path("../../fixtures/australia_dfat/consolidated-list.xlsx", __dir__))

  let(:adapter) { described_class.new }
  let(:entities) { adapter.parse(raw) }

  def entity(ref) = entities.find { |candidate| candidate.source_ref == ref }

  def names_of(ref) = entity(ref).names.map { |name| [name.value, name.kind, name.quality] }

  def dates_of(ref) = entity(ref).dates_of_birth.map(&:to_s)

  def extras_of(ref) = entity(ref).remarks.to_s.split(ActiveSanction::Sources::Remarks::MARKER).last.to_s

  it_behaves_like "a sanction source", fixture: "australia_dfat/consolidated-list.xlsx"

  # The fixture is seventeen real listings lifted verbatim from the published
  # workbook -- 124 of its 11,163 rows, with the shared strings they use and
  # the publisher's own styles, so every cell is encoded exactly as DFAT
  # encoded it. Between them they carry every quirk this adapter exists to
  # absorb: all three listing types, an alias reference with two letters, a
  # birth date as an Excel serial, as a month serial, as a plain year, as
  # `dd/mm/yyyy` text, as `Approximately`, as `Approximately: Between ... and`,
  # as a ten-year list and as two dates separated by a carriage return Excel
  # escaped; a birth date ending in a non-breaking space; two birth dates DFAT
  # typed wrong; names in Arabic and Cyrillic; both alias strengths on one
  # record; two citizenships in one cell; an address enumerated `a) ... b)`;
  # an address that is three places separated by semicolons; a place of birth
  # only an alias row carries; a vessel with an IMO number and a maritime
  # restriction; a record with no additional information; and a record whose
  # listing information names an instrument and no date.

  describe "what it declares" do
    it "registers itself, so requiring the gem is enough to reach it" do
      expect(ActiveSanction::Sources[:australia_dfat]).to eq(described_class)
    end

    it "names the publisher the way a compliance report has to print it" do
      expect(described_class.authority).to eq("Australian Sanctions Office, Department of Foreign Affairs and Trade")
    end

    it "declares the one spreadsheet the whole list arrives in" do
      expect(described_class.urls)
        .to eq(main: "https://www.dfat.gov.au/sites/default/files/Australian_Sanctions_Consolidated_List.xlsx")
    end

    # The path this gem was scoped against now redirects to a `.xls` last
    # modified in March 2022, which is served 200 and would look healthy on
    # every sync while being four years stale.
    it "does not read the retired regulation8 file" do
      expect(described_class.url).not_to include("regulation8")
    end

    it "says what it is, so a report does not have to infer the format" do
      expect(described_class.format).to eq(:xlsx)
    end
  end

  describe "joining rows into records" do
    it "builds one entity per reference, in published order" do
      expect(entities.map(&:source_ref))
        .to eq(%w[2 5 44 114 142 272 300 334 733 1145 1281 2557 2647 3125 8154 8227 8824])
    end

    it "identifies a record by DFAT's own reference" do
      expect(entity("2").id).to eq("australia_dfat:2")
    end

    # 346 of the published rows are vessels, and a search for a person that can
    # rank a tanker is what the distinct type closes.
    it "types people, organizations and vessels apart" do
      expect(entities.map(&:type).tally).to eq(individual: 14, organization: 2, vessel: 1)
    end

    # `300a` through `300z` were not enough for this listing, so DFAT carried on
    # into `300aa`. A suffix rule that assumed one letter would file those six
    # rows as records of their own.
    it "joins an alias reference carrying two letters to the same record" do
      expect(names_of("300").map(&:first)).to include("LASHKAR-E-TAYYIBA", "Jamaat ud-Daawa")
    end

    # Two of the 3,906 published records have a place of birth only because an
    # alias row carried one, which is why every column is unioned across the
    # group rather than read off the primary row.
    it "keeps a column an alias row filled in and the primary row did not" do
      expect(extras_of("733")).to include("Place of birth: Baghdad, Iraq")
    end

    it "reads the whole fixture without a complaint" do
      entities
      expect(adapter.warnings).to be_empty
    end

    # DFAT stamps the export inside the workbook, and reports the same date on
    # its download page as when the list was last updated.
    it "reads the list version out of the workbook's own properties" do
      entities
      expect(adapter.source_version).to eq("2026-09-04T05:37:12Z")
    end
  end

  describe "names" do
    it "marks the one name DFAT calls primary, and files the rest as aliases" do
      expect(entity("5").primary_name.value).to eq("Muhammad Taher Anwari")
    end

    # Strong and weak are the distinction the UN grades Good and Low, so they
    # map onto the grade the scorer already knows how to discount.
    it "grades an alias the way DFAT graded it" do
      expect(names_of("5")).to include(["Mohammad Taher Anwari", :aka, :good], ["Haji Mudir", :aka, :low])
    end

    # A name in original script is the same name written another way, not a
    # second designation -- and DFAT publishes no strength for one.
    it "files a name in original script as an ungraded alias" do
      expect(names_of("2")).to eq([["MOHAMMAD HASSAN AKHUND", :primary, nil], ["محمد حسن أخوند", :aka, nil]])
    end

    # Which script a string is in is a question about its characters, and the
    # normalizer is where that gets answered -- the same call the UN, EU and UK
    # adapters make.
    it "declares no script, on a Cyrillic name or any other" do
      expect(entity("3125").names.map(&:script).uniq).to eq([nil])
    end
  end

  describe "dates of birth" do
    # 4,183 of the published birth dates are Excel serial numbers, and 2,709 are
    # the year somebody was born written as a plain number. Read without the
    # cell's format they are the same thing.
    it "reads a serial date as the day it displays" do
      expect(dates_of("334")).to eq(["1962-08-24"])
    end

    it "reads a plain year as a year, and not as a serial" do
      expect(dates_of("114")).to eq(["1958"])
    end

    # A `mmm-yy` cell displays a month, and the day in its serial is whatever
    # the spreadsheet needed to store one.
    it "reads a month-formatted serial to month precision" do
      expect(dates_of("2557")).to eq(["1973-11"])
    end

    # A committee that received ten reports of when somebody was born publishes
    # ten. Collapsing them would mean choosing which report to believe.
    it "keeps every date in a cell that lists more than one" do
      expect(dates_of("2")).to eq(%w[1945 1946 1947 1948 1949 1950 1955 1956 1957 1958])
    end

    it "reads Australian day-first text dates" do
      expect(dates_of("8154")).to eq(%w[1992-01-13 1993-03-16])
    end

    it "keeps DFAT's own hedge on a date it is unsure of" do
      expect(entity("44").dates_of_birth.select(&:approximate?).map(&:to_s)).to eq(["circa 1968"])
    end

    it "reads a span DFAT writes as an approximate range" do
      expect(dates_of("8824")).to eq(["circa 1959 to 1965"])
    end

    # 203 of the 6,823 birth-date cells end in a non-breaking space, which
    # `String#strip` leaves in place and which would otherwise leave a perfectly
    # good date matching no pattern at all.
    it "reads a date padded with a non-breaking space" do
      expect(dates_of("334")).not_to be_empty
    end

    # `Approximately 1968_x000D_ 28/08/1965` is two dates and one cell.
    it "splits a cell whose dates are separated by an escaped carriage return" do
      expect(dates_of("44")).to contain_exactly("circa 1968", "1968", "1965-08-28")
    end

    # Four records out of 3,906 carry a fragment typed wrong at the source.
    # Dropping one silently would lose something DFAT said about a person.
    it "keeps a date it cannot read, verbatim, rather than dropping it" do
      expect(extras_of("1145")).to include("Date of birth, as published: 1980.1981")
    end

    it "still reads the readable dates in the same cell" do
      expect(dates_of("1145")).to eq(%w[1979 1980 1981 1982])
    end
  end

  describe "the Control Date, which is not a listing date" do
    # DFAT's guide defines it as the last date the entry was edited. Mapping it
    # to `listed_on` would report a designation made in 2001 as having been made
    # this year, and nothing would look wrong.
    it "does not report the last edit as the day the designation was made" do
      expect(entity("2").listed_on.to_s).to eq("2001-01-25")
    end

    it "keeps the Control Date in remarks, labelled as what it is" do
      expect(extras_of("2")).to include("Control date (last edited, not listed): 2026-04-14")
    end

    # The listing date is prose, and 63% of the column names an instrument and
    # no date at all. That is DFAT publishing nothing rather than this failing
    # to read something.
    it "leaves the listing date unset where DFAT states only an instrument" do
      expect(entity("8227").listed_on).to be_nil
    end

    # 17 rows read `... List 2001 (updated on 5 Aug. 2004)`, where the first
    # date in the cell is when the listing was last touched.
    it "does not read an amendment date as the listing date" do
      expect(entity("272").listed_on).to be_nil
    end
  end

  describe "the rest of the mapping" do
    it "splits the citizenships DFAT separates with a semicolon" do
      expect(entity("114").nationalities).to eq(%w[Afghanistan Pakistan])
    end

    it "reads the sanctions framework as the programme" do
      expect(entity("300").programs).to eq(["1267 (ISIL (Da'esh) and Al-Qaida)"])
    end

    # 859 rows enumerate more than one address in a single cell, the way the UN
    # enumerates them in its own prose.
    it "splits an enumerated address into the addresses it holds" do
      expect(entity("142").addresses.map(&:street))
        .to eq(["Iltifat village, Shakardara District, Kabul Province, Afghanistan",
                "Puli Charkhi Area, District Number 9, Kabul City, Kabul Province"])
    end

    # A semicolon is not a declared separator here: it appears inside single
    # addresses too, and a rule that split on it would manufacture fragments.
    it "does not split an address on a semicolon" do
      expect(entity("1281").addresses.map(&:street))
        .to eq(["Sanaa, Yemen; Mehran Military Base, Ilam Province, Iran; Kermanshah, Iran"])
    end

    # The only identifier of any kind on the list: DFAT publishes no passport,
    # national identity or company registration number for any record.
    it "files a vessel's IMO number as the registry number it is" do
      expect(entity("8227").identifiers.map { |id| [id.kind, id.value, id.note] })
        .to eq([[:other, "9288693", "IMO number"]])
    end

    it "names the measures rather than leaving them as ones and zeroes" do
      expect(extras_of("8227")).to include("Measures: maritime restriction")
    end

    it "keeps DFAT's own prose ahead of anything this adapter appended" do
      expect(described_class.published_remarks(entity("2").remarks)).to start_with("TAi.002. Title:")
    end

    # 205 cells carry a carriage return Excel escaped as `_x000D_`. Left in, it
    # becomes part of a name, an address or a place of birth.
    it "leaves no spreadsheet escape anywhere in a record" do
      expect(entities.map(&:to_h).to_s).not_to include("_x000D_")
    end
  end

  describe "a payload that is not the list" do
    # A column DFAT renames is not a list with an empty column; it is a
    # publisher who has changed the file, and every record built from it
    # afterwards would be missing whatever that column carried.
    it "refuses a sheet whose header no longer names a column it reads" do
      strings = ActiveSanction::Parsers::Spreadsheet::Archive.new(raw).fetch("xl/sharedStrings.xml")
      renamed = WorkbookBuilder.from(raw)
                               .part("xl/sharedStrings.xml", strings.sub("<t>Citizenship</t>", "<t>Nationality</t>"))
                               .zip
      expect { adapter.parse(renamed) }
        .to raise_error(ActiveSanction::Parsers::ParseError, /does not name the column\(s\) citizenship/)
    end

    # The sheet is named, so that a publisher adding a tab does not silently
    # change which one is read.
    it "refuses a workbook whose sheet is no longer the one it names" do
      book = ActiveSanction::Parsers::Spreadsheet::Archive.new(raw).fetch("xl/workbook.xml")
      expect do
        adapter.parse(WorkbookBuilder.from(raw).part("xl/workbook.xml", book.sub("Consolidated List", "Sheet1")).zip)
      end
        .to raise_error(ActiveSanction::Parsers::ParseError, /has no sheet named "Consolidated List"/)
    end
  end

  describe "fetching it", :live do
    # The endpoint research this adapter exists on the far side of: DFAT's edge
    # drops a request whose leading User-Agent token it does not recognise, and
    # the gem's own agent is one of those. Tagged :live because the only thing
    # that can answer whether an edge still filters is the edge.
    it "is served when the agent is wrapped in the compatible form" do
      response = ActiveSanction::HttpClient.new.get(
        described_class.url,
        headers: { "User-Agent" => "Mozilla/5.0 (compatible; #{ActiveSanction.config.user_agent})" }
      )
      expect(response.status).to eq(200)
    end
  end
end
