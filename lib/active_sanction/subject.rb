# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"
require "active_sanction/query"
require "active_sanction/scorer/subject"

module ActiveSanction
  # One entry in a book of business: an application's own id, and everything
  # it knows about the person or company behind it.
  #
  #   subject = ActiveSanction::Subject.new(
  #     id:            "cust_1",
  #     name:          "Bosco Ntaganda",
  #     type:          :individual,
  #     date_of_birth: "1973",
  #     country:       "CD"
  #   )
  #
  #   subject.id     # => "cust_1"
  #   subject.name   # => "Bosco Ntaganda"
  #
  # ### Why an id is the whole of what this adds
  #
  # `screen` answers about a name. Rescreening answers about *a customer*, and
  # the two are not the same question: an alert has to name the row in the
  # host's database that a compliance team is going to open, hold and
  # eventually dispose of. A book screened as bare names comes back as an
  # array somebody has to re-join by position, which works exactly until a
  # book is filtered, streamed in batches, or contains the same name twice --
  # and two customers called Jane Miller is not a corner case, it is Tuesday.
  #
  # So the id is required, it is the caller's own, and nothing here interprets
  # it. It travels onto every alert the subject produces (Rescreen::Alert), so
  # a run's output joins back to the host's records without the host having
  # kept the order it sent them in.
  #
  # ### It takes what `screen` takes
  #
  # Every evidence field a screening call accepts is accepted here, in every
  # spelling Query accepts it in -- `date_of_birth:` and `dates_of_birth:`,
  # `country:`, `countries:` and `nationalities:`, `identifier:` and
  # `identifiers:`. A subject is a query about a customer, and a caller should
  # not have to learn a second vocabulary to write one.
  #
  # The two things it refuses are the search *options* that a rescreen decides
  # for itself. `sources:` is settled by the diff being applied -- a rescreen
  # runs against one list version pair and nothing else -- and `limit:` would
  # cap the alerts a subject can raise, which is not a thing this library is
  # willing to do: an alert dropped for being eleventh is a sanctions hit
  # nobody sees. Both are refused rather than ignored, because a search option
  # that is silently dropped is a caller screening under a rule they think
  # they set.
  #
  # `threshold:` is accepted, and is the one policy knob a subject carries.
  # Risk-based screening is ordinary -- a correspondent bank at 70, a retail
  # customer at 85 -- and a book that could not express it would force a host
  # into one call per tier. Left unset, the subject is screened at whatever
  # threshold the run names. See Rescreen.
  #
  # ### Where the evidence lives
  #
  # In a Scorer::Subject, built once here, which is the same object a Query
  # holds and hands the scorer. The name is folded once, at construction, and
  # a rescreening run compares that one folded form against every changed
  # record rather than re-folding per comparison -- which is what makes
  # streaming a large book past a small diff cheap.
  #
  # Instances are frozen on construction and compare by value.
  class Subject
    extend T::Sig

    # The canonical spelling of every field, and the shape `#to_h` emits.
    #
    # @api private
    MEMBERS = T.let((%i[id] + Scorer::Subject::MEMBERS + %i[threshold]).freeze, T::Array[Symbol])

    # Search options a rescreen settles for itself. See the class comment.
    #
    # @api private
    REFUSED = T.let(
      {
        sources: "the diff being applied names the list -- a rescreen runs against one pair of list versions",
        limit: "a rescreen reports every changed record a subject matches -- an alert dropped for being " \
               "eleventh is a hit nobody sees"
      }.freeze,
      T::Hash[Symbol, String]
    )

    # The caller's own id for this subject, carried onto every alert.
    sig { returns(String) }
    attr_reader :id

    # The evidence, folded once. What the scorer compares against a record.
    sig { returns(Scorer::Subject) }
    attr_reader :evidence

    # The lowest score worth an alert for this subject, or nil to take the
    # run's. See the class comment.
    sig { returns(T.nilable(Float)) }
    attr_reader :threshold

    class << self
      extend T::Sig

      # Whatever a caller had, as a Subject:
      #
      #   Subject.build(subject)                                  # itself
      #   Subject.build(id: "cust_1", name: "Bosco Ntaganda")     # a Hash, string keys or symbol
      #
      # What a book of business is streamed through, so a host can hand this
      # library the rows it already has rather than mapping them first.
      sig { params(value: T.untyped).returns(Subject) }
      def build(value)
        case value
        when Subject then value
        when Hash then from_h(value)
        else
          raise InvalidArgument,
                "a book holds ActiveSanction::Subject or Hash entries, got #{value.class}. A rescreen reports " \
                "alerts against a caller's own id, so a bare name is not enough to raise one"
        end
      end

      # Rebuilds a subject from #to_h output, accepting string keys so a book
      # read out of a database or a JSON payload needs no translation.
      sig { params(hash: T.untyped).returns(Subject) }
      def from_h(hash)
        # `new(**hash)` past a required keyword parameter is one of the few
        # things Sorbet cannot check statically. #initialize validates what
        # arrives, which is where a bad round-trip is caught.
        T.unsafe(self).new(**hash.to_h.transform_keys { |key| key.to_s.to_sym })
      end
    end

    # `id` and `name` are required; everything else is optional, for the
    # reason Scorer::Subject gives -- most callers have a name and little
    # else, and a field absent on either side is neutral rather than a
    # conflict.
    #
    # The evidence fields are taken in any spelling Query accepts them in, and
    # resolved here rather than in a separate builder: unlike a Query, which a
    # screening call constructs on a caller's behalf, this is the object a
    # host writes out by hand, so `.new` is the door everything comes through.
    sig { params(id: T.untyped, fields: T.untyped).void }
    def initialize(id:, **fields)
      attributes = normalize(fields)
      @id = T.let(id!(id), String)
      @evidence = T.let(
        Scorer::Subject.new(name: attributes[:name], type: attributes[:type],
                            dates_of_birth: attributes[:dates_of_birth] || [],
                            nationalities: attributes[:nationalities] || [],
                            identifiers: attributes[:identifiers] || []),
        Scorer::Subject
      )
      @threshold = T.let(threshold!(attributes[:threshold]), T.nilable(Float))
      freeze
    end

    # The name as the caller wrote it, which is what an alert quotes back.
    sig { returns(String) }
    def name = evidence.name

    sig { returns(T.nilable(Symbol)) }
    def type = evidence.type

    sig { returns(T::Array[PartialDate]) }
    def dates_of_birth = evidence.dates_of_birth

    sig { returns(T::Array[String]) }
    def nationalities = evidence.nationalities

    sig { returns(T::Array[Identifier]) }
    def identifiers = evidence.identifiers

    # The folded name every comparison runs against, folded once at
    # construction. What a rescreening run hands the index rather than the
    # string it came from.
    sig { returns(Normalizer::Form) }
    def form = evidence.form

    # This subject as the screening call it is, at the threshold given or its
    # own -- which is what a MatchResult records as the question that was
    # asked. `sources:` is the list the run covers.
    sig { params(threshold: T.untyped, sources: T.untyped).returns(Query) }
    def query(threshold: nil, sources: nil)
      T.unsafe(Query).new(**evidence.to_h, sources: sources, threshold: threshold || self.threshold)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h = { id: id }.merge(evidence.to_h).merge(threshold: threshold)

    sig { params(other: T.untyped).returns(T::Boolean) }
    def ==(other)
      return false unless other.instance_of?(self.class)

      to_h == other.to_h
    end
    alias eql? ==

    sig { returns(Integer) }
    def hash = [self.class, to_h].hash

    sig { returns(String) }
    def inspect = "#<#{self.class} #{id} #{name.inspect}>"

    private

    # Symbol keys, with every spelling Query accepts resolved to its canonical
    # one -- and the two search options a rescreen settles for itself refused
    # by name rather than ignored.
    sig { params(fields: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
    def normalize(fields)
      attributes = fields.each_with_object({}) do |(key, value), resolved|
        member = Query::ALIASES.fetch(key, key)
        reason = REFUSED[member]
        raise InvalidArgument, "a Subject does not take #{member}: #{reason}" if reason

        resolved[member] = wrap(member, value)
      end
      unknown = attributes.keys - MEMBERS
      raise InvalidArgument, "unknown Subject attribute(s): #{unknown.join(", ")}" if unknown.any?

      attributes
    end

    # A single value where a collection is expected is a collection of one,
    # for the reason Query gives: `dates_of_birth: "1973"` is what a
    # caller with one date writes, and `Array(hash)` would read one identifier
    # as a list of its pairs.
    sig { params(member: Symbol, value: T.untyped).returns(T.untyped) }
    def wrap(member, value)
      return value unless Query::COLLECTIONS.include?(member)
      return value if value.nil? || value.is_a?(Array)

      [value]
    end

    # Required, and taken as the caller wrote it: an id this library edited
    # would not join back to the row it came from.
    sig { params(value: T.untyped).returns(String) }
    def id!(value)
      string = value.to_s.strip
      if string.empty?
        raise InvalidArgument,
              "a subject needs an id -- an alert has to name the record a compliance team will open, and a " \
              "book screened by position cannot survive being filtered or streamed"
      end

      -string
    end

    # nil means "whatever the run says", which is the common case and the
    # reason this is not defaulted from configuration here: a subject that
    # quietly carried the configured threshold could not be told apart from
    # one that asked for it, and the run could never override it.
    sig { params(value: T.untyped).returns(T.nilable(Float)) }
    def threshold!(value)
      return nil if value.nil?

      number = begin
        Float(value)
      rescue TypeError, ArgumentError
        raise InvalidArgument, "threshold must be a number between 0 and 100, got #{value.inspect}"
      end
      Scorer.threshold!(number)
    end
  end
end
