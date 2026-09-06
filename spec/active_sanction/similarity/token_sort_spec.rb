# frozen_string_literal: true

RSpec.describe ActiveSanction::Similarity::TokenSort do
  it_behaves_like "a similarity algorithm"

  def score(left, right) = described_class.call(left, right)

  # The publisher's own string, folded the way every comparison in this
  # library folds one. The strings below are transcribed from the fixture
  # rows named beside them rather than invented, and they go through
  # Normalizer here rather than arriving pre-folded, because the thing worth
  # testing is what a screening run would actually compare -- and half of
  # that is what the fold left behind.
  def folded(name, type: nil) = ActiveSanction::Normalizer.call(name, type: type).value

  # The comma OFAC writes every individual's name with, and what happens to
  # it. Nothing here has to strip it, look for it, or know it was ever there:
  # stage 4 of the fold turned it into a space long before a score is asked
  # for, which is why the inversion arrives as nothing more exotic than two
  # tokens in the wrong order.
  describe "the LAST, First inversion these lists are written in" do
    it "reaches a comparison as tokens, the comma already folded away" do
      expect(ActiveSanction::Normalizer.call("ABBAS, Abu").value).to eq("abbas abu")
    end

    # Rows of spec/fixtures/ofac_sdn (SDN.CSV 2674 and the `ABU ABBAS` its own
    # remarks field carries, ALT.CSV 220 and 221) and of
    # spec/fixtures/ofac_consolidated (PRIM.CSV 9640 and 29242). Every one is
    # the same person written twice, and every one is exactly 1.0 here: the
    # tokens are identical and only their order is not.
    {
      ["ABBAS, Abu", "Abu Abbas"] => "an alias its own remarks carry",
      ["ZAYDAN, Muhammad", "Muhammad Zaydan"] => "the name that entity is now known as",
      ["ABU TEIR, Mohammed", "Mohammed Abu Teir"] => "a three-token name",
      ["TANG, Chris", "Chris Tang"] => "a two-token name Levenshtein scores 0.0"
    }.each do |(listed, query), description|
      it "scores #{listed.inspect} against #{query.inspect} 1.0, #{description}" do
        expect(score(folded(listed), folded(query))).to eq(1.0)
      end
    end

    # The acceptance the issue was written around, and the number that made
    # the case for this file: 0.805 from Jaro-Winkler and 0.333 from
    # Levenshtein, for two spellings of one name that differ in nothing but
    # word order.
    it "turns the pair the character algorithms miss into a perfect match" do
      listed = folded("ABBAS, Abu")
      query = folded("Abu Abbas")
      expect(score(listed, query)).to be > ActiveSanction::Similarity::JaroWinkler.call(listed, query)
    end
  end

  describe "what it still says no to" do
    # Reordering is forgiven; being a different person is not. Two individuals
    # from spec/fixtures/ofac_consolidated, PRIM.CSV 9640 and 9647.
    it "scores two different individuals far below the screening threshold" do
      expect(score(folded("ABU TEIR, Mohammed"), folded("ZAHHAR, Mahmoud Khaled"))).to be < 0.5
    end

    # Sorting says nothing about spelling, which is what the character
    # algorithms underneath are still doing.
    it "still charges for a letter that differs inside a token" do
      expect(score("abbas abu", "abbas abd")).to be_within(1e-12).of(1 - (1 / 9.0))
    end
  end

  # Sorting is a trade, not an improvement. It buys indifference to word order
  # by spending the information that two names were already in the same order,
  # and for a pair whose tokens line up as written that is a real loss -- which
  # is why the scorer (#32) keeps the character-level columns rather than
  # replacing them with this one.
  describe "what sorting costs" do
    it "can score a pair below what Levenshtein makes of it unsorted" do
      expect(score("kim jong un", "kim yong chol"))
        .to be < ActiveSanction::Similarity::Levenshtein.call("kim jong un", "kim yong chol")
    end

    # Both fixture rows for one airline (spec/fixtures/ofac_sdn, SDN.CSV 36 and
    # ALT.CSV 12), and neither ratio can help: the disagreement is about where
    # a token *ends*, not about what order the tokens came in, so there is
    # nothing for a sort to line up. Recorded because it is a real recall gap
    # and it belongs to a different stage -- see Normalizer on why the fold
    # splits `AERO-CARIBBEAN` rather than joining it.
    it "does nothing for two names that disagree about a token boundary" do
      expect(score(folded("AEROCARIBBEAN AIRLINES"), folded("AERO-CARIBBEAN"))).to be < 0.6
    end
  end

  describe "what it does not handle, which is why TokenSet exists" do
    # The issue's second acceptance pair. Sorting lines `putin` up with
    # `putin` and `vladimir` with `vladimir`, and then the patronymic has
    # nowhere to go and costs half the longer name.
    it "collapses when one side carries a token the other does not" do
      expect(score(folded("PUTIN, Vladimir Vladimirovich"), folded("Vladimir Putin"))).to eq(0.5)
    end

    it "leaves that pair to the token set ratio, which scores it 1.0" do
      expect(ActiveSanction::Similarity::TokenSet.call(folded("PUTIN, Vladimir Vladimirovich"),
                                                       folded("Vladimir Putin"))).to eq(1.0)
    end
  end

  describe ".sorted" do
    it "puts a name's tokens in alphabetical order" do
      expect(described_class.sorted("zaydan muhammad")).to eq("muhammad zaydan")
    end

    it "takes the tokens a Form already carries as readily as the string" do
      form = ActiveSanction::Normalizer.call("ABBAS, Abu")
      expect(described_class.sorted(form.tokens)).to eq(described_class.sorted(form.value))
    end
  end

  # A Form holds both, and which one a caller passes is a question about
  # allocation rather than about meaning: the index (#31) will be handing over
  # a few hundred candidates that have each already been split once.
  describe "a name as tokens rather than as a string" do
    it "scores the two forms of the same pair identically" do
      left = ActiveSanction::Normalizer.call("ABBAS, Abu")
      right = ActiveSanction::Normalizer.call("Abu Abbas")
      expect(described_class.call(left.tokens, right.tokens)).to eq(described_class.call(left.value, right.value))
    end

    it "compares a string on one side against tokens on the other" do
      expect(described_class.call("abbas abu", %w[abu abbas])).to eq(1.0)
    end
  end

  # Sorting a folded name does not change its length, so the bound Levenshtein
  # derives from two lengths is exactly the bound here -- and the shared
  # contract holds that claim against every pair it can build.
  describe "the early exit" do
    it "is Levenshtein's ceiling, which is the one the comparison runs under" do
      expect(described_class.ceiling(9, 11)).to eq(ActiveSanction::Similarity::Levenshtein.ceiling(9, 11))
    end

    it "rules a perfect score out when the lengths differ at all" do
      expect(described_class.ceiling(7, 8)).to be < 1.0
    end

    it "rejects a pair whose lengths differ by more than the threshold allows" do
      expect(described_class.call("abbas abu", "abu abbas mahmoud khaled", threshold: 0.85)).to eq(0.0)
    end
  end
end
