# frozen_string_literal: true

# What the similarity algorithms (#28, #29) cost, and what the early exits
# save.
#
#     bundle exec rake benchmark:similarity
#
# The number that matters is the per-query section's: the index (#31) hands
# the scorer a few hundred candidates, the scorer runs all four algorithms
# over every name each candidate has, and the whole query is meant to fit in
# ~10 ms. This says how much of that budget the comparison takes, which is the
# question that decided against a C extension -- see Similarity for the rest
# of that argument.
#
# The token ratios are rearrangements with Levenshtein run over the result, so
# what they cost is one Levenshtein call for the sort ratio and three for the
# set ratio, plus the sorting and the set arithmetic. What is worth watching
# is the last section: a threshold buys the set ratio almost nothing, because
# a name that is a subset of another scores 1.0 at any length and no bound can
# rule that out in advance.
#
# Timings are the best of three passes rather than an average: the fastest run
# is the one least disturbed by whatever else the machine was doing. The JIT
# is worth a factor of three here and is off by default, so the header says
# which answer you are reading:
#
#     RUBYOPT=--yjit bundle exec rake benchmark:similarity

require_relative "../lib/active_sanction"

module SimilarityBenchmark
  JW = ActiveSanction::Similarity::JaroWinkler
  LEV = ActiveSanction::Similarity::Levenshtein
  SORT = ActiveSanction::Similarity::TokenSort
  SET = ActiveSanction::Similarity::TokenSet

  # The four the scorer (#32) blends, in the order they cost.
  ALGORITHMS = [["jaro_winkler", JW], ["levenshtein", LEV],
                ["token_sort", SORT], ["token_set", SET]].freeze

  # Folded names, in the form Normalizer leaves them, and in the proportions
  # these lists actually publish: mostly people, a good number of companies
  # carrying legal forms, a few vessels, and the long compound organization
  # names that decide how much work a comparison is.
  NAMES = [
    "abbas abu", "abu abbas", "abd al rahman muhammad zafir al dubaysi",
    "muhammad al zawahiri", "mohammed al zawahri", "mohamad zawahri",
    "ayman muhammad rabi al zawahiri", "usama bin muhammad bin awad bin ladin",
    "putin vladimir vladimirovich", "vladimir putin", "sergei viktorovich lavrov",
    "qaddafi muammar", "gaddafi moammar", "saif al islam qadhafi",
    "kim jong un", "kim yong chol", "choe song chol",
    "smith john", "john smith", "jon smyth", "maria garcia lopez",
    "hassan nasrallah", "hasan nasralla", "ali akbar tabatabaei",
    "gazprom", "gazprombank", "gazprom neft", "public joint stock company gazprom",
    "rosneft", "rosneft oil company", "aero caribbean", "aerocaribbean airlines",
    "bank melli iran", "bank of kunlun co ltd", "china telecom corporation limited",
    "islamic republic of iran shipping lines", "national iranian tanker company",
    "artavia", "ep iba", "munoz hermanos sa"
  ].freeze

  # The pairs a scorer actually sees: one query name against every candidate
  # the index kept. Names are compared against names of every length, which is
  # why the corpus above spans 7 characters to 38.
  PAIRS = NAMES.product(NAMES).freeze

  # A short personal name against long organization names -- a person's query
  # reaching the vessel and company half of the list. This is the shape the
  # length-difference exit is for.
  MISMATCHED = NAMES.select { |name| name.length < 12 }
                    .product(NAMES.select { |name| name.length > 28 })
                    .freeze

  module_function

  def run
    jit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "yjit" : "no jit"
    puts "ruby #{RUBY_VERSION} (#{RUBY_PLATFORM}, #{jit}) -- active_sanction #{ActiveSanction::VERSION}"
    per_comparison
    per_query
    early_exit
  end

  # Best of three, in seconds.
  def time(&block)
    3.times.map do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      block.call
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end.min
  end

  def report(label, seconds, comparisons)
    printf("  %<label>-44s %<each>7.2f us/pair %<rate>11s pairs/s\n",
           label: label, each: seconds / comparisons * 1_000_000,
           rate: (comparisons / seconds).round.to_s.reverse.scan(/\d{1,3}/).join(",").reverse)
  end

  def per_comparison
    puts "\nOne comparison, over #{PAIRS.size} name pairs"
    ALGORITHMS.each do |name, algorithm|
      report(name, time { PAIRS.each { |left, right| algorithm.call(left, right) } }, PAIRS.size)
    end
  end

  # The shape #31 hands over: one query, a few hundred candidates, all four
  # algorithms on each. The scorer adds a phonetic comparison (#30) on top of
  # this.
  #
  # The token ratios are handed tokens rather than strings, which is what a
  # Form carries and what the index will be passing: splitting 500 candidate
  # names again per query is work the fold already did.
  def per_query
    candidates = (NAMES * 13).first(500)
    query = "muhammad al zawahiri"
    tokens = candidates.map(&:split)
    query_tokens = query.split
    puts "\nOne query against #{candidates.size} candidates"
    [0.0, 0.85].each do |cutoff|
      seconds = time { query(query, query_tokens, candidates, tokens, cutoff) }
      printf("  %<label>-44s %<ms>25.2f ms/query\n",
             label: "all four algorithms, threshold #{cutoff}", ms: seconds * 1000)
    end
  end

  def query(query, query_tokens, candidates, tokens, cutoff)
    candidates.each_with_index do |name, index|
      JW.call(query, name, threshold: cutoff)
      LEV.call(query, name, threshold: cutoff)
      SORT.call(query_tokens, tokens.fetch(index), threshold: cutoff)
      SET.call(query_tokens, tokens.fetch(index), threshold: cutoff)
    end
  end

  # The acceptance criterion: the early exit has to be visible, not merely
  # present. On mismatched lengths Levenshtein's bound is tight enough to skip
  # the matrix outright, and the token sort ratio inherits that bound exactly;
  # Jaro-Winkler's is loosened by the prefix bonus, and the token set ratio
  # has none at all. All four are bounds on what the algorithm can produce
  # rather than tuning choices, which is why the last of them is 1.0 and says
  # so.
  def early_exit
    puts "\nThe early exit, over #{MISMATCHED.size} length-mismatched pairs"
    ALGORITHMS.each do |name, algorithm|
      full = time { MISMATCHED.each { |left, right| algorithm.call(left, right) } }
      capped = time { MISMATCHED.each { |left, right| algorithm.call(left, right, threshold: 0.85) } }
      report("#{name}, no threshold", full, MISMATCHED.size)
      report("#{name}, threshold 0.85 (#{(full / capped).round(1)}x)", capped, MISMATCHED.size)
    end
  end
end

SimilarityBenchmark.run
