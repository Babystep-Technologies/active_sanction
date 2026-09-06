# frozen_string_literal: true

# What the edit-distance primitives (#28) cost, and what the early exits save.
#
#     bundle exec rake benchmark:similarity
#
# The number that matters is the last section's: the index (#31) hands the
# scorer a few hundred candidates, the scorer runs both algorithms over every
# name each candidate has, and the whole query is meant to fit in ~10 ms. This
# says how much of that budget the primitives take, which is the question that
# decided against a C extension -- see Similarity for the rest of that
# argument.
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
    report("jaro_winkler", time { PAIRS.each { |left, right| JW.call(left, right) } }, PAIRS.size)
    report("levenshtein", time { PAIRS.each { |left, right| LEV.call(left, right) } }, PAIRS.size)
  end

  # The shape #31 hands over: one query, a few hundred candidates, both
  # algorithms on each. The scorer adds the token ratios (#29) and a phonetic
  # comparison (#30) on top of this.
  def per_query
    candidates = (NAMES * 13).first(500)
    query = "muhammad al zawahiri"
    puts "\nOne query against #{candidates.size} candidates"
    [0.0, 0.85].each do |cutoff|
      seconds = time do
        candidates.each do |name|
          JW.call(query, name, threshold: cutoff)
          LEV.call(query, name, threshold: cutoff)
        end
      end
      printf("  %<label>-44s %<ms>25.2f ms/query\n",
             label: "both algorithms, threshold #{cutoff}", ms: seconds * 1000)
    end
  end

  # The acceptance criterion: the early exit has to be visible, not merely
  # present. On mismatched lengths Levenshtein's bound is tight enough to skip
  # the matrix outright; Jaro-Winkler's is loosened by the prefix bonus, which
  # is a bound on what the algorithm can produce rather than a tuning choice.
  def early_exit
    puts "\nThe early exit, over #{MISMATCHED.size} length-mismatched pairs"
    [["jaro_winkler", JW], ["levenshtein", LEV]].each do |name, algorithm|
      full = time { MISMATCHED.each { |left, right| algorithm.call(left, right) } }
      capped = time { MISMATCHED.each { |left, right| algorithm.call(left, right, threshold: 0.85) } }
      report("#{name}, no threshold", full, MISMATCHED.size)
      report("#{name}, threshold 0.85 (#{(full / capped).round(1)}x)", capped, MISMATCHED.size)
    end
  end
end

SimilarityBenchmark.run
