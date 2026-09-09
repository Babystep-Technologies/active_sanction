# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/configuration"
require "active_sanction/error"
require "active_sanction/match_result"

module ActiveSanction
  # One configured installation of this library, as an object a server can
  # hold.
  #
  #   client = ActiveSanction::Client.new(
  #     storage:    ActiveSanction::Storage::FileSystem.new(root: "/srv/sanctions"),
  #     sources:    %i[ofac_sdn un_consolidated canada_sema],
  #     user_agent: "acme-bank/1.0 (compliance@acme.example)"
  #   )
  #
  #   client.sync!
  #   client.screen(name: "Vladimir Putin", threshold: 75)
  #
  # `ActiveSanction.screen` and everything beside it are sugar over a default
  # client this module builds on first use, so a script and the README
  # quickstart never have to know this class exists. What it exists for is the
  # process that needs more than one configuration alive at once, which a
  # process-global cannot express at all:
  #
  # - **A pinned list version beside the current one.** An audit re-run has to
  #   screen against the snapshot a decision was actually made under while
  #   live traffic screens against today's. Two clients over two stores, both
  #   warm, neither reaching for the other's.
  # - **Different lists per tenant.** One customer's obligations are OFAC and
  #   the UN; another's add the EU and the UK. A client per source set, held
  #   for the life of the process.
  # - **A different publisher identity per caller**, which is the fetch half of
  #   the same thing.
  #
  # ### It is a value object with one memo
  #
  # Everything a client is asked is answered from a frozen Configuration --
  # the store, the source list, the weights, the candidate cap, the thresholds
  # a query defaults to, the User-Agent every request carries. A client's
  # settings cannot be edited after it is built. Deriving a neighbour from one
  # is what `#with` is for:
  #
  #   audit = client.with(storage: pinned_store)
  #
  # The one thing a client holds that is not settled at construction is the
  # matcher, because building one reads every stored list and indexes it --
  # seconds and tens of megabytes on a full corpus. It is built on first use
  # under a lock and then only read. See #matcher.
  #
  # ### The thread-safety contract
  #
  # **A built client and the index it has loaded are safe to screen from
  # concurrently.** `#screen`, `#screen_all`, `#matcher` and every reader here
  # may be called from as many threads as a host has; the matcher is frozen at
  # build and nothing on the query path writes to anything shared. This is the
  # guarantee a web process needs, and it is the reason the matcher is
  # replaced rather than updated.
  #
  # **`#sync!` is not concurrent-safe against readers of the same storage.**
  # It is safe to run alongside screening -- a store publishes a list whole,
  # so a thread mid-screen finishes against the version it started with, and
  # `#reload!` is what moves the next screening call onto the new one. What is
  # not supported is two syncs writing the same store at the same time, from
  # this process or another: the last writer wins per source and the losers'
  # downloads are discarded. A host that syncs from more than one process
  # needs a lock of its own around the run, not a bigger `sync_concurrency:`
  # -- that number is how many *publishers* one run fetches from at once, and
  # is safe.
  #
  # **Nothing here makes a store thread-safe that is not.** The two shipped
  # adapters are: Memory guards its hash, and FileSystem publishes a list by
  # renaming one file over another. An adapter a host wrote is held to the
  # same rule by the shared conformance group.
  class Client
    extend T::Sig

    # The settings this client answers from, frozen. Reading one is how a host
    # asks what a client is: `client.configuration.user_agent`.
    sig { returns(Configuration) }
    attr_reader :configuration

    # Where screening happened, stamped onto every result. `:local` is this
    # gem doing the work against a list on this machine; #56 introduces the
    # seam and the names of the others.
    sig { returns(Symbol) }
    attr_reader :backend

    # Takes a Configuration, or the settings to build one from, or both -- in
    # which case the settings are applied on top of a copy and the
    # configuration handed in is left alone:
    #
    #   ActiveSanction::Client.new(user_agent: "acme-bank/1.0 (compliance@acme.example)")
    #   ActiveSanction::Client.new(configuration: ActiveSanction.config)
    #   ActiveSanction::Client.new(configuration: base, sources: %i[ofac_sdn])
    #
    # Every setting `ActiveSanction.configure` takes is a keyword argument
    # here, held to exactly the same rule and failing with the same message --
    # they are the same writers. An unknown one raises ConfigurationError
    # rather than being ignored, because a misspelled setting that is silently
    # dropped is a client running on a default somebody thinks they changed.
    #
    # A configuration passed in with no overrides is frozen in place rather
    # than copied, so `ActiveSanction.config` is the object the `configure`
    # block just wrote to. That is the one visible side effect of building a
    # client, and it is the point: a settings object that can still move is
    # the thing this class exists to remove.
    sig { params(configuration: T.nilable(Configuration), backend: T.untyped, settings: T.untyped).void }
    def initialize(configuration: nil, backend: MatchResult::DEFAULT_BACKEND, **settings)
      base = configuration || Configuration.new
      @configuration = T.let((settings.empty? ? base : base.with(**settings)).freeze, Configuration)
      @backend = T.let(backend.to_s.to_sym, Symbol)
      @lock = T.let(Mutex.new, Mutex)
      @matcher = T.let(nil, T.nilable(Matcher))
    end

    # Another client with some settings changed, sharing nothing with this one
    # -- not the configuration, and not the matcher:
    #
    #   audit = client.with(storage: januarys_snapshots)
    #
    # The second client builds its own index over its own store, which is the
    # cost of the isolation and the reason this is an explicit call rather
    # than a per-query option.
    sig { params(overrides: T.untyped).returns(Client) }
    def with(**overrides)
      self.class.new(configuration: configuration.with(**overrides), backend: backend)
    end

    # Where this client's synced lists are read from and written to.
    sig { returns(Storage::Base) }
    def storage = configuration.storage

    # The lists this client syncs and screens against, or nil for every
    # registered source -- which is what an installation that has not named
    # any should get, so that a gem adding a jurisdiction takes effect without
    # an edit to the host's initializer.
    sig { returns(T.nilable(T::Array[Symbol])) }
    def sources = configuration.sources

    # This client's matcher, built from its store on first use and then held.
    #
    # Building it reads every list this client's configuration names, indexes
    # them, and takes each list's checksum from the very snapshot it indexed.
    # That costs seconds and tens of megabytes on a full corpus, so it happens
    # once, under a lock -- two threads racing to do it at boot would build
    # two indexes and throw one away.
    #
    # What comes back is immutable and safe to screen from concurrently. It is
    # never updated: a sync builds a new one, which is what `#reload!` makes
    # the next screening call do.
    sig { returns(Matcher) }
    def matcher
      @lock.synchronize do
        @matcher ||= with_configuration do
          Matcher.build(storage, sources: configuration.sources, weights: configuration.scorer_weights,
                                 candidate_limit: configuration.candidate_limit, backend: backend)
        end
      end
    end

    # Screens one name against this client's lists:
    #
    #   client.screen(name: "Vladimir Putin", type: :individual, threshold: 75)
    #
    # Sugar over #matcher, which is where everything this does is documented.
    # A query that names no threshold or limit takes this client's, not the
    # default client's.
    sig { params(query: T.untyped, overrides: T.untyped).returns(T::Array[MatchResult]) }
    def screen(query = nil, **overrides)
      built = matcher
      with_configuration { built.screen(query, **overrides) }
    end

    # A book of names against one list version, one array of results per
    # query, in the order they were given. See Matcher#screen_all.
    sig { params(queries: T.untyped, overrides: T.untyped).returns(T::Array[T::Array[MatchResult]]) }
    def screen_all(queries, **overrides)
      built = matcher
      with_configuration { built.screen_all(queries, **overrides) }
    end

    # Fetches, parses and stores this client's lists, and returns what each
    # one did:
    #
    #   report = client.sync!                   # every source this client names
    #   report = client.sync!(:ofac_sdn)        # one
    #   report = client.sync!(force: true)      # bypass conditional GET
    #
    # A failing source does not raise and does not stop the others: it is
    # captured into the report and **its previous snapshot is kept**. See
    # Sync, which is where all of that is documented, and Sync::Report.
    #
    # Drops this client's matcher when any list changed, so the next screening
    # call is answered by what was just synced. Not concurrent-safe against
    # another sync of the same storage -- see the class comment.
    sig do
      params(sources: T.untyped, options: T.untyped,
             block: T.nilable(T.proc.params(result: Sync::Result).void)).returns(Sync::Report)
    end
    def sync!(*sources, **options, &block)
      report = with_configuration do
        T.unsafe(Sync).new(sources: sources, store: storage, **options).call(&block)
      end
      reload! if report.updated.any?
      report
    end

    # What changed between two snapshots of one of this client's lists, read
    # from this client's store. See Diff.
    sig { params(source: T.untyped, options: T.untyped).returns(Diff) }
    def diff(source = nil, **options)
      with_configuration { T.unsafe(Diff).call(source, store: storage, **options) }
    end

    # Applies a snapshot diff to a book of subjects, and returns the alerts:
    #
    #   diff   = client.diff(:ofac_sdn, from: yesterdays_snapshot)
    #   alerts = client.rescreen(book, diff: diff, threshold: 75)
    #
    #   alerts.first.subject_id   # => "cust_1"
    #   alerts.first.change       # => :newly_listed
    #
    # Who a list change affects, which is the step that turns a diff into an
    # alert. Costs the book times the handful of records that moved rather
    # than the book times the whole corpus, and does not touch this client's
    # matcher -- a rescreen indexes the diff and nothing else. A host
    # streaming a large book builds one Rescreen and calls it per batch, so
    # that index is built once; see Rescreen, which is where all of it is
    # documented.
    sig do
      params(subjects: T.untyped, diff: T.untyped, options: T.untyped,
             block: T.nilable(T.proc.params(alert: Rescreen::Alert).void)).returns(T::Array[Rescreen::Alert])
    end
    def rescreen(subjects, diff:, **options, &block)
      with_configuration do
        T.unsafe(Rescreen).call(subjects, diff: diff, backend: backend, **options, &block)
      end
    end

    # Writes one of this client's lists to a portable bundle file, and returns
    # the Bundle::Header it wrote:
    #
    #   client.export(:ofac_sdn, to: "ofac_sdn.asb")
    #   client.export(:ofac_sdn, to: "ofac_sdn.asb", sign_with: private_key)
    #   client.export(snapshot,  to: "ofac_sdn.asb")   # one just synced, unstored
    #
    # The file that comes out is the unit of distribution: another machine loads
    # it with #import and screens against it without ever reaching the
    # publisher. See Snapshot::Bundle, and docs/bundle_format.md.
    sig do
      params(source: T.untyped, to: T.untyped, sign_with: T.untyped,
             generator: T.untyped).returns(Snapshot::Bundle::Header)
    end
    def export(source, to:, sign_with: nil, generator: nil)
      snapshot = source.is_a?(Snapshot) ? source : with_configuration { storage.fetch_snapshot(source) }
      ::File.open(to.to_s, "wb") do |io|
        Snapshot::Bundle.write(snapshot, io: io, sign_with: sign_with, generator: generator)
      end
    end

    # Loads a bundle into this client's store and returns the Snapshot it held:
    #
    #   client.import("ofac_sdn.asb")                        # unverified, and usable
    #   client.import("ofac_sdn.asb", verify_with: public_key)
    #
    # With a key, a bundle that was not signed by its holder raises rather than
    # being stored -- an unverified list is a fine thing to screen against, and
    # a list that failed a verification somebody asked for is not.
    #
    # Drops this client's matcher, so the next screening call is answered by
    # what was just imported.
    #
    # ### What comes back is trusted; what is stored is not
    #
    # The snapshot returned reports `trusted?` when it verified. Reading the
    # same list back out of a FileSystem or ActiveRecord store afterwards does
    # not: a signature attests to the bundle's bytes, not to the copy this gem
    # rewrote into its own layout. An installation that wants
    # `MatchResult#verified?` on its results holds the imported snapshot in
    # memory -- `client.with(storage: ActiveSanction::Storage::Memory.new)` --
    # rather than round-tripping it through a directory. See Snapshot#trusted?.
    sig { params(path: T.untyped, verify_with: T.untyped).returns(Snapshot) }
    def import(path, verify_with: nil)
      snapshot = ::File.open(path.to_s, "rb") { |io| Snapshot::Bundle.read(io, verify_with: verify_with) }
      with_configuration { storage.write_snapshot(snapshot) }
      reload!
      snapshot
    end

    # Diagnoses whether one of this client's sources has changed format,
    # against the version its store holds. Writes nothing. See Doctor.
    sig do
      params(sources: T.untyped, options: T.untyped,
             block: T.nilable(T.proc.params(diagnosis: Doctor::Diagnosis).void)).returns(Doctor::Report)
    end
    def doctor(*sources, **options, &block)
      with_configuration do
        T.unsafe(Doctor).new(sources: sources, store: storage, **options).call(&block)
      end
    end

    # Drops this client's matcher so the next screening call builds one over
    # what its store holds now. What a host calls after syncing from another
    # process -- `#sync!` calls it itself when a list changed.
    #
    # A screening call already in flight keeps the matcher it started with and
    # finishes against one consistent list version, which is what makes its
    # results re-derivable.
    sig { returns(T.self_type) }
    def reload!
      @lock.synchronize { @matcher = nil }
      self
    end

    # Whether a matcher has been built and is being held. What a host checks
    # to decide whether a screening call is about to cost an index build.
    sig { returns(T::Boolean) }
    def loaded? = !@lock.synchronize { @matcher }.nil?

    sig { returns(String) }
    def inspect
      named = sources ? T.must(sources).join(", ") : "every registered source"
      "#<#{self.class} #{named} in #{storage.class}#{" loaded" if loaded?}>"
    end

    private

    # Runs a block with this client's settings in force, so that everything
    # reached from inside it -- the fetch layer's User-Agent and timeouts, the
    # normalizer's dictionary, the XML backend, the threshold and limit a
    # query defaults to -- reads this client's numbers rather than the default
    # client's. See ActiveSanction.with_configuration, which is where the
    # mechanism and its one limit are documented.
    sig { params(block: T.proc.returns(T.untyped)).returns(T.untyped) }
    def with_configuration(&block) = ActiveSanction.with_configuration(configuration, &block)
  end
end
