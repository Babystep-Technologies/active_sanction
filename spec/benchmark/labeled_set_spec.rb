# frozen_string_literal: true

require_relative "../../benchmark/labeled_set"

# The accuracy report (#37) is only worth reading if the set it scores against
# is intact, and every way it can rot is silent: an `expect` naming a record
# that no longer parses out of the fixtures reads as a miss, a constructed
# record nothing queries reads as nothing at all, and either would move the
# numbers a threshold is set from without moving a line of matching code.
#
# So the fixture is checked here rather than in the benchmark, where a broken
# entry would surface as a worse F1 that somebody has to go and explain.
RSpec.describe LabeledSet do
  let(:cases) { described_class.cases }

  # The vocabulary the fixture's own header documents, read back out of it, so
  # that a new kind of variation has to be explained where a reader of the
  # file will meet it.
  let(:documented) do
    File.read(described_class::DEFINITION)[/^#   published.*?^#\n/m].to_s.scan(/^#   (\w+)/).flatten.map(&:to_sym)
  end

  it "resolves every expectation to exactly one listed record" do
    expect { cases }.not_to raise_error
  end

  it "holds queries with a right answer, which is what recall is measured over" do
    expect(cases.count(&:positive?)).to be_positive
  end

  it "holds queries with no right answer, since a set of only positives measures half of it" do
    expect(cases.reject(&:positive?)).not_to be_empty
  end

  it "screens against records from every source the fixtures cover" do
    sources = described_class.listed.map(&:source).uniq
    expect(sources).to include(:ofac_sdn, :un_consolidated, :canada_sema)
  end

  it "parses the real records out of the committed fixtures rather than inventing them" do
    real = described_class.listed.reject { |record| described_class.constructed?(record) }
    expect(real.size).to be >= 30
  end

  it "queries every constructed record, since one nothing asks about measures nothing" do
    asked = cases.filter_map { |kase| kase.target&.id }.uniq
    expect(described_class.constructed_ids.to_a - asked).to be_empty
  end

  it "reads a documented vocabulary of variations out of the fixture's own header" do
    expect(documented).to include(:published, :near_miss)
  end

  it "labels every query with a variation that vocabulary documents" do
    expect(cases.map(&:variation).uniq - documented).to be_empty
  end

  it "gives every positive query a listed record to find" do
    expect(cases.select(&:positive?).map(&:target)).to all(be_a(ActiveSanction::Entity))
  end

  # The haystack the reports hide the labeled records in must not contain
  # them: a duplicate of a labeled record would be scored as a false alert for
  # being the right answer.
  it "keeps the haystack clear of the records the queries are about" do
    labeled = described_class.listed.map { |record| record.primary_name&.value&.downcase }
    hidden = described_class.haystack(50).map { |record| record.primary_name&.value&.downcase }
    expect(hidden).not_to include(*labeled)
  end
end
