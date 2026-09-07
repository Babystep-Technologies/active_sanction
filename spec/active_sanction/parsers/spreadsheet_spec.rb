# frozen_string_literal: true

RSpec.describe ActiveSanction::Parsers::Spreadsheet do
  # Built rather than committed, because these are shapes no published list
  # happens to contain and a fixture written to contain them would prove
  # nothing about a workbook anybody actually ships. The Australian fixture is
  # where the real evidence is; see the adapter's spec.
  def workbook(...) = WorkbookBuilder.new(...)

  def rows_of(bytes, **options) = described_class.new(**options).read(bytes).map(&:to_h)

  def raw(attributes, body) = WorkbookBuilder.raw(attributes, body)

  describe "what it declares" do
    it "reads the sheet's own column names by default" do
      expect(described_class.new).to be_headers
    end

    it "refuses a column list that names the same column twice" do
      expect { described_class.new(columns: %i[name name]) }
        .to raise_error(ArgumentError, /duplicate column name/)
    end

    it "says which sheet it reads, for a message" do
      expect(described_class.new(sheet: "Consolidated List").inspect).to include('"Consolidated List"')
    end
  end

  describe "the ZIP an .xlsx arrives in" do
    it "reads a workbook whose parts are deflated" do
      expect(rows_of(workbook.zip)).to eq([{ reference: "1", name: "ADAM" }])
    end

    # Legal, and what a writer emits for a part that would grow under deflate.
    it "reads a workbook whose parts are stored uncompressed" do
      expect(rows_of(workbook.zip(method: 0))).to eq([{ reference: "1", name: "ADAM" }])
    end

    # An empty payload is a failed download, a moved URL or an outage -- never a
    # day on which nobody is sanctioned.
    it "refuses a payload with nothing in it" do
      expect { rows_of("") }.to raise_error(ActiveSanction::Parsers::ParseError, /truncated, or is not a workbook/)
    end

    it "refuses an HTML error page served under a spreadsheet's URL" do
      expect { rows_of("<html><body>503 Service Unavailable</body></html>") }
        .to raise_error(ActiveSanction::Parsers::ParseError, /found no end-of-central-directory/)
    end

    # The central directory is at the end of the file, so a download that
    # stopped early has no index at all and not one entry can be located.
    it "refuses an archive whose index was never received" do
      bytes = workbook.zip
      expect { rows_of(bytes[0, bytes.bytesize / 2]) }
        .to raise_error(ActiveSanction::Parsers::ParseError, /found no end-of-central-directory/)
    end

    it "refuses an entry whose bytes are encrypted rather than inflating them into noise" do
      expect { rows_of(workbook.zip(flags: 1)) }
        .to raise_error(ActiveSanction::Parsers::ParseError, /is encrypted/)
    end

    it "refuses a compression method it does not implement, by number" do
      expect { rows_of(workbook.zip(method: 12)) }
        .to raise_error(ActiveSanction::Parsers::ParseError, /compression method 12/)
    end

    it "refuses an archive whose index points somewhere that is not a local header" do
      expect { rows_of(workbook.zip(corrupt: "xl/workbook.xml")) }
        .to raise_error(ActiveSanction::Parsers::ParseError, /is not a local header/)
    end
  end

  describe "finding the sheet" do
    it "names every sheet the workbook declares" do
      expect(described_class.new.read(workbook(sheet: "Consolidated List").zip).sheet_names)
        .to eq(["Consolidated List"])
    end

    it "reads the sheet a caller names" do
      expect(rows_of(workbook(sheet: "Consolidated List").zip, sheet: "Consolidated List")).not_to be_empty
    end

    it "reads the sheet a caller names by index" do
      expect(rows_of(workbook.zip, sheet: 0)).not_to be_empty
    end

    # Naming the sheet is how an adapter survives a publisher adding a tab, so
    # a name that is no longer there has to say so rather than reading the
    # first sheet and looking healthy.
    it "refuses a sheet name the workbook does not have, and says what it does have" do
      expect { rows_of(workbook(sheet: "Consolidated List").zip, sheet: "Sheet1") }
        .to raise_error(ActiveSanction::Parsers::ParseError, /has no sheet named "Sheet1".*Consolidated List/m)
    end

    it "refuses a sheet index past the last one" do
      expect { rows_of(workbook.zip, sheet: 3) }
        .to raise_error(ActiveSanction::Parsers::ParseError, /there is no sheet 3/)
    end

    # A workbook is free to store its first sheet in any part it likes, and the
    # relationship is the only thing that says which.
    it "follows the relationship rather than assuming a part name" do
      expect(rows_of(sheet_moved_to("xl/worksheets/anywhere.xml"))).to eq([{ reference: "1", name: "ADAM" }])
    end

    def sheet_moved_to(part)
      book = workbook
      book.part(part, book.parts.fetch("xl/worksheets/sheet1.xml"))
          .part("xl/worksheets/sheet1.xml", nil)
          .part("xl/_rels/workbook.xml.rels", <<~XML).zip
            <?xml version="1.0"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Target="#{part.delete_prefix("xl/")}"/>
            <Relationship Id="rId2" Target="sharedStrings.xml"/>
            </Relationships>
          XML
    end

    it "refuses a workbook that declares no sheets at all" do
      empty = workbook.part("xl/workbook.xml", <<~XML)
        <?xml version="1.0"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheets/></workbook>
      XML
      expect { rows_of(empty.zip) }.to raise_error(ActiveSanction::Parsers::ParseError, /declares no sheets/)
    end
  end

  describe "the header row" do
    it "names the columns after the sheet's own first row, snake_cased" do
      bytes = workbook(rows: [["Name of Individual or Entity", "IMO Number"], %w[ADAM 9288693]]).zip
      expect(rows_of(bytes).first.keys).to eq(%i[name_of_individual_or_entity imo_number])
    end

    # The header is a header whether or not the adapter is using its labels: a
    # published spreadsheet has one, and yielding it as a record would put a
    # row of column titles into a sanctions list.
    it "consumes the header row even when the columns were declared" do
      bytes = workbook(rows: [%w[Reference Name], %w[1 ADAM]]).zip
      expect(rows_of(bytes, columns: %i[ref who])).to eq([{ ref: "1", who: "ADAM" }])
    end

    # A blank header cell still holds the position of everything after it.
    it "names a column the publisher left unlabelled after its position" do
      bytes = workbook(rows: [["Reference", nil, "Name"], %w[1 x ADAM]]).zip
      expect(rows_of(bytes).first.keys.map(&:to_s)).to eq(%w[reference column_2 name])
    end

    it "refuses a sheet whose first row is empty" do
      bytes = workbook(rows: [[nil, nil], %w[1 ADAM]]).zip
      expect { rows_of(bytes) }.to raise_error(ActiveSanction::Parsers::ParseError, /expected a header row/)
    end
  end

  describe "reading rows" do
    # A row states only the cells that hold something, so its cells' addresses
    # are the only thing that lines them up with the header. Reading by
    # position would shift every value after an empty cell one column left.
    it "places a sparse row's cells by their address and not by their position" do
      bytes = workbook(rows: [%w[a b c d], ["1", nil, nil, "4"]]).zip
      expect(rows_of(bytes)).to eq([{ a: "1", b: nil, c: nil, d: "4" }])
    end

    it "reports the sheet's own row number, which is what a reader of the file sees" do
      bytes = workbook(rows: [%w[a], %w[1], %w[2]]).zip
      expect(described_class.new.read(bytes).map(&:number)).to eq([2, 3])
    end

    it "skips a row that holds nothing, which is spacing rather than a record" do
      bytes = workbook(rows: [%w[a b], [nil, nil], %w[1 x]]).zip
      expect(rows_of(bytes)).to eq([{ a: "1", b: "x" }])
    end

    # A publisher appending a column mid-year should degrade the fields nobody
    # has mapped yet, not the whole list -- but it has to say so, because a
    # column silently ignored is how a new sanctions measure stops being read.
    it "keeps a row whose values run past the header rather than dropping the row" do
      bytes = workbook(rows: [%w[a b], %w[1 x surprise]]).zip
      expect(rows_of(bytes)).to eq([{ a: "1", b: "x" }])
    end

    # A column silently ignored is how a new sanctions measure stops being read.
    it "names the value it dropped past the header" do
      reader = described_class.new.read(workbook(rows: [%w[a b], %w[1 x surprise]]).zip)
      reader.to_a
      expect(reader.warnings.map(&:to_s)).to contain_exactly(/1 value\(s\) past the 2 column\(s\).*surprise/)
    end

    it "raises on a column the sheet never named, rather than answering nil to a typo" do
      row = described_class.new.read(workbook.zip).first
      expect { row[:nmae] }.to raise_error(KeyError, /no column :nmae/)
    end

    it "re-reading resets the warnings rather than appending a second pass to the first" do
      reader = described_class.new.read(workbook(rows: [%w[a b], %w[1 x surprise]]).zip)
      2.times { reader.to_a }
      expect(reader.warnings.size).to eq(1)
    end
  end

  describe "what a cell holds" do
    # Two columns, because a row holding nothing at all is spacing rather than
    # a record and never reaches a caller -- which is itself a rule below.
    def value_of(cell, **options)
      rows_of(workbook(rows: %w[a b].then { |head| [head, [cell, "kept"]] }).zip, **options).first.fetch(:a)
    end

    it "looks a shared string up in the part that holds it" do
      expect(value_of("AEROCARIBBEAN AIRLINES")).to eq("AEROCARIBBEAN AIRLINES")
    end

    it "reads an inline string, which carries its text where an offset would be" do
      expect(value_of(raw(%( t="inlineStr"), "<is><t>INLINE</t></is>"))).to eq("INLINE")
    end

    it "reads a boolean as the word the sheet displays" do
      expect(value_of(raw(%( t="b"), "<v>1</v>"))).to eq("TRUE")
    end

    # A formula is not evaluated; what is read is the value cached in the cell,
    # which is what the file displays and what an export contains.
    it "reads a formula's cached result rather than evaluating it" do
      expect(value_of(raw(%( t="str"), "<f>A1&amp;B1</f><v>CACHED</v>"))).to eq("CACHED")
    end

    it "keeps a cell holding a spreadsheet error as the error it displays" do
      expect(value_of(raw(%( t="e"), "<v>#N/A</v>"))).to eq("#N/A")
    end

    it "treats a blank cell and an absent one alike" do
      expect(value_of(nil)).to be_nil
    end

    it "resolves the publisher's own null sentinel" do
      expect(value_of("-0-", null: "-0-")).to be_nil
    end
  end

  # The whole reason this needs the styles: `18798` is a date if the cell is
  # formatted as one and the year 18798 if it is not, and only xl/styles.xml
  # says which. The Australian list turns on exactly this -- 4,183 of its birth
  # dates are serials and 2,709 are the year somebody was born.
  describe "a number that is a date, and a number that is not" do
    def value_of(cell, **options)
      rows_of(workbook(rows: [%w[a b], [cell, "kept"]], **options).zip).first.fetch(:a)
    end

    it "leaves a number under the General format as the number it is" do
      expect(value_of([1963, 0])).to eq("1963")
    end

    it "renders a serial under a date format as ISO 8601" do
      expect(value_of([27_395, 1])).to eq("1975-01-01")
    end

    # `mmm-yy` displays a month, and the day in its serial is whatever the
    # spreadsheet needed to store one. PartialDate::Parser reads the truncated
    # form as the month-precision date it is.
    it "truncates a serial to the precision its format displays" do
      expect(value_of([27_395, 2])).to eq("1975-01")
    end

    it "renders a custom year-only format as a year" do
      expect(value_of([27_395, 4])).to eq("1975")
    end

    # 18 to 21 and 45 to 47 are times. A serial's fraction is a time of day and
    # says nothing about which day, so a time-formatted number is not a date.
    it "does not read a time format as a date" do
      expect(value_of([0.5, 3])).to eq("0.5")
    end

    # Lotus 1-2-3 treated 1900 as a leap year and every spreadsheet since has
    # kept the bug, so the epoch differs either side of the phantom 29 February.
    it "reads a serial below the phantom leap day" do
      expect(value_of([59, 1])).to eq("1900-02-28")
    end

    it "reads a serial above it" do
      expect(value_of([61, 1])).to eq("1900-03-01")
    end

    it "counts from 1904 when the workbook says it does" do
      expect(value_of([27_395, 1], date1904: true)).to eq("1979-01-02")
    end

    it "leaves a number outside any real date alone, however it is formatted" do
      expect(value_of([0, 1])).to eq("0")
    end
  end

  describe "the escapes a spreadsheet writes" do
    def value_of(text) = rows_of(workbook(rows: [%w[a b], [text, "kept"]]).zip).first.fetch(:a)

    # Excel cannot put a carriage return in XML, so it writes `_x000D_`. Left
    # alone it becomes part of a name, and a name carrying it matches nothing.
    it "resolves an escaped control character" do
      expect(value_of("Approximately 1968_x000D_ 28/08/1965")).to eq("Approximately 1968\r 28/08/1965")
    end

    # And escapes the escape, for a string somebody actually typed that way.
    it "leaves a doubly-escaped sequence as the literal text it stands for" do
      expect(value_of("_x005F_x000D_")).to eq("_x000D_")
    end
  end

  describe "a shared string split into styled runs" do
    # No sanctions list publishes one, but a spreadsheet may, and reading only
    # the first run would silently truncate a name. `<rPh>` is a Japanese
    # reading aid rather than part of the string.
    it "joins the runs and skips the phonetic guide" do
      bytes = workbook(rows: [%w[a b], %w[x y]]).part("xl/sharedStrings.xml", <<~XML).zip
        <?xml version="1.0"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="4" uniqueCount="4">
        <si><t>a</t></si><si><t>b</t></si>
        <si><r><t>NORTH</t></r><rPh sb="0" eb="5"><t>ignored</t></rPh><r><t>WIND</t></r></si>
        <si><t>y</t></si>
        </sst>
      XML
      expect(rows_of(bytes).first.fetch(:a)).to eq("NORTHWIND")
    end
  end

  describe "the workbook's own version marker" do
    it "reads when the publisher last saved the file" do
      expect(described_class.new.read(workbook.zip).modified).to eq("2026-09-04T05:37:12Z")
    end

    it "answers nil for a workbook carrying no core properties" do
      expect(described_class.new.read(workbook.part("docProps/core.xml", nil).zip).modified).to be_nil
    end
  end
end
