# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "time"
require "active_sanction/diff"
require "active_sanction/error"
require "active_sanction/index"
require "active_sanction/match_result"
require "active_sanction/scorer"
require "active_sanction/subject"
require "active_sanction/rescreen/alert"

module ActiveSanction
  # Who a list change affects. Screening answers about a name; this answers
  # about a book of business.
  #
  #   book = [
  #     ActiveSanction::Subject.new(id: "cust_1", name: "Bosco Ntaganda", date_of_birth: "1973"),
  #     ActiveSanction::Subject.new(id: "cust_2", name: "Jane Miller")
  #   ]
  #
  #   diff   = ActiveSanction.diff(:ofac_sdn, from: yesterdays_snapshot)
  #   alerts = ActiveSanction.rescreen(book, diff: diff, threshold: 75)
  #
  #   alerts.first.subject_id      # => "cust_1"
  #   alerts.first.change          # => :newly_listed
  #   alerts.first.result          # => a full MatchResult, with its explanation
  #   alerts.first.previous_score  # => nil, or what it scored before
  #
  # ### Why this is the primitive rather than a nightly full screen
  #
  # Screening a customer once is a checkbox. The obligation is ongoing:
  # somebody cleared last month may be listed today, and a delisting matters
  # just as much, because it is the entry that lets a customer back through
  # the door. That is recurring work, and the naive way to do it -- every
  # subject against every record, every night -- costs the whole book times
  # the whole corpus and stops being nightly somewhere around a few thousand
  # customers.
  #
  # A rescreen costs the whole book times *the handful of records that moved*.
  # Diff (#35) computes what changed in the list; this computes who that
  # change affects, and it is the step that turns a diff into an alert. On a
  # typical day an OFAC diff is a few dozen records, so the index built here
  # is a few dozen names rather than 46,000 -- see the numbers in the README.
  #
  # ### It is built once and then only read
  #
  # A Rescreen holds an index over the records the diff names, both versions
  # of each amended one, the weights it scores with and the threshold it
  # defaults to. All of it is fixed at construction and the object is frozen,
  # so a large book is streamed past one of these, in batches, from as many
  # threads as a host has:
  #
  #   rescreening = ActiveSanction::Rescreen.new(diff: diff, threshold: 75)
  #   customers.find_each(batch_size: 1_000) do |batch|
  #     rescreening.call(batch) { |alert| AlertRecord.create!(alert.to_h) }
  #   end
  #
  # Nothing about a book is held: subjects are read one at a time and only
  # alerts are kept, so memory is a function of how much moved rather than of
  # how many customers there are. The block is what makes even that bounded --
  # it is called with each alert as it is raised, and a host that writes them
  # out as they arrive never accumulates the array at all.
  #
  # ### It does not touch the matcher
  #
  # A rescreen builds its own index, over the diff, and never reads the store
  # or the client's matcher. That is the point: applying a diff to a book must
  # not cost an index build over the whole corpus, and a host that has never
  # screened anything in this process can rescreen without paying for one.
  #
  # ### An empty diff does no work at all
  #
  # A sync that changed nothing, or a first sync -- which is a baseline rather
  # than a list of 19,015 additions, see Diff -- yields no alerts and scores
  # nothing. Not one subject is folded. A host that syncs hourly and
  # rescreens after each sync is paying for the hours that moved, which is
  # what makes rescreening after every sync affordable.
  #
  # ### What it does not do
  #
  # It reports the changes; it does not remember them. There is no alert
  # store, no deduplication against what was raised yesterday, and no
  # disposition -- see the note on case management in the README. Two runs
  # over the same diff produce the same alerts, which is the property that
  # makes them re-derivable and the reason a host, not this library, owns the
  # queue they go into.
  #
  # It also cannot find what was already there. A subject who matched a record
  # that did not change is not in a diff at all, and no rescreen will report
  # them: the first screening run against a book is a deliberate full screen
  # (`Client#screen_all`), and this is what keeps it current afterwards.
  class Rescreen
    extend T::Sig

    # The diff being applied, which is what the alerts are about.
    sig { returns(Diff) }
    attr_reader :diff

    # The lowest score worth an alert, for a subject that does not name its
    # own. Read once, at construction, so a configuration changed mid-run
    # cannot produce a book screened half one way.
    sig { returns(Float) }
    attr_reader :threshold

    # What each signal was worth for this run, and what every result it
    # produces records.
    sig { returns(Scorer::Weights) }
    attr_reader :weights

    # How many names the index hands the scorer per subject. It does not bind
    # on a typical diff -- a few dozen records cannot exceed it -- and is here
    # for the day a publisher reissues a whole list under new ids.
    sig { returns(Integer) }
    attr_reader :candidate_limit

    sig { returns(Symbol) }
    attr_reader :backend

    # Sugar, and what ActiveSanction.rescreen calls:
    #
    #   ActiveSanction::Rescreen.call(book, diff: diff, threshold: 75)
    #
    # Builds a Rescreen and applies it once. A host streaming a book in
    # batches builds one with .new and calls it per batch instead, so the
    # index is built once rather than per batch.
    sig do
      params(subjects: T.untyped, diff: T.untyped, options: T.untyped,
             block: T.nilable(T.proc.params(alert: Alert).void)).returns(T::Array[Alert])
    end
    def self.call(subjects, diff:, **options, &block)
      T.unsafe(self).new(diff: diff, **options).call(subjects, &block)
    end

    sig do
      params(diff: T.untyped, threshold: T.untyped, weights: T.untyped, candidate_limit: T.untyped,
             backend: T.untyped).void
    end
    def initialize(diff:, threshold: nil, weights: nil, candidate_limit: nil,
                   backend: MatchResult::DEFAULT_BACKEND)
      @diff = T.let(diff!(diff), Diff)
      @threshold = T.let(threshold!(threshold), Float)
      @weights = T.let(Scorer::Weights.build(weights), Scorer::Weights)
      @candidate_limit = T.let(candidate_limit!(candidate_limit), Integer)
      @backend = T.let(backend.to_s.to_sym, Symbol)
      @versions = T.let(versions, T::Hash[String, T::Array[T.untyped]])
      @fields = T.let(amended, T::Hash[String, T::Array[Symbol]])
      # Both versions of an amended record are indexed, because a subject may
      # have matched only the alias that was taken away.
      @index = T.let(Index.build(@versions.values.flatten.compact), Index)
      freeze
    end

    # The alerts this diff raises against this book, highest score first
    # within each subject and in the order the subjects arrived:
    #
    #   rescreening.call(book)
    #   rescreening.call(book) { |alert| queue.push(alert) }
    #
    # `subjects` is anything that responds to `each`, so an Enumerator over a
    # database cursor is streamed rather than materialized. Each entry is a
    # Subject or the Hash one is built from.
    #
    # Every alert in a run carries one `screened_at`, because a rescreening
    # of a book against a new list version is a single event in an audit
    # trail rather than ten thousand of them a microsecond apart. A host that
    # calls this once per batch is running one event per batch, which is the
    # honest description of what it did.
    sig do
      params(subjects: T.untyped, block: T.nilable(T.proc.params(alert: Alert).void)).returns(T::Array[Alert])
    end
    def call(subjects, &block)
      return [] if diff.empty?

      screened_at = Time.now.utc
      alerts = T.let([], T::Array[Alert])
      each(subjects) do |value|
        found(Subject.build(value), screened_at).each do |alert|
          block&.call(alert)
          alerts << alert
        end
      end
      alerts
    end

    # The list this run is about, taken from the diff.
    sig { returns(Symbol) }
    def source = diff.source

    # How many records moved, which is what a run costs per subject.
    sig { returns(Integer) }
    def size = diff.size

    # Nothing moved, so nothing can be affected. See the class comment.
    sig { returns(T::Boolean) }
    def empty? = diff.empty?

    sig { returns(String) }
    def inspect = "#<#{self.class} #{source} #{size} changed records at #{threshold}>"

    private

    # The alerts one subject raises, highest score first and then by record
    # id, so that two runs over the same diff and the same book produce the
    # same output in the same order.
    sig { params(subject: Subject, screened_at: Time).returns(T::Array[Alert]) }
    def found(subject, screened_at)
      cutoff = subject.threshold || threshold
      readings = candidates(subject).filter_map { |id| compare(subject, id, cutoff) }
      return [] if readings.empty?

      query = subject.query(threshold: cutoff, sources: [source])
      readings.map { |reading| alert(subject, reading, query, screened_at) }
              .sort_by { |raised| [-(raised.score || T.must(raised.previous_score)), raised.entity_id] }
    end

    # The records worth scoring this subject against: the same retrieval stage
    # a screening call uses, over a corpus the size of the diff. An entity
    # reached through two of its names, or through both versions of itself, is
    # one record to compare and not two.
    sig { params(subject: Subject).returns(T::Array[String]) }
    def candidates(subject)
      @index.candidates(subject.form, limit: candidate_limit).map { |candidate| candidate.entity.id }.uniq
    end

    # What this subject scores against both versions of one record, or nil
    # when it reaches the threshold against neither -- which is the answer for
    # nearly every pair and is why the cutoff is passed to the scorer rather
    # than applied afterwards. See Scorer on what a threshold buys.
    sig { params(subject: Subject, id: String, cutoff: Float).returns(T.nilable(T::Array[T.untyped])) }
    def compare(subject, id, cutoff)
      previous, current = @versions.fetch(id)
      before = score(subject, previous, cutoff)
      after = score(subject, current, cutoff)
      return nil if before.nil? && after.nil?

      change = if before.nil? then :newly_listed
               elsif after.nil? then :delisted
               else :details_changed
               end
      # The side that did not clear is scored again without a cutoff, so an
      # alert can say a subject moved from 71 to 94 rather than only that it
      # now matches. Reached once per alert, which is why it is affordable.
      [id, change, before || score(subject, previous, 0.0), after || score(subject, current, 0.0)]
    end

    sig { params(subject: Subject, entity: T.untyped, cutoff: Float).returns(T.nilable(Scorer::Result)) }
    def score(subject, entity, cutoff)
      return nil if entity.nil?

      Scorer.call(subject.evidence, entity, weights: weights, threshold: cutoff)
    end

    sig do
      params(subject: Subject, reading: T::Array[T.untyped], query: Query, screened_at: Time).returns(Alert)
    end
    def alert(subject, reading, query, screened_at)
      id, change, before, after = reading
      Alert.new(
        subject: subject, change: change, fields: @fields.fetch(id, []),
        result: stamp(after, diff.to.checksum, query, screened_at),
        previous_result: stamp(before, T.must(diff.from).checksum, query, screened_at),
        snapshot_id: diff.to.checksum, previous_snapshot_id: T.must(diff.from).checksum
      )
    end

    # One scored record as the audit object it has to be, stamped with the
    # checksum of the list version it was scored against -- which is the whole
    # of why an alert holds two of these rather than one score and a delta.
    sig do
      params(result: T.nilable(Scorer::Result), snapshot_id: String, query: Query,
             screened_at: Time).returns(T.nilable(MatchResult))
    end
    def stamp(result, snapshot_id, query, screened_at)
      return nil if result.nil?

      MatchResult.from_scorer(result, query: query, snapshot_id: snapshot_id, weights: weights,
                                      screened_at: screened_at, backend: backend)
    end

    sig { params(subjects: T.untyped, block: T.proc.params(value: T.untyped).void).void }
    def each(subjects, &block)
      unless subjects.respond_to?(:each)
        raise InvalidArgument,
              "a book of subjects has to be enumerable, got #{subjects.class}. An Array, or anything that " \
              "responds to #each -- an Enumerator over a database cursor is streamed rather than materialized"
      end

      subjects.each(&block)
    end

    # Every record the diff names, by id, as a pair: how the old list had it
    # and how the new list has it. A record that was added has no first half
    # and one that was withdrawn has no second, and an amended one has both --
    # which is what lets a single comparison produce a score on either side of
    # the change. The three sets are disjoint, because a diff joins its two
    # snapshots by id.
    sig { returns(T::Hash[String, T::Array[T.untyped]]) }
    def versions
      found = T.let({}, T::Hash[String, T::Array[T.untyped]])
      diff.removed.each { |entity| found[entity.id] = [entity, nil].freeze }
      diff.added.each { |entity| found[entity.id] = [nil, entity].freeze }
      diff.modified.each { |change| found[change.id] = [change.previous, change.entity].freeze }
      found.freeze
    end

    sig { params(value: T.untyped).returns(Float) }
    def threshold!(value) = Scorer.threshold!(value || ActiveSanction.config.screening_threshold)

    sig { params(value: T.untyped).returns(Integer) }
    def candidate_limit!(value) = Integer(value || ActiveSanction.config.candidate_limit)

    # Which fields moved, per amended record, so an alert can say whether a
    # subject's status changed because the list did or because the record did.
    sig { returns(T::Hash[String, T::Array[Symbol]]) }
    def amended = diff.modified.to_h { |change| [change.id, change.fields] }.freeze

    # A baseline diff is empty, so `from` is present on every diff that can
    # raise an alert -- which is what lets an alert cite both checksums. The
    # check is here rather than at the alert, where the missing one would read
    # as a bug in this class.
    sig { params(value: T.untyped).returns(Diff) }
    def diff!(value)
      raise InvalidArgument, "diff must be an ActiveSanction::Diff, got #{value.class}" unless value.is_a?(Diff)
      return value if value.empty? || value.from

      raise InvalidArgument, "a rescreen needs both list versions to cite, and this diff has no `from`"
    end
  end
end
