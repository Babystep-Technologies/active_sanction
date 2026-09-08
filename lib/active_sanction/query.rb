# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/scorer"
require "active_sanction/sources/definition"

module ActiveSanction
  # One screening request: what is known about the subject, and how the
  # search is to be run.
  #
  #   query = ActiveSanction::Query.build(
  #     name:          "Vladimir Putin",
  #     type:          :individual,
  #     date_of_birth: "1952-10-07",
  #     countries:     %w[RU],
  #     sources:       %i[ofac_sdn un_consolidated],
  #     threshold:     75,
  #     limit:         10
  #   )
  #
  #   query.subject     # => Scorer::Subject, folded once and held
  #   query.threshold   # => 75.0
  #
  # ### Two kinds of field, and the line between them matters
  #
  # **Evidence** -- the name, the type, the dates of birth, the nationalities,
  # the identifiers -- is what the scorer compares against a record, and it
  # belongs to Scorer::Subject, which this builds and holds. **Search
  # options** -- `sources`, `threshold`, `limit` -- decide which records are
  # looked at and how many come back, and they never touch a comparison.
  #
  # Keeping them apart is what lets a stored decision be re-derived: the
  # evidence says what was screened and the options say what the run was
  # willing to return, and an audit needs both separately. It is also why
  # Subject carries no threshold -- see the note at the end of that class.
  #
  # ### Singular and plural spellings are both accepted
  #
  # `date_of_birth:` and `dates_of_birth:`, `country:`, `countries:` and
  # `nationalities:`, `identifier:` and `identifiers:` all mean the same
  # thing. A caller with one date writes the singular and a caller with three
  # writes the plural, and neither should have to remember which this library
  # prefers. `#to_h` emits the plural, canonical spelling.
  #
  # That resolution happens in `.build` and `.from_h`, which is what every
  # screening call goes through -- `Matcher#screen` builds one of these out of
  # whatever it was handed. `.new` takes the canonical names and nothing else,
  # in the manner of Scorer::Weights: one constructor states the shape and one
  # accepts what a caller wrote.
  #
  # ### Defaults come from configuration, once, here
  #
  # A query with no `threshold:` takes `config.screening_threshold` and one
  # with no `limit:` takes `config.screening_limit`, both read at construction
  # and then fixed. Nothing downstream reads a global: a Matcher screens the
  # numbers on the query it was given, so a configuration changed mid-batch
  # cannot produce a run that is half one threshold and half another.
  #
  # Instances are frozen on construction and compare by value.
  class Query
    extend T::Sig

    # The canonical spelling of every field, and the shape `#to_h` emits.
    MEMBERS = T.let(
      %i[name type dates_of_birth nationalities identifiers sources threshold limit].freeze,
      T::Array[Symbol]
    )

    # The spellings a caller may write instead, and what each one means. See
    # the note above.
    ALIASES = T.let(
      {
        date_of_birth: :dates_of_birth, dob: :dates_of_birth, dobs: :dates_of_birth,
        country: :nationalities, countries: :nationalities, nationality: :nationalities,
        identifier: :identifiers, source: :sources
      }.freeze,
      T::Hash[Symbol, Symbol]
    )

    # The members that are lists. A value that is not one becomes a list of
    # one, which is what makes `identifier: { kind: :passport, value: "AB-1" }`
    # a single identifier: `Array(hash)` reads a Hash as a list of its pairs,
    # and a caller naming one document would get two nonsense identifiers back.
    COLLECTIONS = T.let(%i[dates_of_birth nationalities identifiers sources].freeze, T::Array[Symbol])

    # The evidence, folded once. Every comparison in a screening run happens
    # against this one object rather than against a name re-folded per
    # candidate.
    sig { returns(Scorer::Subject) }
    attr_reader :subject

    # Which lists to screen against, or nil for every list the matcher holds.
    # Naming one it does not hold is an error rather than a shorter answer --
    # see Matcher.
    sig { returns(T.nilable(T::Array[Symbol])) }
    attr_reader :sources

    # 0..100. The lowest score worth reporting, and the number that decides
    # what a screening call costs -- see Scorer.
    sig { returns(Float) }
    attr_reader :threshold

    # How many results to return, highest score first.
    sig { returns(Integer) }
    attr_reader :limit

    class << self
      extend T::Sig

      # Whatever a caller had, as a Query:
      #
      #   Query.build("Vladimir Putin")
      #   Query.build(name: "Vladimir Putin", threshold: 80)
      #   Query.build(query, limit: 5)         # the same query, with one option changed
      #
      # A bare String or Name is a query about that name and nothing else,
      # which is what a batch of names is a list of.
      sig { params(value: T.untyped, overrides: T.untyped).returns(Query) }
      def build(value = nil, **overrides)
        case value
        when Query then overrides.empty? ? value : T.unsafe(value).merge(**overrides)
        when Hash then from_h(normalize(value).merge(normalize(overrides)))
        when nil then from_h(overrides)
        else from_h(normalize(overrides).merge(name: value))
        end
      end

      # Rebuilds a query from #to_h output, accepting string keys so one
      # stored in an audit record survives the round-trip through JSON.
      sig { params(hash: T.untyped).returns(Query) }
      def from_h(hash)
        attributes = normalize(hash)
        unknown = attributes.keys - MEMBERS
        raise QueryError, "unknown Query attribute(s): #{unknown.join(", ")}" if unknown.any?

        # `new(**hash)` past a required keyword parameter is one of the few
        # things Sorbet cannot check statically. #initialize validates what
        # arrives, which is where a bad round-trip is caught.
        T.unsafe(self).new(**attributes)
      end

      private

      # Symbol keys, with every accepted spelling resolved to its canonical
      # one. A caller that wrote both spellings of the same field is a typo
      # rather than a merge, so it is refused.
      sig { params(hash: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
      def normalize(hash)
        spellings = T.let({}, T::Hash[Symbol, Symbol])
        hash.to_h.each_with_object({}) do |(key, value), attributes|
          written = key.to_s.to_sym
          member = ALIASES.fetch(written, written)
          clash = spellings[member]
          raise QueryError, "#{clash} and #{written} are the same field -- pass one" if conflict?(clash, written)

          spellings[member] = written
          attributes[member] = wrap(member, value)
        end
      end

      sig { params(clash: T.nilable(Symbol), written: Symbol).returns(T::Boolean) }
      def conflict?(clash, written) = !clash.nil? && clash != written

      sig { params(member: Symbol, value: T.untyped).returns(T.untyped) }
      def wrap(member, value)
        return value unless COLLECTIONS.include?(member)
        return value if value.nil? || value.is_a?(Array)

        [value]
      end
    end

    # Only `name` is required; see Scorer::Subject on why that is the shape of
    # the problem rather than a convenience.
    sig do
      params(name: T.untyped, type: T.untyped, dates_of_birth: T.untyped, nationalities: T.untyped,
             identifiers: T.untyped, sources: T.untyped, threshold: T.untyped, limit: T.untyped).void
    end
    def initialize(name:, type: nil, dates_of_birth: [], nationalities: [], identifiers: [],
                   sources: nil, threshold: nil, limit: nil)
      @subject = T.let(
        Scorer::Subject.new(name: name, type: type, dates_of_birth: dates_of_birth,
                            nationalities: nationalities, identifiers: identifiers),
        Scorer::Subject
      )
      @sources = T.let(sources!(sources), T.nilable(T::Array[Symbol]))
      @threshold = T.let(threshold!(threshold), Float)
      @limit = T.let(limit!(limit), Integer)
      freeze
    end

    # This query with some fields replaced, which is how a batch applies one
    # threshold to a list of names.
    sig { params(overrides: T.untyped).returns(Query) }
    def merge(**overrides) = self.class.build(to_h, **overrides)

    # The name as the caller wrote it, which is what a report quotes back.
    sig { returns(String) }
    def name = subject.name

    sig { returns(T.nilable(Symbol)) }
    def type = subject.type

    sig { returns(T::Array[PartialDate]) }
    def dates_of_birth = subject.dates_of_birth

    sig { returns(T::Array[String]) }
    def nationalities = subject.nationalities

    sig { returns(T::Array[Identifier]) }
    def identifiers = subject.identifiers

    # The folded name every comparison runs against, and what a Matcher hands
    # the index rather than the string it came from.
    sig { returns(Normalizer::Form) }
    def form = subject.form

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h
      subject.to_h.merge(sources: sources, threshold: threshold, limit: limit)
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
    def inspect = "#<#{self.class} #{name.inspect} threshold=#{threshold} limit=#{limit}>"

    private

    # nil means every list the matcher holds. An empty array does not: a
    # caller that computed its source list and got nothing back is asking to
    # screen against no lists at all, which returns a clean report for
    # everybody, so it is refused rather than quietly read as "all".
    sig { params(value: T.untyped).returns(T.nilable(T::Array[Symbol])) }
    def sources!(value)
      return nil if value.nil?

      keys = Array(value).map { |key| Sources::Definition.key!(key) }.uniq
      raise QueryError, "sources cannot be empty -- omit it to screen against every list" if keys.empty?

      keys.freeze
    end

    # Validated by the scorer's own check, so a threshold on the 0..1 scale is
    # refused here with the message that explains it rather than three layers
    # down.
    sig { params(value: T.untyped).returns(Float) }
    def threshold!(value)
      return Scorer.threshold!(ActiveSanction.config.screening_threshold) if value.nil?

      number = begin
        Float(value)
      rescue TypeError, ArgumentError
        raise QueryError, "threshold must be a number between 0 and 100, got #{value.inspect}"
      end
      Scorer.threshold!(number)
    end

    sig { params(value: T.untyped).returns(Integer) }
    def limit!(value)
      return ActiveSanction.config.screening_limit if value.nil?

      integer = begin
        Integer(value)
      rescue TypeError, ArgumentError
        raise QueryError, "limit must be a whole number of results, got #{value.inspect}"
      end
      raise QueryError, "limit must be at least 1, got #{integer}" unless integer.positive?

      integer
    end
  end
end
