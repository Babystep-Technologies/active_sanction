# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  # How close two folded names are, as a number between 0 and 1. Stage 3 of
  # the matching pipeline.
  #
  #   left  = ActiveSanction::Normalizer.call("ABBAS, Abu")
  #   right = ActiveSanction::Normalizer.call("Abu Abbas")
  #
  #   ActiveSanction::Similarity::JaroWinkler.call(left.value, right.value)  # => 0.8053
  #   ActiveSanction::Similarity::Levenshtein.call(left.value, right.value)  # => 0.3333
  #   ActiveSanction::Similarity::TokenSort.call(left.tokens, right.tokens)  # => 1.0
  #   ActiveSanction::Similarity::TokenSet.call(left.tokens, right.tokens)   # => 1.0
  #
  # Four algorithms and nothing else. Two compare characters -- JaroWinkler
  # and Levenshtein, stage 3a -- and two compare tokens -- TokenSort and
  # TokenSet, stage 3b. The token ratios are rearrangements of the same two
  # names with Levenshtein run over the result, so there is still exactly one
  # place in this library that knows how to walk two strings. The scorer (#32)
  # blends all four, and nothing in the library has any other way to ask how
  # close two names are.
  #
  # ### Why four
  #
  # Each of them is generous about something, and their disagreements are the
  # point:
  #
  #                                        JW     Lev    Sort    Set
  #     abbas abu / abu abbas            0.805  0.333   1.000  1.000
  #     putin vladimir vladimirovich /
  #       vladimir putin                 0.679  0.357   0.500  1.000
  #     gazprom / gazprom neft           0.917  0.583   0.583  1.000
  #     kim jong un / kim yong chol      0.869  0.615   0.462  0.462
  #
  # Row one is an inverted name, which is the single most common query shape
  # against these lists, which character comparison misses and sorting makes
  # trivial. Row two adds a patronymic on one side, which sorting cannot
  # absorb either and the set ratio is built for. Row three is two different
  # companies, and the 1.000 is what that tolerance costs. Row four is a pair
  # already written in the same order, where sorting *loses* the information
  # that they are, and the character algorithms are the honest ones.
  #
  # No single column is the score. #32 blends them, and rows three and four
  # are why it has to.
  #
  # Stage 3c is next door, in Phonetics, and not in here: Double Metaphone
  # answers what a name *sounds* like with a key rather than a number, and a
  # key cannot be blended with four scores or held to the contract below.
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
  # 20 us per pair and Levenshtein about 60. The token ratios cost what they
  # are: the sort ratio is one Levenshtein call on a rearranged string and
  # prices like one, and the set ratio is three and costs about 110. The whole
  # of a 500-candidate query, all four on every name, is about 25 ms with a
  # threshold passed and six times that without one; YJIT takes a factor of
  # two and a half off both and puts a thresholded query near 10 ms. That is
  # the budget a screening call has, and it is the reason a threshold is worth
  # passing -- the exits below are most of the difference between those two
  # numbers.
  #
  # ### The contract all four keep
  #
  # **Folded names in.** Nothing here normalizes anything -- see Normalizer
  # for why the fold happens once, at one entry point, for both sides of a
  # comparison. A caller passes `form.value`, or `form.tokens` to either of
  # the token ratios; passing raw publisher text instead scores the case and
  # the punctuation rather than the name.
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
  # algorithm is that bound, exposed so it can be held to that promise. How
  # much it is worth differs: Levenshtein's is tight, Jaro-Winkler's is loose
  # because the prefix bonus can add 0.4 to anything, and TokenSet has none at
  # all, because a name that is a subset of another scores 1.0 at any length.
  module Similarity
    extend T::Sig
    extend T::Helpers

    # Called as `Similarity.threshold!`, which is where `raise` comes from.
    requires_ancestor { Kernel }

    # A folded name, as either the string or the tokens it splits into. The
    # token ratios take either on either side, because their two callers hold
    # different things: a Form already carries `tokens` and should not pay for
    # a split per comparison, while a spec, a console and the benchmark are
    # written in strings.
    Value = T.type_alias { T.any(String, T::Array[String]) }

    module_function

    # A threshold as a Float, or an InvalidArgument.
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

      raise InvalidArgument,
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

    # The form both token ratios work in: an Array of tokens.
    #
    # `String#split` with no argument, which is all the splitting a folded
    # value needs: Normalizer's stage 4 turned every punctuation mark into a
    # space and stage 5 collapsed the runs, so whitespace is the only boundary
    # left in the string and there are no empty tokens at either end.
    #
    # An Array is taken as it stands. That is the path that matters -- the
    # index (#31) hands the scorer a few hundred candidates, each carrying
    # several names, and every one of those names has already been split once
    # by the Form it lives in.
    #
    # Scrubbed first when it has to be, for the reason `codepoints` scrubs and
    # Form repairs: `String#split` raises on a byte sequence that is not valid
    # UTF-8, and one stray byte in a government file must not take an index
    # build down with it.
    sig { params(value: Value).returns(T::Array[String]).checked(:tests) }
    def tokens(value)
      return value unless value.is_a?(String)

      (value.valid_encoding? ? value : value.scrub).split
    end
  end
end

require "active_sanction/similarity/jaro_winkler"
require "active_sanction/similarity/levenshtein"
require "active_sanction/similarity/token_sort"
require "active_sanction/similarity/token_set"
