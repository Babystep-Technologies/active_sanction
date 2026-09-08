# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/phonetics"
require "active_sanction/similarity"

module ActiveSanction
  module Scorer
    # How close two folded names are, on the 0..100 scale a screening decision
    # is made on.
    #
    #   left  = ActiveSanction::Normalizer.call("ABBAS, Abu")
    #   right = ActiveSanction::Normalizer.call("Abu Abbas")
    #
    #   ActiveSanction::Scorer::NameScore.call(left, right)   # => 90.4
    #   ActiveSanction::Scorer::NameScore.ratios(left, right)
    #   # => { jaro_winkler: 0.805, levenshtein: 0.333, token_sort: 1.0,
    #   #      token_set: 1.0, phonetic: 1.0 }
    #
    # Stage 4a. Everything in Similarity answers one question about a pair of
    # names and answers it well; this is the one place in the library that
    # decides what those four answers are worth together, and Weights is why
    # each is worth what it is.
    #
    # ### The blend is a weighted mean, and that is a choice
    #
    # The obvious alternative is a weighted maximum -- take the best evidence
    # any of the four found, discounted by how tolerant that comparison is --
    # which is what the well-known Python ratio does. It is rejected here for
    # one reason: `token_set` returns 1.0 whenever one name's words are a
    # subset of the other's, so a maximum would score the query `Mohammed`
    # against `MOHAMMED AL-ZAWAHIRI` in the nineties. On a corpus where a
    # quarter of the individuals share a handful of given names, that is not a
    # tolerance, it is an alert queue nobody can work through.
    #
    # A mean makes the four disagree in public instead. The same pair comes
    # out in the high seventies -- still high, because the caller's whole query
    # really is on the record, and that is the honest answer -- and what pulls
    # it apart from a real match is not the name at all. It is the date of
    # birth and the passport number, which is exactly the argument the issue
    # this implements makes: name alone produces enormous false-positive
    # volume on common names, and identifiers are the corrective.
    #
    # ### The phonetic share
    #
    # Double Metaphone answers with a key rather than a number, so it is
    # turned into one the only way that respects what a key means: the
    # fraction of the shorter name's tokens that have a token on the other
    # side sounding like them. `QADHAFI, Muammar` against `Muammar Gaddafi` is
    # 1.0 -- both tokens have a partner -- and one token in three agreeing is
    # 0.33.
    #
    # Per token rather than over the whole name, because that is how the keys
    # are built (see Phonetics: a token handed over on its own is what the
    # index and this both key on) and because a name is rearranged as often as
    # it is respelled.
    #
    # ### What this stage cannot do, and what covers it
    #
    # One name transliterated two different ways scores poorly here, and
    # raising the phonetic share does not fix it. `QADHAFI, Muammar` against
    # `Muammar Gaddafi` comes out at 58.8: the token ratios see two words with
    # two letters different and one word matching, the character algorithms
    # see less than that, and the phonetic share is one of five. Pushing that
    # share to 0.15 moves the pair to 66.8 -- still under any threshold worth
    # setting, while lifting every common-name near-miss by the same few
    # points. It buys nothing and costs precision, so it is not done.
    #
    # What actually covers the case is upstream and is the reason this stage
    # is built the way it is. These lists publish the variants themselves:
    # OFAC's Qadhafi record carries `QADHAFI`, `QADAFI`, `GADAFI`, `KADAFI`
    # and half a dozen more as aliases, because a sanctions list whose
    # spelling had to be guessed would not work either. The index (#31) keys
    # on Double Metaphone so that a query for one spelling retrieves a record
    # filed under another, and the scorer takes the *maximum over an entity's
    # names* -- so the query meets the alias it is actually a spelling of and
    # is scored against that one instead. `Muammar Gaddafi` against the
    # `GADDAFI, Muammar` alias is 84.8, where the same query against the
    # `QADHAFI, Muammar` primary name is 58.8. See Scorer.
    #
    # The residue is a record that carries one spelling and one only, queried
    # with a different one. That is a real recall limitation, it is stated
    # rather than papered over, and the honest mitigation is the identifier
    # fields rather than a bigger number in Weights.
    #
    # ### Cost, and why `threshold:` is most of it
    #
    # This runs a few hundred times per screening call and is very nearly all
    # of what one costs -- the identifier adjustments, the fold and the
    # explanation together are under 2% of it. Unthresholded, the five shares
    # come to about 280 us per pair of names without a JIT and 120 with one,
    # which puts a 200-candidate query at roughly 105 ms and 46 ms. Neither of
    # those is a screening call.
    #
    # `threshold:` is what makes it one, and it keeps exactly the promise
    # Similarity's does: a score at or above the threshold is the same Float
    # the same call without one returns, and anything below is reported as 0.0
    # rather than computed. Two mechanisms, both exact:
    #
    # **The shares are measured one at a time and the sum is bounded as they
    # go.** Everything still unmeasured is worth at most its own weight, so
    # `total + remaining` is the highest this pair can still reach; when that
    # falls under the cutoff, the rest is not measured. On a candidate that
    # was never going to clear, that is usually two of the five.
    #
    # **What is measured is measured with a threshold of its own.** Given the
    # weights left to come, the least this share could be worth and still
    # leave the pair reachable is arithmetic, and it is handed down as the
    # algorithm's own `threshold:` -- where Levenshtein turns it into an edit
    # budget and stops its rows early, and Jaro-Winkler rejects on length
    # before looking at a character.
    #
    # Together, on a 200-candidate query against a full-size corpus:
    #
    #     threshold       no jit      yjit    results
    #             0     105.6 ms   46.3 ms      184.0
    #            50      85.6 ms   37.2 ms      118.2
    #            75      37.5 ms   16.3 ms       31.4
    #            85      24.0 ms   10.5 ms       10.6
    #
    # `rake benchmark:scorer` prints that sweep and is how to take it again on
    # another machine. The scores that come back are unchanged, which is what
    # the benchmark checks on every run and what the suite holds this to --
    # the exits are bounds on what a pair can reach, never approximations of
    # what it did reach.
    #
    # The threshold is therefore not an optional refinement for the caller in
    # front of this. A matcher that screens without one spends three times the
    # budget computing exact scores for candidates it is about to discard.
    #
    # Two smaller things keep the unthresholded path honest as well. Tokens
    # are handed to the token ratios as the arrays a Form already holds, so
    # nothing is split per comparison; and the phonetic pass skips any token
    # that appears on both sides verbatim, which on a real match is most of
    # them, so Double Metaphone runs on the tokens that actually differ.
    #
    module NameScore
      extend T::Sig
      extend T::Helpers

      # Called as `NameScore.measure`, which is where `raise` comes from.
      requires_ancestor { Kernel }

      # The scale a screening score is read and thresholded on. Similarity
      # works in 0..1 and never rounds; the conversion happens once, here.
      SCALE = T.let(100.0, Float)

      # The order the shares are measured in, which is the only reason this
      # differs from the order Weights lists them in. It is measured rather
      # than argued -- `rake benchmark:scorer` is what produced it -- and what
      # it optimizes is not cost per share but how quickly the bound tightens
      # for what each share costs.
      #
      # **Jaro-Winkler first**, at about 18 us the cheapest of the five, and
      # it resolves 0.15 of the weight before anything expensive runs.
      #
      # **The token set ratio second**, though at about 80 us it is the
      # dearest of the four that can be thresholded: it carries 0.45 of the
      # weight on its own, which is most of what the bound needs, and it is
      # the measure that separates a candidate worth finishing from one that
      # is not. Running it early is what lets a poor candidate be abandoned
      # two measures in rather than four.
      #
      # **The phonetic pass last, always.** It is the smallest share at 0.05
      # and it is also, at about 85 us, the most expensive thing here -- the
      # one measure that cannot be given a threshold of its own, because
      # Double Metaphone answers with a key and has no early exit to offer.
      # Its cost is paid in full whenever it is paid at all, so last is where
      # it is paid least often: by then the bound is within 0.05 of settled,
      # and almost every candidate has already been decided.
      ORDER = T.let(%i[jaro_winkler token_set token_sort levenshtein phonetic].freeze, T::Array[Symbol])

      module_function

      # The blended similarity of two folded names, 0..100 and unrounded --
      # Reason rounds once, where the number becomes something a person reads.
      #
      # `threshold:` is on the same 0..100 scale as the answer, and it is an
      # optimization rather than a filter: a pair that cannot reach it comes
      # back 0.0 instead of being finished. See the note on cost above.
      sig do
        params(left: Normalizer::Form, right: Normalizer::Form, weights: Weights, threshold: Numeric)
          .returns(Float).checked(:tests)
      end
      def call(left, right, weights = Weights.default, threshold: 0.0)
        cutoff = (threshold.to_f / SCALE).clamp(0.0, 1.0)
        total = 0.0
        remaining = 1.0
        ORDER.each do |share|
          weight = weights.fetch(share)
          return 0.0 if total + remaining < cutoff

          remaining -= weight
          total += weight * measure(share, left, right, floor(cutoff, total, remaining, weight))
        end
        total < cutoff ? 0.0 : SCALE * total
      end

      # The least this share can be worth while leaving the pair able to reach
      # the cutoff, given everything already measured and everything still to
      # come at its best. Zero when the pair can reach the cutoff whatever
      # this share says, which is what a threshold of nothing always produces.
      sig do
        params(cutoff: Float, total: Float, remaining: Float, weight: Float).returns(Float).checked(:tests)
      end
      def floor(cutoff, total, remaining, weight)
        return 0.0 unless weight.positive?

        ((cutoff - total - remaining) / weight).clamp(0.0, 1.0)
      end

      # One share, with its own early exit. A share a host has weighted to
      # zero is not measured at all.
      sig do
        params(share: Symbol, left: Normalizer::Form, right: Normalizer::Form, threshold: Float)
          .returns(Float).checked(:tests)
      end
      def measure(share, left, right, threshold = 0.0)
        case share
        when :jaro_winkler then Similarity::JaroWinkler.call(left.value, right.value, threshold: threshold)
        when :levenshtein then Similarity::Levenshtein.call(left.value, right.value, threshold: threshold)
        when :token_sort then Similarity::TokenSort.call(left.tokens, right.tokens, threshold: threshold)
        when :token_set then Similarity::TokenSet.call(left.tokens, right.tokens, threshold: threshold)
        when :phonetic then phonetic(left.tokens, right.tokens)
        else raise InvalidArgument, "unknown name share #{share.inspect}"
        end
      end

      # What each of the five actually said, which is the whole of the
      # difference between a score and a number.
      #
      # Public for the reason `TokenSort.sorted` and `TokenSet.strings` are
      # public: a hit a compliance user cannot account for is a hit they
      # cannot clear, and an analyst asking why two names scored what they did
      # gets the answer by printing this beside the weights.
      sig do
        params(left: Normalizer::Form, right: Normalizer::Form).returns(T::Hash[Symbol, Float]).checked(:tests)
      end
      def ratios(left, right)
        Weights::NAME_SHARES.to_h { |share| [share, measure(share, left, right)] }
      end

      # The fraction of the shorter name's tokens that sound like a token of
      # the longer one.
      #
      # The shorter side is the denominator on purpose: a query of two tokens
      # against a record of four should not be capped at 0.5 for the two the
      # record has and the query does not. That is what `token_set` is already
      # measuring, in a share of its own.
      sig { params(left: T::Array[String], right: T::Array[String]).returns(Float).checked(:tests) }
      def phonetic(left, right)
        return 0.0 if left.empty? || right.empty?

        shorter, longer = left.size <= right.size ? [left, right] : [right, left]
        keys = T.let(nil, T.nilable(T::Array[String]))
        agreed = shorter.count do |token|
          # Identical tokens sound identical, and skipping them is what keeps
          # the phonetic pass off the hot path of a real match.
          next true if longer.include?(token)

          keys ||= sounds(longer)
          Phonetics::DoubleMetaphone.call(token).intersect?(keys)
        end
        agreed.fdiv(shorter.size)
      end

      # Every Double Metaphone key of every token, primary and alternate --
      # see Phonetics for why the alternate is not optional. Flattened across
      # the tokens because the question here is whether *any* token of the
      # longer name sounds like the one being tested.
      sig { params(tokens: T::Array[String]).returns(T::Array[String]).checked(:tests) }
      def sounds(tokens) = tokens.flat_map { |token| Phonetics::DoubleMetaphone.call(token) }
    end
  end
end
