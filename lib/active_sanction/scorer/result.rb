# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/scorer/reason"

module ActiveSanction
  module Scorer
    # One entity scored against one subject, and the account of how.
    #
    #   result = ActiveSanction::Scorer.call(subject, entity)
    #
    #   result.score        # => 87.4
    #   result.entity.id    # => "ofac_sdn:2674"
    #   result.name.value   # => "AERO-CARIBBEAN"
    #   result.explanation.map(&:to_s)
    #   # => ["+91.2 name: matched alias 'AERO-CARIBBEAN' (aka)",
    #   #     "+4.0 dob: date of birth 1948 overlaps listed 1948-12-10",
    #   #     "-8.0 nationality: query RU vs listed EG"]
    #
    # ### The score is the explanation
    #
    # `score` is not stored beside the reasons, it is the sum of them, rounded
    # once. There is no arithmetic anywhere in this library that can move one
    # without the other, which is the point: a compliance officer has to
    # answer "why did this score 87?" to an examiner, and a number that merely
    # travels alongside a list of reasons is a number that can come apart from
    # them in a later release and be wrong quietly for a year.
    #
    # So the explanation is never empty -- the blended name similarity is
    # always the first reason, even when nothing else was known -- and it
    # always adds up.
    #
    # ### `name` is the specific spelling that produced the score
    #
    # An entity's score is the best of its names, and this is the one that
    # won. It matters more than it looks: OFAC ships more aliases than primary
    # names, so the answer to "what did we match?" is usually an alias, and a
    # report that quoted the primary name instead would be describing a
    # comparison that never happened.
    #
    # `form` is that name folded, which is the string the scorers actually
    # compared. Both are here for the reason Normalizer::Form carries both:
    # the published spelling is what a person reads and the folded one is what
    # a person checks.
    #
    # ### What this is not
    #
    # It is not `MatchResult` (#33). This carries what the scorer knows -- a
    # score, a name, an entity, an explanation -- and nothing about the
    # screening run that produced it. The snapshot checksum, the matcher
    # version, the thresholds and the backend all belong to the public API
    # above this one, which is where an audit record is assembled.
    #
    # Instances are frozen on construction and compare by value.
    class Result
      extend T::Sig

      sig { returns(Entity) }
      attr_reader :entity

      # The name that scored highest, as its publisher wrote it.
      sig { returns(Name) }
      attr_reader :name

      # That name folded -- the string the comparison ran on.
      sig { returns(Normalizer::Form) }
      attr_reader :form

      # 0..100, one decimal place, and equal to the sum of the explanation.
      sig { returns(Float) }
      attr_reader :score

      # Never empty. See the class comment.
      sig { returns(T::Array[Reason]) }
      attr_reader :explanation

      sig do
        params(entity: Entity, name: Name, form: Normalizer::Form, explanation: T::Array[Reason])
          .void.checked(:tests)
      end
      def initialize(entity:, name:, form:, explanation:)
        raise InvalidArgument, "a result needs at least one reason" if explanation.empty?

        @entity = entity
        @name = name
        @form = form
        @explanation = T.let(explanation.dup.freeze, T::Array[Reason])
        @score = T.let(explanation.sum(&:contribution).round(Reason::PRECISION).to_f, Float)
        freeze
      end

      # The list this entity came from, which every hit has to name.
      sig { returns(Symbol) }
      def source = entity.source

      # The reasons that lowered the score, which is the half of an
      # explanation a reviewer clearing an alert reads first.
      sig { returns(T::Array[Reason]) }
      def penalties = explanation.select(&:penalty?)

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h
        {
          score: score,
          entity_id: entity.id,
          source: source,
          name: name.to_h,
          explanation: explanation.map(&:to_h)
        }
      end

      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.instance_of?(self.class)

        entity == other.entity && name == other.name && explanation == other.explanation
      end
      alias eql? ==

      sig { returns(Integer) }
      def hash = [self.class, entity, name, explanation].hash

      sig { returns(String) }
      def inspect = "#<#{self.class} #{score} #{name.value.inspect} (#{entity.id})>"
    end
  end
end
