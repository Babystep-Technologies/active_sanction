# frozen_string_literal: true

RSpec.describe ActiveSanction::Similarity::Levenshtein do
  it_behaves_like "a similarity algorithm"

  def score(left, right) = described_class.call(left, right)

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  # The textbook pairs, which between them cover a substitution, an insertion,
  # a deletion and a run of all three. `.distance` is exact and has one right
  # answer, so these are equality rather than tolerance.
  describe ".distance, against the reference pairs" do
    {
      %w[kitten sitting] => 3,
      %w[Saturday Sunday] => 3,
      %w[flaw lawn] => 2,
      %w[gumbo gambol] => 2,
      %w[book back] => 2
    }.each do |(left, right), distance|
      it "counts #{distance} edits between #{left} and #{right}" do
        expect(described_class.distance(left, right)).to eq(distance)
      end
    end

    it "counts every character of a name against nothing" do
      expect(described_class.distance("gazprom", "")).to eq(7)
    end

    it "counts nothing between a string and itself" do
      expect(described_class.distance("gazprom", "gazprom")).to eq(0)
    end
  end

  describe "the normalized score" do
    # Dividing by the longer of the two is what keeps the result in 0..1 and
    # symmetric, and what makes a three-edit gap mean less between long names
    # than between short ones.
    it "is one minus the distance over the longer length" do
      expect(score("kitten", "sitting")).to be_within(1e-12).of(1 - (3 / 7.0))
    end

    it "is 0.0 for two strings with nothing in common" do
      expect(score("abc", "xyz")).to eq(0.0)
    end
  end

  describe "what it is good at" do
    # Where Jaro-Winkler is generous. Two different companies, and a whole
    # word of difference between them that the prefix bonus is inclined to
    # forgive; the scorer (#32) blends the two so neither one decides alone.
    it "charges for a name that gained a word, which the prefix bonus forgives" do
      expect(score("gazprom", "gazprombank"))
        .to be < ActiveSanction::Similarity::JaroWinkler.call("gazprom", "gazprombank")
    end
  end

  describe "what it is not good at, which is why Jaro-Winkler is here too" do
    it "charges two edits for a transposition" do
      expect(described_class.distance("marhta", "martha")).to eq(2)
    end
  end

  describe "Unicode" do
    # Codepoints, not bytes: `и` and `е` are two bytes each in UTF-8, so a
    # byte-wise walk would call this two edits and score Cyrillic pairs on a
    # different scale than Latin ones.
    it "counts one edit for one changed Cyrillic letter" do
      expect(described_class.distance("путин", "пугин")).to eq(1)
    end
  end

  # Unlike Jaro-Winkler's, this ceiling is tight -- the missing characters are
  # insertions and nothing can absorb them -- so it does most of the work of
  # the threshold on its own.
  describe "the early exit" do
    it "rejects a pair whose lengths differ by more than the threshold allows" do
      expect(described_class.ceiling(9, 11)).to be < 0.85
    end

    it "keeps a pair whose lengths are close enough to reach it" do
      expect(described_class.ceiling(10, 11)).to be > 0.85
    end

    # Equal lengths, so the length check cannot reject the pair and every one
    # of the million cells is on the table. What stops it is the other half of
    # the exit: row minima never decrease, so once a row's smallest value is
    # past the edit budget, no row below it can come back under.
    it "abandons the matrix as soon as no row can come back under the budget" do
      left = "a" * 1_000
      right = "b" * 1_000
      full = elapsed { score(left, right) }
      expect(elapsed { described_class.call(left, right, threshold: 0.95) }).to be < full / 5
    end
  end
end
