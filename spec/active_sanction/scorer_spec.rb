# frozen_string_literal: true

RSpec.describe ActiveSanction::Scorer do
  after { ActiveSanction.reset! }

  def name(value, kind: :primary, quality: nil)
    ActiveSanction::Name.new(value: value, kind: kind, quality: quality)
  end

  def entity(*names, type: :individual, source: :ofac_sdn, **rest)
    ActiveSanction::Entity.new(
      id: "sdn:1", source: source, type: type,
      names: names.map.with_index do |value, at|
        if value.is_a?(ActiveSanction::Name)
          value
        else
          name(value, kind: at.zero? ? :primary : :aka)
        end
      end,
      **rest
    )
  end

  def screened(**overrides)
    ActiveSanction::Scorer::Subject.new(name: "Abu Abbas", type: :individual, **overrides)
  end

  def dates(*values) = values.map { |value| ActiveSanction::PartialDate.parse(value) }

  describe "the score" do
    it "scores an entity whose name the query matches exactly at 100" do
      expect(described_class.call(screened(name: "ABBAS, Abu"), entity("ABBAS, Abu")).score).to eq(100.0)
    end

    it "scores an inverted name in the nineties" do
      expect(described_class.call(screened, entity("ABBAS, Abu")).score).to be_within(0.1).of(90.4)
    end

    it "takes an Index::Candidate as readily as an Entity" do
      index = ActiveSanction::Index.build([entity("ABBAS, Abu")])

      expect(described_class.call(screened, index.candidates("Abu Abbas").first).score).to be_within(0.1).of(90.4)
    end
  end

  describe "the maximum over an entity's names" do
    # OFAC ships more aliases than primary names and a hit is produced by one
    # specific spelling. A score that only read the primary name would miss
    # most of what these lists are for.
    it "scores the best of the names rather than the primary one" do
      listed = entity("ZAYDAN, Muhammad", "ABBAS, Abu")

      expect(described_class.call(screened, listed).score).to be_within(0.1).of(90.4)
    end

    it "reports which name produced the score" do
      listed = entity("ZAYDAN, Muhammad", "ABBAS, Abu")

      expect(described_class.call(screened, listed).name.value).to eq("ABBAS, Abu")
    end

    it "says in the explanation that the winner was an alias, and which kind" do
      listed = entity("ZAYDAN, Muhammad", "ABBAS, Abu")

      expect(described_class.call(screened, listed).explanation.first.detail)
        .to eq("matched alias \"ABBAS, Abu\" (aka)")
    end

    it "skips a name that folds away to nothing" do
      expect(described_class.call(screened, entity("---", "ABBAS, Abu")).name.value).to eq("ABBAS, Abu")
    end

    it "is nil for an entity whose every name folds away" do
      expect(described_class.call(screened, entity("---"))).to be_nil
    end

    # A former name is a name the person really used, and discounting it would
    # discount exactly the alias someone changes their name to escape.
    it "does not penalize a former name" do
      expect(described_class.call(screened, entity("ZAYDAN, Muhammad", name("ABBAS, Abu", kind: :fka))).score)
        .to be_within(0.1).of(90.4)
    end
  end

  describe "the low-quality alias penalty" do
    it "penalizes a name the UN graded Low" do
      listed = entity("ZAYDAN, Muhammad", name("ABBAS, Abu", kind: :aka, quality: :low))

      expect(described_class.call(screened, listed).score).to be_within(0.1).of(80.4)
    end

    it "says so in the explanation" do
      listed = entity("ZAYDAN, Muhammad", name("ABBAS, Abu", kind: :aka, quality: :low))

      expect(described_class.call(screened, listed).penalties.first.detail).to include("low-quality alias")
    end

    # Only the UN grades aliases; an ungraded name must not be penalized for a
    # field its source never publishes.
    it "does not penalize a name whose publisher grades nothing" do
      expect(described_class.call(screened, entity(name("ABBAS, Abu", kind: :aka))).penalties).to be_empty
    end

    # Applied before the maximum rather than to the winner afterwards: a good
    # name scoring 85 has to beat a low-quality one scoring 90.
    it "lets a good name outrank a higher-scoring low-quality one" do
      listed = entity("Abu Al Abbas", name("ABBAS, Abu", kind: :aka, quality: :low))

      expect(described_class.call(screened, listed).name.value).to eq("Abu Al Abbas")
    end
  end

  describe "the entity type filter" do
    # There is no score at which a compliance officer wants a ship in a list
    # of people, so this is a filter and not a penalty.
    it "does not score a vessel against a person" do
      expect(described_class.call(screened(name: "Northern Star"), entity("NORTHERN STAR", type: :vessel))).to be_nil
    end

    it "does not score an organization against a person either" do
      expect(described_class.call(screened, entity("ABBAS, Abu", type: :organization))).to be_nil
    end

    it "scores everything for a subject that gave no type" do
      asked = ActiveSanction::Scorer::Subject.new(name: "Northern Star")

      expect(described_class.call(asked, entity("NORTHERN STAR", type: :vessel))).not_to be_nil
    end
  end

  describe "the explanation" do
    # The acceptance criterion: every result carries a non-empty explanation.
    it "is never empty, even when only the name was known" do
      expect(described_class.call(screened, entity("ABBAS, Abu")).explanation).not_to be_empty
    end

    it "adds up to the score" do
      listed = entity("ABBAS, Abu", dates_of_birth: dates("1948"), nationalities: ["Egypt"])
      result = described_class.call(screened(dates_of_birth: "1948-12-10", nationalities: %w[RU]), listed)

      expect(result.explanation.sum(&:contribution).round(1)).to eq(result.score)
    end

    it "leads with the name, whatever else was known" do
      listed = entity("ABBAS, Abu", nationalities: ["Egypt"])

      expect(described_class.call(screened(nationalities: %w[RU]), listed).explanation.first.factor).to eq(:name)
    end
  end

  describe "absent identifiers never reduce a score" do
    # The acceptance criterion, and the rule the whole of Adjustments obeys.
    it "scores a record carrying nothing but a name the same as the name alone" do
      bare = described_class.call(screened, entity("ABBAS, Abu")).score
      asked = screened(dates_of_birth: "1948", nationalities: %w[RU], identifiers: "AB123456")

      expect(described_class.call(asked, entity("ABBAS, Abu")).score).to eq(bare)
    end

    it "scores a caller who supplied nothing but a name the same way" do
      listed = entity("ABBAS, Abu", dates_of_birth: dates("1948"), nationalities: ["Egypt"])

      expect(described_class.call(screened,
                                  listed).score).to eq(described_class.call(screened, entity("ABBAS, Abu")).score)
    end
  end

  describe "a date-of-birth conflict" do
    # The acceptance criterion: it has to put a name-identical pair under a
    # threshold rather than merely rank it lower.
    it "drops a name-identical pair from 100 to under any threshold worth setting" do
      listed = entity("ABBAS, Abu", dates_of_birth: dates("1948-12-10"))

      expect(described_class.call(screened(name: "ABBAS, Abu", dates_of_birth: "1965-04-29"), listed).score).to eq(65.0)
    end
  end

  describe "a decisive identifier" do
    it "carries a mediocre name over any threshold" do
      listed = entity("SMITH, John", identifiers: [ActiveSanction::Identifier.new(value: "AB123456")])
      asked = screened(name: "Jon Smyth", identifiers: "AB123456")

      expect(described_class.call(asked, listed).score).to eq(100.0)
    end

    # A cap that silently swallowed points would leave a reviewer adding a
    # column of figures that does not reach the number printed above it.
    it "records the clamp as a reason of its own" do
      listed = entity("SMITH, John", identifiers: [ActiveSanction::Identifier.new(value: "AB123456")])
      asked = screened(name: "Jon Smyth", identifiers: "AB123456")

      expect(described_class.call(asked, listed).explanation.last.factor).to eq(:clamp)
    end

    it "keeps the explanation adding up through the clamp" do
      listed = entity("SMITH, John", identifiers: [ActiveSanction::Identifier.new(value: "AB123456")])
      result = described_class.call(screened(name: "Jon Smyth", identifiers: "AB123456"), listed)

      expect(result.explanation.sum(&:contribution).round(1)).to eq(100.0)
    end

    it "never lets a stack of penalties take a score below zero" do
      listed = entity("Jane Brown", dates_of_birth: dates("1948"), nationalities: ["Egypt"])
      asked = screened(name: "SMITH, John", dates_of_birth: "1965", nationalities: %w[RU])

      expect(described_class.call(asked, listed).score).to eq(0.0)
    end
  end

  describe "determinism" do
    # A screening decision is re-derived during an audit months later, and a
    # score that moved by a tenth is a decision nobody can defend.
    it "produces the same score and the same explanation every time" do
      listed = entity("ABBAS, Abu", "Abu Al Abbas", dates_of_birth: dates("1948"), nationalities: ["Egypt"])
      asked = screened(dates_of_birth: "1948-12-10", nationalities: %w[RU])

      expect(Array.new(5) { described_class.call(asked, listed) }.uniq.size).to eq(1)
    end

    it "settles a tie between two equally good names on the publisher's order" do
      listed = entity("ABBAS, Abu", "ABBAS Abu")

      expect(described_class.call(screened(name: "abbas abu"), listed).name.value).to eq("ABBAS, Abu")
    end
  end

  describe "threshold" do
    def listed = entity("ABBAS, Abu", "Abu Al Abbas", dates_of_birth: dates("1948"))

    it "is nil for an entity that cannot reach it" do
      expect(described_class.call(screened(name: "Jane Brown"), listed, threshold: 75)).to be_nil
    end

    # The promise Similarity's threshold makes, one stage up: the early exits
    # are bounds on what a pair can reach, never approximations of what it
    # did reach.
    it "returns exactly the result the same call without one returns" do
      asked = screened(dates_of_birth: "1948-12-10")

      expect(described_class.call(asked, listed, threshold: 75)).to eq(described_class.call(asked, listed))
    end

    it "still picks the same name out of several" do
      expect(described_class.call(screened, listed, threshold: 75).name.value).to eq("ABBAS, Abu")
    end

    # A subject carrying the right passport number needs 40 points less of a
    # name, so the threshold cannot be applied to the name score alone.
    it "does not discard a weak name that an identifier carries over the line" do
      carried = entity("SMITH, John", identifiers: [ActiveSanction::Identifier.new(value: "AB123456")])
      asked = screened(name: "Jon Smyth", identifiers: "AB123456")

      expect(described_class.call(asked, carried, threshold: 75).score).to eq(100.0)
    end

    # 0.75 is a legitimate threshold and there is no way to tell it from a
    # 0.75 meant as three-quarters. That mistake returns everything rather
    # than nothing, which is the survivable direction.
    it "reads 0.75 as 0.75 rather than as three-quarters" do
      expect(described_class.call(screened(name: "Jane Brown"), listed, threshold: 0.75)).not_to be_nil
    end

    it "refuses a threshold above 100" do
      expect { described_class.call(screened, listed, threshold: 175) }
        .to raise_error(ArgumentError, /between 0 and 100/)
    end

    it "refuses a negative threshold" do
      expect { described_class.call(screened, listed, threshold: -1) }
        .to raise_error(ArgumentError, /between 0 and 100/)
    end
  end

  describe "weights" do
    it "reads the configured set by default" do
      ActiveSanction.configure { |c| c.scorer_weights = { dob_conflict: -20.0 } }
      listed = entity("ABBAS, Abu", dates_of_birth: dates("1948-12-10"))

      expect(described_class.call(screened(name: "ABBAS, Abu", dates_of_birth: "1965"), listed).score).to eq(80.0)
    end

    it "takes a per-call set, which is what a caller re-deriving an old decision needs" do
      listed = entity("ABBAS, Abu", dates_of_birth: dates("1948-12-10"))
      asked = screened(name: "ABBAS, Abu", dates_of_birth: "1965")

      expect(described_class.call(asked, listed, weights: { dob_conflict: -20.0 }).score).to eq(80.0)
    end
  end
end
