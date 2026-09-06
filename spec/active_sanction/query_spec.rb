# frozen_string_literal: true

RSpec.describe ActiveSanction::Query do
  after { ActiveSanction.reset_configuration! }

  def query(**overrides) = described_class.build(name: "Vladimir Putin", **overrides)

  describe "the evidence" do
    it "builds the subject the scorer compares against" do
      expect(query(type: :individual).subject).to be_a(ActiveSanction::Scorer::Subject)
    end

    # Folding is what a screening call does once and a naive one does per
    # candidate. See Scorer::Subject.
    it "folds the name once, at construction" do
      expect(query.form.value).to eq("vladimir putin")
    end

    it "keeps the name as the caller wrote it, which is what a report quotes" do
      expect(query.name).to eq("Vladimir Putin")
    end

    it "refuses a name that folds away to nothing" do
      expect { query(name: "---") }.to raise_error(ArgumentError, /folds away/)
    end

    it "reads the dates of birth" do
      expect(query(date_of_birth: "1952-10-07").dates_of_birth.map(&:to_s)).to eq(["1952-10-07"])
    end

    it "reads the identifiers" do
      expect(query(identifier: { kind: :passport, value: "AB-123" }).identifiers.size).to eq(1)
    end
  end

  # A caller with one date writes the singular and a caller with three writes
  # the plural; neither should have to remember which this library prefers.
  describe "the spellings a caller may write" do
    it "reads date_of_birth as dates_of_birth" do
      expect(query(date_of_birth: "1952").dates_of_birth.size).to eq(1)
    end

    it "reads countries as nationalities" do
      expect(query(countries: %w[RU]).nationalities).to eq(%w[RU])
    end

    it "reads country as nationalities" do
      expect(query(country: "Russia").nationalities).to eq(["Russia"])
    end

    it "reads source as sources" do
      expect(described_class.build(name: "Putin", source: :ofac_sdn).sources).to eq(%i[ofac_sdn])
    end

    it "emits the canonical plural from to_h" do
      expect(described_class.build(name: "Putin", dob: "1952").to_h.keys).to include(:dates_of_birth)
    end

    it "refuses two spellings of the same field, which is a typo rather than a merge" do
      expect { described_class.build(name: "Putin", dob: "1952", dates_of_birth: "1953") }
        .to raise_error(ArgumentError, /same field/)
    end
  end

  describe "the search options" do
    it "defaults the threshold to the configured one" do
      expect(query.threshold).to eq(ActiveSanction::Configuration::DEFAULT_SCREENING_THRESHOLD)
    end

    it "defaults the limit to the configured one" do
      expect(query.limit).to eq(ActiveSanction::Configuration::DEFAULT_SCREENING_LIMIT)
    end

    # Read once, at construction. A configuration changed mid-batch cannot
    # produce a run that is half one threshold and half another.
    it "takes the configured threshold as it stood when the query was built" do
      ActiveSanction.configure { |c| c.screening_threshold = 90 }

      expect(query.threshold).to eq(90.0)
    end

    it "takes the configured limit as it stood when the query was built" do
      ActiveSanction.configure { |c| c.screening_limit = 3 }

      expect(query.limit).to eq(3)
    end

    it "keeps a threshold the caller named" do
      expect(query(threshold: 85).threshold).to eq(85.0)
    end

    # The mistake this catches is an 85 arriving where 0.85 was meant, which
    # would reject every pair and read as "nothing matched". See Scorer.
    it "refuses a threshold outside 0..100" do
      expect { query(threshold: 101) }.to raise_error(ArgumentError, /percentage, not a similarity/)
    end

    it "accepts 0.75 as three-quarters of a point, which is the mistake it cannot catch" do
      expect(query(threshold: 0.75).threshold).to eq(0.75)
    end

    it "refuses a threshold that is not a number" do
      expect { query(threshold: "high") }.to raise_error(ArgumentError, /must be a number/)
    end

    it "refuses a limit of zero, which returns a clean report for everybody" do
      expect { query(limit: 0) }.to raise_error(ArgumentError, /at least 1/)
    end

    it "refuses a limit that is not a whole number" do
      expect { query(limit: "ten") }.to raise_error(ArgumentError, /whole number/)
    end
  end

  describe "the source filter" do
    it "means every list when it is nil" do
      expect(query.sources).to be_nil
    end

    it "normalizes the keys it was given" do
      expect(query(sources: %w[ofac_sdn un_consolidated]).sources).to eq(%i[ofac_sdn un_consolidated])
    end

    it "takes a single source as a list of one" do
      expect(query(sources: :ofac_sdn).sources).to eq(%i[ofac_sdn])
    end

    it "drops a repeated source" do
      expect(query(sources: %i[ofac_sdn ofac_sdn]).sources).to eq(%i[ofac_sdn])
    end

    it "refuses a key that is not a usable source name" do
      expect { query(sources: ["OFAC SDN"]) }.to raise_error(ActiveSanction::Sources::DeclarationError)
    end

    # A caller that computed its source list and got nothing back is asking to
    # screen against no lists at all, which reports everybody clear.
    it "refuses an empty list of sources rather than reading it as all of them" do
      expect { query(sources: []) }.to raise_error(ArgumentError, /omit it/)
    end
  end

  describe ".build" do
    it "takes a bare name, which is what a batch of names is a list of" do
      expect(described_class.build("Vladimir Putin").name).to eq("Vladimir Putin")
    end

    it "takes a Name" do
      expect(described_class.build(ActiveSanction::Name.new(value: "Vladimir Putin")).name).to eq("Vladimir Putin")
    end

    it "takes a hash of attributes" do
      expect(described_class.build(name: "Putin", threshold: 80).threshold).to eq(80.0)
    end

    it "returns a query it was handed unchanged" do
      original = query

      expect(described_class.build(original)).to equal(original)
    end

    it "applies overrides to a query it was handed" do
      expect(described_class.build(query(threshold: 80), threshold: 90).threshold).to eq(90.0)
    end

    it "keeps the rest of a query it was handed while overriding one option" do
      expect(described_class.build(query(type: :individual), limit: 5).type).to eq(:individual)
    end

    it "lets an override win over the hash it was given" do
      expect(described_class.build({ name: "Putin", limit: 5 }, limit: 9).limit).to eq(9)
    end

    it "lets an override name the field by its other spelling" do
      expect(described_class.build({ name: "Putin", dates_of_birth: "1952" }, dob: "1953").dates_of_birth.map(&:to_s))
        .to eq(["1953"])
    end
  end

  describe "serialization" do
    it "round-trips through to_h" do
      original = query(type: :individual, dob: "1952-10-07", countries: %w[RU], sources: %i[ofac_sdn], threshold: 80)

      expect(described_class.from_h(original.to_h)).to eq(original)
    end

    it "round-trips through JSON, which is how one reaches an audit record" do
      original = query(type: :individual, dob: "1952-10-07", identifier: "AB-123456")

      expect(described_class.from_h(JSON.parse(JSON.generate(original.to_h)))).to eq(original)
    end

    it "refuses an attribute it does not have" do
      expect { described_class.from_h(name: "Putin", fuzzy: true) }
        .to raise_error(ArgumentError, /unknown Query attribute/)
    end
  end

  describe "the value semantics" do
    it "is frozen on construction" do
      expect(query).to be_frozen
    end

    it "compares by value" do
      built = described_class.build(name: "Vladimir Putin", threshold: 80)

      expect(query(threshold: 80)).to eq(built)
    end

    it "is not equal to a query with a different threshold" do
      expect(query(threshold: 80)).not_to eq(query(threshold: 90))
    end

    it "hashes by value" do
      expect([query, query].uniq.size).to eq(1)
    end

    it "says what it is" do
      expect(query.inspect).to eq('#<ActiveSanction::Query "Vladimir Putin" threshold=75.0 limit=10>')
    end
  end
end
