# frozen_string_literal: true

RSpec.describe ActiveSanction::Similarity::TokenSet do
  it_behaves_like "a similarity algorithm"

  def score(left, right) = described_class.call(left, right)

  # As in the token sort specs: the publisher's own string, folded by the
  # Normalizer a screening run folds it with, so that what is scored here is
  # what would be scored there.
  def folded(name, type: nil) = ActiveSanction::Normalizer.call(name, type: type).value

  # The condition this exists for: a token on one side and not the other.
  # Sorting lines up what the two names share and then has to pay for
  # everything else, character by character; this compares what they share
  # against each of them, and the extra tokens stop deciding the answer.
  describe "a token count that does not match" do
    # The issue's acceptance pair. A patronymic Russian records carry and
    # nobody types.
    it "scores a name against itself plus a patronymic 1.0" do
      expect(score(folded("PUTIN, Vladimir Vladimirovich"), folded("Vladimir Putin"))).to eq(1.0)
    end

    it "does so where the token sort ratio pays half the name for it" do
      listed = folded("PUTIN, Vladimir Vladimirovich")
      query = folded("Vladimir Putin")
      expect(score(listed, query)).to be > ActiveSanction::Similarity::TokenSort.call(listed, query)
    end

    # spec/fixtures/un_consolidated, the FIRST/SECOND/THIRD name fields of one
    # listed individual, against the two-thirds of it a query would carry.
    it "absorbs a middle name a query did not carry" do
      expect(score(folded("QUSAY SADDAM HUSSEIN"), folded("Qusay Hussein"))).to eq(1.0)
    end

    # spec/fixtures/ofac_consolidated: PRIM.CSV 9640 against its own ALT.CSV
    # 9152 alias, which adds a token *and* spells the surname differently. The
    # extra token is forgiven; the spelling is not, which is the whole point of
    # running an edit distance underneath rather than comparing sets.
    it "still charges for a spelling difference inside the shared tokens" do
      expect(score(folded("ABU TEIR, Mohammed"), folded("ABU TAIR, Mohammed Mahmud")))
        .to be_within(0.005).of(0.706)
    end
  end

  describe "the inverted names, which it handles for the same reason sorting does" do
    it "scores a name against its own inversion 1.0" do
      expect(score(folded("ABBAS, Abu"), folded("Abu Abbas"))).to eq(1.0)
    end

    # spec/fixtures/ofac_sdn, ALT.CSV 220: the same person with `Al` added and
    # the order reversed, which is the two problems at once.
    it "scores an inversion that also gained a token 1.0" do
      expect(score(folded("ABBAS, Abu Al"), folded("Abu Abbas"))).to eq(1.0)
    end
  end

  # The price of all of the above, in the one place it hurts. It is stated
  # here rather than argued away because a screening library that hides what
  # its scores cannot tell apart is worse than one that says so: the answer is
  # not to weaken this ratio but to keep the scorer (#32) from letting it vote
  # alone.
  describe "what the tolerance costs" do
    # spec/fixtures/ofac_consolidated, PRIM.CSV 18299, against its parent's
    # name. A subsidiary is a real entity with a real separate listing, and
    # this column cannot see the difference.
    it "scores a name that is a subset of another 1.0, whatever else it says" do
      expect(score(folded("ROSNEFT TRADING S.A.", type: :organization),
                   folded("Rosneft", type: :organization))).to eq(1.0)
    end

    it "does so no matter how much longer the other name is" do
      expect(score("gazprom", "gazprom neft public joint stock company")).to eq(1.0)
    end

    # What stops that from deciding a hit: the other three columns all charge
    # for the extra words, and the blend is where the disagreement is resolved.
    it "is the only one of the four that cannot tell those two apart" do
      expect(ActiveSanction::Similarity::Levenshtein.call("gazprom", "gazprom neft")).to be < 0.85
    end
  end

  describe "what it says no to" do
    # Two different individuals, spec/fixtures/ofac_consolidated PRIM.CSV 9640
    # and 9647. Nothing shared, so the comparison falls back to what the sort
    # ratio would have said.
    it "scores two unrelated names far below the screening threshold" do
      expect(score(folded("ABU TEIR, Mohammed"), folded("ZAHHAR, Mahmoud Khaled"))).to be < 0.5
    end

    it "is the sorted comparison exactly when the two share no token at all" do
      expect(score("bank kunlun", "bm holding"))
        .to eq(ActiveSanction::Similarity::TokenSort.call("bank kunlun", "bm holding"))
    end

    # A shared given name is not a match, and this is the shape where that
    # matters most: a quarter of the individuals on these lists share a
    # handful of them.
    it "does not let one shared token carry two different people" do
      expect(score("mohammed abu teir", "mohammed zahhar")).to be < 0.85
    end
  end

  # Sets, so a token that repeats is a token. `ALI, Ali Hassan` is a real
  # shape, and the second `ali` is a naming convention rather than a second
  # piece of evidence.
  describe "duplicate tokens" do
    it "counts a repeated token once" do
      expect(score("ali ali hassan", "ali hassan")).to eq(1.0)
    end

    it "gives the same answer whichever side the repetition is on" do
      expect(score("ali hassan", "ali ali hassan")).to eq(score("ali ali hassan", "ali hassan"))
    end
  end

  describe ".strings" do
    # What was actually compared, which is what an analyst clearing a hit has
    # to be able to see: the shared tokens, then each name's own, all in
    # alphabetical order.
    it "returns the shared tokens and each side's full set" do
      expect(described_class.strings(%w[putin vladimir vladimirovich], %w[vladimir putin]))
        .to eq(["putin vladimir", "putin vladimir vladimirovich", "putin vladimir"])
    end

    it "puts a name's own tokens after the shared ones" do
      expect(described_class.strings(%w[abu abbas al], %w[abu abbas]))
        .to eq(["abbas abu", "abbas abu al", "abbas abu"])
    end
  end

  describe "a name as tokens rather than as a string" do
    it "scores the two forms of the same pair identically" do
      left = ActiveSanction::Normalizer.call("PUTIN, Vladimir Vladimirovich")
      right = ActiveSanction::Normalizer.call("Vladimir Putin")
      expect(described_class.call(left.tokens, right.tokens)).to eq(described_class.call(left.value, right.value))
    end

    it "compares a string on one side against tokens on the other" do
      expect(described_class.call("abbas abu", %w[abu abbas])).to eq(1.0)
    end
  end

  # There is no length at which this ratio can promise less than a perfect
  # score, because a subset scores one at any length. Saying so is the honest
  # answer and the safe one; a tighter bound would discard true matches on the
  # strength of a length difference, and silently, since a caller cannot tell
  # a pair rejected by a ceiling from one that scored badly.
  describe ".ceiling" do
    it "allows a perfect score however far apart the lengths are" do
      expect(described_class.ceiling(7, 38)).to eq(1.0)
    end

    it "rules one out only when a name has no characters to match at all" do
      expect(described_class.ceiling(0, 7)).to eq(0.0)
    end

    it "still clears a threshold-passed call that a length difference would have rejected" do
      expect(described_class.call("gazprom", "gazprom neft", threshold: 0.85)).to eq(1.0)
    end
  end
end
