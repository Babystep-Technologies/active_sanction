# frozen_string_literal: true

RSpec.describe ActiveSanction::Parsers::DelimitedTable do
  def columns = %i[ent_num name type program]

  def table(**options) = described_class.new(columns: columns, null: "-0-", **options)

  # OFAC's real shape: no header row, "-0- " for null, trailing space included.
  def ofac_row = %(36,"AEROCARIBBEAN AIRLINES",-0- ,"CUBA"\n)

  describe "the null sentinel" do
    it "resolves the publisher's sentinel to nil" do
      expect(table.read(ofac_row).to_a.first[:type]).to be_nil
    end

    it "tolerates the trailing space OFAC actually writes" do
      expect(table.value("-0- ")).to be_nil
    end

    it "tolerates leading whitespace around it too" do
      expect(table.value("  -0-")).to be_nil
    end

    it "treats a blank field as null too, since the lists use both conventions" do
      row = table.read(%(1,"A","",   \n)).to_a.first
      expect([row[:type], row[:program]]).to eq([nil, nil])
    end

    it "accepts several sentinels for a publisher that uses more than one" do
      multi = described_class.new(columns: columns, null: ["-0-", "N/A"])
      expect(multi.read(%(1,"A","N/A","-0-"\n)).to_a.first.to_h)
        .to include(type: nil, program: nil)
    end

    it "leaves a value that merely contains the sentinel alone" do
      expect(table.value("-0-9")).to eq("-0-9")
    end

    it "strips surrounding whitespace but nothing else" do
      expect(table.value("  ABBAS, Abu  ")).to eq("ABBAS, Abu")
    end
  end

  describe "positional columns" do
    it "names the fields of a headerless file in declaration order" do
      expect(table.read(ofac_row).to_a.first.to_h)
        .to eq(ent_num: "36", name: "AEROCARIBBEAN AIRLINES", type: nil, program: "CUBA")
    end

    it "raises on a column the table never declared, so a typo is not a nil" do
      expect { table.read(ofac_row).to_a.first[:nmae] }
        .to raise_error(KeyError, /no column :nmae.*Declared: ent_num, name/m)
    end

    it "still answers #fetch for a genuinely optional column" do
      expect(table.read(ofac_row).to_a.first.fetch(:nmae, "?")).to eq("?")
    end

    it "rejects duplicate names, which would silently drop a column" do
      expect { described_class.new(columns: %i[a b a]) }
        .to raise_error(ArgumentError, /duplicate column name\(s\): a/)
    end

    it "rejects an empty list and says how to ask for a header instead" do
      expect { described_class.new(columns: []) }
        .to raise_error(ArgumentError, /pass nil to read them from the file's header/)
    end
  end

  describe "a file that names its own columns" do
    def headered = described_class.new(columns: nil, null: "-0-")

    it "takes the names from the first row" do
      rows = headered.read(%(ent_num,name\n36,"AEROCARIBBEAN"\n)).to_a
      expect(rows.first.to_h).to eq(ent_num: "36", name: "AEROCARIBBEAN")
    end

    it "normalizes however the publisher capitalized and punctuated them" do
      rows = headered.read(%(Ent Num,City/State/ZIP\n36,"London"\n)).to_a
      expect(rows.first.to_h.keys).to eq(%i[ent_num city_state_zip])
    end

    it "reports an empty payload rather than yielding nothing in silence" do
      expect { headered.read("").to_a }
        .to raise_error(ActiveSanction::Parsers::ParseError, /expected a header row/)
    end
  end

  describe "rows of the wrong width" do
    it "keeps a short row, padding the missing columns with nil" do
      reader = table.read(%(36,"AEROCARIBBEAN"\n))
      expect(reader.to_a.first.to_h).to eq(ent_num: "36", name: "AEROCARIBBEAN", type: nil, program: nil)
    end

    it "warns, because a shifted column is otherwise invisible" do
      reader = table.read(%(36,"AEROCARIBBEAN"\n))
      reader.to_a
      expect(reader.warnings.first.to_s).to include("line 1: expected 4 columns, got only 2")
    end

    it "keeps a long row and says so" do
      reader = table.read(%(36,"A","B","C","D","E"\n))
      reader.to_a
      expect(reader.warnings.first.message).to eq("expected 4 columns, got 6")
    end
  end

  describe "row-level failure isolation" do
    # liberal_parsing absorbs most published sloppiness; this is what a genuine
    # parse failure does to the rows around it.
    def strict = described_class.new(columns: %i[a b], liberal_parsing: false)

    it "loses one malformed row and keeps the other 499" do
      rows = (1..500).map { |i| %(#{i},"name #{i}") }
      rows[249] = %(250,bad"quote)
      reader = strict.read("#{rows.join("\n")}\n")
      expect(reader.to_a.size).to eq(499)
    end

    it "records where the bad row was" do
      reader = strict.read(%(1,"ok"\n2,bad"quote\n3,"ok"\n))
      reader.to_a
      expect(reader.warnings.map(&:line)).to eq([2])
    end

    it "gives up when every row fails, rather than collecting a warning per row" do
      body = (1..150).map { |i| %(#{i},ok"x) }.join("\n")
      expect { strict.read(body).to_a }
        .to raise_error(ActiveSanction::Parsers::ParseError, /100 consecutive rows.*not the CSV it was read as/m)
    end

    it "truncates the evidence, since a bad row is often an enormous one" do
      reader = table.read(%(36,"#{"x" * 500}"\n))
      reader.to_a
      expect(reader.warnings.first.snippet.length).to eq(123)
    end
  end

  describe "encoding" do
    def latin = described_class.new(columns: %i[a b], encoding: Encoding::WINDOWS_1252)

    it "decodes the Windows-1252 OFAC actually serves" do
      bytes = %(1,"MUÑOZ"\n).encode(Encoding::WINDOWS_1252)
      expect(latin.read(bytes).to_a.first[:b]).to eq("MUÑOZ")
    end

    it "replaces bytes that are not valid in the declared encoding rather than refusing the list" do
      reader = described_class.new(columns: %i[a b]).read("1,\"M\xD1OZ\"\n".b)
      expect(reader.to_a.first[:b]).to eq("M�OZ")
    end

    it "says that it replaced them" do
      reader = described_class.new(columns: %i[a b]).read("1,\"M\xD1OZ\"\n".b)
      reader.to_a
      expect(reader.warnings.first.message).to match(/not valid UTF-8.*replaced with U\+FFFD/)
    end

    it "strips the DOS EOF marker every OFAC file ends with" do
      reader = described_class.new(columns: %i[a b]).read(%(1,"x"\r\n2,"y"\r\n\x1A))
      expect([reader.to_a.size, reader.warnings]).to eq([2, []])
    end

    it "strips a BOM, which would otherwise become part of the first column" do
      expect(described_class.new(columns: %i[a b]).read("\xEF\xBB\xBF1,\"x\"\n".b).to_a.first[:a]).to eq("1")
    end

    it "rejects an encoding it cannot find" do
      expect { described_class.new(encoding: "KLINGON-8") }
        .to raise_error(ArgumentError, /unknown encoding "KLINGON-8"/)
    end
  end

  describe "other delimiters" do
    it "reads TSV" do
      tsv = described_class.new(columns: %i[a b], col_sep: "\t")
      expect(tsv.read("1\tLondon\n").to_a.first[:b]).to eq("London")
    end

    it "names the format in its complaints, so an error says TSV rather than text" do
      expect(described_class.new(col_sep: "\t").col_sep_name).to eq("TSV")
    end
  end

  describe "reading" do
    it "is lazy, so a list-sized payload does not have to be held as rows" do
      reader = table.read((1..1000).map { |i| %(#{i},"n") }.join("\n"))
      expect(reader.lazy.map { |row| row[:ent_num] }.first(2)).to eq(%w[1 2])
    end

    it "numbers rows by their line in the file, which is what a warning cites" do
      expect(table.read(%(1,"a"\n2,"b"\n3,"c"\n)).to_a.map(&:line)).to eq([1, 2, 3])
    end

    it "resets warnings when re-enumerated, so two passes do not accumulate" do
      reader = table.read(%(36,"AEROCARIBBEAN"\n))
      2.times { reader.to_a }
      expect(reader.warnings.size).to eq(1)
    end

    it "skips blank lines rather than reporting them as short rows" do
      expect(table.read(%(1,"a"\n\n2,"b"\n)).to_a.size).to eq(2)
    end
  end
end
