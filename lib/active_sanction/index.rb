# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  # Which names are worth comparing at all. Stage 2 of the matching pipeline,
  # and the difference between a library a service can call and one it cannot.
  #
  #   index = ActiveSanction::Index.build(ActiveSanction.storage)
  #   index.size                                  # => 46_218
  #
  #   index.candidates("Abu Abbas").first.name.value   # => "ABBAS, Abu"
  #   index.candidates("Abu Abbas", limit: 50).size    # => 50
  #
  # ### Why an index rather than a scan
  #
  # The corpus is roughly 46,000 searchable name strings. Running the scorers
  # over all of them costs a few hundred milliseconds per query in pure Ruby,
  # which is fine for one call and hopeless for a service. Narrowing to a few
  # hundred first is what puts a screening call in the ~10 ms range, and every
  # cost decision in Similarity was made on the assumption that this stage
  # exists.
  #
  # ### Recall is this stage's whole job
  #
  # A name this does not retrieve is never compared to anything. It cannot
  # score badly; it does not appear. There is no later stage that can recover
  # it and no signal to a caller that it happened -- a missed hit and a clean
  # screening look identical from outside. So the bias here is the opposite of
  # the scorers': retrieve generously, rank roughly, and let #32 be the one
  # that says no.
  #
  # That is also why the cap is the dangerous part of this file. It is the one
  # place a true match can be dropped silently, which is why `Candidate#weight`
  # is exposed, why the default is set from a measured recall curve rather than
  # a round number, and why the specs check recall against deliberately
  # damaged queries rather than checking that retrieval merely works.
  #
  # ### One recall gap worth knowing about
  #
  # A query carrying *part* of a legal form is the one shape the recall
  # harness found this stage weak on. `PUBLIC JOINT STOCK COMPANY GAZPROM` is
  # indexed as `gazprom`, because the fold strips the legal form as a phrase;
  # a query of `Gazprom Public Joint Stock` keeps all four words, since the
  # phrase is not there to be matched. The query then looks more like every
  # other long company name than like the short one it actually named, and the
  # right entity can fall outside the cap -- about one in five, where every
  # other damaged query shape measured above 0.99.
  #
  # It belongs to the fold rather than to the ranking, and is recorded here
  # because this is where it shows up. Nothing in this file can fix it: an
  # index can only look up what the fold produced.
  #
  # ### Three feature spaces, unioned
  #
  # Tokens, character trigrams and Double Metaphone keys -- see Features for
  # what each is for and where each fails. A query is described the same way,
  # and any name sharing any feature is a candidate.
  #
  # ### Ranking: rarity, and then length
  #
  # A name is a vector over the three feature spaces, each feature weighted by
  # how rare it is -- `idf = log(1 + N/df)`, where `df` is how many indexed
  # names carry the feature and `N` is how many there are -- and a candidate's
  # weight is the cosine between its vector and the query's.
  #
  # **Rarity** is the first half, and this corpus is why. A quarter of the
  # individuals on these lists share a handful of given names: `mohammed` is
  # carried by thousands of names and says almost nothing about which one you
  # meant, while a surname carried by two says nearly everything. Counting
  # shared features equally would let a query for `Mohammed Al-Zawahiri` fill
  # its candidate set with strangers called Mohammed and push the one Zawahiri
  # off the end of the cap -- a false negative produced by a ranking choice,
  # which is the worst way to produce one.
  #
  # **Length** is the second half, and it is not optional. Rarity alone is a
  # sum, and a sum rewards having many features to add up: a query of four
  # tokens carries about thirty trigrams, and twenty middling ones agreeing
  # beat one rare token agreeing, however much rarer that token is. Measured
  # rather than supposed -- it is what a recall harness caught this ranking
  # doing, retrieving two hundred long organization names ahead of the short
  # one the query actually named.
  #
  # Dividing by each side's norm is what fixes it, and it is the ordinary
  # cosine: a candidate is measured on the *fraction* of itself the query
  # accounts for, not on how much of it there is. A short name matched
  # entirely outranks a long name matched partly, which is the behaviour a
  # screening query wants.
  #
  # Together they also settle the three feature spaces against each other
  # without a table of hand-set weights, which is the other thing a
  # sum-of-counts cannot do.
  #
  # ### The cost of a query is bounded on purpose
  #
  # Walking a posting list is cheap per entry and there are lists with tens of
  # thousands of entries in them. A query that walked every list it matched
  # would spend most of its time on the features that tell it the least --
  # exactly the ones the ranking is about to score near zero.
  #
  # So features are walked rarest first and stop at POSTINGS_BUDGET. What is
  # dropped is always the least informative thing available, the rarest
  # feature is always walked however common the query is, and the budget is
  # what makes a query's cost a function of the cap rather than of how
  # ordinary the name is. `Vladimir` and `Mohammed` cost the same as `Zawahiri`.
  #
  # ### Immutable, so a service can share one
  #
  # Everything here is frozen: the entries, the posting lists, the arrays
  # inside them. A built index has no method that changes it, which is why a
  # web process can hand the same one to every thread without a lock and why
  # `candidates` can be called concurrently.
  #
  # A sync does not update an index. It builds a new one and the application
  # swaps its reference:
  #
  #   INDEX = Concurrent::AtomicReference.new(ActiveSanction::Index.build(store))
  #   # after a sync
  #   INDEX.set(ActiveSanction::Index.build(store))
  #
  # A plain `@index = ...` is enough on CRuby, where a reference assignment is
  # atomic. Requests in flight keep the index they started with and finish
  # against a consistent view of one list version, which is what makes a
  # screening decision re-derivable: an index that mutated underneath a query
  # would produce a result no snapshot checksum explains.
  #
  # @api private
  class Index
    extend T::Sig

    # How many postings a query may walk before it stops adding features.
    #
    # Measured rather than chosen. Over a full-size corpus, 5,000 is the first
    # budget at which a published name and an inverted one are both found
    # every time, and raising it to 50,000 moves a typo's recall from 0.993 to
    # 0.997 while the median query goes from 1.7 ms to 3.5 and the 99th
    # percentile from 2.3 ms to 10.0. Lowering it to 2,500 starts losing names
    # that were being found.
    #
    # The features a larger budget buys are the ones the cosine is about to
    # weigh at nearly nothing, which is why it buys latency and almost no
    # recall. `rake benchmark:index` prints that sweep and is how to take the
    # numbers again on another machine.
    POSTINGS_BUDGET = T.let(5_000, Integer)

    # Entries, in the order they were indexed. The posting lists hold
    # positions in this array.
    sig { returns(T::Array[Entry]).checked(:tests) }
    attr_reader :entries

    # An index over every entity in a store, or over any enumerable of them:
    #
    #   ActiveSanction::Index.build(ActiveSanction.storage)
    #   ActiveSanction::Index.build(store, sources: %i[ofac_sdn])
    #   ActiveSanction::Index.build(snapshot.entities)
    #
    # A store is streamed rather than materialized -- see Storage::Base#each_entity,
    # which exists for this -- so building never holds every snapshot open at
    # once.
    sig { params(source: T.untyped, sources: T.untyped).returns(Index).checked(:tests) }
    def self.build(source, sources: nil)
      builder = Builder.new
      each_entity(source, sources) { |entity| builder.add(entity) }
      builder.build
    end

    sig { params(source: T.untyped, sources: T.untyped, block: T.proc.params(entity: T.untyped).void).void }
    def self.each_entity(source, sources, &block)
      return source.each_entity(sources: sources, &block) if source.respond_to?(:each_entity)
      return source.each(&block) if source.respond_to?(:each)

      raise InvalidArgument,
            "cannot index #{source.class}: expected a storage adapter or an enumerable of entities"
    end
    private_class_method :each_entity

    # Built by Builder, and the arguments are its internals: this takes
    # ownership of them and freezes them.
    sig do
      params(entries: T::Array[Entry], tokens: T::Hash[String, T::Array[Integer]],
             trigrams: T::Hash[String, T::Array[Integer]], phonetics: T::Hash[String, T::Array[Integer]])
        .void.checked(:tests)
    end
    def initialize(entries:, tokens:, trigrams:, phonetics:)
      @entries = T.let(entries.freeze, T::Array[Entry])
      @tokens = T.let(seal(tokens), T::Hash[String, T::Array[Integer]])
      @trigrams = T.let(seal(trigrams), T::Hash[String, T::Array[Integer]])
      @phonetics = T.let(seal(phonetics), T::Hash[String, T::Array[Integer]])
      @norms = T.let(norms.freeze, T::Array[Float])
      freeze
    end

    # The names worth comparing to this one, most promising first.
    #
    #   index.candidates("Abu Abbas")
    #   index.candidates(form, limit: 500, sources: %i[ofac_sdn])
    #
    # A String is folded here, under `type:` when the caller knows what kind
    # of entity it is asking about -- which matters, because the fold's
    # stoplists depend on it. A Form that has already been folded is taken as
    # it stands, which is what a caller screening one name against several
    # indexes should pass.
    #
    # `sources:` filters before the cap rather than after it. Filtering a
    # capped list would silently return fewer names than asked for, and would
    # do it precisely when the corpus is largest.
    #
    # An empty result means no indexed name shares a single token, trigram or
    # phonetic key with the query. That is a real answer -- a name in a script
    # nothing in the corpus is written in, most often -- and not an error.
    sig do
      params(query: T.untyped, limit: T.nilable(Integer), type: T.nilable(Symbol), sources: T.untyped)
        .returns(T::Array[Candidate]).checked(:tests)
    end
    def candidates(query, limit: nil, type: nil, sources: nil)
      form = query.is_a?(Normalizer::Form) ? query : Normalizer.call(query, type: type)
      return [] if form.empty? || entries.empty?

      walked = lists(form)
      weights = accumulate(walked)
      weights = keep(weights, sources) if sources
      top(cosine(weights, walked), limit || ActiveSanction.config.candidate_limit)
    end

    # How many names are indexed. Names rather than entities: an entity with
    # six aliases is six of these, because a comparison happens against one
    # spelling at a time.
    sig { returns(Integer).checked(:tests) }
    def size = entries.size

    sig { returns(T::Boolean).checked(:tests) }
    def empty? = entries.empty?

    # What the index is made of, for an operator endpoint and for the
    # benchmark. Distinct features per space, and how many postings each holds
    # -- which together are most of what the memory is.
    sig { returns(T::Hash[Symbol, Integer]).checked(:tests) }
    def stats
      {
        names: entries.size,
        entities: entries.map { |entry| entry.entity.id }.uniq.size,
        tokens: @tokens.size,
        trigrams: @trigrams.size,
        phonetics: @phonetics.size,
        postings: [@tokens, @trigrams, @phonetics].sum { |space| space.sum { |_, ids| ids.size } }
      }
    end

    sig { returns(String) }
    def inspect = "#<#{self.class} #{size} names>"

    private

    sig { params(postings: T::Hash[String, T::Array[Integer]]).returns(T::Hash[String, T::Array[Integer]]) }
    def seal(postings)
      postings.each_value(&:freeze)
      postings.freeze
    end

    # How much name each entry is, in the same units its features are weighted
    # in: the length of its own vector. Computed once at build, because it
    # cannot be computed before every posting list is complete -- a feature's
    # rarity is a property of the finished corpus -- and because dividing by it
    # is the difference between ranking a name and ranking its length.
    sig { returns(T::Array[Float]) }
    def norms
      squares = Array.new(@entries.size, 0.0)
      [@tokens, @trigrams, @phonetics].each do |space|
        space.each_value do |ids|
          square = idf(ids.size)**2
          ids.each { |id| squares[id] += square }
        end
      end
      squares.map! { |square| Math.sqrt(square) }
    end

    # What one feature carried by `df` of the corpus's names is worth.
    sig { params(document_frequency: Integer).returns(Float) }
    def idf(document_frequency) = Math.log(1.0 + (@entries.size / document_frequency.to_f))

    # The posting lists this query will actually walk, rarest first, stopping
    # at the budget. The first one is always taken: a query made entirely of
    # common features still has to return something.
    sig { params(form: Normalizer::Form).returns(T::Array[T::Array[Integer]]) }
    def lists(form)
      found = [[@tokens, Features.tokens(form)], [@trigrams, Features.trigrams(form)],
               [@phonetics, Features.phonetics(form)]]
              .flat_map { |space, features| features.filter_map { |feature| space[feature] } }
              .sort_by(&:size)
      walked = 0
      found.take_while do |ids|
        keep = walked.zero? || walked + ids.size <= POSTINGS_BUDGET
        walked += ids.size
        keep
      end
    end

    # The un-normalized half of the cosine: for every candidate, the sum of
    # `idf**2` over the features it shares with the query.
    #
    # The weight is computed once per posting list rather than once per
    # posting, which matters: this loop runs tens of thousands of times per
    # query, and a logarithm inside it would be most of the cost of a
    # screening call.
    sig { params(lists: T::Array[T::Array[Integer]]).returns(T::Hash[Integer, Float]) }
    def accumulate(lists)
      weights = Hash.new(0.0)
      lists.each do |ids|
        square = idf(ids.size)**2
        ids.each { |id| weights[id] += square }
      end
      weights
    end

    # The other half: divide by both vectors' lengths.
    #
    # The query's norm is the same for every candidate and cannot change the
    # order, but it is applied anyway, because it is what makes the result a
    # cosine in 0..1 -- a number that means the same thing from one query to
    # the next, rather than one that quietly scales with how long a name
    # somebody typed.
    #
    # It is taken over the features actually walked rather than every feature
    # the query has, so that a candidate agreeing with all of them scores
    # exactly 1.0. What the budget dropped was not compared and does not
    # belong in the denominator.
    sig { params(weights: T::Hash[Integer, Float], lists: T::Array[T::Array[Integer]]).returns(T::Hash[Integer, Float]) }
    def cosine(weights, lists)
      query_norm = Math.sqrt(lists.sum { |ids| idf(ids.size)**2 })
      return weights if query_norm.zero?

      weights.each do |id, weight|
        norm = @norms.fetch(id) * query_norm
        # Clamped because a name matching a query exactly divides its own norm
        # by itself, and floating point makes that 1.0000000000000002 often
        # enough to matter to anything comparing against 1.
        cosine = norm.positive? ? weight / norm : 0.0
        weights[id] = [cosine, 1.0].min
      end
    end

    sig { params(weights: T::Hash[Integer, Float], sources: T.untyped).returns(T::Hash[Integer, Float]) }
    def keep(weights, sources)
      wanted = Array(sources).to_set { |source| Sources::Definition.key!(source) }
      weights.select { |id, _| wanted.include?(entries.fetch(id).source) }
    end

    # The heaviest `limit`, and a deterministic order among equals.
    #
    # Ties are not a corner case here, they are most of the list: every name
    # that matched the query on the same features scores exactly the same
    # Float, so the cap usually falls inside a group of equals. Which of them
    # gets in has to be the same answer in a year's time -- a screening
    # decision is re-derived during an audit -- so equals are ordered by id,
    # which is the order the publisher listed them in.
    #
    # Sorting the whole thing by `[-weight, id]` says that in one line and
    # costs about eight milliseconds a query, because comparing two-element
    # arrays is a method call per comparison and there are tens of thousands
    # of comparisons. So the k-th weight is found first, which is a C-level
    # scan; everything above it is a list shorter than the cap, and everything
    # equal to it is settled by taking the smallest ids. Same answer, about a
    # tenth of the time.
    sig { params(weights: T::Hash[Integer, Float], limit: Integer).returns(T::Array[Candidate]) }
    def top(weights, limit)
      return [] if weights.empty?

      # Non-nil because `weights` is not empty, which is the line above.
      cutoff = T.must(weights.values.max(limit).last)
      above, tied = weights.keys.partition { |id| weights.fetch(id) > cutoff }
      chosen = above.sort_by { |id| [-weights.fetch(id), id] } + tied.min(limit - above.size)
      chosen.map { |id| Candidate.new(entry: entries.fetch(id), weight: weights.fetch(id)) }
    end
  end
end

require "active_sanction/index/features"
require "active_sanction/index/entry"
require "active_sanction/index/candidate"
require "active_sanction/index/builder"
