# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  module Similarity
    # Token set ratio: compare what two names share against what each of them
    # is, and take the best of it. 0..1.
    #
    #   TokenSet.call("putin vladimir vladimirovich", "vladimir putin")  # => 1.0
    #   TokenSet.call("vladimir putin", "vladimir zhirinovsky")          # => 0.5714
    #   TokenSet.call("gazprom neft", "gazprombank")                     # => 0.5833
    #
    # ### The shape it exists for
    #
    # A token one side has and the other does not, which is the ordinary
    # condition of a real query rather than an edge case. Lists carry the full
    # legal name and a query carries what somebody typed: a patronymic that
    # only Russian records bother with, a middle name a payment message
    # dropped, a `bin` chain written out in full on one side and abbreviated on
    # the other. Sorting does nothing for any of it -- TokenSort scores
    # `PUTIN, Vladimir Vladimirovich` against `Vladimir Putin` at 0.5, because
    # half the characters on the longer side have no partner and the edit
    # distance charges for every one of them.
    #
    # ### The three strings
    #
    # Take both names as sets of tokens and split them three ways -- what they
    # share, what only the left has, what only the right has -- then build:
    #
    #   t0  the shared tokens, alphabetically
    #   t1  t0, then the left's own tokens, alphabetically
    #   t2  t0, then the right's own tokens, alphabetically
    #
    # and score the pair as the best of `t0/t1`, `t0/t2` and `t1/t2`. For
    # `putin vladimir vladimirovich` against `vladimir putin` that is:
    #
    #   t0 = "putin vladimir"
    #   t1 = "putin vladimir vladimirovich"
    #   t2 = "putin vladimir"
    #
    # `t0/t2` is a perfect match, and the answer is 1.0. Every one of the three
    # comparisons runs on Levenshtein, for the reason TokenSort gives.
    #
    # The construction is Seatgeek's, from `fuzzywuzzy`'s `token_set_ratio`,
    # and it is kept as published rather than adjusted. A screening score that
    # nobody outside this repository can reproduce is a score that has to be
    # argued from scratch every time an examiner asks about it.
    #
    # ### What that tolerance costs, and who pays it
    #
    # A name whose tokens are all present in the other scores 1.0, however
    # much else the other one says:
    #
    #   TokenSet.call("gazprom", "gazprom neft")  # => 1.0
    #
    # Those are two different companies, and this ratio cannot tell them
    # apart -- `t0/t2` is a string against itself whenever one side's tokens
    # are a subset of the other's, and no length difference is large enough to
    # change that. The same generosity finds `Vladimir Putin` inside `PUTIN,
    # Vladimir Vladimirovich`, so it is not a bug to be fixed here; it is the
    # single property this algorithm has, and it points in both directions.
    #
    # Recorded rather than lamented, and recorded in the specs as well: what
    # keeps it from deciding a hit is that the scorer (#32) blends four
    # numbers, and the other three all charge for the extra word. Levenshtein
    # scores that pair 0.583 and TokenSort 0.583. A scorer that let this
    # column vote alone would put every subsidiary of every listed parent in
    # front of an analyst at 100.
    #
    # ### Sets, so a repeated token is one token
    #
    # `ALI, Ali Hassan` is `ali ali hassan` folded, and the second `ali` is not
    # a second piece of evidence. Deduplicating is what the name of the
    # algorithm says and what these lists want: a repeated given name is a
    # naming convention, not a stronger signal, and counting it twice would
    # make an entity's score depend on how many times its own name repeats.
    module TokenSet
      extend T::Sig

      module_function

      # The similarity of two already-folded names -- see Similarity for what
      # `threshold:` does and what it promises, and for why either side may be
      # a string or the tokens it splits into.
      #
      # The threshold is passed down to all three comparisons rather than
      # applied to their maximum, which keeps the promise exactly: the largest
      # of three numbers is at or above the cutoff precisely when one of them
      # is, and that one comes back exact.
      sig { params(left: Value, right: Value, threshold: Numeric).returns(Float).checked(:tests) }
      def call(left, right, threshold: 0.0)
        cutoff = Similarity.threshold!(threshold)
        left_tokens = Similarity.tokens(left)
        right_tokens = Similarity.tokens(right)
        # A name with no tokens cannot be scored, and the three strings would
        # all be empty and compare as identical if this fell through. Both
        # empty is the answer the other algorithms give for two empty strings.
        return 1.0 if left_tokens.empty? && right_tokens.empty?
        return 0.0 if left_tokens.empty? || right_tokens.empty?

        shared, left_full, right_full = strings(left_tokens, right_tokens)
        best(shared, left_full, right_full, cutoff)
      end

      # The three strings this actually compares, in the order `t0, t1, t2`.
      #
      # Public for the reason TokenSort.sorted is: this is the whole of the
      # difference between what a caller passed and what was scored, and a hit
      # a compliance user cannot account for is a hit they cannot clear.
      #
      # Where the sets are made: `&` and `-` both deduplicate what they keep,
      # apart from the repeats inside a name's own tokens, which `uniq`
      # removes.
      sig { params(left: T::Array[String], right: T::Array[String]).returns([String, String, String]).checked(:tests) }
      def strings(left, right)
        shared = (left & right).sort
        [shared.join(" "),
         (shared + (left - right).uniq.sort).join(" "),
         (shared + (right - left).uniq.sort).join(" ")]
      end

      # 1.0 for any two non-empty names, which is not much of a bound and is
      # the true one.
      #
      # The other three algorithms can rule a perfect score out from a length
      # difference alone, because a character one name has and the other does
      # not costs something wherever it falls. This one cannot: a subset scores
      # 1.0 at any length, which is the whole of what it is for. A tighter
      # number here would be a wrong one, and wrong in the direction that
      # silently discards true matches -- a caller cannot tell a pair rejected
      # by a ceiling from one that scored badly.
      #
      # So `threshold:` buys this ratio nothing before the comparison and only
      # what the three Levenshtein calls can find inside it. That is a real
      # cost, paid where the tolerance is, and it is the reason the scorer
      # runs the cheap columns first.
      sig { params(left_length: Integer, right_length: Integer).returns(Float).checked(:tests) }
      def ceiling(left_length, right_length)
        return left_length == right_length ? 1.0 : 0.0 if left_length.zero? || right_length.zero?

        1.0
      end

      # The best of the three, each computed against the caller's cutoff.
      sig do
        params(shared: String, left_full: String, right_full: String, cutoff: Float).returns(Float).checked(:tests)
      end
      def best(shared, left_full, right_full, cutoff)
        [Levenshtein.call(shared, left_full, threshold: cutoff),
         Levenshtein.call(shared, right_full, threshold: cutoff),
         Levenshtein.call(left_full, right_full, threshold: cutoff)].max
      end

      private_class_method :best
    end
  end
end
