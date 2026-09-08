# frozen_string_literal: true

RSpec.describe ActiveSanction::Doctor::Profile do
  def listed(id = 1, **without) = FakeDoctorSource.entity(:ofac_sdn, id, **without)

  def company(id = 1)
    ActiveSanction::Entity.new(id: "ofac_sdn:#{id}", source: :ofac_sdn, source_ref: id.to_s,
                               type: :organization,
                               names: [ActiveSanction::Name.new(value: "ACME TRADING LIMITED")])
  end

  def snapshot(entities) = ActiveSanction::Snapshot.new(source: :ofac_sdn, entities: entities)

  def measure(entities, **options) = described_class.measure(snapshot(entities), **options)

  describe ".measure" do
    it "counts the records of each type, and all of them" do
      expect(measure([listed(1), listed(2), company(3)]).cohorts)
        .to include(individual: 2, organization: 1, all: 3)
    end

    it "measures a field over every record where any kind of party can carry one" do
      expect(measure([listed(1), company(2)]).fill[:addresses]).to eq(0.5)
    end

    # An organization never has a date of birth, and counting one against the
    # rate would make it a function of how many companies a designation round
    # named.
    it "measures a date of birth over individuals alone" do
      expect(measure([listed(1), company(2)]).fill[:dates_of_birth]).to eq(1.0)
    end

    # A list that stopped publishing alternate spellings still has a name on
    # every record and is far harder to match against.
    it "measures alternate names separately from names" do
      expect(measure([listed(1), company(2)]).fill).to include(names: 1.0, aliases: 0.5)
    end

    # Calling it 0% would report a regression the first time an individual was
    # listed.
    it "leaves out a field whose cohort is empty rather than calling it zero" do
      expect(measure([company(1)]).fill).not_to have_key(:dates_of_birth)
    end

    it "records which list version it measured" do
      list = [listed(1)]

      expect(measure(list).checksum).to eq(snapshot(list).checksum)
    end
  end

  # Half of a profile is recomputable from a snapshot stored months ago; the
  # other half exists only while a parse is running.
  describe "what only a parse can supply" do
    it "leaves the parse-time half nil when it measured a stored snapshot" do
      expect(measure([listed(1)]))
        .to have_attributes(warnings: nil, orphans: nil, remarks_coverage: nil)
    end

    it "counts warnings by class rather than one by one" do
      warnings = (1..3).map { |at| ActiveSanction::Parsers::Warning.new(line: at, message: "row #{at} skipped") }
      adapter = FakeDoctorSource.new(:ofac_sdn, warnings: warnings)

      expect(measure([listed(1)], adapter: adapter).warnings).to eq({ "row # skipped" => 3 })
    end

    # What distinguishes one class of warning from another on these lists is
    # the value the publisher put in a field, not the row it was on.
    it "keeps a value that distinguishes one complaint from another" do
      warnings = [ActiveSanction::Parsers::Warning.new(line: 1, message: 'unknown SDN_Type "syndicate"'),
                  ActiveSanction::Parsers::Warning.new(line: 2, message: 'unknown SDN_Type "trust"')]
      adapter = FakeDoctorSource.new(:ofac_sdn, warnings: warnings)

      expect(measure([listed(1)], adapter: adapter).warnings.keys)
        .to contain_exactly('unknown SDN_Type "syndicate"', 'unknown SDN_Type "trust"')
    end

    it "takes the free-text coverage from an adapter that reads any" do
      adapter = FakeDoctorSource.new(:ofac_sdn, coverage: FakeCoverage.new(0.973, unrecognized: { "DOB c." => 4 }))

      expect(measure([listed(1)], adapter: adapter))
        .to have_attributes(remarks_coverage: 0.973, worst_unrecognized: ["DOB c.", 4])
    end

    it "counts orphaned child rows by file" do
      adapter = FakeDoctorSource.new(:ofac_sdn, orphans: { aliases: %w[1 2], addresses: [] })

      expect(measure([listed(1)], adapter: adapter)).to have_attributes(orphans: { aliases: 2, addresses: 0 },
                                                                        orphan_count: 2)
    end
  end

  describe "reading a fill rate back" do
    it "says how many records the rate was measured over" do
      profile = measure([listed(1), company(2)])

      expect([profile.cohort_size(:dates_of_birth), profile.cohort_size(:addresses)]).to eq([1, 2])
    end

    it "names them the way a sentence would" do
      expect(measure([listed(1)]).cohort_name(:dates_of_birth)).to eq("individuals")
    end
  end

  describe "serialization" do
    it "rebuilds from its own hash" do
      adapter = FakeDoctorSource.new(:ofac_sdn, orphans: { aliases: 1 }, coverage: FakeCoverage.new(0.9))
      original = measure([listed(1)], adapter: adapter)

      expect(described_class.from_h(original.to_h)).to eq(original)
    end

    it "survives the trip through JSON" do
      original = measure([listed(1), company(2)])

      expect(described_class.from_h(JSON.parse(JSON.generate(original.to_h)))).to eq(original)
    end
  end
end
