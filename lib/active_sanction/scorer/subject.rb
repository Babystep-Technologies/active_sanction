# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/country"
require "active_sanction/entity"
require "active_sanction/identifier"
require "active_sanction/normalizer"
require "active_sanction/partial_date"

module ActiveSanction
  module Scorer
    # What the caller knows about the person or company being screened.
    #
    #   subject = ActiveSanction::Scorer::Subject.new(
    #     name:           "Vladimir Putin",
    #     type:           :individual,
    #     dates_of_birth: "1952-10-07",
    #     nationalities:  %w[RU],
    #     identifiers:    [{ kind: :passport, value: "AB-123 456" }]
    #   )
    #
    #   subject.form.value   # => "vladimir putin"
    #
    # One side of every comparison the scorer makes, and the mirror image of
    # the Entity on the other side: the same four kinds of evidence, arriving
    # from an application's own customer record rather than from a government.
    #
    # ### Only `name` is required, and that is the shape of the problem
    #
    # Most callers have a name and little else, and most records carry less
    # than that -- Canada supplies no aliases and often no date of birth. So
    # every field but the name is optional on both sides, and a field absent
    # on either side is neutral rather than a conflict. See Adjustments, where
    # that rule is the difference between a screening tool and a tool that
    # systematically under-scores the sparser lists.
    #
    # ### `type` decides two things
    #
    # It is the entity type the caller is asking about, and it does two jobs
    # that are easy to confuse. It selects the normalizer's stoplists, so a
    # company name is folded with its legal form stripped -- and both sides of
    # a comparison have to be folded the same way, which is why the scorer
    # folds each candidate name under its own entity's type. And it filters:
    # a subject that says `:individual` is never scored against a vessel, at
    # any name similarity. See Scorer.
    #
    # Passing no type is a legitimate answer and a different question -- no
    # stoplist, no filter -- rather than a worse one.
    #
    # ### The fold happens once, here
    #
    # `form` is the folded name, produced by the one `Normalizer.call` every
    # other stage uses, and held for the life of the subject. A screening call
    # compares one subject against a few hundred candidates, and folding the
    # query per candidate would be the same string folded a few hundred times.
    #
    # A caller that has already folded a name passes the Form, which is what
    # screening one name against several indexes should do.
    #
    # ### Where Query fits
    #
    # This is the scorer's input, not the library's public screening API. The
    # `Query` object (#33) validates what a host application sends -- a
    # threshold, a limit, a source filter -- and builds one of these for the
    # matcher to score with. Everything on this class is evidence about a
    # subject; nothing on it is a search option.
    #
    # Instances are frozen on construction and compare by value.
    class Subject
      extend T::Sig

      # @api private
      MEMBERS = T.let(%i[name type dates_of_birth nationalities identifiers].freeze, T::Array[Symbol])

      # The folded name every comparison runs against.
      sig { returns(Normalizer::Form) }
      attr_reader :form

      sig { returns(T.nilable(Symbol)) }
      attr_reader :type

      sig { returns(T::Array[PartialDate]) }
      attr_reader :dates_of_birth

      # As published by the caller, in the caller's own vocabulary: `RU`,
      # `Russia` and `Russian Federation` are all fine here. See #countries
      # for the resolved form the scorer compares on.
      sig { returns(T::Array[String]) }
      attr_reader :nationalities

      sig { returns(T::Array[Identifier]) }
      attr_reader :identifiers

      sig { params(hash: T.untyped).returns(T.attached_class) }
      def self.from_h(hash)
        attributes = hash.to_h.transform_keys(&:to_sym)
        unknown = attributes.keys - MEMBERS
        raise InvalidArgument, "unknown Subject attribute(s): #{unknown.join(", ")}" if unknown.any?

        T.unsafe(self).new(**attributes)
      end

      # `name` is a String, a Name or an already-folded Form. The three
      # collections each accept a single value as a collection of one, since
      # `dates_of_birth: "1952-10-07"` is what a caller with one date writes.
      #
      # Dates accept anything PartialDate reads, including the free text these
      # lists publish; identifiers accept an Identifier, its hash, or a bare
      # document number, which becomes an identifier of unstated kind.
      sig do
        params(name: T.untyped, type: T.untyped, dates_of_birth: T.untyped, nationalities: T.untyped,
               identifiers: T.untyped).void
      end
      def initialize(name:, type: nil, dates_of_birth: [], nationalities: [], identifiers: [])
        @type = T.let(type!(type), T.nilable(Symbol))
        @form = T.let(form!(name), Normalizer::Form)
        @dates_of_birth = T.let(Array(dates_of_birth).map { |value| date!(value) }.freeze, T::Array[PartialDate])
        @nationalities = T.let(strings(nationalities), T::Array[String])
        @identifiers = T.let(Array(identifiers).map { |value| identifier!(value) }.freeze, T::Array[Identifier])
        @countries = T.let(resolve(@nationalities), T::Array[String])
        freeze
      end

      # The name as the caller wrote it, which is what a report quotes back.
      sig { returns(String) }
      def name = form.original

      # The alpha-2 codes #nationalities resolved to, which may be shorter
      # than the list it came from: a value Country does not recognize is
      # dropped here rather than guessed at, and the scorer treats a subject
      # whose countries did not all resolve as one that cannot contradict a
      # record. See Adjustments.
      sig { returns(T::Array[String]) }
      attr_reader :countries

      # True when every nationality the caller gave resolved to a country.
      # A conflict penalty is only applied when both sides can say this.
      sig { returns(T::Boolean) }
      def countries? = nationalities.any? && countries.size == nationalities.uniq.size

      sig { returns(T::Boolean) }
      def dates_of_birth? = dates_of_birth.any?

      sig { returns(T::Boolean) }
      def identifiers? = identifiers.any?

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h
        {
          name: name,
          type: type,
          dates_of_birth: dates_of_birth.map(&:to_h),
          nationalities: nationalities,
          identifiers: identifiers.map(&:to_h)
        }
      end

      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.instance_of?(self.class)

        to_h == other.to_h
      end
      alias eql? ==

      sig { returns(Integer) }
      def hash = [self.class, to_h].hash

      sig { returns(String) }
      def inspect = "#<#{self.class} #{name.inspect}#{" type=#{type.inspect}" if type}>"

      private

      # A Form is taken as it stands, and it is the caller's job to have
      # folded it under the same type -- there is no way to check, since a
      # Form does not record which stoplist produced it, and re-folding it
      # here would silently discard the caller's intent. See Normalizer on
      # why one fold, once, is the whole point.
      sig { params(value: T.untyped).returns(Normalizer::Form) }
      def form!(value)
        return value if value.is_a?(Normalizer::Form)

        string = value.to_s.strip
        raise InvalidArgument, "name is required -- there is nothing to screen without one" if string.empty?

        folded = Normalizer.call(string, type: type)
        raise InvalidArgument, "name folds away to nothing: #{string.inspect}" if folded.empty?

        folded
      end

      sig { params(value: T.untyped).returns(T.nilable(Symbol)) }
      def type!(value)
        return nil if value.nil? || value.to_s.empty?

        symbol = value.to_s.downcase.to_sym
        return symbol if Entity::TYPES.include?(symbol)

        raise InvalidArgument, "unknown type #{symbol.inspect}, expected one of #{Entity::TYPES.join(", ")} or nil"
      end

      sig { params(value: T.untyped).returns(PartialDate) }
      def date!(value)
        case value
        when PartialDate then value
        when Hash then PartialDate.from_h(value)
        else PartialDate.parse(value) || raise(InvalidArgument, "not a date of birth: #{value.inspect}")
        end
      end

      sig { params(value: T.untyped).returns(Identifier) }
      def identifier!(value)
        case value
        when Identifier then value
        when Hash then Identifier.from_h(value)
        else Identifier.new(value: value)
        end
      end

      # A value Country does not recognize is dropped rather than guessed at.
      # #countries? is how a caller tells a fully resolved list from a partly
      # resolved one, which is the difference between a nationality that may
      # contradict a record and one that may only agree with it.
      sig { params(values: T::Array[String]).returns(T::Array[String]) }
      def resolve(values) = values.filter_map { |value| Country.code(value) }.uniq.freeze

      sig { params(value: T.untyped).returns(T::Array[String]) }
      def strings(value)
        Array(value).map { |entry| -entry.to_s.strip }.reject(&:empty?).uniq.freeze
      end
    end
  end
end
