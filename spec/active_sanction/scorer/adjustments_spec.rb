# frozen_string_literal: true

RSpec.describe ActiveSanction::Scorer::Adjustments do
  def entity(**overrides)
    ActiveSanction::Entity.new(id: "sdn:1", source: :ofac_sdn, type: :individual,
                               names: [ActiveSanction::Name.new(value: "ABBAS, Abu")], **overrides)
  end

  def screened(**overrides)
    ActiveSanction::Scorer::Subject.new(name: "Abu Abbas", **overrides)
  end

  def factors(screened, entity) = described_class.call(screened, entity).map(&:factor)

  def contribution(screened, entity, factor)
    described_class.call(screened, entity).find { |reason| reason.factor == factor }&.contribution
  end

  describe "absent is not conflict" do
    # The rule everything here obeys. Most records lack most identifiers, and
    # a scorer that read absence as disagreement would systematically
    # under-score the sparser lists.
    it "makes no adjustment at all when the record carries nothing but a name" do
      expect(described_class.call(screened(dates_of_birth: "1948", nationalities: %w[RU],
                                           identifiers: "AB123456"), entity)).to be_empty
    end

    it "makes no adjustment when the caller supplied nothing but a name" do
      listed = entity(dates_of_birth: [ActiveSanction::PartialDate.parse("1948")], nationalities: ["Egypt"])

      expect(described_class.call(screened, listed)).to be_empty
    end

    it "never lowers a score for a field only one side has" do
      listed = entity(dates_of_birth: [ActiveSanction::PartialDate.parse("1948")])

      expect(described_class.call(screened(nationalities: %w[RU]), listed).sum(&:contribution)).to eq(0.0)
    end
  end

  describe "identifiers" do
    def listed(value, kind: :passport, country: nil)
      entity(identifiers: [ActiveSanction::Identifier.new(kind: kind, value: value, country: country)])
    end

    it "boosts decisively on an exact document number" do
      mine = [{ kind: :passport, value: "AB123456" }]

      expect(contribution(screened(identifiers: mine), listed("AB123456"), :identifier)).to eq(40.0)
    end

    # Two governments transcribing one passport rarely agree on its
    # punctuation, which is what Identifier#normalized_value is for.
    it "reads through the punctuation two publishers wrote differently" do
      expect(contribution(screened(identifiers: "ab-123 456"), listed("AB123456"), :identifier)).to eq(40.0)
    end

    it "names both spellings, so a reviewer can see what was compared" do
      reasons = described_class.call(screened(identifiers: "ab-123 456"), listed("AB123456"))

      expect(reasons.first.detail).to eq("passport ab-123 456 matches listed AB123456")
    end

    # OFAC's remarks produce :other for a number its sentence did not
    # classify, and requiring the kinds to be equal would throw most of them
    # away.
    it "matches an unclassified number against a classified one" do
      expect(contribution(screened(identifiers: "AB123456"), listed("AB123456"), :identifier)).to eq(40.0)
    end

    it "refuses to match a passport against a national ID with the same digits" do
      expect(contribution(screened(identifiers: [{ kind: :passport, value: "AB123456" }]),
                          listed("AB123456", kind: :national_id), :identifier)).to be_nil
    end

    # Two passports with the same number from different countries are
    # different documents -- the rule Identifier's own equality carries.
    it "refuses to match two countries' documents that share a number" do
      mine = [{ kind: :passport, value: "AB123456", country: "Russia" }]

      expect(contribution(screened(identifiers: mine), listed("AB123456", country: "Egypt"), :identifier)).to be_nil
    end

    it "matches when only one side states a country" do
      mine = [{ kind: :passport, value: "AB123456" }]

      expect(contribution(screened(identifiers: mine), listed("AB123456", country: "Egypt"), :identifier)).to eq(40.0)
    end

    it "reads two spellings of one country as one country" do
      mine = [{ kind: :passport, value: "AB123456", country: "Russia" }]

      expect(contribution(screened(identifiers: mine), listed("AB123456", country: "RUS"), :identifier)).to eq(40.0)
    end

    # Nothing a government issues is three characters long, and a 40-point
    # boost has no business landing on a coincidence.
    it "ignores a number too short to be a document number" do
      expect(contribution(screened(identifiers: "12"), listed("12"), :identifier)).to be_nil
    end
  end

  describe "dates of birth" do
    def listed(*dates)
      entity(dates_of_birth: dates.map { |date| ActiveSanction::PartialDate.parse(date) })
    end

    it "boosts strongly on an exact full date" do
      expect(contribution(screened(dates_of_birth: "1948-12-10"), listed("1948-12-10"), :dob)).to eq(15.0)
    end

    it "boosts moderately when a year-only date sits inside a full one" do
      expect(contribution(screened(dates_of_birth: "1948"), listed("1948-12-10"), :dob)).to eq(6.0)
    end

    it "says which way the overlap ran" do
      reasons = described_class.call(screened(dates_of_birth: "1948"), listed("1948-12-10"))

      expect(reasons.first.detail).to eq("date of birth 1948 overlaps listed 1948-12-10")
    end

    # A "circa" date is widened by a year on each side before it is compared,
    # so two governments' reports of one person do not read as a conflict.
    it "treats an approximate date as agreement rather than an exact match" do
      expect(contribution(screened(dates_of_birth: "circa 1962"), listed("1963"), :dob)).to eq(6.0)
    end

    it "penalizes a genuine conflict" do
      expect(contribution(screened(dates_of_birth: "1965-04-29"), listed("1948-12-10"), :dob)).to eq(-35.0)
    end

    it "names both dates in the conflict, so a reviewer can check it" do
      reasons = described_class.call(screened(dates_of_birth: "1965-04-29"), listed("1948-12-10"))

      expect(reasons.first.detail).to eq("date of birth 1965-04-29 conflicts with listed 1948-12-10")
    end

    # The UN publishes several dates for 140 of its individuals because
    # several governments reported several dates. Any of them matching is a
    # match, so a conflict means none of the pairings overlap.
    it "matches against any of several published dates" do
      expect(contribution(screened(dates_of_birth: "1949"), listed("1948", "1949"), :dob)).to eq(6.0)
    end

    it "conflicts only when no pairing overlaps at all" do
      expect(contribution(screened(dates_of_birth: %w[1948 1965]), listed("1949"), :dob)).to eq(-35.0)
    end

    it "prefers an exact match over an overlap elsewhere in the list" do
      expect(contribution(screened(dates_of_birth: %w[1948 1948-12-10]), listed("1948", "1948-12-10"), :dob))
        .to eq(15.0)
    end
  end

  describe "nationality" do
    it "boosts on agreement, whichever vocabulary each side used" do
      expect(contribution(screened(nationalities: %w[RU]), entity(nationalities: ["Russia"]), :nationality)).to eq(6.0)
    end

    it "penalizes a conflict" do
      expect(contribution(screened(nationalities: %w[RU]), entity(nationalities: ["Egypt"]), :nationality)).to eq(-12.0)
    end

    it "names both countries by code" do
      reasons = described_class.call(screened(nationalities: %w[RU]), entity(nationalities: ["Egypt"]))

      expect(reasons.first.detail).to eq("query RU vs listed EG")
    end

    it "boosts when one of several nationalities agrees, since people hold two passports" do
      expect(contribution(screened(nationalities: %w[RU GB]), entity(nationalities: %w[Egypt Russia]),
                          :nationality)).to eq(6.0)
    end

    # "These two strings are not equal" is not evidence that two countries
    # are different, and a penalty on it lands on the records where a caller
    # supplied the most information.
    it "does not penalize a country it cannot resolve" do
      expect(contribution(screened(nationalities: %w[RU]), entity(nationalities: ["Stateless"]), :nationality))
        .to be_nil
    end

    it "still finds agreement on a value neither side could resolve" do
      expect(contribution(screened(nationalities: ["Stateless"]), entity(nationalities: ["stateless"]),
                          :nationality)).to eq(6.0)
    end
  end

  describe "order" do
    # Strongest evidence first, so a reviewer meets the reason the score is
    # what it is before the ones that adjusted it -- and so the sum is taken
    # the same way on every run.
    it "reports identifier, then date of birth, then nationality" do
      listed = entity(dates_of_birth: [ActiveSanction::PartialDate.parse("1948")], nationalities: ["Egypt"],
                      identifiers: [ActiveSanction::Identifier.new(value: "AB123456")])
      asked = screened(dates_of_birth: "1948", nationalities: %w[RU], identifiers: "AB123456")

      expect(factors(asked, listed)).to eq(%i[identifier dob nationality])
    end
  end
end
