# frozen_string_literal: true

# What a screening call costs, end to end (#37).
#
#     bundle exec rake benchmark:latency
#     RUBYOPT=--yjit bundle exec rake benchmark:latency
#     BACKGROUND=store bundle exec rake benchmark:latency
#
# benchmark/index.rb and benchmark/scorer.rb time one stage each. This times
# the call an application actually makes -- `Matcher#screen`, which folds the
# query, retrieves, scores, filters, sorts, caps and stamps -- against a
# corpus the size of the real lists, and it is the number a service is sized
# from. #37 puts the budget at 25 ms at the median, which is what leaves a web
# request room for everything else it has to do.
#
# Percentiles rather than a mean, because a service is sized by its slow
# requests. The slow ones here are not exotic: a query made entirely of common
# tokens retrieves a full candidate set that all scores something, and a
# quarter of the individuals on these lists share a handful of given names.
#
# ### Nothing here is committed
#
# The accuracy report is a committed file, because the same fixtures give the
# same numbers everywhere and a diff in it means the matching changed. This
# one measures the machine it ran on -- its CPU, its Ruby, whether YJIT was
# enabled -- so a committed copy would change on every laptop and say nothing
# about the library. It prints, and the run that matters is the one on the
# hardware the service will run on.
#
# ### On the corpus
#
# The labeled records inside a synthetic haystack, the same corpus the
# accuracy report is measured against -- see benchmark/labeled_set.rb, and
# spec/support/synthetic_corpus.rb for why a synthetic one is the honest
# choice rather than a convenient one. `BACKGROUND=store` screens against
# whatever the configured store holds instead.

require_relative "labeled_set"

module LatencyBenchmark
  # Roughly OFAC plus the UN plus Canada once aliases are counted, which is
  # the size every other benchmark here uses.
  ENTITIES = 27_000

  # #37's acceptance criterion, in milliseconds, at the median.
  BUDGET = 25.0

  THRESHOLDS = [0, 50, 75, 85].freeze

  # How many names to sample out of the corpus, on top of the labeled queries.
  # Each becomes three queries, and every one of them is screened at every
  # threshold: the tail is what is being measured, and a sample that made the
  # run long enough to skip would not get run.
  SAMPLE = 100

  module_function

  def run
    jit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "yjit" : "no jit"
    puts "ruby #{RUBY_VERSION} (#{RUBY_PLATFORM}, #{jit}) -- active_sanction #{ActiveSanction::VERSION}"
    matcher = build
    queries = mix(matcher)
    screen(matcher, queries)
    batch(matcher, queries)
  end

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def resident_mb = `ps -o rss= -p #{Process.pid}`.to_i / 1024.0

  def time
    started = clock
    yield
    clock - started
  end

  def row(label, value) = printf("  %<label>-34s %<value>s\n", label: label, value: value)

  # What a boot costs. `Matcher.build` is the whole of it: it reads each
  # snapshot, indexes every name on it and takes each list's checksum, which
  # is what a web process does once before it can answer anything. The memory
  # figure is resident set across the build, so it counts the entities the
  # index retains as well as its posting lists -- the honest number, since a
  # process holding this matcher is holding all of it.
  def build
    store = LabeledSet.store(ENTITIES)
    GC.start
    before = resident_mb
    matcher = nil
    elapsed = time { matcher = ActiveSanction::Matcher.build(store) }
    GC.start
    puts "\nBuilding a matcher over #{LabeledSet.haystack_description(ENTITIES)} plus the labeled records"
    row("Matcher.build", format("%<value>8.2f s", value: elapsed))
    row("resident, index and corpus", format("%<value>8.0f MB", value: resident_mb - before))
    matcher.index.stats.each { |name, value| row(name, format("%<value>8d", value: value)) }
    matcher
  end

  # The queries the percentiles are taken over: every labeled query, plus
  # names sampled across the corpus in the three shapes a real one arrives in
  # -- as published, inverted, and with a letter changed. The labeled set
  # alone would be too few to say anything about a tail, and sampled names
  # alone would be a corpus talking to itself.
  def mix(matcher)
    entries = sample(matcher.index)
    damaged = entries.flat_map do |entry|
      [entry.name.value, entry.form.tokens.reverse.join(" "), typo(entry.form.value)]
        .uniq.map { |name| { name: name, type: entry.entity.type } }
    end
    LabeledSet.cases.map(&:query) + damaged
  end

  # Spread across the corpus rather than taken off the front of it, so the
  # sample carries the same mix of common and rare names the whole index does.
  def sample(index, count = SAMPLE)
    index.entries.each_slice([index.size / count, 1].max).map(&:first).first(count)
  end

  def typo(value)
    positions = value.each_char.with_index.select { |character, _| character.match?(/[a-z]/) }.map(&:last)
    return value if positions.size < 4

    value.dup.tap { |damaged| damaged[positions.fetch(positions.size / 2)] = "x" }
  end

  # The section the budget is judged against. A threshold is what makes a
  # screening call affordable -- it turns off the expensive shares of the
  # scorer for candidates that were never going to clear -- so the sweep is
  # here rather than only in benchmark/scorer.rb: this is the same argument
  # measured through the call an application makes.
  def screen(matcher, queries)
    timings = THRESHOLDS.to_h { |threshold| [threshold, measure(matcher, queries, threshold)] }
    puts "\nOne screening call over #{matcher.size} names, #{queries.size} queries"
    printf("  %<t>-10s %<mean>9s %<p50>9s %<p95>9s %<p99>9s %<max>9s\n",
           t: "threshold", mean: "mean", p50: "p50", p95: "p95", p99: "p99", max: "slowest")
    timings.each { |threshold, times| sweep(threshold, times) }
    verdict(timings.fetch(ActiveSanction.config.screening_threshold.round))
  end

  def sweep(threshold, times)
    printf("  %<t>-10d %<mean>6.1f ms %<p50>6.1f ms %<p95>6.1f ms %<p99>6.1f ms %<max>6.1f ms\n",
           t: threshold, mean: times.sum / times.size * 1000, p50: percentile(times, 0.50) * 1000,
           p95: percentile(times, 0.95) * 1000, p99: percentile(times, 0.99) * 1000, max: times.last * 1000)
  end

  # Warmed once, so the first query's lazily built normalizer cache is not
  # charged to the median.
  def measure(matcher, queries, threshold)
    queries.first(20).each { |query| matcher.screen(query, threshold: threshold) }
    queries.map { |query| time { matcher.screen(query, threshold: threshold) } }.sort
  end

  def percentile(sorted, fraction) = sorted.fetch([(sorted.size * fraction).to_i, sorted.size - 1].min)

  def verdict(times)
    p50 = percentile(times, 0.50) * 1000
    state = p50 <= BUDGET ? "under" : "OVER"
    puts format("\n  p50 at the default threshold: %<p50>.1f ms, %<state>s the %<budget>.0f ms budget (#37)",
                p50: p50, state: state, budget: BUDGET)
  end

  # What rescreening a customer book costs, which is the other call this
  # library gets made in anger: one `screened_at` over the whole batch, and
  # the number that says whether a nightly rescreen is minutes or hours.
  def batch(matcher, queries)
    book = queries.first(200)
    elapsed = time { matcher.screen_all(book) }
    puts "\nRescreening a book of #{book.size} names with #screen_all"
    row("elapsed", format("%<value>8.2f s", value: elapsed))
    row("throughput", format("%<value>8.0f names/second", value: book.size / elapsed))
    row("one million names", format("%<value>8.1f hours", value: 1_000_000 * elapsed / book.size / 3600))
  end
end

LatencyBenchmark.run
