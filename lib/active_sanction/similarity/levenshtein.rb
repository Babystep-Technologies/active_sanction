# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  module Similarity
    # Levenshtein edit distance, and the similarity derived from it, 0..1.
    #
    #   ActiveSanction::Similarity::Levenshtein.distance("kitten", "sitting") # => 3
    #   ActiveSanction::Similarity::Levenshtein.call("kitten", "sitting")     # => 0.5714
    #
    # ### Why this one, next to Jaro-Winkler
    #
    # It answers a different question. Jaro-Winkler asks how many characters
    # two names share and how far out of order they are, and it is generous:
    # it has no way to charge for a name that is simply longer than the other,
    # and its prefix bonus is deliberately biased toward the front. Edit
    # distance counts what it would actually take to turn one string into the
    # other, which is the thing that stays honest when a name gains a whole
    # word.
    #
    #   JaroWinkler.call("gazprom", "gazprombank")   # => 0.9273
    #   Levenshtein.call("gazprom", "gazprombank")   # => 0.6364
    #
    # Two different companies, and the scorer (#32) blends the two numbers
    # precisely so that neither algorithm's blind spot decides a hit on its
    # own.
    #
    # ### Normalized by the longer string
    #
    # `1 - distance / longer.length`, so the result is comparable across name
    # lengths and against Jaro-Winkler. Dividing by the longer of the two is
    # what makes the measure symmetric and keeps it in 0..1: the distance can
    # never exceed the longer length, and it equals it exactly when the two
    # share nothing.
    #
    # ### What else runs on it
    #
    # Both token ratios. TokenSort is one call to this on a pair of names
    # whose tokens have been put in alphabetical order, and TokenSet is three
    # on a pair that has been split into what they share and what they do not,
    # so half of stage 3 is this file with the strings rearranged first. See
    # TokenSort for why the rearranging is not done on top of Jaro-Winkler.
    module Levenshtein
      extend T::Sig

      module_function

      # The similarity of two already-folded strings -- see Similarity for
      # what `threshold:` does and what it promises.
      sig { params(left: String, right: String, threshold: Numeric).returns(Float).checked(:tests) }
      def call(left, right, threshold: 0.0)
        cutoff = Similarity.threshold!(threshold)
        return 1.0 if left == right

        left_codes = Similarity.codepoints(left)
        right_codes = Similarity.codepoints(right)
        longer = [left_codes.size, right_codes.size].max
        return 0.0 if ceiling(left_codes.size, right_codes.size) < cutoff

        # An edit budget rather than a score: within the budget the score is
        # at or above the threshold, and the rows stop the moment a row's
        # smallest value passes it.
        distance = rows(left_codes, right_codes, ((1.0 - cutoff) * longer).floor)
        return 0.0 if distance.nil?

        score = 1.0 - distance.fdiv(longer)
        score < cutoff ? 0.0 : score
      end

      # The number of single-character insertions, deletions and substitutions
      # that turn one string into the other. Exact, and public because it is
      # the quantity people know: a caller who wants "within two typos"
      # already knows what to compare against, and asking that of a 0..1 score
      # means multiplying by a length.
      sig { params(left: String, right: String).returns(Integer).checked(:tests) }
      def distance(left, right)
        return 0 if left == right

        left_codes = Similarity.codepoints(left)
        right_codes = Similarity.codepoints(right)

        # No cell can exceed the longer length, so a budget of it never fires
        # and the walk is exhaustive.
        T.must(rows(left_codes, right_codes, [left_codes.size, right_codes.size].max))
      end

      # The highest score two strings of these lengths can reach, whatever
      # they contain. This is the early exit: a pair whose ceiling is under
      # the caller's threshold is rejected without either string being looked
      # at, and without the matrix.
      #
      # Turning the shorter string into the longer one costs at least the
      # difference in their lengths -- every missing character is an
      # insertion, however well the rest lines up -- so the score can be no
      # better than `shorter / longer`. Unlike Jaro-Winkler's ceiling this one
      # is tight, and it bites: at a 0.85 threshold it rejects every pair
      # whose lengths differ by more than 15%, which on these lists is most of
      # the corpus for a given query.
      sig { params(left_length: Integer, right_length: Integer).returns(Float).checked(:tests) }
      def ceiling(left_length, right_length)
        shorter = [left_length, right_length].min
        longer = [left_length, right_length].max
        return shorter == longer ? 1.0 : 0.0 if shorter.zero?

        shorter.fdiv(longer)
      end

      # The matrix, one row at a time, or nil once no row can lead to a
      # distance within `max`.
      #
      # Two rows rather than the full grid: a cell depends on the one above
      # it, the one to its left, and the one diagonally above-left, so nothing
      # older than the previous row is ever read again. The full matrix for a
      # pair of 40-character names is 1,681 cells held for no reason, and the
      # scorer runs this a few hundred times per query.
      #
      # The cutoff is what makes `threshold:` worth more than the length check
      # in `ceiling`: row minima never decrease as the walk descends, so once
      # a row's smallest value is past the budget, no later row and no final
      # cell can come back under it.
      sig do
        params(left: T::Array[Integer], right: T::Array[Integer], max: Integer)
          .returns(T.nilable(Integer))
          .checked(:tests)
      end
      def rows(left, right, max)
        previous = (0..right.size).to_a
        current = Array.new(right.size + 1, 0)
        left.each_with_index do |code, i|
          current[0] = i + 1
          return nil if fill(code, right, previous, current) > max

          previous, current = current, previous
        end
        previous.fetch(right.size)
      end

      # One row, and the smallest value in it. Three of the four numbers a
      # cell needs are already in hand -- the substitution and deletion costs
      # come from the same two positions of the previous row, and the
      # insertion cost is the cell just written -- so only one read of each
      # row and one of the string happen per cell.
      #
      # `fetch` rather than `[]` for those: this is the innermost loop in the
      # library, and Sorbet types `Array#[]` as nilable, so every read through
      # it would carry a `T.must`, which is a Ruby-level method call per cell.
      sig do
        params(code: Integer, right: T::Array[Integer], previous: T::Array[Integer], current: T::Array[Integer])
          .returns(Integer)
          .checked(:tests)
      end
      def fill(code, right, previous, current)
        # The cell to the left is the one just written and the cell
        # diagonally above-left is the one that was above, so both are carried
        # in locals rather than read back out of the rows.
        left_cell = current.fetch(0)
        smallest = left_cell
        diagonal = previous.fetch(0)
        width = right.size
        j = 0
        while j < width
          above = previous.fetch(j + 1)
          value = diagonal + (right.fetch(j) == code ? 0 : 1)          # substitution
          value = above + 1 if above < value                           # deletion
          value = left_cell + 1 if left_cell < value                   # insertion
          diagonal = above
          left_cell = current[j + 1] = value
          smallest = value if value < smallest
          j += 1
        end
        smallest
      end

      private_class_method :rows, :fill
    end
  end
end
