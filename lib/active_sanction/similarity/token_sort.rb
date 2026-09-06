# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  module Similarity
    # Token sort ratio: put both names' tokens in alphabetical order, then
    # compare what comes out. 0..1.
    #
    #   ActiveSanction::Similarity::TokenSort.call("abbas abu", "abu abbas")    # => 1.0
    #   ActiveSanction::Similarity::TokenSort.call("smith john", "john smith")  # => 1.0
    #   ActiveSanction::Similarity::TokenSort.call("abbas abu", "abbas abd")    # => 0.8889
    #
    # ### The shape it exists for
    #
    # Sanctions lists store a personal name inverted and a query almost never
    # is. OFAC publishes `ABBAS, Abu` and `ZAYDAN, Muhammad`; a customer
    # record says `Abu Abbas` and a payment message says `Muhammad Zaydan`.
    # The comma does not survive to be read here -- Normalizer turns
    # punctuation into a space, so both sides arrive as the same tokens in
    # opposite orders -- and character-level comparison is helpless in front of
    # that:
    #
    #   JaroWinkler.call("abbas abu", "abu abbas")   # => 0.8053
    #   Levenshtein.call("abbas abu", "abu abbas")   # => 0.3333
    #   TokenSort.call("abbas abu", "abu abbas")     # => 1.0
    #
    # Those are two names that are not merely similar but identical, scored as
    # a miss at the 85 this industry screens on. Sorting is what makes word
    # order stop mattering, and word order is the difference between how these
    # lists are written and how anybody types.
    #
    # It is worth being plain that this is not clever. Sorting is a blunt
    # instrument that answers one question exactly -- are these the same words
    # in some order -- and the reason it is the right instrument is that the
    # inversion it defeats is a publishing convention rather than a
    # coincidence, applied to essentially every individual on every list.
    #
    # ### What it costs, and why Levenshtein is still here
    #
    # Sorting destroys the information that two names were *already* in the
    # same order, which for a pair that shares its leading tokens is
    # information worth having:
    #
    #   Levenshtein.call("kim jong un", "kim yong chol")  # => 0.6154
    #   TokenSort.call("kim jong un", "kim yong chol")    # => 0.4615
    #
    # `jong` and `yong` line up as written and are pulled apart by the sort,
    # which puts `jong` next to `chol` and `un` next to `yong`. So this ratio
    # is an additional question rather than a better one, and the scorer (#32)
    # is where the two answers meet. A pipeline that sorted first and compared
    # once would be strictly worse than one that does neither.
    #
    # ### Why Levenshtein underneath and not Jaro-Winkler
    #
    # Winkler's premise is that people get the beginning of a name right and
    # drift later, which is true of a name as it is written and false of one
    # whose words have just been put in alphabetical order: the front of a
    # sorted string is whichever token happened to sort first, so the prefix
    # bonus would be paying for a property of the alphabet. Sorted `abbas abd`
    # and `abbas abu` share six characters of prefix for no reason anybody
    # typed.
    #
    # Levenshtein also charges honestly for a token the other side does not
    # have, which after sorting is most of what is left to measure. Being
    # generous about that is the other ratio's job, and two generous
    # algorithms stacked on each other is how a token ratio starts saying yes
    # to everything.
    #
    # ### What it does not handle, which is why TokenSet exists
    #
    # A token on one side and not the other. Sorting lines the shared words up
    # but does nothing about the ones with nowhere to go, and the edit
    # distance charges for every character of them:
    #
    #   TokenSort.call("putin vladimir vladimirovich", "vladimir putin")  # => 0.5
    #
    # Half the name is a patronymic the query did not carry, and half is what
    # this scores. That is the whole of TokenSet's job.
    module TokenSort
      extend T::Sig

      module_function

      # The similarity of two already-folded names -- see Similarity for what
      # `threshold:` does and what it promises, and for why either side may be
      # a string or the tokens it splits into.
      sig { params(left: Value, right: Value, threshold: Numeric).returns(Float).checked(:tests) }
      def call(left, right, threshold: 0.0)
        cutoff = Similarity.threshold!(threshold)

        Levenshtein.call(sorted(left), sorted(right), threshold: cutoff)
      end

      # The string this actually compares: the name's tokens in alphabetical
      # order, single-spaced.
      #
      # Public because a score nobody can account for is a score nobody can
      # defend, and `sorted` is the whole of the difference between what a
      # caller passed and what was compared. An analyst asking why `kim jong
      # un` scored what it did against `kim yong chol` gets the answer by
      # printing this.
      sig { params(value: Value).returns(String).checked(:tests) }
      def sorted(value) = Similarity.tokens(value).sort.join(" ")

      # Levenshtein's ceiling, on the lengths of the two folded names, because
      # sorting a folded name's tokens does not change its length -- the same
      # characters and the same single spaces come out in a different order.
      # That equality is the one thing this delegation rests on, and it is the
      # reason the contract says *folded* names: a string carrying double
      # spaces or a leading one is shorter after the sort than the length it
      # reports, and a ceiling computed from the longer length would come in
      # under the real score, which is the one direction a bound may never
      # err in.
      sig { params(left_length: Integer, right_length: Integer).returns(Float).checked(:tests) }
      def ceiling(left_length, right_length) = Levenshtein.ceiling(left_length, right_length)
    end
  end
end
