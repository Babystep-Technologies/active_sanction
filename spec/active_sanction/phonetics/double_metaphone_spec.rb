# frozen_string_literal: true

RSpec.describe ActiveSanction::Phonetics::DoubleMetaphone do
  def keys(word) = described_class.call(word)

  # Philips' reference C++ produced every one of these, and nothing in this
  # repository can produce them -- which is the point. An algorithm that is a
  # hundred special cases about spelling cannot be checked by reasoning about
  # it; it can only be compared against the implementation it was transcribed
  # from. See the fixture's own header for how it was generated and for the
  # wider check it is a slice of.
  describe "against the reference implementation's output" do
    def reference
      path = File.expand_path("../../fixtures/double_metaphone/reference.tsv", __dir__)
      File.readlines(path, chomp: true).reject { |line| line.start_with?("#") }
          .map { |line| line.split("\t") }
    end

    it "has a corpus worth calling one" do
      expect(reference.size).to be > 2_500
    end

    it "agrees on every word in it" do
      disagreements = reference.reject { |word, expected| keys(word) == expected.split(",") }
      expect(disagreements).to be_empty
    end
  end

  # The acceptance the issue was written around: agencies transliterate the
  # same name differently, and these are the groups that shows up as.
  describe "the transliteration variants these lists publish" do
    {
      "MHMT" => %w[mohammed muhammad mohamad mohamed],
      "ASF" => %w[yusuf yousef youssef jusuf],
      "KTF" => %w[qaddafi gaddafi kadafi qadhafi],
      "APTL" => %w[abdul abdel abdal],
      "XK" => %w[shaykh sheikh shaikh],
      "HSN" => %w[hussein hussain husain]
    }.each do |key, group|
      it "collapses #{group.join(", ")} onto #{key}" do
        expect(group.map { |name| keys(name) }).to all(include(key))
      end
    end

    # `Qaddafi` against `Gaddafi` is the pair the issue names as the one edit
    # distance handles worst, because the letter they differ on is the first
    # one -- where Jaro-Winkler's prefix bonus is withheld and Levenshtein's
    # edit lands on the most distinctive character in the name.
    it "matches a pair the character algorithms disagree about most" do
      expect(described_class.match?("qaddafi", "gaddafi")).to be(true)
    end
  end

  # The second key is the whole reason this algorithm rather than Soundex.
  describe "the alternate key" do
    it "is nil for a spelling that is not ambiguous" do
      expect(described_class.new("yusuf").alternate).to be_nil
    end

    # `J-` is read as English in one language of origin and as Slavic in
    # another, which is exactly the ambiguity a transliterated name carries.
    it "is the second pronunciation of a spelling that is" do
      expect(described_class.new("jusuf").alternate).to eq("ASF")
    end

    it "is what lets a name match one that has no ambiguity of its own" do
      expect(described_class.match?("jusuf", "yusuf")).to be(true)
    end

    # Neither name's primary is the other's primary: `SMITH` is `SM0` and
    # `SCHMIDT` is `XMT`. They meet on `SMITH`'s alternate, which is the
    # published example of why both keys are returned.
    it "is where two spellings of one surname meet" do
      expect(keys("smith") & keys("schmidt")).to eq(["XMT"])
    end

    it "is dropped when it would repeat the primary, so a caller indexes one bucket" do
      expect(keys("mohammed")).to eq(["MHMT"])
    end
  end

  describe "one word, not one name" do
    # Stated rather than assumed: a name is keyed token by token, and the
    # tokens are what the index (#31) will write. Handing the whole folded
    # value over instead gives a key for the sentence, which matches nothing.
    it "keys a name's tokens separately" do
      form = ActiveSanction::Normalizer.call("ABBAS, Abu")
      expect(form.tokens.map { |token| keys(token) }).to eq([%w[APS], %w[AP]])
    end

    it "does not key a whole name the way it keys its parts" do
      expect(keys("abbas abu")).not_to eq(keys("abbas"))
    end
  end

  # The caveat the issue asks to be documented, held to by a spec so it
  # cannot quietly stop being true.
  describe "Latin script only" do
    it "gives a Cyrillic name no key at all" do
      expect(keys("путин")).to be_empty
    end

    it "gives an Arabic name no key at all" do
      expect(keys("محمد")).to be_empty
    end

    # The one that would matter. An empty key shared by every unkeyable name
    # would make each of them a phonetic hit against all the others, which on
    # these lists is thousands of records.
    it "does not let two unkeyable names match each other" do
      expect(described_class.match?("путин", "محمد")).to be(false)
    end

    it "does not let a name match itself when it has no keys" do
      expect(described_class.match?("путин", "путин")).to be(false)
    end

    # The romanized alias on the same record is what an English-language query
    # reaches, which is what makes the limitation survivable -- see Normalizer
    # for the same argument about the fold.
    it "keys the romanization these lists publish alongside it" do
      expect(keys("putin")).to eq(["PTN"])
    end
  end

  # The departures from the ports, which are agreements with Philips' C.
  describe "characters that are not letters" do
    # Folded names carry digits -- vessel and aircraft names especially, and
    # `EP-IBA` folds to a token pair with one. The widely used Python port
    # re-applies the previous letter's rule here and keys this `PTNN`.
    it "skips a digit rather than repeating the letter before it" do
      expect(keys("putin2")).to eq(keys("putin"))
    end

    it "skips punctuation that survived into a token" do
      expect(keys("o'brien")).to eq(keys("obrien"))
    end

    it "has no keys for a word that is all digits" do
      expect(keys("747")).to be_empty
    end
  end

  describe "what a caller does with a key" do
    # Philips' article truncated to four characters and his reference C++ did
    # not. Neither does this, because a prefix is recoverable and the
    # characters are not: #31 can decide how coarse it wants its buckets.
    it "leaves the classic four-character key a slice away" do
      expect(keys("gazprombank").first[0, 4]).to eq("KSPR")
    end

    it "keeps the characters that tell two long names apart" do
      expect(keys("gazprom")).not_to eq(keys("gazprombank"))
    end
  end

  # Recorded rather than lamented, the way the token set ratio's blind spot
  # is. This column is deliberately generous and the scorer (#32) is where
  # that is paid for.
  describe "what a shared key is not" do
    it "collapses two given names that are not the same name" do
      expect(described_class.match?("hussein", "hassan")).to be(true)
    end

    it "collapses a surname onto an ordinary English word" do
      expect(described_class.match?("putin", "button")).to be(true)
    end

    # The other direction, and the reason this is a column rather than a
    # filter: dropping the `I` moves the `H` to where the rules make it
    # silent, and two spellings of one name come apart.
    it "misses a transliteration pair the character algorithms score 0.85" do
      expect(described_class.match?("zawahiri", "zawahri")).to be(false)
    end

    it "leaves that pair to the columns that do see it" do
      expect(ActiveSanction::Similarity::Levenshtein.call("zawahiri", "zawahri")).to be > 0.85
    end
  end

  describe "the names in the fixtures" do
    # spec/fixtures/ofac_consolidated, PRIM.CSV 9640 against its own ALT.CSV
    # 9153 alias: `ABU TEIR` and `ABOU TAYR`, one person, three spellings
    # between them. Character comparison scores the surnames 0.6.
    it "matches a surname against the alias spelling of it" do
      expect(described_class.match?("teir", "tayr")).to be(true)
    end

    # spec/fixtures/ofac_sdn, SDN.CSV 15007 and ALT.CSV 901, which differ only
    # by a tilde the fold has already removed.
    it "keys a folded name the same as the alias it folds onto" do
      expect(keys(ActiveSanction::Normalizer.call("MUÑOZ").value)).to eq(keys("munoz"))
    end
  end

  describe "the shape of the answer" do
    it "is empty for an empty word" do
      expect(keys("")).to eq([])
    end

    it "is the same whatever the case of the input" do
      expect(keys("QADDAFI")).to eq(keys("qaddafi"))
    end

    # A screening decision is re-derived during an audit, so a key computed
    # last quarter has to be the key computed today.
    it "is deterministic" do
      expect(3.times.map { keys("schwarzenegger") }.uniq.size).to eq(1)
    end

    it "is frozen, because an index holds onto it" do
      expect(keys("gazprom")).to be_frozen
    end

    it "is symmetric as a match" do
      expect(described_class.match?("jusuf", "yusuf")).to eq(described_class.match?("yusuf", "jusuf"))
    end
  end
end
