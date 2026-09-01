# frozen_string_literal: true

RSpec.describe ActiveSanction::Normalizer::Form do
  def fold(string) = described_class.new(string).value

  describe "immutability" do
    it "freezes the form" do
      expect(described_class.new("Bélarus")).to be_frozen
    end

    it "freezes the tokens, which the index holds onto" do
      expect(described_class.new("CO., LTD.").tokens).to be_frozen
    end
  end

  describe "stage 1: compatibility decomposition" do
    # A publisher's export tooling emits these, and a caller typing the name
    # into a form does not.
    it "folds the compatibility forms an export produces" do
      expect(["ＡＢＣ Ｃｏ．", "Ⅳ", "①②③", "ﬁrst"].map { |value| fold(value) })
        .to eq(["abc co", "iv", "123", "first"])
    end

    it "reads the no-break spaces the delimited lists are padded with" do
      expect(fold("ABBAS,\u00A0Abu")).to eq("abbas abu")
    end
  end

  describe "stage 2: combining marks" do
    it "strips the diacritics decomposition separated" do
      expect(%w[Bélarus Müller Ñuñez Ångström].map { |value| fold(value) })
        .to eq(%w[belarus muller nunez angstrom])
    end

    # The same rule reaches Arabic for free, and Arabic wants it: the harakat
    # are optional in writing, so one publisher's vocalized spelling and
    # another's bare one have to fold together.
    it "strips Arabic vocalization, which is written or omitted at will" do
      expect(fold("مُحَمَّد")).to eq(fold("محمد"))
    end

    it "folds the hamza-carrying alef onto a bare one, which is the same letter spelled twice" do
      expect(fold("أبو")).to eq(fold("ابو"))
    end

    # Indic vowel signs are spacing marks, and they are letters in every sense
    # that matters here: dropping them would fold two different words onto the
    # same consonant.
    it "keeps spacing marks, which are vowels rather than diacritics" do
      expect(fold("का")).not_to eq(fold("कि"))
    end
  end

  describe "stage 3: casefolding" do
    it "lowercases" do
      expect(fold("AERO-CARIBBEAN")).to eq("aero caribbean")
    end

    # String#downcase would leave a ß that no query is ever typed with.
    it "casefolds rather than downcasing" do
      expect(fold("Straße")).to eq("strasse")
    end

    it "folds the Turkish dotted capital I, which downcasing alone leaves marked" do
      expect(fold("İSTANBUL")).to eq("istanbul")
    end
  end

  describe "stage 3b: the Latin letters decomposition cannot reach" do
    # None of these is a letter wearing a mark, so NFKD leaves every one of
    # them alone and the table is the only thing that folds them.
    it "transliterates them" do
      expect(%w[Bjørn Łukasz Þórir Ærø Đặng Əliyev].map { |value| fold(value) })
        .to eq(%w[bjorn lukasz thorir aero dang eliyev])
    end

    it "covers every key in the table" do
      folded = described_class::TRANSLITERATIONS.keys.map { |letter| fold(letter) }
      expect(folded).to eq(described_class::TRANSLITERATIONS.values)
    end
  end

  describe "stage 4: punctuation" do
    it "turns punctuation into spaces rather than closing the gap" do
      expect(["Al-Qaida", "O'Brien", "CO., LTD.", "d’Ivoire"].map { |value| fold(value) })
        .to eq(["al qaida", "o brien", "co ltd", "d ivoire"])
    end

    # A hyphen and a space are written interchangeably across these lists, so
    # the two spellings have to reach the same tokens.
    it "leaves a hyphenated name and a spaced one identical" do
      expect(fold("Al-Qaida")).to eq(fold("Al Qaida"))
    end

    it "keeps digits, which vessel and company names carry" do
      expect(fold("Bank 131 (JSC)")).to eq("bank 131 jsc")
    end

    # Unicode calls these letters; a transliterator uses them as apostrophes,
    # and one that survives is a token no query will ever be typed with.
    it "reads the modifier letters a transliteration uses as punctuation" do
      expect(%w[Sanʻa Qurʼan Alʹbert].map { |value| fold(value) })
        .to eq(["san a", "qur an", "al bert"])
    end
  end

  describe "stage 5: whitespace" do
    it "collapses runs and strips the ends" do
      expect(fold("  ABBAS,\t\tAbu \n")).to eq("abbas abu")
    end

    it "splits the collapsed string into tokens" do
      expect(described_class.new("PUTIN, Vladimir Vladimirovich").tokens)
        .to eq(%w[putin vladimir vladimirovich])
    end
  end

  describe "a name nothing survives" do
    # It happens in real data, and it matters: such a name cannot be indexed
    # and cannot be scored, so the index has to be able to tell.
    it "reports itself empty rather than raising" do
      expect(["---", "   ", "©", ""].map { |value| described_class.new(value).empty? })
        .to all(be(true))
    end

    it "has no tokens" do
      expect(described_class.new("---").tokens).to eq([])
    end

    it "is not empty when a single letter survives" do
      expect(described_class.new("Ю").empty?).to be(false)
    end
  end

  describe "the original" do
    it "keeps the publisher's string exactly as it arrived" do
      expect(described_class.new("O'Brien, Seán").original).to eq("O'Brien, Seán")
    end

    it "takes anything that stringifies, which is what lets an indexer pass a Name" do
      name = ActiveSanction::Name.new(value: "AERO-CARIBBEAN", kind: :aka)
      expect(described_class.new(name).value).to eq("aero caribbean")
    end
  end

  # An index build that dies on one record's stray byte costs a whole list,
  # and a list that will not build is a list nobody is screened against.
  describe "bytes that are not text" do
    it "folds a string that is not valid UTF-8 instead of raising" do
      expect(fold("M\xFCller".dup.force_encoding("UTF-8"))).to eq("m ller")
    end

    it "folds a string that arrived in the encoding OFAC serves" do
      expect(fold("M\xFCller".dup.force_encoding("Windows-1252"))).to eq("muller")
    end

    it "keeps the original in whatever encoding it arrived in" do
      expect(described_class.new("M\xFCller".dup.force_encoding("Windows-1252")).original.encoding)
        .to eq(Encoding::Windows_1252)
    end
  end

  describe "non-Latin script, which v1 does not transliterate" do
    it "leaves Cyrillic in Cyrillic, casefolded" do
      expect(fold("ПУТИН, Владимир")).to eq("путин владимир")
    end

    it "leaves Han alone, having nothing to fold" do
      expect(fold("山田太郎")).to eq("山田太郎")
    end

    # The documented consequence of NFKD on Hangul. Both sides of a comparison
    # are folded the same way, so nothing downstream cares.
    it "decomposes Hangul syllables into jamo" do
      expect(fold("김정은")).to eq("김정은".unicode_normalize(:nfkd))
    end
  end

  # The one stage that depends on something outside the string. What is on the
  # lists, and the particles they may never touch, is Dictionary's spec; this
  # is what the fold does with one.
  describe "stage 6: the token dictionaries" do
    let(:organizations) { ActiveSanction::Normalizer::Dictionary.default.stoplist(:organization) }

    def strip(string, stoplist) = described_class.new(string, stoplist: stoplist).value

    it "drops the tokens the stoplist names, wherever they appear" do
      expect(strip("JSC Rosneft Oil Company", organizations)).to eq("rosneft oil")
    end

    it "drops nothing at all without one, which is what an untyped call gets" do
      expect(strip("JSC Rosneft Oil Company", nil)).to eq("jsc rosneft oil company")
    end

    it "carries the type it folded for, since two folds of one string are two answers" do
      expect([described_class.new("Rosneft", stoplist: organizations).type,
              described_class.new("Rosneft").type]).to eq([:organization, nil])
    end

    # An organization called "The Company" is a poor name to screen on and a
    # worse one to index as the empty string, which matches everything or
    # nothing depending on which scorer sees it first.
    it "keeps a name that is legal forms and function words and nothing else" do
      expect(strip("The Company", organizations)).to eq("the company")
    end

    it "still freezes the tokens, which the index holds onto" do
      expect(described_class.new("Rosneft Oil Company", stoplist: organizations).tokens).to be_frozen
    end
  end

  describe "equality" do
    it "compares by the original, since the value is a function of it" do
      form = described_class.new("Bélarus")
      expect(described_class.new("Bélarus")).to eq(form)
    end

    # `value` is a function of the original *and* the stoplist, which is what
    # the second half of #== is for.
    it "is not equal to the same name folded for a different entity type" do
      stoplist = ActiveSanction::Normalizer::Dictionary.default.stoplist(:organization)
      expect(described_class.new("Rosneft Oil Company", stoplist: stoplist))
        .not_to eq(described_class.new("Rosneft Oil Company"))
    end

    it "is not equal to a differently written name that folds the same way" do
      expect(described_class.new("Bélarus")).not_to eq(described_class.new("BELARUS"))
    end

    it "hashes with #== so a Set and a Hash agree with it" do
      forms = [described_class.new("Bélarus"), described_class.new("Bélarus")]
      expect(forms.uniq.size).to eq(1)
    end
  end

  describe "#to_s and #inspect" do
    it "stringifies to the folded value, which is what a comparison takes" do
      expect(described_class.new("Al-Qaida").to_s).to eq("al qaida")
    end

    it "shows both halves, because a fold is only debuggable next to its input" do
      expect(described_class.new("Bélarus").inspect).to include("Bélarus", "belarus")
    end
  end
end
