# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "uri"
require "active_sanction/error"
require "active_sanction/sources"
require "active_sanction/storage"
require "active_sanction/sync/result"
require "active_sanction/sync/report"

module ActiveSanction
  # Fetch, parse and store every configured list in one run, isolating each
  # source from the others.
  #
  #   report = ActiveSanction.sync!                 # every configured source
  #   report = ActiveSanction.sync!(:ofac_sdn)      # one
  #   report = ActiveSanction.sync!(force: true)    # bypass conditional GET
  #
  #   report.failed?                                # => false
  #   report[:ofac_sdn].record_count                # => 19015
  #
  # One source at a time is Sources::Base#sync, which fetches, parses and
  # checksums, and deliberately rescues nothing. This is the layer above it:
  # what a *run* does, which is a different set of decisions.
  #
  # ### One source failing must not abort the others
  #
  # Government endpoints go down, change format without notice, and
  # occasionally serve half a file. If a UN outage stopped OFAC from syncing,
  # the library would fail exactly when it is most needed -- during an
  # incident, which is when lists move. So every source runs inside its own
  # rescue: the failure is captured into its Result, the remaining sources
  # carry on, and the run ends with a summary that says which one broke.
  #
  # StandardError and not Exception. An Interrupt or a SIGTERM is somebody
  # stopping this run on purpose, and swallowing it to go on downloading three
  # more lists is not isolation, it is a job that will not die.
  #
  # ### A failed source keeps its previous snapshot
  #
  # This is the single most important behaviour here, and it is a decision
  # about what "no data" costs. Nothing clears a source's stored list on
  # failure -- not a 500, not a parse error, not a publisher that started
  # serving HTML where XML used to be. Screening against yesterday's OFAC list
  # produces a report with a known, visible age on it; screening against an
  # empty list produces a clean report for every customer, which is the most
  # expensive thing this library can get wrong.
  #
  # That trade is only safe while the age is visible, so every Result carries
  # the age and record count of the snapshot that source is being screened
  # against now -- see Sync::Result, which is where the failure ends up.
  #
  # ### Unchanged sources cost nothing
  #
  # The launch lists change daily at most and every one of them serves ETag and
  # Last-Modified, so an hourly sync should transfer bytes once a day. A source
  # whose publisher answers 304 is never parsed and never stored: the whole
  # saving of conditional GET (#10) is that the parse -- the expensive half for
  # OFAC's three-file join -- is skipped along with the download.
  #
  # A source whose bytes changed but whose *content* hashes to what is already
  # stored is also reported unchanged and not rewritten. A publisher
  # regenerating an identical file with a new timestamp is not a new list
  # version, and rewriting tens of megabytes to say so would churn the
  # checksum every audit record cites.
  #
  # ### Optional parallelism, with a politeness limit
  #
  #   ActiveSanction.sync!(concurrency: 3)
  #
  # Sources that share a publisher are never fetched at the same time. They are
  # grouped by the host they download from and each group runs sequentially, so
  # raising concurrency fetches from more governments at once and never harder
  # from any one of them -- which matters because two of the built-in adapters
  # (OFAC SDN and OFAC Consolidated) are the same file server. The default is 1
  # and a run of four lists takes about as long as its slowest list.
  #
  # Each source is fetched by its own adapter, so nothing is shared between two
  # sources in flight except the files underneath them: the validator store is
  # one small JSON file, written by rename and resolving last-writer-wins,
  # exactly as it already does for a sync running beside a CLI command. The
  # cost of losing that race is one avoidable download on the next run, and it
  # is the reason the default is sequential rather than the reason parallelism
  # is unsafe.
  #
  # ### Where this belongs
  #
  # Syncing is a capability of the local backend (#56), not of every backend: a
  # hosted one does not sync, because data freshness is exactly what its user
  # is paying somebody else to handle, and it should say so through
  # `supports?(:sync)`. When that seam lands this becomes `Backend::Local#sync`
  # unchanged -- which is why the report is a serializable object rather than
  # console output, and why nothing here writes to `$stdout`.
  class Sync
    extend T::Sig

    # Raised by Report#success!, for a caller that wants any failure fatal.
    # Never raised by the run itself: by the time a failure is known, every
    # other source has already been fetched and stored.
    class Failed < Error
      extend T::Sig

      sig { returns(Report) }
      attr_reader :report

      sig { params(report: Report).void }
      def initialize(report)
        @report = T.let(report, Report)
        super(report.failure_message)
      end
    end

    # The adapters this run covers: classes as registered, or instances a
    # caller passed in.
    sig { returns(T::Array[T.untyped]) }
    attr_reader :sources

    sig { returns(T::Array[Symbol]) }
    attr_reader :keys

    sig { returns(T.untyped) }
    attr_reader :store

    sig { returns(T::Boolean) }
    attr_reader :force

    # How many publishers to fetch from at once. See the class comment.
    sig { returns(Integer) }
    attr_reader :concurrency

    sig { returns(T.untyped) }
    attr_reader :logger

    sig { params(options: T.untyped, block: T.untyped).returns(Report) }
    def self.call(**options, &block) = T.unsafe(self).new(**options).call(&block)

    # `sources:` takes source keys, adapter classes, adapter instances, or nil
    # for whatever `config.sources` names. A key nothing is registered under
    # raises here, before the first list is downloaded, rather than after.
    sig do
      params(sources: T.untyped, store: T.untyped, force: T::Boolean, concurrency: T.untyped,
             logger: T.untyped).void
    end
    def initialize(sources: nil, store: nil, force: false, concurrency: nil, logger: ActiveSanction.config.logger)
      @sources = T.let(resolve(sources), T::Array[T.untyped])
      @keys = T.let(@sources.map { |source| Sources::Definition.key!(source.key) }, T::Array[Symbol])
      @store = T.let(store || ActiveSanction.storage, T.untyped)
      @force = T.let(force, T::Boolean)
      @concurrency = T.let(
        Configuration.sync_concurrency!(concurrency || ActiveSanction.config.sync_concurrency), Integer
      )
      @logger = T.let(logger, T.untyped)
      @lock = T.let(Mutex.new, Mutex)
    end

    # Runs the sync and returns the Report. Never raises for a source that
    # failed -- that is what the report is for -- and does raise for anything
    # that makes the run itself impossible, such as a store that cannot be
    # written to at all.
    #
    # The optional block is the progress hook: it is called with each Result as
    # that source finishes, so a long run says something before it ends. It is
    # called under a lock, so a block that appends to an array or writes a line
    # does not have to be thread-safe to be correct under `concurrency:`.
    #
    #   ActiveSanction.sync! { |result| puts result }
    sig { params(block: T.nilable(T.proc.params(result: Result).void)).returns(Report) }
    def call(&block)
      started_at = Time.now.utc
      began = monotonic
      log_start
      work = keys.each_with_index.map { |key, at| [at, key, sources.fetch(at)] }
      results = run(work, &block).sort_by(&:first).map(&:last)
      report = Report.new(results: results, started_at: started_at, duration: elapsed(began))
      log_finish(report)
      report
    end

    sig { returns(String) }
    def inspect = "#<#{self.class} #{keys.join(", ")}#{" forced" if force} concurrency=#{concurrency}>"

    private

    sig { params(requested: T.untyped).returns(T::Array[T.untyped]) }
    def resolve(requested)
      listed = Array(requested).flatten.compact
      return Sources.enabled if listed.empty?

      listed.map { |source| adapter!(source) }
    end

    # A key is looked up in the registry; a class is left to be built inside
    # the run's rescue, so a source whose constructor raises is that source's
    # failure and not the whole run's; an instance a caller built itself is
    # used as it stands.
    sig { params(source: T.untyped).returns(T.untyped) }
    def adapter!(source)
      return Sources[source] if source.is_a?(Symbol) || source.is_a?(String)
      return source if source.respond_to?(:key) && source.respond_to?(source.is_a?(Class) ? :new : :sync)

      raise ArgumentError, "a source must be a registered key, or answer .key and .new, got #{source.inspect}"
    end

    # Groups that may run at the same time, each of which runs in order. See
    # the class comment on politeness.
    sig do
      params(work: T::Array[T.untyped], block: T.nilable(T.proc.params(result: Result).void))
        .returns(T::Array[T.untyped])
    end
    def run(work, &block)
      groups = work.group_by { |(_at, key, source)| publisher(key, source) }.values
      workers = [concurrency, groups.size].min
      return groups.flatten(1).map { |item| pair(item, &block) } if workers < 2

      queue = Queue.new
      groups.each { |group| queue << group }
      queue.close
      Array.new(workers) { Thread.new { drain(queue, &block) } }.flat_map(&:value)
    end

    sig do
      params(queue: Queue, block: T.nilable(T.proc.params(result: Result).void)).returns(T::Array[T.untyped])
    end
    def drain(queue, &block)
      collected = []
      while (group = queue.pop)
        group.each { |item| collected << pair(item, &block) }
      end
      collected
    end

    sig do
      params(item: T::Array[T.untyped], block: T.nilable(T.proc.params(result: Result).void))
        .returns(T::Array[T.untyped])
    end
    def pair(item, &block)
      at, key, source = item
      result = sync_source(key, source)
      @lock.synchronize do
        log_result(result)
        block&.call(result)
      end
      [at, result]
    end

    # One source, start to finish, inside its own rescue. Nothing in here may
    # raise past this method, and nothing in here may clear what is stored.
    sig { params(key: Symbol, source: T.untyped).returns(Result) }
    def sync_source(key, source)
      started = monotonic
      previous = T.let(nil, T.nilable(Storage::Meta))
      begin
        # What is stored is read before the adapter is built, so that a source
        # whose constructor raises still reports the snapshot it is keeping.
        previous = readable_meta(key)
        adapter = source.is_a?(Class) ? T.unsafe(source).new : source
        snapshot = adapter.sync(force: force || previous.nil?)
        return complete(key, :unchanged, previous, started) if unchanged?(previous, snapshot)

        store.write_snapshot(snapshot)
        complete(key, :updated, Storage::Meta.from_snapshot(snapshot), started)
      rescue StandardError => e
        complete(key, :failed, previous, started, e)
      end
    end

    # A publisher that answered 304, or one that served a file whose parsed
    # content is what is already stored.
    sig { params(previous: T.nilable(Storage::Meta), snapshot: T.untyped).returns(T::Boolean) }
    def unchanged?(previous, snapshot)
      snapshot.nil? || (!previous.nil? && previous.same_content?(snapshot))
    end

    sig do
      params(key: Symbol, status: Symbol, meta: T.nilable(Storage::Meta), started: Float, error: T.untyped)
        .returns(Result)
    end
    def complete(key, status, meta, started, error = nil)
      Result.new(source: key, status: status, duration: elapsed(started), record_count: meta&.record_count,
                 checksum: meta&.checksum, fetched_at: meta&.fetched_at, age: meta&.age, error: error)
    end

    # What is stored for a source, or nil -- and nil for a stored snapshot that
    # cannot be read, which is why this is not simply `store.snapshot_meta`.
    #
    # Both of those answers make the run fetch this source in full rather than
    # conditionally, and the reason is the same for each: a conditional request
    # asks the publisher whether the copy we hold is current, and we do not
    # hold one. Letting a 304 stand against a list that is missing or corrupt
    # would report a source unchanged that cannot be screened at all.
    sig { params(key: Symbol).returns(T.nilable(Storage::Meta)) }
    def readable_meta(key)
      store.snapshot_meta(key)
    rescue StandardError => e
      log(:warn, "#{key} has a stored snapshot that cannot be read (#{e.class}: #{e.message}); fetching in full")
      nil
    end

    # Which publisher a source downloads from, as the grouping key. A source
    # that cannot say -- one backed by a database table, one whose declaration
    # raises -- gets a group of its own, since there is nobody it could be
    # impolite towards.
    sig { params(key: Symbol, source: T.untyped).returns(String) }
    def publisher(key, source)
      address = source.respond_to?(:urls) ? source.urls.values.first : nil
      host = address.nil? ? nil : URI.parse(address.to_s).host
      host.nil? || host.empty? ? "source:#{key}" : host.downcase
    rescue StandardError
      "source:#{key}"
    end

    sig { returns(Float) }
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f

    sig { params(started: Float).returns(Float) }
    def elapsed(started) = (monotonic - started).round(3).to_f

    sig { void }
    def log_start
      log(:info, "syncing #{keys.size} source(s): #{keys.join(", ")}#{" (forced)" if force}" \
                 "#{", #{concurrency} publishers at a time" if concurrency > 1}")
    end

    # The line an operator greps for, and the one an on-call engineer reads at
    # three in the morning: a failure has to say what is still being screened
    # against, not merely that something broke.
    sig { params(result: Result).void }
    def log_result(result)
      message = +result.to_s
      if result.retained?
        message << "; keeping the previous snapshot of #{result.record_count} records (#{result.age_in_words})"
      elsif result.failed?
        message << "; nothing is stored for this source, so screening does not cover it"
      end
      log(result.failed? ? :warn : :info, message)
    end

    sig { params(report: Report).void }
    def log_finish(report)
      log(report.failed? ? :warn : :info, "synced #{report.summary}")
    end

    # Configuration only promises a logger that answers #info, so a failure is
    # logged at warn where the logger has one and at info where it does not --
    # rather than not at all.
    sig { params(level: Symbol, message: String).void }
    def log(level, message)
      return unless logger

      line = "[active_sanction] #{message}"
      logger.respond_to?(level) ? logger.public_send(level, line) : logger.info(line)
    end
  end
end
