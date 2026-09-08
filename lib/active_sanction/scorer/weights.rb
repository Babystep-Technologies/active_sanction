# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  module Scorer
    # Every number the scorer uses, with a default and a reason for it.
    #
    #   ActiveSanction::Scorer::Weights.default.token_set        # => 0.45
    #   ActiveSanction::Scorer::Weights.default.dob_conflict     # => -35.0
    #
    #   ActiveSanction.configure do |c|
    #     c.scorer_weights = { dob_conflict: -20.0 }
    #   end
    #
    # There are two kinds of number here and they are in different units,
    # which is the thing to know before changing one.
    #
    # ### The name shares, which are fractions of the name score
    #
    # `jaro_winkler`, `levenshtein`, `token_sort`, `token_set` and `phonetic`
    # are shares of one blended similarity. They are each between 0 and 1 and
    # they must sum to exactly 1, which is what makes the name score a
    # percentage rather than an arbitrary total: two identical names score
    # 100 because every share agreed, and a share that agreed on nothing
    # contributes nothing.
    #
    # The defaults are set from what the four algorithms disagree about --
    # Similarity's own table is the argument, and it is worth reading beside
    # this:
    #
    #                                        JW     Lev    Sort    Set   Phon   blend
    #     abbas abu / abu abbas            0.805  0.333  1.000  1.000  1.000    90.4
    #     putin vladimir vladimirovich /
    #       vladimir putin                 0.679  0.357  0.500  1.000  1.000    76.2
    #     gazprom / gazprom neft           0.917  0.583  0.583  1.000  1.000    84.2
    #     kim jong un / kim yong chol      0.869  0.615  0.462  0.462  0.667    54.8
    #
    # **The token ratios carry most of the weight**, because the query shapes
    # this corpus actually produces are rearrangements. An individual is
    # published surname-first and typed given-name-first; a patronymic is on
    # the record and not in the query. Row one and row two are both true
    # matches that the character algorithms score in the sixties and the
    # seventies, and a blend that let them decide would miss the two most
    # common true positives there are.
    #
    # **`token_set` is the largest single share** because a 1.0 from it means
    # something specific and strong: every word of the shorter name appears in
    # the longer one. That is the shape of nearly every honest partial query.
    #
    # **The character algorithms are the brake.** Row four is the case they
    # exist for -- two names already written in the same order, where sorting
    # loses the information that they are, and the token ratios happily score
    # a different person at 0.462. Levenshtein's share is the smallest because
    # it is the harshest measure in the set: on a name that is one token
    # longer it is already down in the fifties, and giving it more would pull
    # every true partial match down with it.
    #
    # **The phonetic share is small and it is a share, not a bonus.** A shared
    # Double Metaphone key is real evidence -- it is what puts `QADHAFI` and
    # `GADDAFI` together -- and it is weak evidence, because `HSN` is the key
    # for `HUSSEIN` and equally for `HASSAN`. Five points is what it is worth
    # on its own; the reason it is inside the sum rather than added on top is
    # that a bonus would put an identical pair over 100 and need clamping to
    # get back, and a score that reaches its ceiling by two different routes
    # is one nobody can reason about.
    #
    # ### The adjustments, which are points on the 0..100 score
    #
    # These are added to the name score, not multiplied into it, because they
    # are separate evidence rather than a re-reading of the name. A passport
    # number is not "more name"; it is the thing that makes a mediocre name
    # match decisive, and a boost that scaled with the name score could not do
    # that.
    #
    # `identifier_match` is 40 and is meant to be decisive: a name in the
    # fifties plus the right passport number clears any sane threshold, which
    # is the entire reason a screening tool asks for document numbers.
    #
    # `dob_conflict` at -35 is the one number the acceptance criteria pin
    # down. A name-identical pair scores 100, and a genuine date-of-birth
    # conflict has to put it under the threshold rather than merely rank it
    # lower -- 65 is under every default this library ships. The exact match
    # is worth less than the conflict costs on purpose: sharing a birthday
    # with a listed person is a coincidence a few thousand people have, and
    # not having theirs is not.
    #
    # `dob_overlap` at 6 is what a year-only date is worth. Most of these
    # records carry one -- see PartialDate on why the type exists -- and
    # `1948` against `1948-12-10` is agreement worth noting and not worth much.
    #
    # Nationality moves the score least in both directions, because it is the
    # softest of the three. People hold two passports, lists record the
    # country a person was born in as often as the one they are a citizen of,
    # and a conflict there is weaker evidence than a date conflict by some way.
    #
    # ### Penalties are stored negative
    #
    # `dob_conflict` is `-35.0` rather than `35.0` subtracted somewhere else,
    # so that a Reason's contribution is the number in this object and a host
    # reading a configuration can see which way each one pushes. A boost
    # written negative, or a penalty written positive, is refused.
    #
    # Instances are frozen on construction and compare by value.
    class Weights
      extend T::Sig

      # The five shares of the blended name score. They sum to 1.
      NAME_SHARES = T.let(%i[jaro_winkler levenshtein token_sort token_set phonetic].freeze, T::Array[Symbol])

      # Points added to the name score. Anything listed in PENALTIES must be
      # zero or negative; everything else here must be zero or positive.
      ADJUSTMENTS = T.let(%i[
        low_quality_alias identifier_match dob_exact dob_overlap dob_conflict
        nationality_match nationality_conflict
      ].freeze, T::Array[Symbol])

      PENALTIES = T.let(%i[low_quality_alias dob_conflict nationality_conflict].freeze, T::Array[Symbol])

      MEMBERS = T.let((NAME_SHARES + ADJUSTMENTS).freeze, T::Array[Symbol])

      DEFAULTS = T.let({
        jaro_winkler: 0.15,
        levenshtein: 0.10,
        token_sort: 0.25,
        token_set: 0.45,
        phonetic: 0.05,
        low_quality_alias: -10.0,
        identifier_match: 40.0,
        dob_exact: 15.0,
        dob_overlap: 6.0,
        dob_conflict: -35.0,
        nationality_match: 6.0,
        nationality_conflict: -12.0
      }.freeze, T::Hash[Symbol, Float])

      # Floating point addition of five decimal fractions does not land on 1.0
      # exactly, and refusing a set of shares over the last bit of a Float
      # would be refusing arithmetic rather than a misconfiguration.
      SHARE_TOLERANCE = T.let(1e-9, Float)

      # Spelled out rather than defined from MEMBERS in a loop, because a
      # reader Sorbet cannot see is a reader every call site has to be
      # `T.unsafe` to reach. Each one reads the hash; nothing here is stored
      # twice.
      sig { returns(Float) }
      def jaro_winkler = fetch(:jaro_winkler)

      sig { returns(Float) }
      def levenshtein = fetch(:levenshtein)

      sig { returns(Float) }
      def token_sort = fetch(:token_sort)

      sig { returns(Float) }
      def token_set = fetch(:token_set)

      sig { returns(Float) }
      def phonetic = fetch(:phonetic)

      sig { returns(Float) }
      def low_quality_alias = fetch(:low_quality_alias)

      sig { returns(Float) }
      def identifier_match = fetch(:identifier_match)

      sig { returns(Float) }
      def dob_exact = fetch(:dob_exact)

      sig { returns(Float) }
      def dob_overlap = fetch(:dob_overlap)

      sig { returns(Float) }
      def dob_conflict = fetch(:dob_conflict)

      sig { returns(Float) }
      def nationality_match = fetch(:nationality_match)

      sig { returns(Float) }
      def nationality_conflict = fetch(:nationality_conflict)

      class << self
        extend T::Sig

        # The shipped numbers. Built at load, so nothing has to synchronize
        # its construction.
        sig { returns(Weights) }
        def default = DEFAULT

        # The shipped numbers with some replaced, which is what a host almost
        # always wants:
        #
        #   Weights.build(dob_conflict: -20.0)
        #
        # A Weights passes through, so a caller holding either can hand this
        # whatever it has.
        sig { params(value: T.untyped).returns(Weights) }
        def build(value)
          return default if value.nil?
          return value if value.is_a?(Weights)
          raise InvalidArgument, "expected a #{self} or a Hash of weights, got #{value.class}" unless value.is_a?(Hash)

          T.unsafe(default).merge(**value.to_h { |member, weight| [member.to_s.to_sym, weight] })
        end
      end

      # Every member defaults, so `new` and `new(dob_conflict: -20.0)` are
      # both a complete set. Unlike the normalizer's dictionaries there is no
      # danger in a partial replacement here: a number left out is the shipped
      # one, and the shares are checked to sum to 1 whatever a caller passed.
      sig { params(overrides: T.untyped).void }
      def initialize(**overrides)
        unknown = overrides.keys - MEMBERS
        raise InvalidArgument, "unknown weight(s): #{unknown.join(", ")}" if unknown.any?

        @weights = T.let(DEFAULTS.merge(overrides).to_h { |member, weight| [member, number!(member, weight)] }.freeze,
                         T::Hash[Symbol, Float])
        validate_shares!
        freeze
      end

      # These weights with some replaced.
      sig { params(overrides: T.untyped).returns(Weights) }
      def merge(**overrides) = T.unsafe(self.class).new(**@weights, **overrides)

      sig { params(member: Symbol).returns(Float) }
      def fetch(member) = @weights.fetch(member)

      sig { returns(T::Hash[Symbol, Float]) }
      def to_h = @weights.dup

      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.instance_of?(self.class)

        to_h == other.to_h
      end
      alias eql? ==

      sig { returns(Integer) }
      def hash = [self.class, to_h].hash

      sig { returns(String) }
      def inspect = "#<#{self.class} #{to_h.map { |member, weight| "#{member}=#{weight}" }.join(" ")}>"

      private

      sig { params(member: Symbol, value: T.untyped).returns(Float) }
      def number!(member, value)
        number = begin
          Float(value)
        rescue TypeError, ArgumentError
          raise InvalidArgument, "#{member} must be a number, got #{value.inspect}"
        end
        direction!(member, number)
        number
      end

      # A boost written negative is a configuration that quietly inverts a
      # signal -- a passport match that lowers a score -- and it would look
      # exactly like a scorer bug from outside.
      sig { params(member: Symbol, number: Float).void }
      def direction!(member, number)
        if PENALTIES.include?(member)
          raise InvalidArgument, "#{member} is a penalty and cannot be positive, got #{number}" if number.positive?
        elsif number.negative?
          raise InvalidArgument, "#{member} is a boost and cannot be negative, got #{number}"
        end
      end

      sig { void }
      def validate_shares!
        NAME_SHARES.each do |share|
          weight = @weights.fetch(share)
          raise InvalidArgument, "#{share} must be between 0 and 1, got #{weight}" unless weight.between?(0.0, 1.0)
        end
        total = NAME_SHARES.sum { |share| @weights.fetch(share) }
        return if (total - 1.0).abs <= SHARE_TOLERANCE

        raise InvalidArgument,
              "the name shares must sum to 1.0, got #{total.round(6)} -- " \
              "#{NAME_SHARES.map { |share| "#{share}=#{@weights.fetch(share)}" }.join(", ")}"
      end

      # Last, because building it runs #initialize, which calls every private
      # method above.
      DEFAULT = T.let(new, Weights)
      private_constant :DEFAULT
    end
  end
end
