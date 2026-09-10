# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  module Scorer
    # One line of the answer to "why did this score 87?".
    #
    #   ActiveSanction::Scorer::Reason.new(
    #     factor: :dob, detail: "year 1948 matches", contribution: 6.0
    #   )
    #
    # ### The explanation adds up
    #
    # A Result's `explanation` is a list of these, and their contributions sum
    # to exactly the score. That is the whole design: the name blend produces
    # the first one and every secondary identifier appends a signed delta, so
    # a reviewer reading the list downwards arrives at the number on the
    # report rather than at something near it.
    #
    # It is a property the suite holds rather than a coincidence of the
    # arithmetic. Contributions are rounded once, here, and the score is the
    # sum of the rounded values -- not the rounded sum, which is how a total
    # ends up one tenth away from the figures printed beside it. Where
    # clamping moves the total off the sum, that correction is itself a reason
    # (`:clamp`), because a score that silently stopped at 100 is a score
    # whose explanation no longer explains it.
    #
    # ### Why this is a required output and not a debugging aid
    #
    # A compliance officer has to defend a screening decision to an examiner,
    # and "the library said 87" is not a defence. Both directions matter: an
    # alert that cannot be accounted for cannot be cleared, and a *clearance*
    # that cannot be accounted for is the one an examiner asks about. So every
    # adjustment the scorer makes writes one of these, including the ones that
    # lower a score.
    #
    # Instances are frozen on construction and compare by value.
    class Reason
      extend T::Sig

      # `:name` is the blended name similarity and is always first. The rest
      # are the secondary-identifier adjustments, in the order Adjustments
      # applies them, and `:clamp` is the correction described above.
      #
      # Closed, so a typo is caught where the reason is built rather than
      # reaching a report as a factor nothing renders.
      #
      # @api private
      FACTORS = T.let(%i[name alias_quality identifier dob nationality clamp].freeze, T::Array[Symbol])

      # One decimal place, which is the precision a screening score is read at
      # -- see the note on adding up above.
      #
      # @api private
      PRECISION = T.let(1, Integer)

      # @api private
      MEMBERS = T.let(%i[factor detail contribution].freeze, T::Array[Symbol])

      sig { returns(Symbol) }
      attr_reader :factor

      # Written for a person, and it names what was compared rather than which
      # rule fired: "year 1948 matches", not "dob_overlap". A reviewer reading
      # it should not need this library's vocabulary.
      sig { returns(String) }
      attr_reader :detail

      # Signed, in the same 0..100 units as the score. Positive raises the
      # score and negative lowers it.
      sig { returns(Float) }
      attr_reader :contribution

      sig { params(hash: T.untyped).returns(T.attached_class) }
      def self.from_h(hash)
        attributes = hash.to_h.transform_keys(&:to_sym)
        unknown = attributes.keys - MEMBERS
        raise InvalidArgument, "unknown Reason attribute(s): #{unknown.join(", ")}" if unknown.any?

        T.unsafe(self).new(**attributes)
      end

      sig { params(factor: T.untyped, detail: T.untyped, contribution: T.untyped).void }
      def initialize(factor:, detail:, contribution:)
        @factor = T.let(factor!(factor), Symbol)
        @detail = T.let(detail!(detail), String)
        @contribution = T.let(Float(contribution).round(PRECISION).to_f, Float)
        freeze
      end

      sig { returns(T::Boolean) }
      def penalty? = contribution.negative?

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h = { factor: factor, detail: detail, contribution: contribution }

      # The line a report prints: "+6.0 dob: year 1948 matches".
      sig { returns(String) }
      def to_s = format("%+.#{PRECISION}f %s: %s", contribution, factor, detail)

      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.instance_of?(self.class)

        to_h == other.to_h
      end
      alias eql? ==

      sig { returns(Integer) }
      def hash = [self.class, to_h].hash

      sig { returns(String) }
      def inspect = "#<#{self.class} #{self}>"

      private

      sig { params(value: T.untyped).returns(Symbol) }
      def factor!(value)
        symbol = value.to_s.to_sym
        return symbol if FACTORS.include?(symbol)

        raise InvalidArgument, "unknown factor #{symbol.inspect}, expected one of #{FACTORS.join(", ")}"
      end

      sig { params(value: T.untyped).returns(String) }
      def detail!(value)
        string = value.to_s.strip
        raise InvalidArgument, "detail is required -- a reason nobody can read is not a reason" if string.empty?

        -string
      end
    end
  end
end
