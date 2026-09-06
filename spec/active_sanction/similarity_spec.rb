# frozen_string_literal: true

RSpec.describe ActiveSanction::Similarity do
  describe ".threshold!" do
    it "returns a threshold in range as a Float" do
      expect(described_class.threshold!(0.85)).to eq(0.85)
    end

    it "accepts the ends of the range" do
      expect([described_class.threshold!(0), described_class.threshold!(1)]).to eq([0.0, 1.0])
    end

    # The scorer, its weights, its default threshold and every report a
    # compliance user reads are on a 0..100 scale; these primitives are not.
    # An 85 that arrived here unchecked would not fail -- it would reject
    # every pair, which reads as "nothing matched" and is the one wrong answer
    # this domain cannot absorb quietly.
    it "refuses a threshold on the 0..100 scale the rest of the library uses" do
      expect { described_class.threshold!(85) }
        .to raise_error(ArgumentError, /got 85 .* not percentages/)
    end

    it "refuses a negative threshold" do
      expect { described_class.threshold!(-0.01) }.to raise_error(ArgumentError)
    end

    it "refuses a threshold no pair could ever clear" do
      expect { described_class.threshold!(1.5) }.to raise_error(ArgumentError)
    end
  end

  describe ".codepoints" do
    it "returns the codepoints of an ASCII string" do
      expect(described_class.codepoints("abc")).to eq([97, 98, 99])
    end

    # One codepoint, two bytes. Both algorithms compare in these units so that
    # a changed letter costs the same wherever the alphabet came from.
    it "returns one entry per character, not per byte" do
      expect(described_class.codepoints("жé")).to eq([1078, 233])
    end

    # A government file with one stray byte in it must not take an index build
    # down: a list that will not build is a list nobody is screened against.
    # Anything that came through Normalizer has already been repaired; this is
    # for everything that did not.
    it "scrubs invalid bytes rather than raising, the way Form does" do
      expect(described_class.codepoints((+"gaz\xFFprom").force_encoding(Encoding::UTF_8)))
        .to eq("gaz�prom".codepoints)
    end
  end

  # Both algorithms reach the outside world through the same two helpers, so
  # the repair above is worth confirming end to end rather than in isolation.
  [ActiveSanction::Similarity::JaroWinkler, ActiveSanction::Similarity::Levenshtein].each do |algorithm|
    it "lets #{algorithm} score a name with a stray byte in it" do
      broken = (+"gaz\xFFprom").force_encoding(Encoding::UTF_8)
      expect(algorithm.call(broken, "gazprom")).to be_within(0.2).of(0.9)
    end
  end
end
