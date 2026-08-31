# frozen_string_literal: true

RSpec.describe ActiveSanction::Sources::Ofac::RemarksParser do
  def parse(text) = described_class.new(text)

  # Every remark in the corpus is a string OFAC published. The file is
  # documented at the top; comments and blank lines are not remarks.
  def corpus
    path = File.expand_path("../../../fixtures/ofac_sdn/remarks.txt", __dir__)
    File.readlines(path, chomp: true).reject { |line| line.empty? || line.start_with?("#") }
  end

  describe "segmenting" do
    it "splits on the semicolon OFAC delimits with" do
      expect(parse("DOB 1948; POB Egypt").segments).to eq(["DOB 1948", "POB Egypt"])
    end

    it "reads nothing out of an entity OFAC published no remark for" do
      expect(parse(nil)).to have_attributes(segments: [], identifiers: [], any?: false)
    end
  end

  describe "dates of birth" do
    it "reads the day-month-year OFAC writes most of them as" do
      expect(parse("DOB 10 Dec 1948").dates_of_birth.map(&:to_s)).to eq(["1948-12-10"])
    end

    it "keeps a year-only date at year precision rather than inventing a January" do
      expect(parse("DOB 1965").dates_of_birth.first.precision).to eq(:year)
    end

    it "carries `circa` through as approximate, which is how the scorer compares it" do
      expect(parse("DOB circa 1937").dates_of_birth.first).to be_approximate
    end

    it "reads a span as a span" do
      expect(parse("DOB 1971 to 1973").dates_of_birth.first).to be_range
    end

    # 140 of the UN's individuals carry several dates of birth for the same
    # reason: several governments reported several dates and all of them are
    # the honest state of the intelligence.
    it "produces one date per `alt.` repeat rather than choosing between them" do
      expect(parse("DOB 31 Jul 1951; alt. DOB 01 Jul 1951").dates_of_birth.map(&:to_s))
        .to eq(%w[1951-07-31 1951-07-01])
    end

    it "leaves a date it cannot read in the remark instead of guessing at one" do
      expect(parse("DOB sometime in the eighties")).to have_attributes(
        dates_of_birth: [], unrecognized: ["DOB sometime in the eighties"]
      )
    end
  end

  describe "the fields that are one word of prose" do
    it "reads a place of birth" do
      expect(parse("POB Culiacan, Sinaloa, Mexico").places_of_birth).to eq(["Culiacan, Sinaloa, Mexico"])
    end

    it "reads `nationality` and `citizen` as the same field, since OFAC uses both" do
      expect(parse("nationality Iraq; citizen Russia").nationalities).to eq(%w[Iraq Russia])
    end

    it "reads a gender" do
      expect(parse("Gender Male").genders).to eq(["Male"])
    end

    it "drops the full stop that ends the last segment of nearly every remark" do
      expect(parse("nationality Iraq.").nationalities).to eq(["Iraq"])
    end
  end

  describe "the aliases that appear only in the remark" do
    it "reads a quoted a.k.a. as a name, without OFAC's quotes" do
      expect(parse("a.k.a. 'SHAM HOLDING'").aliases.map(&:value)).to eq(["SHAM HOLDING"])
    end

    it "keeps the aka/fka distinction, which the scorer ranks differently" do
      expect(parse("a.k.a. 'CHAM'; f.k.a. 'ANA I'").aliases.map(&:kind)).to eq(%i[aka fka])
    end

    it "keeps an apostrophe inside the name, which only the outer quotes are not" do
      expect(parse("a.k.a. 'P'U LI'").aliases.map(&:value)).to eq(["P'U LI"])
    end
  end

  describe "documents" do
    def identifier(text) = parse(text).identifiers.first

    it "reads a passport and its issuing country" do
      expect(identifier("Passport 123456 (Egypt)"))
        .to have_attributes(kind: :passport, value: "123456", country: "Egypt")
    end

    it "reads the issue and expiry dates OFAC appends to the same segment" do
      expect(identifier("Passport ZG4109521 (Pakistan) issued 07 Jun 2008 expires 06 Jun 2013"))
        .to have_attributes(issued_on: an_object_having_attributes(year: 2008),
                            expires_on: an_object_having_attributes(year: 2013))
    end

    it "keeps a number OFAC spaced out, since Identifier compares on the alphanumerics" do
      expect(identifier("Passport B 960789")).to have_attributes(value: "B 960789",
                                                                 normalized_value: "b960789")
    end

    it "maps each government's own word for a document onto one kind" do
      expect(parse("Tax ID No. 102858071 (Serbia); R.F.C. AAZO790915AL6 (Mexico)").identifiers.map(&:kind))
        .to eq(%i[tax_id tax_id])
    end

    it "keeps the label the publisher used, since :tax_id is our word and R.F.C. is theirs" do
      expect(identifier("R.F.C. AAZO790915AL6 (Mexico)").note).to eq("R.F.C.")
    end

    it "reads the outermost parenthesis as the country and files the rest in the note" do
      expect(identifier("Folio Mercantil No. 18740 (Jalisco) (Mexico)"))
        .to have_attributes(value: "18740", country: "Mexico", note: "Folio Mercantil No. (Jalisco)")
    end

    # Hong Kong's ID numbers carry a check digit in brackets. Split off as a
    # country it would leave a number the issuing government would not know.
    it "keeps a parenthesis that is part of the number rather than a qualifier" do
      expect(identifier("National ID No. K357514(4) (Hong Kong)"))
        .to have_attributes(value: "K357514(4)", country: "Hong Kong")
    end

    it "reads a wallet address by shape, so a newly designated currency needs no new label" do
      expect(identifier("Digital Currency Address - TRX TAoLw5yD5XUoHWeBZRSZ1ExK9HMv2CiPvP"))
        .to have_attributes(value: "TAoLw5yD5XUoHWeBZRSZ1ExK9HMv2CiPvP", note: "TRX address")
    end

    it "de-duplicates nothing itself -- two `alt.` passports are two documents" do
      expect(parse("Passport A0009228; alt. Passport 4229533").identifiers.map(&:value))
        .to eq(%w[A0009228 4229533])
    end
  end

  describe "what it refuses to build an identifier out of" do
    it "reads a segment that names no number as unrecognized, not as a document" do
      expect(parse("Passport issued in Sarajevo, Bosnia-Herzegovina"))
        .to have_attributes(identifiers: [], unrecognized: ["Passport issued in Sarajevo, Bosnia-Herzegovina"])
    end

    it "refuses a clause that ran on into a sentence" do
      expect(parse("Passport OR801168 and Kuwaiti National ID No. 281020505755 issued under another name")
        .identifiers).to be_empty
    end

    it "refuses prose that happens to open with a label word" do
      expect(parse("License to operate in the region").identifiers).to be_empty
    end
  end

  describe "the segments it deliberately leaves alone" do
    it "recognizes a statutory citation as prose carrying nothing to extract" do
      expect(parse("Secondary sanctions risk: See Section 11 of Executive Order 14024."))
        .to have_attributes(prose: ["Secondary sanctions risk: See Section 11 of Executive Order 14024."],
                            unrecognized: [])
    end

    it "counts a sentence it has never seen as unrecognized, which is what Coverage watches" do
      expect(parse("Member of the Upper House of Parliament.").unrecognized)
        .to eq(["Member of the Upper House of Parliament."])
    end
  end

  # The one rule this class must not break. Everything else here is a
  # heuristic against text a government writes for people; this is the promise
  # that a heuristic going stale costs structure and never content.
  describe "the corpus of real published remarks" do
    it "never raises, on any of them" do
      expect { corpus.each { |remark| parse(remark) } }.not_to raise_error
    end

    it "leaves every remark it was given exactly as OFAC wrote it" do
      expect(corpus.map { |remark| parse(remark).text }).to eq(corpus)
    end

    it "accounts for every segment as extracted, prose or unrecognized" do
      totals = corpus.map do |remark|
        parsed = parse(remark)
        [parsed.segments.size, parsed.extracted.size + parsed.prose.size + parsed.unrecognized.size]
      end
      expect(totals.map(&:first)).to eq(totals.map(&:last))
    end

    it "reads most of them" do
      coverage = corpus.each_with_object(described_class::Coverage.new) { |remark, tally| tally.record(parse(remark)) }

      expect(coverage.percentage).to be > 90
    end
  end
end
