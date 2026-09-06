# frozen_string_literal: true

RSpec.describe ActiveSanction::Similarity::JaroWinkler do
  it_behaves_like "a similarity algorithm"

  def score(left, right) = described_class.call(left, right)

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  # Winkler's own table, as it is reproduced in the literature and in every
  # implementation worth checking against. These are the numbers that say this
  # is Jaro-Winkler rather than something near it: the scaling factor, the
  # four-character prefix cap and the boost threshold are all visible in the
  # gap between the two columns, and CRATE/TRACE -- which shares no prefix and
  # so is not boosted at all -- pins the difference between them.
  describe "published reference values" do
    {
      %w[MARTHA MARHTA] => [0.9444, 0.9611],
      %w[DIXON DICKSONX] => [0.7667, 0.8133],
      %w[DWAYNE DUANE] => [0.8222, 0.84],
      %w[CRATE TRACE] => [0.7333, 0.7333]
    }.each do |(left, right), (jaro, winkler)|
      it "scores #{left}/#{right} #{jaro} unboosted and #{winkler} boosted" do
        expect([described_class.jaro(left, right).round(4), score(left, right).round(4)])
          .to eq([jaro, winkler])
      end
    end
  end

  describe "the prefix bonus" do
    it "lifts a pair that agrees at the front over one that agrees at the back" do
      expect(score("zawahiri", "zawahira")).to be > score("zawahiri", "kawahiri")
    end

    # Nine characters of shared prefix, four of which count. Without the cap
    # the bonus would be larger than the distance left to travel and the score
    # would pass 1.0.
    it "counts at most four characters of prefix" do
      jaro = described_class.jaro("mohammed ali", "mohammed abu")
      expect(score("mohammed ali", "mohammed abu"))
        .to be_within(1e-12).of(jaro + (described_class::MAX_PREFIX * described_class::PREFIX_SCALE * (1 - jaro)))
    end

    # Winkler's own rule, and it earns its keep on these lists. Two different
    # sanctioned banks share four characters at the front and little else; the
    # gate is what stops the prefix from speaking for the rest of the name.
    it "withholds the bonus from a pair that does not already look alike" do
      expect(described_class.jaro("bank melli", "bank of kunlun co ltd")).to be < described_class::BOOST_THRESHOLD
    end

    it "returns such a pair's unboosted score unchanged" do
      expect(score("bank melli", "bank of kunlun co ltd"))
        .to eq(described_class.jaro("bank melli", "bank of kunlun co ltd"))
    end
  end

  describe "what it is good at" do
    # The reason there are two algorithms rather than one. A transposition is
    # half an edit to Jaro and two to Levenshtein, and `MARHTA` for `MARTHA`
    # is what a typist does rather than what a different name looks like.
    it "treats a transposition as the near-miss it is" do
      expect(score("marhta", "martha")).to be > ActiveSanction::Similarity::Levenshtein.call("marhta", "martha")
    end

    it "scores a transliteration variant well above an unrelated name" do
      expect(score("mohammed", "muhammad")).to be > score("mohammed", "vladimir")
    end
  end

  # Recorded rather than lamented: this is the number the token ratios (#29)
  # have to beat, and the reason the scorer (#32) cannot be built out of
  # character-level comparison alone.
  describe "what it is not good at, which is why #29 exists" do
    it "misses an inverted name at the threshold this industry screens on" do
      expect(score("abbas abu", "abu abbas")).to be < 0.85
    end
  end

  describe "Unicode" do
    # Codepoints, not bytes: `и` and `е` are two bytes each in UTF-8, and a
    # byte-wise comparison would charge two edits for one letter and score
    # Cyrillic pairs on a different scale than Latin ones.
    it "compares a Cyrillic pair on the same scale as its Latin equivalent" do
      expect(score("путин", "пугин")).to be_within(1e-12).of(score("putin", "pugin"))
    end
  end

  # The bound is loose by construction -- the prefix bonus can add 0.4 to
  # anything, so a 0.85 threshold rejects only a pair whose lengths differ by
  # more than about 4x -- and it has to stay loose, because a ceiling that
  # ever came in under a real score would drop true matches. The shared
  # contract holds it to that; these two say what it is worth in practice.
  describe "the early exit" do
    it "rejects a pair that cannot reach the threshold on length alone" do
      expect(described_class.ceiling(5, 50)).to be < 0.85
    end

    it "keeps a pair whose lengths merely differ" do
      expect(described_class.ceiling(9, 12)).to be > 0.85
    end

    # The matching window widens with the longer string, so this pair is on
    # the order of 10^7 character comparisons: a third of a second, against a
    # query budget measured in milliseconds. With a threshold it never starts.
    it "skips the comparison entirely rather than doing that work" do
      left = "a" * 1_000
      right = "b" * 10_000
      full = elapsed { score(left, right) }
      expect(elapsed { described_class.call(left, right, threshold: 0.85) }).to be < full / 50
    end
  end
end
