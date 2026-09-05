# frozen_string_literal: true

# The contract both edit-distance primitives keep, written once.
#
#   RSpec.describe ActiveSanction::Similarity::JaroWinkler do
#     it_behaves_like "a similarity algorithm"
#   end
#
# What each algorithm *means* is its own business and is specified in its own
# file against published reference values. What they have to agree on is the
# shape of the answer, because the scorer (#32) blends them into one number
# and the blend is nonsense if one of them is a distance, or is unbounded, or
# quietly rounds, or means something different when a threshold is passed.
#
# The threshold examples are the ones worth the most. `threshold:` is an
# optimization -- it lets an algorithm stop as soon as the score provably
# cannot reach it -- and an optimization that changes an answer it was
# supposed to leave alone is the kind of bug that surfaces as a name that
# scored 91 last quarter and 0 this quarter.
RSpec.shared_examples "a similarity algorithm" do
  # Folded names, in the form Normalizer leaves them: lowercase, unmarked,
  # single-spaced. Drawn from the shapes these lists actually publish --
  # transliteration variants, inverted order, an added legal form, a dropped
  # patronymic, a common surname -- so that the properties below are held
  # against the corpus the library runs on rather than against lorem ipsum.
  def folded_names
    ["abbas abu", "abu abbas", "abbas abd", "muhammad al zawahiri", "mohammed al zawahri",
     "mohamad zawahri", "putin vladimir vladimirovich", "vladimir putin", "gazprom",
     "gazprombank", "gazprom neft", "aero caribbean", "aerocaribbean airlines", "smith john",
     "john smith", "jon smyth", "qaddafi muammar", "gaddafi moammar", "", "x", "iran air"]
  end

  def folded_pairs = folded_names.product(folded_names)

  describe "the shape of the answer" do
    it "scores identical strings 1.0" do
      expect(folded_names.map { |name| described_class.call(name, name) }).to all(eq(1.0))
    end

    it "stays within 0..1 across the corpus" do
      scores = folded_pairs.map { |left, right| described_class.call(left, right) }
      expect(scores).to all(be_between(0.0, 1.0))
    end

    # Both sides of a comparison are names; neither is the "query" here. An
    # asymmetric primitive would make an entity's score depend on which way
    # the scorer happened to pass its arguments.
    it "is symmetric" do
      asymmetric = folded_pairs.reject do |left, right|
        described_class.call(left, right) == described_class.call(right, left)
      end
      expect(asymmetric).to be_empty
    end

    # A screening decision is re-derived during an audit, sometimes years
    # later. The same two strings have to produce the same number every time.
    it "is deterministic" do
      once = folded_pairs.map { |left, right| described_class.call(left, right) }
      twice = folded_pairs.map { |left, right| described_class.call(left, right) }
      expect(twice).to eq(once)
    end

    it "scores a name against nothing 0.0" do
      expect([described_class.call("gazprom", ""), described_class.call("", "gazprom")]).to all(eq(0.0))
    end

    # Not a special case worth much on its own -- Form#empty? exists so that
    # the index never puts one of these in front of a scorer -- but the two
    # algorithms have to agree, and "identical" is the only defensible answer.
    it "scores two empty strings 1.0, as identical" do
      expect(described_class.call("", "")).to eq(1.0)
    end
  end

  # Stage 1 happens once, at one entry point, for both sides of a comparison.
  # An algorithm that folded anything itself would be a second place the fold
  # is decided, which is the failure Normalizer exists to prevent.
  describe "normalization" do
    it "does not fold case, which is Normalizer's job and has already happened" do
      expect(described_class.call("GAZPROM", "gazprom")).to be < 1.0
    end

    it "does not fold punctuation, for the same reason" do
      expect(described_class.call("al-qaida", "al qaida")).to be < 1.0
    end
  end

  describe "threshold:" do
    # The promise: a score that clears the threshold is the same number the
    # same call returns without one. Only the sub-threshold answers change,
    # and they change to 0.0.
    it "returns the exact score for every pair that clears it" do
      [0.3, 0.7, 0.85, 0.95].each do |cutoff|
        folded_pairs.each do |left, right|
          exact = described_class.call(left, right)
          expected = exact < cutoff ? 0.0 : exact
          expect(described_class.call(left, right, threshold: cutoff)).to eq(expected)
        end
      end
    end

    it "reports a score below it as 0.0 rather than computing it" do
      expect(described_class.call("gazprom", "gazprom neft", threshold: 0.99)).to eq(0.0)
    end

    it "leaves the same pair scoring well above zero without one" do
      expect(described_class.call("gazprom", "gazprom neft")).to be > 0.5
    end

    # 0..100 is the scale the scorer and every compliance report use, so an
    # 85 arriving here is a plausible mistake -- and one that would otherwise
    # reject every pair silently, which reads as "nothing matched".
    it "refuses a threshold on the 0..100 scale" do
      expect { described_class.call("gazprom", "gazprom", threshold: 85) }
        .to raise_error(ArgumentError, /0\.0 and 1\.0.*not percentages/m)
    end

    it "refuses a negative threshold" do
      expect { described_class.call("gazprom", "gazprom", threshold: -0.1) }.to raise_error(ArgumentError)
    end
  end

  # The early exit's safety property, and the only one that matters: the
  # ceiling is what a pair of these lengths *could* reach. If it ever came in
  # under a real score, `threshold:` would start discarding true matches on
  # the strength of a length difference -- silently, since the caller cannot
  # tell a rejected pair from a low-scoring one.
  describe ".ceiling" do
    it "is never below the score any pair of those lengths actually reaches" do
      violations = folded_pairs.reject do |left, right|
        described_class.call(left, right) <= described_class.ceiling(left.length, right.length) + 1e-12
      end
      expect(violations).to be_empty
    end

    it "does not depend on the order of the two lengths" do
      expect(described_class.ceiling(4, 19)).to eq(described_class.ceiling(19, 4))
    end

    it "allows a perfect score when the lengths are equal" do
      expect(described_class.ceiling(7, 7)).to eq(1.0)
    end

    it "rules a perfect score out when they are not" do
      expect(described_class.ceiling(7, 8)).to be < 1.0
    end
  end
end
