# frozen_string_literal: true

RSpec.describe ActiveSanction::Scorer::NameScore do
  def fold(value, type: nil) = ActiveSanction::Normalizer.call(value, type: type)

  def score(left, right, weights = ActiveSanction::Scorer::Weights.default)
    described_class.call(fold(left), fold(right), weights).round(1)
  end

  describe ".call" do
    it "scores two identical names 100" do
      expect(score("Abu Abbas", "Abu Abbas")).to eq(100.0)
    end

    # The single most common query shape against these lists: individuals are
    # published surname-first and typed given-name-first.
    it "scores an inverted name in the nineties" do
      expect(score("ABBAS, Abu", "Abu Abbas")).to be_within(0.1).of(90.4)
    end

    # Row two of Similarity's table: sorting cannot absorb the patronymic and
    # the set ratio is what carries the pair.
    it "scores a name with an extra patronymic in the seventies" do
      expect(score("putin vladimir vladimirovich", "vladimir putin")).to be_within(0.1).of(76.2)
    end

    it "scores two people written in the same order well apart" do
      expect(score("kim jong un", "kim yong chol")).to be_within(0.1).of(54.8)
    end

    it "scores two unrelated names near the bottom" do
      expect(score("SMITH, John", "Jane Brown")).to be < 30
    end

    # A weighted maximum would put this in the nineties, because token_set
    # returns 1.0 whenever one name's words are a subset of the other's. That
    # is the alert queue nobody can work through, and the reason the blend is
    # a mean.
    it "keeps a common given name inside a longer one below a subset's 1.0" do
      expect(score("mohammed", "mohammed al zawahiri")).to be < 80
    end

    it "is symmetric" do
      expect(score("ABBAS, Abu", "Abu Abbas")).to eq(score("Abu Abbas", "ABBAS, Abu"))
    end

    it "honours the weights it is given" do
      only_set = ActiveSanction::Scorer::Weights.new(jaro_winkler: 0.0, levenshtein: 0.0, token_sort: 0.0,
                                                     token_set: 1.0, phonetic: 0.0)

      expect(score("mohammed", "mohammed al zawahiri", only_set)).to eq(100.0)
    end
  end

  describe ".ratios" do
    it "reports what each of the five actually said" do
      expect(described_class.ratios(fold("abbas abu"), fold("abu abbas")))
        .to include(jaro_winkler: be_within(0.001).of(0.805), token_sort: 1.0, token_set: 1.0)
    end

    it "reports one ratio per share, so nothing is weighted that is not measured" do
      expect(described_class.ratios(fold("a b"), fold("c d")).keys)
        .to eq(ActiveSanction::Scorer::Weights::NAME_SHARES)
    end
  end

  describe ".phonetic" do
    it "is 1.0 when every token of the shorter name has a partner that sounds like it" do
      expect(described_class.phonetic(%w[qadhafi muammar], %w[muammar gaddafi])).to eq(1.0)
    end

    it "counts one token in three" do
      expect(described_class.phonetic(%w[kim jong un], %w[kim yong chol])).to be_within(0.001).of(0.667)
    end

    # The shorter side is the denominator so that a two-token query against a
    # four-token record is not capped at 0.5 for words the query never had --
    # token_set already measures that, in a share of its own.
    it "measures against the shorter name" do
      expect(described_class.phonetic(%w[mohammed], %w[mohammed al zawahiri])).to eq(1.0)
    end

    it "is 0.0 for two names with nothing in common" do
      expect(described_class.phonetic(%w[smith], %w[brown])).to eq(0.0)
    end

    it "is 0.0 when either side has no tokens" do
      expect(described_class.phonetic([], %w[smith])).to eq(0.0)
    end

    # `HSN` is the key for HUSSEIN and equally for HASSAN, which is why the
    # phonetic share is the smallest one.
    it "agrees on two names that sound alike and are not the same name" do
      expect(described_class.phonetic(%w[hussein], %w[hassan])).to eq(1.0)
    end
  end

  describe "threshold" do
    def weights = ActiveSanction::Scorer::Weights.default

    def call(left, right, threshold:)
      described_class.call(fold(left), fold(right), weights, threshold: threshold)
    end

    it "reports a pair that cannot reach the cutoff as zero" do
      expect(call("SMITH, John", "Jane Brown", threshold: 75)).to eq(0.0)
    end

    # The promise: an early exit is a bound on what a pair can reach, never an
    # approximation of what it did.
    it "returns the exact score for a pair that clears it" do
      expect(call("ABBAS, Abu", "Abu Abbas", threshold: 75))
        .to eq(described_class.call(fold("ABBAS, Abu"), fold("Abu Abbas"), weights))
    end

    it "returns the exact score at the cutoff itself" do
      expect(call("ABBAS, Abu", "Abu Abbas", threshold: 90.4)).to be_within(0.1).of(90.4)
    end

    it "changes no score, over every pairing of a spread of names" do
      names = ["ABBAS, Abu", "Abu Abbas", "ZAYDAN, Muhammad", "PUTIN, Vladimir", "GAZPROM NEFT", "Jane Brown"]
      pairs = names.product(names)

      expect(pairs.count { |left, right| clipped?(left, right) }).to eq(0)
    end

    def clipped?(left, right)
      full = score(left, right)
      cut = call(left, right, threshold: 60).round(1)
      full >= 60 ? cut != full : !cut.zero?
    end

    it "measures nothing at all when the cutoff cannot be reached" do
      allow(ActiveSanction::Similarity::TokenSort).to receive(:call).and_call_original
      call("SMITH, John", "Jane Brown", threshold: 95)

      expect(ActiveSanction::Similarity::TokenSort).not_to have_received(:call)
    end
  end

  describe "what it cannot do" do
    # Stated rather than papered over: one name transliterated two ways scores
    # poorly, and raising the phonetic share does not fix it.
    it "scores one name transliterated two ways below any usable threshold" do
      expect(score("QADHAFI, Muammar", "Muammar Gaddafi")).to be < 70
    end

    # What actually covers it, and why the scorer takes a maximum over an
    # entity's names: these lists publish the variants themselves.
    it "scores the same query against the alias the list carries far higher" do
      expect(score("GADDAFI, Muammar", "Muammar Gaddafi")).to be > 80
    end
  end
end
