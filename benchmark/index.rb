# frozen_string_literal: true

# What the index (#31) costs to build, what it costs to hold, and what a query
# costs against it.
#
#     bundle exec rake benchmark:index
#     RUBYOPT=--yjit bundle exec rake benchmark:index
#
# Three numbers decide whether this library can back a service, and they are
# the three sections below: a build has to fit in the time between a
# publisher's file landing and an operator losing patience, the result has to
# fit in a web process, and a query has to leave most of a 10 ms budget for the
# scorers that run after it.
#
# The last section is the one that set POSTINGS_BUDGET. It sweeps the budget
# against both latency and recall, and the point it makes is that recall stops
# improving long before latency stops getting worse.
#
# ### On the corpus
#
# Synthetic, and deliberately so -- see spec/support/synthetic_corpus.rb for
# the argument. The real lists are a network call away and change weekly, and
# what the index has to be measured against is not which names are on them but
# how their names are distributed: a handful of given names on a quarter of
# the records, a long tail of surnames on one apiece. A benchmark against
# 46,000 uniformly random strings would report numbers several times better
# than the truth, because every posting list would be short.

require_relative "../lib/active_sanction"
require_relative "../spec/support/synthetic_corpus"

module IndexBenchmark
  # 27,000 entities is about 46,000 indexed names once aliases are counted,
  # which is the size of OFAC plus the UN plus Canada.
  ENTITIES = 27_000

  module_function

  def run
    jit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "yjit" : "no jit"
    puts "ruby #{RUBY_VERSION} (#{RUBY_PLATFORM}, #{jit}) -- active_sanction #{ActiveSanction::VERSION}"
    entities = SyntheticCorpus.build(ENTITIES)
    index = build(entities)
    query(index)
    budget(index)
  end

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def resident_mb = `ps -o rss= -p #{Process.pid}`.to_i / 1024.0

  # Build time and what the built index weighs. The memory figure is resident
  # set before and after, which counts the entities the index retains as well
  # as its posting lists -- that is the honest number, since a process holding
  # this index is holding all of it.
  def build(entities)
    GC.start
    before = resident_mb
    started = clock
    index = ActiveSanction::Index.build(entities)
    elapsed = clock - started
    GC.start
    puts "\nBuilding #{index.size} names from #{entities.size} entities"
    row("build", format("%<value>8.2f s", value: elapsed))
    row("resident, index and corpus", format("%<value>8.0f MB", value: resident_mb - before))
    index.stats.each { |name, value| row(name, format("%<value>8d", value: value)) }
    index
  end

  # One query, which is what the ~10 ms screening budget is actually spent
  # against. Percentiles rather than a mean: a service is sized by its slow
  # requests, and the slow ones here are the names made entirely of common
  # tokens.
  def query(index)
    names = sample(index).map { |entry| entry.name.value }
    3.times { names.each { |name| index.candidates(name) } }
    times = names.map { |name| time { index.candidates(name) } }.sort
    puts "\nOne query against #{index.size} names, limit #{ActiveSanction.config.candidate_limit}"
    percentiles(times).each { |label, seconds| row(label, format("%<value>8.2f ms", value: seconds * 1000)) }
  end

  def percentiles(times)
    { "mean" => times.sum / times.size, "median" => times[times.size / 2],
      "p95" => times[(times.size * 0.95).to_i], "p99" => times[(times.size * 0.99).to_i],
      "slowest" => times.last }
  end

  def time
    started = clock
    yield
    clock - started
  end

  def row(label, value) = printf("  %<label>-34s %<value>s\n", label: label, value: value)

  # The sweep POSTINGS_BUDGET was chosen from. Recall is measured at the
  # configured cap, against queries damaged the way real ones are, so the two
  # columns are directly comparable: what a larger budget costs, and what it
  # buys.
  def budget(index)
    entries = sample(index)
    puts "\nThe postings budget, against #{entries.size} damaged queries each"
    printf("  %<budget>-10s %<median>10s %<p99>10s %<recall>s\n",
           budget: "budget", median: "median", p99: "p99", recall: "recall at the configured cap")
    [2_500, 5_000, 10_000, 25_000, 50_000].each { |budget| sweep(index, entries, budget) }
  ensure
    reset_budget(ActiveSanction::Index::POSTINGS_BUDGET)
  end

  def sweep(index, entries, budget)
    reset_budget(budget)
    times = entries.map { |entry| time { index.candidates(entry.name.value) } }.sort
    recalls = DAMAGE.map { |label, damage| "#{label} #{format("%<r>.3f", r: recall(index, entries, damage))}" }
    printf("  %<budget>-10d %<median>7.2f ms %<p99>7.2f ms  %<recall>s\n",
           budget: budget, median: times[times.size / 2] * 1000,
           p99: times[(times.size * 0.99).to_i] * 1000, recall: recalls.join("  "))
  end

  def reset_budget(value)
    ActiveSanction::Index.send(:remove_const, :POSTINGS_BUDGET)
    ActiveSanction::Index.const_set(:POSTINGS_BUDGET, value)
  end

  # The shapes a real query arrives in: the name as published, the same name
  # with its words the other way round, and the same name with a letter
  # changed.
  DAMAGE = {
    "published" => ->(entry) { entry.name.value },
    "inverted" => ->(entry) { entry.form.tokens.reverse.join(" ") },
    "typo" => ->(entry) { IndexBenchmark.typo(entry.form.value) }
  }.freeze

  def typo(value)
    positions = value.each_char.with_index.select { |character, _| character.match?(/[a-z]/) }.map(&:last)
    return value if positions.size < 4

    value.dup.tap { |damaged| damaged[positions.fetch(positions.size / 2)] = "x" }
  end

  def recall(index, entries, damage)
    found = entries.count do |entry|
      index.candidates(damage.call(entry), type: entry.entity.type)
           .any? { |candidate| candidate.entry.id == entry.id }
    end
    found.fdiv(entries.size)
  end

  # Spread across the corpus rather than taken from the front of it, so the
  # sample carries the same mix of common and rare names the whole index does.
  def sample(index, count = 300)
    index.entries.each_slice([index.size / count, 1].max).map(&:first).first(count)
  end
end

IndexBenchmark.run
