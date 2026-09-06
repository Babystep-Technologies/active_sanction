# frozen_string_literal: true

# What the scorer (#32) costs, and what a threshold buys.
#
#     bundle exec rake benchmark:scorer
#     RUBYOPT=--yjit bundle exec rake benchmark:scorer
#
# The scorer is the whole of what a screening call spends after the index has
# narrowed it, so the number this prints is the number that decides whether a
# service can make one. Three sections:
#
# **What each share costs**, per pair of names, which is what NameScore::ORDER
# is set from -- and the reason the order is not simply cheapest first.
#
# **What a query costs at each threshold**, which is the section that matters.
# Unthresholded scoring is several times the whole budget; a threshold turns
# the expensive shares off for the candidates that were never going to clear,
# and the difference is most of the difference between a library a service can
# call and one it cannot.
#
# **That the thresholds change nothing but the time.** Every candidate is
# scored twice, with and without a cutoff, and the run fails loudly if the two
# ever disagree. The early exits are bounds on what a pair can reach and never
# approximations of what it did reach; a benchmark that made the scorer faster
# and quietly wrong would be worse than no benchmark.
#
# ### On the corpus
#
# Synthetic, for the reason the index benchmark's is -- see
# spec/support/synthetic_corpus.rb. What the scorer has to be measured against
# is not which names are on the real lists but how they are distributed: a
# query for a common given name retrieves two hundred candidates that all
# score *something*, which is the case a threshold has to work on and the one
# a corpus of distinct random strings would never produce.

require_relative "../lib/active_sanction"
require_relative "../spec/support/synthetic_corpus"

module ScorerBenchmark
  # The size the index benchmark uses, for the same reason: roughly the SDN
  # list plus the UN plus Canada once aliases are counted.
  ENTITIES = 27_000

  # The shapes a screening call actually arrives in. The first is the case
  # this stage is hardest on and the one that sizes a service: a quarter of
  # the individuals on these lists share a handful of given names, so a query
  # carrying one retrieves a full candidate set of names that all score.
  QUERIES = [
    ["a very common given name", "Mohammed Al-Zawahiri", :individual],
    ["a name published inverted", "Vladimir Putin", :individual],
    ["an organization", "Gazprom Neft Trading", :organization],
    ["three common tokens", "Ahmad Rashid Saleh", :individual],
    ["a name with no match", "Fionnuala Ni Bhraonain", :individual]
  ].freeze

  THRESHOLDS = [0, 50, 75, 85, 90].freeze

  module_function

  def run
    jit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "yjit" : "no jit"
    puts "ruby #{RUBY_VERSION} (#{RUBY_PLATFORM}, #{jit}) -- active_sanction #{ActiveSanction::VERSION}"
    index = ActiveSanction::Index.build(SyntheticCorpus.build(ENTITIES))
    work = QUERIES.map { |label, name, type| prepare(index, label, name, type) }
    shares(work)
    thresholds(work)
    exactness(work)
  end

  # One subject, and the candidates the index hands the scorer for it, with
  # every candidate name folded once so the timings below measure comparison
  # rather than normalization.
  def prepare(index, label, name, type)
    subject = ActiveSanction::Scorer::Subject.new(name: name, type: type)
    candidates = index.candidates(subject.form, type: type)
    forms = candidates.flat_map do |candidate|
      candidate.entity.names.map { |listed| ActiveSanction::Normalizer.call(listed, type: candidate.entity.type) }
    end
    { label: label, subject: subject, candidates: candidates, forms: forms.reject(&:empty?) }
  end

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def time(repeats = 5, &block)
    block.call
    started = clock
    repeats.times(&block)
    (clock - started) / repeats
  end

  def row(label, value) = printf("  %<label>-34s %<value>s\n", label: label, value: value)

  # Per pair of names, unthresholded, which is what each share costs when it
  # cannot exit early. The token set ratio is three Levenshteins on rearranged
  # strings and prices like it; the phonetic pass is the one with no threshold
  # to be given, which is why it is measured here and ordered last.
  def shares(work)
    weights = ActiveSanction::Scorer::Weights.default
    pairs = work.sum { |query| query[:forms].size }
    puts "\nOne share, per pair of names (#{pairs} pairs)"
    ActiveSanction::Scorer::NameScore::ORDER.each do |share|
      elapsed = time do
        work.each do |query|
          query[:forms].each { |form| ActiveSanction::Scorer::NameScore.measure(share, query[:subject].form, form) }
        end
      end
      row("#{share} (weight #{weights.fetch(share)})", format("%<value>8.1f us", value: elapsed / pairs * 1_000_000))
    end
  end

  # The section the threshold argument is made in: what one screening call
  # costs, and how many of its candidates survive.
  def thresholds(work)
    puts "\nOne query, scoring #{ActiveSanction.config.candidate_limit} candidates"
    printf("  %<t>-10s %<mean>10s %<slowest>10s  %<results>s\n",
           t: "threshold", mean: "mean", slowest: "slowest", results: "results per query")
    THRESHOLDS.each { |threshold| sweep(work, threshold) }
  end

  def sweep(work, threshold)
    times = work.map { |query| time { score(query, threshold) } }.sort
    results = work.sum { |query| score(query, threshold).size }
    printf("  %<t>-10d %<mean>7.1f ms %<slowest>7.1f ms  %<results>5.1f\n",
           t: threshold, mean: times.sum / times.size * 1000, slowest: times.last * 1000,
           results: results.fdiv(work.size))
  end

  def score(query, threshold)
    query[:candidates].filter_map do |candidate|
      ActiveSanction::Scorer.call(query[:subject], candidate, threshold: threshold)
    end
  end

  # A score at or above the threshold has to be the same score the same call
  # without one returns. Anything else is an approximation wearing an
  # optimization's clothes.
  def exactness(work)
    cutoff = 75
    checked = 0
    work.each do |query|
      query[:candidates].each do |candidate|
        checked += 1
        compare(query[:subject], candidate, cutoff)
      end
    end
    puts "\nA threshold of #{cutoff} changed no score, over #{checked} candidates"
  end

  def compare(subject, candidate, cutoff)
    full = ActiveSanction::Scorer.call(subject, candidate)
    cut = ActiveSanction::Scorer.call(subject, candidate, threshold: cutoff)
    return if cut.nil? ? full.nil? || full.score < cutoff : cut == full

    abort "  THRESHOLD CHANGED A SCORE: #{candidate.entity.id} #{full.inspect} vs #{cut.inspect}"
  end
end

ScorerBenchmark.run
