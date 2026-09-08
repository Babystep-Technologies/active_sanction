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
require "active_sanction/doctor"
require "active_sanction/client"
require "active_sanction/sources/ofac_sdn"
require "active_sanction/sources/ofac_consolidated"
require "active_sanction/sources/un_consolidated"
require "active_sanction/sources/canada_sema"
require "active_sanction/sources/eu_fsf"
require "active_sanction/sources/uk_sanctions_list"
require "active_sanction/sources/australia_dfat"

module ActiveSanction
  # Guards the default client. Building one is cheap, but replacing it drops
  # a matcher that indexed every stored list, and two threads racing to
  # `configure` at boot should not each get a different one. A constant rather
  # than a memoized ivar, because a lazily created lock is not one.
  CLIENT_LOCK = T.let(Mutex.new, Mutex)
  private_constant :CLIENT_LOCK

  # Where .with_configuration keeps the settings in force. Fiber-local, which
  # is what `Thread#[]` means: two threads screening through two clients read
  # two configurations, and neither can see the other's.
  CONFIGURATION_KEY = :active_sanction_configuration
  private_constant :CONFIGURATION_KEY

  class << self
    extend T::Sig

    # The client the module-level calls answer through, built from the
    # defaults on first use so that nothing has to remember to initialize it.
    #
    #   ActiveSanction.client.screen("Vladimir Putin")   # same as ActiveSanction.screen(...)
    #
    # Everything below is sugar over this object. A process that needs two
    # configurations at once -- a pinned list version for an audit re-run
    # beside the current one for live traffic, one tenant's sources beside
    # another's -- builds its own with `Client.new` and holds them itself;
    # this one is what a script and the README quickstart use. See Client.
    sig { returns(Client) }
    def client
      CLIENT_LOCK.synchronize { @client ||= T.let(Client.new, T.nilable(Client)) }
    end

    # The settings in force: whatever .with_configuration has installed on
    # this fiber, or the default client's.
    #
    # Frozen, because it belongs to a built client. `configure` is how it is
    # changed, and it changes it by building a new client rather than by
    # editing this one -- a settings object that could move underneath a
    # running index is the thing Client exists to remove.
    sig { returns(Configuration) }
    def config = Thread.current[CONFIGURATION_KEY] || client.configuration

    # The one entry point an application is expected to call at boot:
    #
    #   ActiveSanction.configure do |c|
    #     c.user_agent = "my-app/1.0 (compliance@example.com)"
    #   end
    #
    # The block is handed a mutable copy of what is configured now, so
    # settings accumulate across calls, and the copy is frozen into a new
    # default client when the block returns. That replaces the held matcher,
    # which is the behaviour a changed store or source list needs: an
    # initializer that names a store must not leave a matcher behind that
    # indexed a different one.
    #
    # Configure at boot, before anything screens. Later is honoured from the
    # next call and does not reach what has already happened -- names folded
    # under the old dictionary are already in an index, and scores recorded
    # under the old weights were recorded under the old weights.
    sig { params(block: T.proc.params(config: Configuration).void).returns(Configuration) }
    def configure(&block)
      settings = client.configuration.dup
      block.call(settings)
      CLIENT_LOCK.synchronize { @client = T.let(Client.new(configuration: settings), T.nilable(Client)) }
      settings
    end

    # Runs a block with `configuration` in force, so that everything reached
    # from inside it reads those settings rather than the default client's.
    # This is how a Client makes its own User-Agent, dictionary, XML backend
    # and query defaults reach code that was written against the module --
    # the fetch layer, the normalizer, Query -- without every one of them
    # having to be handed a configuration it does not otherwise want.
    #
    #   ActiveSanction.with_configuration(audit_client.configuration) { ... }
    #
    # The one limit is the one every fiber-local has: **a thread started
    # inside the block does not inherit it**, and starts from the default
    # client's settings. Code that fans out has to reinstall the
    # configuration in each worker, which is what Sync does.
    sig { params(configuration: Configuration, block: T.proc.returns(T.untyped)).returns(T.untyped) }
    def with_configuration(configuration, &block)
      previous = Thread.current[CONFIGURATION_KEY]
      Thread.current[CONFIGURATION_KEY] = configuration
      block.call
    ensure
      Thread.current[CONFIGURATION_KEY] = previous
    end

    # Drops the default client and anything this fiber had installed, so the
    # next call builds one from the defaults. What a suite runs between
    # examples, and the reason a spec that configures a store does not leak it
    # into the next one:
    #
    #   config.after { ActiveSanction.reset! }
    #
    # It clears the fiber-local on the calling thread only; a thread that
    # exited holding one has already taken it with it.
    sig { returns(T.self_type) }
    def reset!
      CLIENT_LOCK.synchronize { @client = T.let(nil, T.nilable(Client)) }
      Thread.current[CONFIGURATION_KEY] = nil
      self
    end

    # Where the default client's synced lists are read from. Gzipped JSON
    # under `storage_dir` unless the application named its own -- see
    # Configuration#storage.
    sig { returns(Storage::Base) }
    def storage = client.storage

    # The default client's matcher, built from its store on first use.
    # See Client#matcher, which is where all of it is documented.
    sig { returns(Matcher) }
    def matcher = client.matcher

    # Screens one name against every configured list:
    #
    #   ActiveSanction.screen(name: "Vladimir Putin", type: :individual, threshold: 75)
    #
    # Sugar over .matcher, which is where everything this does is documented.
    sig { params(query: T.untyped, overrides: T.untyped).returns(T::Array[MatchResult]) }
    def screen(query = nil, **overrides) = client.screen(query, **overrides)

    # Screens a list of names, returning one array of results per query, in
    # the order they were given. See Matcher#screen_all.
    sig { params(queries: T.untyped, overrides: T.untyped).returns(T::Array[T::Array[MatchResult]]) }
    def screen_all(queries, **overrides) = client.screen_all(queries, **overrides)

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
    # call is answered by what was just synced. Not concurrent-safe against
    # another sync of the same storage; see Client.
    sig do
      params(sources: T.untyped, options: T.untyped,
             block: T.nilable(T.proc.params(result: Sync::Result).void)).returns(Sync::Report)
    end
    def sync!(*sources, **options, &block) = T.unsafe(client).sync!(*sources, **options, &block)

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
    def diff(source = nil, **options) = T.unsafe(client).diff(source, **options)

    # Diagnoses whether a source's format has drifted -- fetching each list,
    # parsing it, and comparing what it measures against the version that was
    # stored at the last sync:
    #
    #   report = ActiveSanction.doctor                    # every configured source
    #   report = ActiveSanction.doctor(:ofac_sdn)         # one
    #   report = ActiveSanction.doctor(tolerance: 0.05)   # report smaller movements
    #
    #   report.ok?        # => false
    #   report.findings   # => [Doctor::Finding, ...]
    #   puts report
    #   exit report.exit_code
    #
    # The failure this exists for is the one a sync cannot see: a file that
    # still parses cleanly and means something different. 19,321 entities
    # carrying zero passports looks exactly as healthy as 19,321 carrying
    # 23,429 if all anyone counts is records, and screening a passport number
    # against the first returns a clean result for somebody who is on the list.
    #
    # Nothing is written -- not the snapshot, not the payload cache, not the
    # conditional-GET validators -- so a diagnosis can never be the reason a
    # sync skipped a list that changed, and nothing here repairs anything.
    # Deciding that a 40% drop in record count is a delisting wave rather than
    # a broken parse is a judgment call this library does not make. See Doctor,
    # which is where all of that is documented.
    #
    # The block, if given, is called with each Doctor::Diagnosis as that source
    # finishes.
    sig do
      params(sources: T.untyped, options: T.untyped,
             block: T.nilable(T.proc.params(diagnosis: Doctor::Diagnosis).void)).returns(Doctor::Report)
    end
    def doctor(*sources, **options, &block) = T.unsafe(client).doctor(*sources, **options, &block)

    # Drops the shared matcher so the next screening call builds one over
    # what is stored now. What a process calls after a sync -- a matcher is
    # built once and never updated, which is what lets it be screened from
    # many threads without a lock.
    sig { returns(T.self_type) }
    def reload!
      client.reload!
      self
    end
  end
end
