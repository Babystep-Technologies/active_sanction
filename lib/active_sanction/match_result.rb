# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "time"
require "active_sanction/entity"
require "active_sanction/name"
require "active_sanction/query"
require "active_sanction/version"
require "active_sanction/scorer/reason"
require "active_sanction/scorer/weights"

module ActiveSanction
  # One hit, and everything needed to defend it years later.
  #
  #   result = ActiveSanction.screen(name: "Vladimir Putin", type: :individual).first
  #
  #   result.score            # => 97.3
  #   result.entity.id        # => "ofac_sdn:36320"
  #   result.matched_name     # => the specific Name that produced the score
  #   result.source           # => :ofac_sdn
  #   result.explanation      # => [Reason, ...], summing to the score
  #   result.snapshot_id      # => "sha256:9f86d081884c7d65..."
  #   result.matcher_version  # => "1"
  #   result.verified?        # => false, unless the list came from a signed bundle
  #   result.screened_at      # => 2026-09-06 11:04:02 UTC
  #
  # ### This is the most permanent object in the library
  #
  # Everything else here is a step in a pipeline. This is what leaves the
  # library and goes into a customer's audit record, and it is read by people
  # who do not have this process, this configuration, or this version of the
  # gem -- an examiner asking in 2029 why a payment was cleared in 2026. So it
  # serializes to a documented shape, `from_h` rebuilds it losslessly from
  # that shape, and every field that could have changed the answer is on it.
  #
  # ### The reproducibility stamp
  #
  # Four fields make a past decision re-derivable, and each of them is a way
  # the same query could score differently today:
  #
  # - **`snapshot_id`** -- the checksum (#8) of the exact list version that
  #   answered, for the source this hit came from. Publishers overwrite their
  #   files in place, so "the OFAC list" is not a thing that can be cited; a
  #   checksum is.
  # - **`matcher_version`** -- see Matcher::VERSION. Which pipeline scored it.
  # - **`weights`** -- what each signal was worth. A host that retunes
  #   `dob_conflict` changes what every past decision would score today, and a
  #   record that did not say which numbers it was made under could not be
  #   told apart from one that would score the same.
  # - **`query`** -- what was screened, and under what threshold and limit. A
  #   record that says what was found but not what was asked is half an
  #   answer: a hit at 78 means one thing under a threshold of 75 and cannot
  #   have existed under 85.
  #
  # `backend` is the fifth, and it is here for #56: a hosted backend answers
  # the same call against data somebody else keeps fresh, and an audit record
  # has to say which one answered.
  #
  # `verified` is the sixth, and it is the only one about *provenance* rather
  # than about scoring: whether the list this hit came off was a signed bundle
  # (#57) that checked out under a key this installation holds. See #verified?.
  #
  # ### Constructible without the local scorer, on purpose
  #
  # `.from_scorer` is the convenience the Local backend uses. `.new` takes
  # every field outright, and that is the seam: a hosted backend deserializes
  # what a service returned and builds one of these directly. If this were
  # constructible only from a Scorer::Result, the two products would already
  # have two result types.
  #
  # What both routes are held to is the invariant the explanation carries --
  # `score` is the sum of the reasons, rounded once, and a `score:` passed in
  # that disagrees with them is refused rather than stored. A remote scorer
  # that has drifted from its own explanation is exactly the thing this
  # library must not launder into an audit record.
  #
  # Instances are frozen on construction and compare by value.
  class MatchResult
    extend T::Sig

    # Canonical member order, matching the layout #to_h produces and the
    # documented JSON shape.
    #
    # @api private
    MEMBERS = T.let(
      %i[score entity matched_name explanation query weights snapshot_id matcher_version backend verified
         screened_at].freeze,
      T::Array[Symbol]
    )

    # Where screening happened. `:local` is this gem doing the work against a
    # list on this machine; #56 introduces the seam and the names of the
    # others.
    #
    # @api private
    DEFAULT_BACKEND = T.let(:local, Symbol)

    # 0..100, one decimal place, and equal to the sum of the explanation.
    sig { returns(Float) }
    attr_reader :score

    sig { returns(Entity) }
    attr_reader :entity

    # The specific spelling that produced the score, as its publisher wrote
    # it. Usually an alias -- OFAC ships more of those than primary names --
    # and a report that quoted the primary name instead would be describing a
    # comparison that never happened.
    sig { returns(Name) }
    attr_reader :matched_name

    # Never empty, and it adds up. See Scorer::Reason.
    sig { returns(T::Array[Scorer::Reason]) }
    attr_reader :explanation

    # What was screened, and what the run was willing to return.
    sig { returns(Query) }
    attr_reader :query

    # What each signal was worth when this was scored.
    sig { returns(Scorer::Weights) }
    attr_reader :weights

    # The checksum of the list version this hit came off.
    sig { returns(String) }
    attr_reader :snapshot_id

    sig { returns(String) }
    attr_reader :matcher_version

    sig { returns(Symbol) }
    attr_reader :backend

    # Whether the list this hit came off was cryptographically attested: it was
    # loaded from a signed bundle (#57) that verified under a public key the
    # installation supplied. False for a list this installation fetched and
    # parsed itself, which is not a lesser answer -- it is a different claim.
    #
    # The sixth field of the reproducibility stamp, and the only one that is
    # about where the data came from rather than about how it was scored. "We
    # screened against OFAC" and "we screened against the OFAC bundle Treasury's
    # mirror signed on 28 August" are different sentences in front of an
    # examiner, and a result that could not tell them apart would leave the
    # difference to somebody's memory.
    sig { returns(T::Boolean) }
    def verified? = @verified

    # UTC, truncated to the second, which is the precision #to_h serializes.
    sig { returns(Time) }
    attr_reader :screened_at

    class << self
      extend T::Sig

      # A scored candidate, stamped with the run that produced it. What
      # Matcher builds every result with.
      sig do
        params(result: Scorer::Result, query: Query, snapshot_id: T.untyped, weights: Scorer::Weights,
               screened_at: T.untyped, backend: T.untyped, matcher_version: T.untyped,
               verified: T.untyped).returns(MatchResult)
      end
      def from_scorer(result, query:, snapshot_id:, weights:, screened_at: nil, backend: DEFAULT_BACKEND,
                      matcher_version: nil, verified: false)
        new(entity: result.entity, matched_name: result.name, explanation: result.explanation,
            score: result.score, query: query, weights: weights, snapshot_id: snapshot_id,
            screened_at: screened_at, backend: backend, matcher_version: matcher_version, verified: verified)
      end

      # Rebuilds a result from #to_h output, accepting string keys so a record
      # survives the round-trip through JSON and back out of whatever a host
      # stored it in.
      sig { params(hash: T.untyped).returns(MatchResult) }
      def from_h(hash)
        attributes = hash.to_h.transform_keys(&:to_sym)
        unknown = attributes.keys - MEMBERS
        raise InvalidArgument, "unknown MatchResult attribute(s): #{unknown.join(", ")}" if unknown.any?

        # `new(**hash)` past required keyword parameters is one of the few
        # things Sorbet cannot check statically. #initialize validates what
        # arrives -- including, here, the score against its explanation --
        # which is where a bad round-trip is caught.
        T.unsafe(self).new(**attributes, **objects(attributes))
      end

      private

      # The members that are objects rather than scalars, rebuilt. Only the
      # ones actually present: a record missing one has to reach #initialize
      # missing it, so the error names the field rather than describing a nil.
      sig { params(attributes: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
      def objects(attributes)
        {
          entity: build(Entity, attributes[:entity]),
          matched_name: build(Name, attributes[:matched_name]),
          query: build(Query, attributes[:query]),
          explanation: Array(attributes[:explanation]).map { |value| build(Scorer::Reason, value) }
        }.select { |member, _| attributes.key?(member) }
      end

      # A value that is already the object passes through, so from_h is safe
      # to call on a half-deserialized hash.
      sig { params(klass: T.untyped, value: T.untyped).returns(T.untyped) }
      def build(klass, value) = value.is_a?(Hash) ? klass.from_h(value) : value
    end

    # `score` is derived, not supplied. Passing it -- which is what .from_h
    # does with a stored record -- asserts what the explanation should come
    # to, and construction fails if it does not.
    sig do
      params(entity: T.untyped, matched_name: T.untyped, explanation: T.untyped, query: T.untyped,
             weights: T.untyped, snapshot_id: T.untyped, score: T.untyped, matcher_version: T.untyped,
             backend: T.untyped, verified: T.untyped, screened_at: T.untyped).void
    end
    def initialize(entity:, matched_name:, explanation:, query:, weights:, snapshot_id:, score: nil,
                   matcher_version: nil, backend: DEFAULT_BACKEND, verified: false, screened_at: nil)
      @entity = T.let(instance!(:entity, Entity, entity), Entity)
      @matched_name = T.let(instance!(:matched_name, Name, matched_name), Name)
      @explanation = T.let(explanation!(explanation), T::Array[Scorer::Reason])
      @query = T.let(query!(query), Query)
      @weights = T.let(Scorer::Weights.build(weights), Scorer::Weights)
      @snapshot_id = T.let(string!(:snapshot_id, snapshot_id), String)
      @matcher_version = T.let(string!(:matcher_version, matcher_version || MATCHER_VERSION), String)
      @backend = T.let(symbol!(:backend, backend || DEFAULT_BACKEND), Symbol)
      @verified = T.let(verified == true, T::Boolean)
      @screened_at = T.let(time!(screened_at), Time)
      @score = T.let(score!(score), Float)
      freeze
    end

    # The list this hit came from, which every result has to name. Read off
    # the entity rather than stored beside it: a source that could disagree
    # with the record it describes is a field nobody can trust.
    sig { returns(Symbol) }
    def source = entity.source

    # The threshold this run was willing to report at, which is half of what
    # makes a hit -- or the absence of one -- mean anything.
    sig { returns(Float) }
    def threshold = query.threshold

    # The reasons that lowered the score, which is the half of an explanation
    # a reviewer clearing an alert reads first.
    sig { returns(T::Array[Scorer::Reason]) }
    def penalties = explanation.select(&:penalty?)

    # The documented shape. Every value is a String, a Float, an Integer, an
    # Array or a Hash of the same, so `JSON.generate(result.to_h)` needs
    # nothing from this library and `MatchResult.from_h(JSON.parse(json))`
    # rebuilds exactly this object.
    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h
      {
        score: score,
        entity: entity.to_h,
        matched_name: matched_name.to_h,
        explanation: explanation.map(&:to_h),
        query: query.to_h,
        weights: weights.to_h,
        snapshot_id: snapshot_id,
        matcher_version: matcher_version,
        backend: backend,
        verified: verified?,
        screened_at: screened_at.iso8601
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
    def inspect = "#<#{self.class} #{score} #{matched_name.value.inspect} (#{entity.id}) #{snapshot_id}>"

    private

    sig { params(member: Symbol, klass: T.untyped, value: T.untyped).returns(T.untyped) }
    def instance!(member, klass, value)
      return value if value.is_a?(klass)

      raise InvalidArgument, "#{member} must be an #{klass}, got #{value.class}"
    end

    sig { params(value: T.untyped).returns(Query) }
    def query!(value)
      return Query.build(value) unless value.nil?

      raise InvalidArgument, "query is required -- a hit that cannot say what was screened is half a record"
    end

    sig { params(value: T.untyped).returns(T::Array[Scorer::Reason]) }
    def explanation!(value)
      reasons = Array(value)
      raise InvalidArgument, "a result needs at least one reason -- the score is the explanation" if reasons.empty?

      reasons.each { |reason| instance!(:explanation, Scorer::Reason, reason) }
      reasons.dup.freeze
    end

    # The score is the sum of the rounded contributions rather than the
    # rounded sum -- the same arithmetic Scorer::Result does, so a result
    # rebuilt from JSON comes to the number that was stored.
    sig { params(supplied: T.untyped).returns(Float) }
    def score!(supplied)
      computed = explanation.sum(&:contribution).round(Scorer::Reason::PRECISION).to_f
      return computed if supplied.nil? || Float(supplied).round(Scorer::Reason::PRECISION) == computed

      raise InvalidArgument,
            "score #{supplied} is not what this explanation comes to (#{computed}). The score is the sum of " \
            "the reasons, so a result whose reasons no longer explain it cannot be built"
    end

    sig { params(member: Symbol, value: T.untyped).returns(String) }
    def string!(member, value)
      string = value.to_s.strip
      raise InvalidArgument, "#{member} is required" if string.empty?

      -string
    end

    sig { params(member: Symbol, value: T.untyped).returns(Symbol) }
    def symbol!(member, value) = string!(member, value).to_sym

    # Truncated to the second, the precision #to_h serializes, so a result
    # read back is equal to the one that was written.
    sig { params(value: T.untyped).returns(Time) }
    def time!(value)
      time = case value
             when nil then Time.now
             when Time then value
             when String then Time.parse(value)
             else raise InvalidArgument, "screened_at is not a time: #{value.inspect}"
             end
      Time.at(time.to_i).utc
    end
  end
end
