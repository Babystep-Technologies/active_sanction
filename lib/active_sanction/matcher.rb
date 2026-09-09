# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "time"
require "active_sanction/error"
require "active_sanction/index"
require "active_sanction/match_result"
require "active_sanction/query"
require "active_sanction/scorer"
require "active_sanction/sources/definition"
require "active_sanction/storage"
require "active_sanction/version"

module ActiveSanction
  # The screening call, and the object a server holds.
  #
  #   matcher = ActiveSanction::Matcher.build(store)
  #
  #   results = matcher.screen(
  #     name:          "Vladimir Putin",
  #     type:          :individual,
  #     date_of_birth: "1952-10-07",
  #     countries:     %w[RU],
  #     sources:       %i[ofac_sdn un_consolidated],
  #     threshold:     75,
  #     limit:         10
  #   )
  #
  #   results.first.score        # => 97.3
  #   results.first.snapshot_id  # => "sha256:9f86d081884c7d65..."
  #
  # Stage five, and the only one with nothing after it. It runs the pipeline
  # the other four stages are: fold the query once (Normalizer), retrieve the
  # names worth comparing (Index), score each of them with reasons (Scorer),
  # then filter, sort, cap and stamp. Nothing here decides whether two names
  # are the same person; what it decides is what a caller is handed and what a
  # decision can be defended with.
  #
  # ### It is built once and then only read
  #
  # A Matcher holds an index, the checksum of every list in it, the weights it
  # scores with and the candidate cap it retrieves with. All of it is fixed at
  # construction and the object is frozen, so `screen` allocates locals and
  # touches nothing shared. A web process builds one at boot and screens from
  # every thread without a lock:
  #
  #   MATCHER = ActiveSanction::Matcher.build(store)   # in an initializer
  #   MATCHER.screen(name: params[:name])              # in a request
  #
  # **Nothing on the query path reads configuration.** That is a stronger
  # statement than thread safety and it is the one that matters for an audit:
  # a threshold, a weight or a candidate cap changed halfway through a batch
  # cannot produce a run that is half one set of numbers and half another,
  # because the numbers were read once -- into the Query, and into this.
  #
  # ### A sync does not update a matcher
  #
  # It builds a new one, and the application swaps its reference:
  #
  #   MATCHER = ActiveSanction::Matcher.build(store)   # after a sync
  #
  # A plain reassignment is enough on CRuby, where a reference assignment is
  # atomic; `Concurrent::AtomicReference` is the portable spelling. Requests
  # in flight keep the matcher they started with and finish against one
  # consistent list version, which is what makes their results re-derivable --
  # a matcher that mutated underneath a query would produce a result no
  # snapshot checksum explains. See Index, which is immutable for this reason.
  #
  # ### An empty matcher is refused rather than built
  #
  # Screening against a list that is not there returns a clean report, and a
  # clean report is the most expensive thing this library can get wrong. So a
  # store with nothing in it raises NotSynced at build, a named source that
  # has never been synced raises Storage::MissingSnapshot, and a query naming
  # a source this matcher does not hold raises rather than quietly covering
  # two of the three lists it was asked for.
  #
  # ### Where the backend seam goes
  #
  # This is the Local backend's implementation (#56): `Backend::Local#screen`
  # is this call, and a hosted backend answers the same query with the same
  # MatchResults against data somebody else keeps fresh. Which one answered is
  # on every result. What a server holds is a Client (#55) rather than one of
  # these directly, because a client is what pairs an index with the
  # configuration it was built under; this stays the object to build by hand
  # when a caller already has an index -- a spec, or a process screening one
  # name against several list versions of the same store.
  class Matcher
    extend T::Sig

    # Nothing has ever been synced, so there is nothing to screen against.
    # Separate from Storage::MissingSnapshot, which is about one named list:
    # this is an installation that has not run a sync yet, and the fix is a
    # different sentence.
    class NotSynced < StorageError; end

    # Which lists this matcher holds, and the checksum of each. The stamp on
    # every result comes from here.
    sig { returns(T::Hash[Symbol, String]) }
    attr_reader :snapshots

    # The lists in here that arrived cryptographically attested -- read from a
    # signed bundle (#57) that verified under a key this installation supplied
    # -- sorted. Usually empty, because a list this installation fetched and
    # parsed itself is not attested by anybody.
    #
    # Kept beside `snapshots` rather than folded into it because it is a fact
    # about a different thing: a checksum says which list version answered, and
    # this says who vouched for it. Every result the matcher produces carries
    # both. See MatchResult#verified?.
    sig { returns(T::Array[Symbol]) }
    attr_reader :verified

    sig { returns(Index) }
    attr_reader :index

    # What each signal was worth when this matcher was built, and what every
    # result it produces records.
    sig { returns(Scorer::Weights) }
    attr_reader :weights

    # How many names the index hands the scorer per query. See
    # Configuration::DEFAULT_CANDIDATE_LIMIT -- and note that it bounds a
    # query's `limit:` in practice, since a result cannot be returned for a
    # name that was never retrieved.
    sig { returns(Integer) }
    attr_reader :candidate_limit

    sig { returns(Symbol) }
    attr_reader :backend

    class << self
      extend T::Sig

      # A matcher over what a store holds, or over the lists named:
      #
      #   ActiveSanction::Matcher.build                          # the configured store
      #   ActiveSanction::Matcher.build(store)
      #   ActiveSanction::Matcher.build(store, sources: %i[ofac_sdn])
      #
      # Snapshots are read one at a time and each is released before the next
      # is opened, so building never holds every list in memory at once -- and
      # each list's checksum is taken from the very snapshot that was indexed,
      # rather than read separately afterwards, where a concurrent sync could
      # put a stamp on results the list no longer explains.
      #
      # `sources: nil` means whatever is stored. Naming a list that has never
      # been synced raises instead: a run that quietly covers two of the three
      # lists an application configured is indistinguishable from one that
      # covers all three, and both report the name clear.
      sig do
        params(store: T.untyped, sources: T.untyped, weights: T.untyped, candidate_limit: T.untyped,
               backend: T.untyped).returns(Matcher)
      end
      def build(store = nil, sources: nil, weights: nil, candidate_limit: nil,
                backend: MatchResult::DEFAULT_BACKEND)
        store ||= ActiveSanction.config.storage
        builder = Index::Builder.new
        checksums = T.let({}, T::Hash[Symbol, String])
        attested = T.let([], T::Array[Symbol])
        requested(store, sources).each do |key|
          snapshot = store.fetch_snapshot(key)
          checksums[key] = snapshot.checksum
          # Read off the very snapshot that was indexed, for the reason its
          # checksum is: a store asked again afterwards could answer about a
          # different list.
          attested << key if snapshot.trusted?
          snapshot.entities.each { |entity| builder.add(entity) }
        end
        new(index: builder.build, snapshots: checksums, verified: attested, weights: weights,
            candidate_limit: candidate_limit, backend: backend)
      end

      private

      # The lists to index, in a deterministic order, or the exception that
      # says why there are none.
      sig { params(store: T.untyped, sources: T.untyped).returns(T::Array[Symbol]) }
      def requested(store, sources)
        unless sources.nil?
          keys = Array(sources).map { |key| Sources::Definition.key!(key) }.uniq
          raise InvalidArgument, "sources cannot be empty -- omit it to screen every stored list" if keys.empty?

          return keys
        end

        stored = store.sources
        raise NotSynced, nothing_stored(store) if stored.empty?

        stored
      end

      sig { params(store: T.untyped).returns(String) }
      def nothing_stored(store)
        "#{store.class} holds no lists, so there is nothing to screen against and every name would come back " \
          "clear. Sync one first -- ActiveSanction::Sources[:ofac_sdn].new.sync"
      end
    end

    # Built by .build, which is what a caller almost always wants. Taken
    # directly by a caller that already has an index -- a process screening
    # one name against several list versions, or a spec.
    sig do
      params(index: Index, snapshots: T.untyped, weights: T.untyped, candidate_limit: T.untyped,
             backend: T.untyped, verified: T.untyped).void
    end
    def initialize(index:, snapshots:, weights: nil, candidate_limit: nil, backend: MatchResult::DEFAULT_BACKEND,
                   verified: nil)
      @index = index
      @snapshots = T.let(snapshots!(snapshots), T::Hash[Symbol, String])
      @verified = T.let(verified!(verified), T::Array[Symbol])
      raise NotSynced, "the lists given hold no names to screen against" if index.empty?

      @weights = T.let(Scorer::Weights.build(weights), Scorer::Weights)
      @candidate_limit = T.let(candidate_limit!(candidate_limit), Integer)
      @backend = T.let(backend.to_s.to_sym, Symbol)
      freeze
    end

    # The hits, highest score first:
    #
    #   matcher.screen(name: "Vladimir Putin", threshold: 75)
    #   matcher.screen("Vladimir Putin")            # a name and nothing else
    #   matcher.screen(query, limit: 25)            # a Query, with one option changed
    #
    # An empty array is a real answer and the common one -- most customers are
    # not on a sanctions list. It is not the same answer as an exception, and
    # everything that could make it a lie rather than a fact raises instead:
    # see the note on an empty matcher above.
    #
    # ### One result per entity, not per name
    #
    # An entity is retrieved once for every one of its names the query looks
    # like, and its score is the best of those names (see Scorer). So each
    # entity is scored once and reported once, in the alias that won.
    #
    # ### The order is re-derivable
    #
    # Score descending, and equal scores by list and then entity id. Ties are
    # not a corner case on this corpus -- a query matching two records of the
    # same name scores them identically -- and which one is listed first has
    # to be the same answer in a year's time.
    sig { params(query: T.untyped, overrides: T.untyped).returns(T::Array[MatchResult]) }
    def screen(query = nil, **overrides)
      run(Query.build(query, **overrides), Time.now.utc)
    end

    # A book of names against one list version:
    #
    #   matcher.screen_all(["Vladimir Putin", "Gazprom"], threshold: 80)
    #   matcher.screen_all(customers.map { |c| { name: c.name, dob: c.born_on } })
    #
    # Index-aligned: the nth element is the nth query's results, and it is an
    # empty array for a name that hit nothing. Deliberately not keyed by name
    # -- a batch of customers contains the same name twice often enough, and a
    # Hash would silently screen one of them and report both.
    #
    # Every result in the batch carries one `screened_at`, because a batch is
    # one screening run: a rescreening of a customer book against a new list
    # version is a single event in an audit trail, not ten thousand of them a
    # microsecond apart.
    sig { params(queries: T.untyped, overrides: T.untyped).returns(T::Array[T::Array[MatchResult]]) }
    def screen_all(queries, **overrides)
      raise QueryError, "screen_all takes an Array of queries, got #{queries.class}" unless queries.is_a?(Array)

      screened_at = Time.now.utc
      queries.map { |query| run(Query.build(query, **overrides), screened_at) }
    end

    # The lists this matcher screens against, sorted.
    sig { returns(T::Array[Symbol]) }
    def sources = snapshots.keys.sort

    # The checksum of the list version this matcher holds for a source, or nil
    # for one it does not. Named for the Backend contract (#56), where every
    # backend has to be able to answer it or reproducibility breaks at the
    # seam.
    sig { params(source: T.untyped).returns(T.nilable(String)) }
    def snapshot_id(source) = snapshots[Sources::Definition.key!(source)]

    # Whether the list this matcher holds for a source was attested. What every
    # result off that list records.
    sig { params(source: T.untyped).returns(T::Boolean) }
    def verified?(source) = verified.include?(Sources::Definition.key!(source))

    # How many names are screened against. Names rather than entities -- see
    # Index#size.
    sig { returns(Integer) }
    def size = index.size

    sig { returns(String) }
    def inspect = "#<#{self.class} #{size} names from #{sources.join(", ")}>"

    private

    # One query, at one instant. Everything `screen` and `screen_all` share.
    sig { params(query: Query, screened_at: Time).returns(T::Array[MatchResult]) }
    def run(query, screened_at)
      held!(query)
      # The same stamp on every result the run produces: one query, one set of
      # weights, one instant, one backend. Only the snapshot checksum varies,
      # and only because a run may cover several lists.
      stamp = { query: query, weights: weights, backend: backend, screened_at: screened_at }
      scored(query)
        .sort_by { |result| [-result.score, result.source.to_s, result.entity.id] }
        .first(query.limit)
        .map do |result|
          MatchResult.from_scorer(result, snapshot_id: snapshots.fetch(result.source),
                                          verified: verified.include?(result.source), **stamp)
        end
    end

    # Every entity the index retrieved, scored once.
    #
    # An entity reached through two of its names is one hit and not two, and
    # the scorer already takes the maximum over an entity's names, so the
    # second candidate would recompute the answer the first one gave. Rejected
    # entities are remembered as nil for the same reason: a common given name
    # retrieves the same record under several spellings, and rescoring one
    # that has already failed the threshold is the most expensive way to
    # arrive at the same no.
    sig { params(query: Query).returns(T::Array[Scorer::Result]) }
    def scored(query)
      seen = T.let({}, T::Hash[[Symbol, String], T.nilable(Scorer::Result)])
      index.candidates(query.form, limit: candidate_limit, sources: query.sources).each do |candidate|
        # Keyed by list as well as id, because the same person really is two
        # records when two governments list them, and both belong in a report.
        key = [candidate.source, candidate.entity.id]
        next if seen.key?(key)

        seen[key] = Scorer.call(query.subject, candidate, weights: weights, threshold: query.threshold)
      end
      seen.values.compact
    end

    # A query may only name lists this matcher actually holds. Screening
    # against a list that is not here returns fewer hits and no signal that it
    # did, which reads exactly like a clean report.
    sig { params(query: Query).void }
    def held!(query)
      missing = (query.sources || []) - snapshots.keys
      return if missing.empty?

      raise Storage::MissingSnapshot,
            "this matcher does not hold #{missing.join(", ")}. It screens #{sources.join(", ")} -- " \
            "rebuild it over the lists you meant, and sync any that have never been fetched"
    end

    sig { params(value: T.untyped).returns(T::Hash[Symbol, String]) }
    def snapshots!(value)
      checksums = value.to_h { |source, checksum| [Sources::Definition.key!(source), -checksum.to_s] }
      raise NotSynced, "a matcher needs at least one list to screen against" if checksums.empty?

      blank = checksums.select { |_, checksum| checksum.empty? }.keys
      raise InvalidArgument, "no snapshot checksum for #{blank.join(", ")}" if blank.any?

      checksums.freeze
    end

    # Only lists this matcher actually holds, sorted. A source named here that
    # is not in `snapshots` is a caller building a stamp out of a list nothing
    # was screened against.
    sig { params(value: T.untyped).returns(T::Array[Symbol]) }
    def verified!(value)
      keys = Array(value).map { |source| Sources::Definition.key!(source) }.uniq.sort
      missing = keys - snapshots.keys
      raise InvalidArgument, "verified names #{missing.join(", ")}, which this matcher does not hold" if missing.any?

      keys.freeze
    end

    sig { params(value: T.untyped).returns(Integer) }
    def candidate_limit!(value)
      return ActiveSanction.config.candidate_limit if value.nil?

      integer = begin
        Integer(value)
      rescue TypeError, ArgumentError
        raise InvalidArgument, "candidate_limit must be a whole number of names, got #{value.inspect}"
      end
      raise InvalidArgument, "candidate_limit must be at least 1, got #{integer}" unless integer.positive?

      integer
    end
  end
end
