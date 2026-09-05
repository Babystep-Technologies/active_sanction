# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  module Similarity
    # Jaro-Winkler similarity, 0..1.
    #
    #   ActiveSanction::Similarity::JaroWinkler.call("martha", "marhta")  # => 0.9611
    #   ActiveSanction::Similarity::JaroWinkler.call("dixon", "dicksonx") # => 0.8133
    #
    # ### Why this one
    #
    # Jaro counts the characters two strings share within a window that widens
    # with their length, and charges half an edit for each pair that matched
    # out of order. That is a good model of how names are actually
    # mistyped -- `MARHTA` for `MARTHA` is one transposition and two
    # substitutions to Levenshtein, which scores it 0.667 against Jaro's 0.944.
    #
    # Winkler's addition is a bonus for a shared prefix, on the observation
    # that people get the beginning of a name right and drift later. Names are
    # the case that observation was drawn from and the case it holds best for:
    # a transliterator's choice of vowel, a clerk's spelling of a suffix, and
    # a truncated field all differ at the end.
    #
    # The prefix bonus is also the reason this is not the only scorer in the
    # pipeline. It rewards `SMITH` against `SMITHSON`, and it has nothing at
    # all to say about `ABBAS, Abu` against `Abu Abbas`, which shares no
    # prefix and is the single most common query shape against these lists.
    # The token ratios (#29) are what answer that, on top of this.
    module JaroWinkler
      extend T::Sig

      # Winkler's constants, and they are his: 0.1 with a four-character cap
      # is what the 1990 paper used and what every published reference value
      # is computed against. `p * l` cannot exceed 0.4, which is what keeps
      # the bonus from pushing a score past 1.0.
      PREFIX_SCALE = T.let(0.1, Float)
      MAX_PREFIX = T.let(4, Integer)

      # The bonus applies only to pairs that already look alike, which is
      # Winkler's own rule and worth keeping for a reason this domain cares
      # about: without it, every name beginning `MOHAMMED` is pulled toward
      # every other one regardless of what follows, and a list where a quarter
      # of the entries share a given name is exactly where that shows up as
      # false positives.
      BOOST_THRESHOLD = T.let(0.7, Float)

      module_function

      # The similarity of two already-folded strings -- see Similarity for
      # what `threshold:` does and what it promises.
      sig { params(left: String, right: String, threshold: Numeric).returns(Float).checked(:tests) }
      def call(left, right, threshold: 0.0)
        cutoff = Similarity.threshold!(threshold)
        return 1.0 if left == right

        left_codes = Similarity.codepoints(left)
        right_codes = Similarity.codepoints(right)
        return 0.0 if ceiling(left_codes.size, right_codes.size) < cutoff

        score = winkler(left_codes, right_codes, jaro_score(left_codes, right_codes))
        score < cutoff ? 0.0 : score
      end

      # The highest score two strings of these lengths can reach, whatever
      # they contain. This is the early exit: a pair whose ceiling is under
      # the caller's threshold is rejected without either string being looked
      # at.
      #
      # At most `shorter` characters can match, so the two coverage terms are
      # bounded by 1 and `shorter / longer` and the transposition term by 1;
      # the prefix bonus on top can be no larger than a prefix of `shorter`
      # allows. The bound is loose -- a 0.85 threshold only rejects a pair
      # whose lengths differ by more than 4x, because the prefix bonus is
      # generous about it -- and loose is the only safe direction. A ceiling
      # that ever came in under a real score would drop true matches, so it is
      # derived rather than tuned, and the specs hold it to that against every
      # pair they can build.
      sig { params(left_length: Integer, right_length: Integer).returns(Float).checked(:tests) }
      def ceiling(left_length, right_length)
        shorter = [left_length, right_length].min
        longer = [left_length, right_length].max
        return shorter == longer ? 1.0 : 0.0 if shorter.zero?

        jaro = (2.0 + shorter.fdiv(longer)) / 3.0
        jaro + ([shorter, MAX_PREFIX].min * PREFIX_SCALE * (1.0 - jaro))
      end

      # Jaro on its own, without the prefix bonus. Public because it is the
      # published quantity -- a reference table gives both -- and because the
      # scorer may yet want the unboosted number for a pair whose shared
      # prefix is the part a caller has least confidence in.
      sig { params(left: String, right: String).returns(Float).checked(:tests) }
      def jaro(left, right)
        return 1.0 if left == right

        jaro_score(Similarity.codepoints(left), Similarity.codepoints(right))
      end

      # Codepoints in, for the reason Similarity.codepoints gives. `left` and
      # `right` mean the same two names here as they do above; only the
      # representation changes, and the signatures say which is which.
      sig { params(left: T::Array[Integer], right: T::Array[Integer]).returns(Float).checked(:tests) }
      def jaro_score(left, right)
        return 0.0 if left.empty? || right.empty?

        window = ([left.size, right.size].max / 2) - 1
        window = 0 if window.negative?
        left_matched, right_matched, matches = match(left, right, window)
        return 0.0 if matches.zero?

        halved = transpositions(left, right, left_matched, right_matched) / 2.0
        (matches.fdiv(left.size) + matches.fdiv(right.size) + ((matches - halved) / matches)) / 3.0
      end

      # Which characters of each string found a partner in the other, and how
      # many did.
      #
      # A character matches at most once, and only within `window` positions
      # of where it sits in the other string -- that window is what makes this
      # a similarity between two names rather than a bag-of-letters count, and
      # what keeps `ORWELL` from scoring highly against `LLEWRO`.
      sig do
        params(left: T::Array[Integer], right: T::Array[Integer], window: Integer)
          .returns([T::Array[T::Boolean], T::Array[T::Boolean], Integer])
          .checked(:tests)
      end
      def match(left, right, window)
        left_matched = Array.new(left.size, false)
        right_matched = Array.new(right.size, false)
        last = right.size - 1
        matches = 0
        left.each_with_index do |code, i|
          low = i > window ? i - window : 0
          j = partner(right, right_matched, code, low, [i + window, last].min)
          next if j.nil?

          left_matched[i] = true
          right_matched[j] = true
          matches += 1
        end
        [left_matched, right_matched, matches]
      end

      # The first position in `right[low..high]` holding `code` and not already
      # spoken for, or nil. Leftmost, which is what makes the pairing
      # deterministic: `call(x, y)` has to return the same number every time
      # it is asked, because a screening decision is re-derived during an
      # audit.
      sig do
        params(right: T::Array[Integer], matched: T::Array[T::Boolean], code: Integer, low: Integer, high: Integer)
          .returns(T.nilable(Integer))
          .checked(:tests)
      end
      def partner(right, matched, code, low, high)
        j = low
        while j <= high
          return j if !matched[j] && right.fetch(j) == code

          j += 1
        end
        nil
      end

      # Matched characters that came out in a different order on each side.
      # Walking both sides in step, every position where the two disagree is
      # half of a transposition, which is why the caller halves the count.
      sig do
        params(left: T::Array[Integer], right: T::Array[Integer],
               left_matched: T::Array[T::Boolean], right_matched: T::Array[T::Boolean])
          .returns(Integer)
          .checked(:tests)
      end
      def transpositions(left, right, left_matched, right_matched)
        count = 0
        k = 0
        left.each_with_index do |code, i|
          next unless left_matched[i]

          k += 1 until right_matched.fetch(k)
          count += 1 unless code == right.fetch(k)
          k += 1
        end
        count
      end

      # The prefix bonus.
      sig do
        params(left: T::Array[Integer], right: T::Array[Integer], jaro: Float).returns(Float).checked(:tests)
      end
      def winkler(left, right, jaro)
        return jaro if jaro < BOOST_THRESHOLD

        jaro + (prefix_length(left, right) * PREFIX_SCALE * (1.0 - jaro))
      end

      sig { params(left: T::Array[Integer], right: T::Array[Integer]).returns(Integer).checked(:tests) }
      def prefix_length(left, right)
        limit = [MAX_PREFIX, left.size, right.size].min
        length = 0
        length += 1 while length < limit && left.fetch(length) == right.fetch(length)
        length
      end

      private_class_method :jaro_score, :match, :partner, :transpositions, :winkler, :prefix_length
    end
  end
end
