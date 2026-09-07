# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"
require "active_sanction/version"
require "active_sanction/configuration"
require "active_sanction/name"
require "active_sanction/address"
require "active_sanction/identifier"
require "active_sanction/partial_date"
require "active_sanction/entity"
require "active_sanction/snapshot"
require "active_sanction/http_client"
require "active_sanction/validators"
require "active_sanction/validator_store"
require "active_sanction/fetcher"
require "active_sanction/payload_cache"
require "active_sanction/parsers"
require "active_sanction/sources"
require "active_sanction/storage"
require "active_sanction/normalizer"
require "active_sanction/similarity"
require "active_sanction/phonetics"
require "active_sanction/index"
require "active_sanction/country"
require "active_sanction/scorer"
require "active_sanction/query"
require "active_sanction/match_result"
require "active_sanction/matcher"
require "active_sanction/sync"
require "active_sanction/diff"
require "active_sanction/sources/ofac_sdn"
require "active_sanction/sources/ofac_consolidated"
require "active_sanction/sources/un_consolidated"
require "active_sanction/sources/canada_sema"
require "active_sanction/sources/eu_fsf"

module ActiveSanction
  # Guards the memoized matcher. Building one indexes every stored list, so
  # two threads racing to do it at boot is worth a lock; a constant rather
  # than a memoized ivar because a lazily created lock is not one. See
  # .matcher.
  MATCHER_LOCK = T.let(Mutex.new, Mutex)
  private_constant :MATCHER_LOCK

  class << self
    extend T::Sig

    # Library-wide settings. Reading this before anything is configured builds
    # the defaults, so nothing has to remember to initialize it.
    sig { returns(Configuration) }
    def config
      @config ||= T.let(Configuration.new, T.nilable(Configuration))
    end

    # The one entry point an application is expected to call at boot:
    #
    #   ActiveSanction.configure do |c|
    #     c.user_agent = "my-app/1.0 (compliance@example.com)"
    #   end
    sig { params(block: T.proc.params(config: Configuration).void).returns(Configuration) }
    def configure(&block)
      block.call(config)
      config
    end

    # Mostly for tests, which need each example to start from the defaults
    # rather than from whatever the last one set. Drops the memoized matcher
    # too: it holds the weights, the candidate cap and the store that the
    # configuration it was built under named.
    sig { returns(Configuration) }
    def reset_configuration!
      @config = T.let(nil, T.nilable(Configuration))
      reload!
      config
    end

    # Where synced lists are read from. Gzipped JSON under `storage_dir`
    # unless the application named its own -- see Configuration#storage.
    sig { returns(Storage::Base) }
    def storage = config.storage

    # The shared matcher, built from the configured store on first use.
    #
    # Building it reads every stored list and indexes it, which takes seconds
    # and tens of megabytes on a full corpus, so it happens once and is held.
    # The result is immutable and safe to screen from concurrently -- see
    # Matcher.
    #
    # A process that needs two configurations at once -- a pinned list version
    # for an audit re-run beside the current one for live traffic, one tenant's
    # sources beside another's -- builds its own matchers with
    # `Matcher.build(store, sources: ...)` and holds them itself. That is what
    # Client (#55) turns into a first-class object; this is the sugar a script
    # and the README quickstart use.
    sig { returns(Matcher) }
    def matcher
      MATCHER_LOCK.synchronize do
        @matcher ||= T.let(Matcher.build(storage, sources: config.sources), T.nilable(Matcher))
      end
    end

    # Screens one name against every configured list:
    #
    #   ActiveSanction.screen(name: "Vladimir Putin", type: :individual, threshold: 75)
    #
    # Sugar over .matcher, which is where everything this does is documented.
    sig { params(query: T.untyped, overrides: T.untyped).returns(T::Array[MatchResult]) }
    def screen(query = nil, **overrides) = matcher.screen(query, **overrides)

    # Fetches, parses and stores every configured list, and returns what each
    # one did:
    #
    #   report = ActiveSanction.sync!                   # every configured source
    #   report = ActiveSanction.sync!(:ofac_sdn)        # one
    #   report = ActiveSanction.sync!(force: true)      # bypass conditional GET
    #   report = ActiveSanction.sync!(concurrency: 3)   # fetch three publishers at once
    #
    #   report.failed?                                  # => false
    #   report[:ofac_sdn].status                        # => :updated
    #   exit report.exit_code                           # 1 if any source failed
    #
    # A failing source does not raise and does not stop the others: it is
    # captured into the report and **its previous snapshot is kept**, because
    # yesterday's list with a visible age is safer than no list. See Sync,
    # which is where all of that is documented, and Sync::Report.
    #
    # The block, if given, is called with each Sync::Result as that source
    # finishes -- the progress hook for a run that takes minutes.
    #
    # Drops the shared matcher when any list changed, so the next screening
    # call is answered by what was just synced. A process holding its own
    # matcher rebuilds it instead; see .matcher.
    sig do
      params(sources: T.untyped, options: T.untyped,
             block: T.nilable(T.proc.params(result: Sync::Result).void)).returns(Sync::Report)
    end
    def sync!(*sources, **options, &block)
      report = T.unsafe(Sync).new(sources: sources, **options).call(&block)
      reload! if report.updated.any?
      report
    end

    # What changed between two snapshots of one source:
    #
    #   diff = ActiveSanction.diff(:ofac_sdn, from: last_months_snapshot, to: todays_snapshot)
    #   diff = ActiveSanction.diff(:ofac_sdn, from: last_months_snapshot)  # `to:` is what is stored now
    #
    #   diff.added     # => [Entity], newly listed
    #   diff.removed   # => [Entity], delisted
    #   diff.modified  # => [Diff::Change], amended, with the fields that moved
    #   diff.changed   # => [Entity], what to re-screen a book of business against
    #
    # So that re-screening runs against the eleven records that moved rather
    # than against the whole list. A first sync -- `from: nil` -- is a baseline
    # rather than a list of additions, and an amended record reports as one
    # modification rather than as a delisting and a new listing. See Diff,
    # which is where all of that is documented.
    sig { params(source: T.untyped, options: T.untyped).returns(Diff) }
    def diff(source = nil, **options) = T.unsafe(Diff).call(source, **options)

    # Screens a list of names, returning one array of results per query, in
    # the order they were given. See Matcher#screen_all.
    sig { params(queries: T.untyped, overrides: T.untyped).returns(T::Array[T::Array[MatchResult]]) }
    def screen_all(queries, **overrides) = matcher.screen_all(queries, **overrides)

    # Drops the shared matcher so the next screening call builds one over
    # what is stored now. What a process calls after a sync -- a matcher is
    # built once and never updated, which is what lets it be screened from
    # many threads without a lock.
    sig { returns(T.self_type) }
    def reload!
      MATCHER_LOCK.synchronize { @matcher = T.let(nil, T.nilable(Matcher)) }
      self
    end
  end
end
