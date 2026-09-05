# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  # How close two folded names are, as a number between 0 and 1. Stage 3a of
  # the matching pipeline.
  #
  #   left  = ActiveSanction::Normalizer.call("Muhammad Al-Zawahiri")
  #   right = ActiveSanction::Normalizer.call("Mohammed al Zawahri")
  #
  #   ActiveSanction::Similarity::JaroWinkler.call(left.value, right.value)
  #   # => 0.8264...
  #   ActiveSanction::Similarity::Levenshtein.call(left.value, right.value)
  #   # => 0.85
  #
  # Two character-level algorithms and nothing else. The token ratios (#29)
  # are built out of these, the scorer (#32) blends them, and neither has any
  # other way to ask how close two strings are.
  #
  # ### Why pure Ruby
  #
  # `fuzzy_string_match` and the other C extensions are faster per call, and
  # they would put a native build in the path of every application that
  # installs this gem and in every container image the future service is
  # deployed from. That is a poor trade at the volume involved: the corpus is
  # roughly 46,000 name strings, and the inverted index (#31) narrows a query
  # to a few hundred candidates before any of this runs.
  #
  # `rake benchmark:similarity` is what that costs, and the numbers are the
  # argument. On name-length strings without a JIT, Jaro-Winkler runs about
  # 17 us per pair and Levenshtein about 60; the whole of a 500-candidate
  # query, both algorithms on every candidate, is about 12 ms with a threshold
  # passed and three times that without one. YJIT takes another factor of
  # three off. That is inside the budget a screening call has, and it is the
  # reason a threshold is worth passing -- the exits below are most of the
  # difference between those two numbers.
  #
  # ### The contract both algorithms keep
  #
  # **Folded strings in.** Nothing here normalizes anything -- see Normalizer
  # for why the fold happens once, at one entry point, for both sides of a
  # comparison. A caller passes `form.value`; passing raw publisher text
  # instead scores the case and the punctuation rather than the name.
  #
  # **A similarity out, not a distance.** 1.0 is identical, 0.0 is nothing in
  # common, and the number is a Float that is never rounded here. The scorer
  # works in 0..100 and does its own rounding; rounding twice is how a
  # threshold comparison starts disagreeing with the number printed beside it.
  #
  # **`threshold:` is an optimization, not a filter.** Passing one lets the
  # algorithm stop as soon as the score provably cannot reach it, and any
  # score below it is reported as 0.0 rather than computed exactly:
  #
  #   Similarity::Levenshtein.call("gazprom", "gazprom neft")   # => 0.5833...
  #   Similarity::Levenshtein.call("gazprom", "gazprom neft", threshold: 0.8)
  #   # => 0.0
  #
  # A score at or above the threshold is exactly the score the same call
  # without a threshold returns -- the early exits are bounds on what a pair
  # can reach, never approximations of what it did reach. `ceiling` on each
  # algorithm is that bound, exposed so it can be held to that promise.
  module Similarity
    extend T::Sig
    extend T::Helpers

    # Called as `Similarity.threshold!`, which is where `raise` comes from.
    requires_ancestor { Kernel }

    module_function

    # A threshold as a Float, or an ArgumentError.
    #
    # The 0..1 range is checked rather than assumed because the surrounding
    # library speaks in 0..100 -- the scorer's weights, its thresholds and
    # everything a compliance user reads are percentages -- and a `85` that
    # arrives here unchecked does not fail. It silently rejects every pair,
    # which reads as "nothing matched" and is the one failure this domain
    # cannot afford.
    sig { params(threshold: Numeric).returns(Float).checked(:tests) }
    def threshold!(threshold)
      cutoff = threshold.to_f
      return cutoff if cutoff.between?(0.0, 1.0)

      raise ArgumentError,
            "threshold must be between 0.0 and 1.0, got #{threshold.inspect} -- " \
            "these are similarities on a 0..1 scale, not percentages"
    end

    # The form both algorithms work in: an Array of codepoints.
    #
    # Codepoints rather than characters because comparing Integers is cheaper
    # than comparing one-character Strings, and both algorithms compare in
    # their innermost loop. Codepoints rather than bytes because a byte is not
    # a character outside ASCII, and half of these names are not ASCII: `ж` is
    # two bytes, and a byte-wise edit distance would charge two edits for
    # changing one letter and score Cyrillic pairs against a different scale
    # than Latin ones.
    #
    # A string that is not valid UTF-8 is scrubbed rather than raising, for
    # the reason Form repairs one: a single stray byte in a government file
    # must not take a whole index build down with it. Normalizer has already
    # done this to anything that came through it.
    sig { params(string: String).returns(T::Array[Integer]).checked(:tests) }
    def codepoints(string) = string.valid_encoding? ? string.codepoints : string.scrub.codepoints
  end
end

require "active_sanction/similarity/jaro_winkler"
require "active_sanction/similarity/levenshtein"
