# frozen_string_literal: true

# The labeled set the accuracy harness (#37) is scored against, loaded.
#
#   LabeledSet.cases.size          # => 87
#   LabeledSet.listed.size         # => 36
#   LabeledSet.matcher(27_000)     # the labeled records inside a realistic haystack
#
# Two halves. The **listed records** are the thirty real ones the committed
# source fixtures hold, parsed by the real adapters, plus the six constructed
# ones the identifier cases need -- see benchmark/fixtures/labeled_set.yml,
# which documents where each comes from and why. The **cases** are that file's
# queries, each resolved to the one record it is supposed to find, or to
# nothing for a query that must not alert at all.
#
# ### Why the records are put inside a haystack
#
# Thirty records is a corpus in which almost nothing collides, and precision
# measured against it would be a number about the fixture rather than about
# the library. So the labeled records are indexed together with a synthetic
# corpus of the size and the shape of the real lists (see
# spec/support/synthetic_corpus.rb), and every alert on one of those is
# counted separately from an alert on a labeled record: one is noise a
# threshold has to keep out of an analyst's queue, the other is a mistake
# about a record somebody wrote down the right answer for.
#
# `BACKGROUND=store` swaps that haystack for whatever the configured store
# holds, which is what running the reports against a real synced corpus means.
# The real lists carry the records these fixtures were lifted from, so a
# background record whose primary name a labeled record already carries is
# dropped -- otherwise the harness would count the genuine OFAC record for Abu
# Abbas as a false positive for finding Abu Abbas.

require "set"
require "yaml"

require_relative "../lib/active_sanction"
require_relative "../spec/support/synthetic_corpus"

module LabeledSet
  DEFINITION = File.expand_path("fixtures/labeled_set.yml", __dir__)

  # Committed real records, and the adapter that reads each. Paths are under
  # spec/fixtures; a source published in several files names each under the
  # key its adapter declared the URL with.
  FIXTURES = {
    ofac_sdn: { sdn: "ofac_sdn/SDN.CSV", alt: "ofac_sdn/ALT.CSV", add: "ofac_sdn/ADD.CSV" },
    un_consolidated: "un_consolidated/consolidated.xml",
    canada_sema: "canada_sema/sema.xml"
  }.freeze

  # The keys of a query entry that are not part of the query itself.
  ANNOTATIONS = %w[query expect variation note].freeze

  # One labeled query: what is screened, what it must find, and what shape of
  # damage it is testing. `target` is nil for a query that must not alert.
  Case = Struct.new(:query, :target, :variation, :note, keyword_init: true) do
    def positive? = !target.nil?
    def name = query.name
    def source = target&.source
  end

  module_function

  def definition = @definition ||= YAML.safe_load_file(DEFINITION)

  # Every record a query is screened against: the real ones, then the
  # constructed pairs.
  def listed
    @listed ||= FIXTURES.flat_map { |key, paths| parse(key, paths) } +
                definition.fetch("constructed").map { |attributes| entity(attributes) }
  end

  def ids = @ids ||= listed.to_set(&:id)

  # The six invented records, which several reports name separately -- see the
  # fixture's header for why they exist at all.
  def constructed_ids = @constructed_ids ||= definition.fetch("constructed").to_set { |record| record.fetch("id") }

  def constructed?(entity) = !entity.nil? && constructed_ids.include?(entity.id)

  def background?(result) = !ids.include?(result.entity.id)

  # The queries, with each `expect` resolved to the record it names. A name
  # that resolves to none or to several is a broken fixture rather than a
  # score of zero, so it raises here.
  def cases
    @cases ||= definition.fetch("queries").map do |entry|
      Case.new(query: ActiveSanction::Query.build(**query_attributes(entry)),
               target: target(entry.fetch("expect")), variation: entry.fetch("variation").to_sym,
               note: entry["note"])
    end
  end

  def query_attributes(entry)
    entry.except(*ANNOTATIONS).transform_keys(&:to_sym).merge(name: entry.fetch("query"))
  end

  def target(expected)
    return nil if expected == "none"

    found = listed.select { |candidate| candidate.primary_name&.value == expected }
    raise "no listed record is published as #{expected.inspect}" if found.empty?
    raise "#{found.size} listed records are published as #{expected.inspect}" if found.size > 1

    found.first
  end

  # A store holding the labeled records inside a haystack, which is what the
  # reports screen against. One snapshot per source, so that a matcher built
  # from it holds the same per-source checksums a synced one would.
  def store(background)
    entities = (listed + haystack(background)).group_by(&:source)
    ActiveSanction::Storage::Memory.new.tap do |memory|
      entities.each do |source, records|
        memory.write_snapshot(ActiveSanction::Snapshot.new(source: source, entities: records))
      end
    end
  end

  def matcher(background) = ActiveSanction::Matcher.build(store(background))

  # The corpus the labeled records are hidden in: synthetic by default, and
  # the configured store's own lists under BACKGROUND=store. See the header on
  # why a duplicate of a labeled record is dropped rather than screened.
  def haystack(background)
    records = ENV["BACKGROUND"] == "store" ? stored : SyntheticCorpus.build(background)
    published = listed.filter_map { |record| published_name(record) }.to_set
    records.reject { |record| published.include?(published_name(record)) }
  end

  def published_name(record) = record.primary_name&.value&.downcase

  def stored
    store = ActiveSanction.config.storage
    sources = store.sources
    raise ActiveSanction::Matcher::NotSynced, "BACKGROUND=store, but #{store.class} holds no lists" if sources.empty?

    sources.flat_map { |key| store.fetch_snapshot(key).entities }
  end

  # What the haystack is described as in a report header.
  def haystack_description(background)
    return "the #{ActiveSanction.config.storage.class} store's own lists" if ENV["BACKGROUND"] == "store"

    "#{background} synthetic entities"
  end

  def parse(key, paths)
    payload = named(key, paths).transform_values { |path| File.binread(fixture_path(path)) }
    source = ActiveSanction::Sources[key]
    source.new.parse(source.multi_url? ? payload : payload.values.first)
  end

  def named(key, paths)
    return paths if paths.is_a?(Hash)

    { ActiveSanction::Sources[key].urls.keys.first => paths }
  end

  def fixture_path(path) = File.expand_path("../spec/fixtures/#{path}", __dir__)

  # A constructed record, with its dates read the way an adapter would read
  # them. Everything else Entity.from_h coerces itself.
  def entity(attributes)
    members = attributes.transform_keys(&:to_sym)
    members[:dates_of_birth] = Array(members[:dates_of_birth]).map { |value| ActiveSanction::PartialDate.parse(value) }
    ActiveSanction::Entity.from_h(members)
  end
end
