# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"
require "active_sanction/instrumentation"
require "active_sanction/normalizer"
require "active_sanction/scorer/weights"
require "active_sanction/version"

module ActiveSanction
  # Library-wide settings, set once at boot:
  #
  #   ActiveSanction.configure do |c|
  #     c.user_agent = "my-app/1.0 (compliance@example.com)"
  #   end
  #
  # The fetch layer's settings live here, plus which sources a sync runs,
  # where they are stored, and the thresholds a screening call defaults to.
  # Every value has a working default, so an application that configures
  # nothing still runs -- the point of `configure` is that a caller *can*
  # identify itself, not that it must recite the whole schema.
  class Configuration
    extend T::Sig

    # OFAC returns 403 to a request with no User-Agent, so this cannot be nil.
    # The default identifies the library and points at its source, which is
    # what a publisher watching its logs actually wants; applications should
    # still override it with their own contact address, because a publisher
    # that needs to reach whoever is hammering an endpoint can only reach the
    # gem's repository otherwise.
    DEFAULT_USER_AGENT = T.let(
      -"active_sanction/#{VERSION} (+https://github.com/Babystep-Technologies/active_sanction)", String
    )

    # Generous by list-download standards: these are government file servers
    # redirecting to blob storage, and a 126 MB XML body arrives in bursts with
    # real gaps between them. The read timeout is per-read, not per-request, so
    # it does not cap how long a large download may take overall.
    DEFAULT_OPEN_TIMEOUT = T.let(10, Numeric)

    # Seconds to wait for the next chunk of a body, not for the whole of one.
    DEFAULT_READ_TIMEOUT = T.let(60, Numeric)

    # OFAC's download URLs 302 to blob storage, one hop. Five leaves room for
    # a publisher to add a vanity domain or a region redirect without a release
    # of this gem, and still stops a redirect chain from becoming a crawl.
    DEFAULT_MAX_REDIRECTS = T.let(5, Integer)

    # Three attempts total for a transient failure. Sanctions syncs are batch
    # work with no user waiting on them, but they are also not worth an hour of
    # a government server's patience.
    DEFAULT_MAX_RETRIES = T.let(2, Integer)

    # Seconds before the first retry, doubling on each one after it.
    DEFAULT_RETRY_BACKOFF = T.let(1.0, Numeric)

    # Cache validators and raw payloads live under here. The XDG base directory
    # is the right default for data a user is entitled to delete: everything
    # here is recoverable by fetching again, with one honest caveat -- once a
    # publisher overwrites its file the previous payload is gone, whether or
    # not this directory still holds a copy. PayloadCache is a bounded aid to
    # re-parsing and auditing, not the system of record; storage (#24) is.
    #
    # @api private
    XDG_CACHE_HOME = T.let("XDG_CACHE_HOME", String)

    # The directory this gem takes for itself under whichever cache root wins.
    DEFAULT_CACHE_DIRNAME = T.let("active_sanction", String)

    # Where Storage::FileSystem (#24) keeps parsed snapshots. Deliberately not
    # under `cache_dir`, and the difference is the whole distinction between
    # the two directories: everything under `~/.cache` is recoverable by
    # fetching again and a user is entitled to delete it, while a stored
    # snapshot is the system of record -- once a publisher overwrites its file,
    # the list version a past decision was screened against exists only here.
    DEFAULT_STORAGE_DIRNAME = T.let(".active_sanction", String)

    # How many raw payloads PayloadCache keeps per source. Three is enough to
    # diff a suspicious list against the two that came before it, and small
    # enough that a cache directory does not quietly grow by 126 MB a day. An
    # installation that must keep every version it ever screened against wants
    # its own retention storage, not a bigger number here.
    DEFAULT_RETAIN_PAYLOADS = T.let(3, Integer)

    # How many publishers a sync fetches from at once. One, because these are
    # government file servers with nobody waiting on the result, and a library
    # that opens four connections to Treasury by default is a library that gets
    # a jurisdiction's operators asking who we are. Raising it fetches from
    # more publishers at a time and never harder from any one of them -- Sync
    # groups sources by the host they download from and runs each group in
    # order -- so the number is a bound on how many governments are being asked
    # at once, not on how fast any one of them is asked.
    DEFAULT_SYNC_CONCURRENCY = T.let(1, Integer)

    # How far one of Doctor's measurements may move from what it was at the
    # last sync before the run says so. A tenth, because these lists move by
    # single-digit percentages between syncs -- a designation round is dozens
    # of records against tens of thousands -- while the changes this is looking
    # for halve a fill rate. Tightening it finds drift sooner and reports more
    # of the movement that is just the list changing; loosening it does the
    # reverse, and a diagnostic nobody reads because it always says something
    # is worse than one that says slightly less.
    DEFAULT_DOCTOR_TOLERANCE = T.let(0.10, Float)

    # The launch lists change roughly daily at most, so a source last confirmed
    # within a day is not worth asking about again when a caller is only trying
    # to decide whether a sync is due. This is what #stale? measures against;
    # it does not cap how long a cached copy may be used, which is the calling
    # application's policy to set.
    DEFAULT_STALE_AFTER = T.let(86_400, T.nilable(Numeric))

    # Which XML library the XML toolkit parses with. REXML is stdlib, needs no
    # build step, and -- the part that decides it -- gives every installation
    # the same answer. Snapshot checksums a list's parsed content and a
    # screening decision has to be re-derivable months later, so the parser
    # must not be chosen by whether the host app happened to load Nokogiri.
    #
    #   c.xml_backend = :nokogiri   # libxml2, for a host parsing OFAC's 126 MB XML
    #
    # See Parsers::XmlRecords::Backends for the contract a backend implements.
    DEFAULT_XML_BACKEND = T.let(:rexml, Symbol)

    # How many names the index (#31) hands the scorer per query.
    #
    # 200 is where the recall curve flattens on this corpus, and a
    # deliberately damaged query still finds its own name inside the first
    # handful. Raising it buys precision nothing -- the scorer already sees
    # everything that could clear a threshold -- and spends milliseconds a
    # service does not have.
    #
    # What it costs is the scorer's cost, and that depends on the threshold
    # rather than on this number alone: 200 candidates is roughly 16 ms of
    # comparison under YJIT at a threshold of 75 and roughly 46 ms with no
    # threshold at all, because the early exits are what stop the expensive
    # comparisons running on candidates that cannot clear. See
    # Scorer::NameScore, and `rake benchmark:scorer`.
    DEFAULT_CANDIDATE_LIMIT = T.let(200, Integer)

    # The lowest score a screening call reports, on the scorer's 0..100 scale.
    #
    # 75 is where the scorer's own table separates the two things it has to
    # separate. An inverted name blends to 90.4 and a company named by half
    # its words to 84.2 -- both true matches, both reported. `kim jong un`
    # against `kim yong chol` blends to 54.8, and a query of one common given
    # name against a full listed name lands in the high seventies with nothing
    # but the name agreeing, which is why the identifiers exist and why this
    # is a floor rather than a verdict.
    #
    # It is also most of what a screening call costs. Everything a threshold
    # turns off is a comparison that could not have changed the answer -- see
    # Scorer::NameScore -- so 75 is roughly a third of the work of screening
    # with no threshold at all, and returns the same scores.
    DEFAULT_SCREENING_THRESHOLD = T.let(75.0, Float)

    # How many results a screening call returns, highest score first.
    #
    # Ten is a review queue rather than a report: a human clears alerts one at
    # a time, and a call that returned every name over the threshold would
    # bury the one that matters under the fifty that share a given name. A
    # caller writing an investigation tool rather than an onboarding check
    # raises it per query.
    DEFAULT_SCREENING_LIMIT = T.let(10, Integer)

    # Which lists a sync runs, by key. nil means every registered source,
    # which is what an application that has not thought about it should get:
    # requiring an explicit list would mean a gem adding a jurisdiction had no
    # way to take effect without an edit to the host app's initializer.
    DEFAULT_SOURCES = T.let(nil, T.nilable(T::Array[Symbol]))

    sig { returns(String) }
    attr_reader :user_agent

    # Seconds. Numeric rather than Integer because the writers run every value
    # through Float(), so a timeout set to 2.5 stays 2.5.
    sig { returns(Numeric) }
    attr_reader :open_timeout

    sig { returns(Numeric) }
    attr_reader :read_timeout

    sig { returns(Integer) }
    attr_reader :max_redirects

    sig { returns(Integer) }
    attr_reader :max_retries

    sig { returns(Numeric) }
    attr_reader :retry_backoff

    sig { returns(String) }
    attr_reader :cache_dir

    sig { returns(String) }
    attr_reader :storage_dir

    sig { returns(Integer) }
    attr_reader :retain_payloads

    # nil disables the staleness clock entirely -- see #stale_after=.
    sig { returns(T.nilable(Numeric)) }
    attr_reader :stale_after

    # nil means every registered source. Keys are not resolved here; see
    # #sources=.
    sig { returns(T.nilable(T::Array[Symbol])) }
    attr_reader :sources

    sig { returns(Symbol) }
    attr_reader :xml_backend

    # See DEFAULT_DOCTOR_TOLERANCE. A per-run `tolerance:` overrides it.
    sig { returns(Float) }
    attr_reader :doctor_tolerance

    # See DEFAULT_SYNC_CONCURRENCY. A per-run `concurrency:` overrides it.
    sig { returns(Integer) }
    attr_reader :sync_concurrency

    # See DEFAULT_CANDIDATE_LIMIT. A per-query `limit:` overrides it.
    sig { returns(Integer) }
    attr_reader :candidate_limit

    # See DEFAULT_SCREENING_THRESHOLD. A per-query `threshold:` overrides it.
    sig { returns(Float) }
    attr_reader :screening_threshold

    # See DEFAULT_SCREENING_LIMIT. A per-query `limit:` overrides it.
    sig { returns(Integer) }
    attr_reader :screening_limit

    # The token lists the normalizer strips per entity type. Defaults to the
    # shipped ones; see #normalizer_dictionary= and Normalizer::Dictionary.
    sig { returns(Normalizer::Dictionary) }
    attr_reader :normalizer_dictionary

    # What each signal the scorer reads is worth. See #scorer_weights=.
    sig { returns(Scorer::Weights) }
    attr_reader :scorer_weights

    # Anything Logger-shaped, which is what #logger= checks for and all this
    # library ever asks of it. Declaring `::Logger` would make a host's
    # wrapper, a Rails logger broadcast or a test spy a type error rather than
    # the perfectly good logger each of them is.
    sig { returns(T.untyped) }
    attr_reader :logger

    # Anything answering `#call(event)`, or nil for the default, which is that
    # nothing is listening. See #instrumenter= and Instrumentation.
    sig { returns(T.untyped) }
    attr_reader :instrumenter

    sig { void }
    def initialize
      @user_agent = T.let(DEFAULT_USER_AGENT, String)
      @open_timeout = T.let(DEFAULT_OPEN_TIMEOUT, Numeric)
      @read_timeout = T.let(DEFAULT_READ_TIMEOUT, Numeric)
      @max_redirects = T.let(DEFAULT_MAX_REDIRECTS, Integer)
      @max_retries = T.let(DEFAULT_MAX_RETRIES, Integer)
      @retry_backoff = T.let(DEFAULT_RETRY_BACKOFF, Numeric)
      @cache_dir = T.let(self.class.default_cache_dir, String)
      @storage_dir = T.let(self.class.default_storage_dir, String)
      @retain_payloads = T.let(DEFAULT_RETAIN_PAYLOADS, Integer)
      @stale_after = T.let(DEFAULT_STALE_AFTER, T.nilable(Numeric))
      @sources = T.let(DEFAULT_SOURCES, T.nilable(T::Array[Symbol]))
      @xml_backend = T.let(DEFAULT_XML_BACKEND, Symbol)
      @sync_concurrency = T.let(DEFAULT_SYNC_CONCURRENCY, Integer)
      @doctor_tolerance = T.let(DEFAULT_DOCTOR_TOLERANCE, Float)
      @candidate_limit = T.let(DEFAULT_CANDIDATE_LIMIT, Integer)
      @screening_threshold = T.let(DEFAULT_SCREENING_THRESHOLD, Float)
      @screening_limit = T.let(DEFAULT_SCREENING_LIMIT, Integer)
      @normalizer_dictionary = T.let(Normalizer::Dictionary.default, Normalizer::Dictionary)
      @scorer_weights = T.let(Scorer::Weights.default, Scorer::Weights)
      @logger = T.let(nil, T.untyped)
      @instrumenter = T.let(nil, T.untyped)
      @storage = T.let(nil, T.nilable(Storage::Base))
      @default_storage = T.let(nil, T.nilable(Storage::Base))
    end

    # A copy starts unfrozen -- that is Ruby's rule for `dup`, and the reason
    # `with` can derive a mutable configuration from a frozen one -- and drops
    # the store that was derived from `storage_dir`, so a copy that moves the
    # directory reads the directory it names. A store the caller assigned is
    # not derived and is carried over.
    sig { params(other: Configuration).void }
    def initialize_copy(other)
      super
      @default_storage = nil
    end

    sig { params(value: T.untyped).void }
    def user_agent=(value)
      @user_agent = self.class.user_agent!(value)
    end

    sig { params(value: T.untyped).void }
    def open_timeout=(value)
      @open_timeout = positive_number!(:open_timeout, value)
    end

    sig { params(value: T.untyped).void }
    def read_timeout=(value)
      @read_timeout = positive_number!(:read_timeout, value)
    end

    sig { params(value: T.untyped).void }
    def max_redirects=(value)
      @max_redirects = non_negative_integer!(:max_redirects, value)
    end

    sig { params(value: T.untyped).void }
    def max_retries=(value)
      @max_retries = non_negative_integer!(:max_retries, value)
    end

    sig { params(value: T.untyped).void }
    def retry_backoff=(value)
      @retry_backoff = positive_number!(:retry_backoff, value)
    end

    sig { params(value: T.untyped).void }
    def cache_dir=(value)
      @cache_dir = -File.expand_path(directory!(:cache_dir, value))
    end

    sig { params(value: T.untyped).void }
    def storage_dir=(value)
      @storage_dir = -File.expand_path(directory!(:storage_dir, value))
    end

    sig { params(value: T.untyped).void }
    def retain_payloads=(value)
      @retain_payloads = self.class.retain_payloads!(value)
    end

    # `nil` disables the staleness clock entirely: a source with stored
    # validators is then never stale, and the publisher's 304 is the only thing
    # that decides whether a sync did any work.
    sig { params(value: T.untyped).void }
    def stale_after=(value)
      @stale_after = value.nil? ? nil : positive_number!(:stale_after, value)
    end

    # The lists to sync, named by the keys their adapters declare:
    #
    #   c.sources = %i[ofac_sdn my_internal_watchlist]
    #
    # Keys are not resolved here. An initializer runs before a gem that
    # registers a source may have been required, and rejecting a key at
    # assignment would make the order of an application's requires decide
    # whether its configuration is valid. Sources.enabled resolves them at the
    # start of a run instead, where an unknown key is an error about a typo
    # rather than about load order.
    sig { params(value: T.untyped).void }
    def sources=(value)
      @sources = value.nil? ? nil : source_keys!(value)
    end

    # Not resolved here, for the reason `sources=` is not: an initializer runs
    # before a gem that registers a backend may have been required, and load
    # order should not decide whether a configuration is valid. XmlRecords
    # resolves the name when it parses, where an unknown one is an error about
    # a typo and lists what is registered.
    sig { params(value: T.untyped).void }
    def xml_backend=(value)
      name = value.to_s.strip
      raise ConfigurationError, "xml_backend cannot be blank" if name.empty?

      @xml_backend = name.to_sym
    end

    sig { params(value: T.untyped).void }
    def sync_concurrency=(value)
      @sync_concurrency = self.class.sync_concurrency!(value)
    end

    sig { params(value: T.untyped).void }
    def doctor_tolerance=(value)
      @doctor_tolerance = self.class.doctor_tolerance!(value)
    end

    # Raising this trades milliseconds for recall and lowering it does the
    # reverse, which is why it is a number a host can set rather than a
    # constant. Zero is refused: an index that returns nothing screens nobody,
    # and a configuration that turns screening off has to be a typo.
    sig { params(value: T.untyped).void }
    def candidate_limit=(value)
      integer = begin
        Integer(value)
      rescue TypeError, ArgumentError
        raise ConfigurationError, "candidate_limit must be a whole number of names, got #{value.inspect}"
      end
      raise ConfigurationError, "candidate_limit must be at least 1, got #{integer}" unless integer.positive?

      @candidate_limit = integer
    end

    # A Hash adds to the shipped lists, which is what a host almost always
    # wants -- one more legal form its market uses, one more particle its names
    # carry:
    #
    #   c.normalizer_dictionary = { legal_forms: %w[OYJ TBK] }
    #
    # A Normalizer::Dictionary replaces them outright, and has to spell out all
    # four lists including the particles. Replacing is the rarer and more
    # dangerous operation -- a set of lists that forgot to carry the preserve
    # list over would strip `al` out of several hundred SDN names -- so it is
    # the one that has to be written out in full.
    #
    # Set this at boot, before anything is folded. A dictionary changed later
    # is honoured from the next call, but names folded under the old one are
    # already in an index (#31) and were already screened against, and the two
    # folds do not compare.
    sig { params(value: T.untyped).void }
    def normalizer_dictionary=(value)
      @normalizer_dictionary = normalizer_dictionary!(value)
    end

    # A Hash replaces the numbers it names and leaves the rest, which is what
    # a host tuning one signal wants:
    #
    #   c.scorer_weights = { dob_conflict: -20.0, identifier_match: 50.0 }
    #
    # A Scorer::Weights is taken as it stands. Unlike the normalizer's
    # dictionaries there is no partial-replacement hazard here -- a number
    # left out is the shipped one, and the five name shares are checked to sum
    # to 1 whichever way they arrived.
    #
    # Set this at boot. Changing it later is honoured from the next call, and
    # every score already recorded was made under the old numbers; a stored
    # screening decision has to say which set it used, which is what #33's
    # reproducibility stamp is for.
    sig { params(value: T.untyped).void }
    def scorer_weights=(value)
      @scorer_weights = begin
        Scorer::Weights.build(value)
      rescue ArgumentError => e
        raise ConfigurationError, "scorer_weights: #{e.message}"
      end
    end

    # The lowest score a screening call reports, unless a query names its own.
    # Refused outside 0..100 by the scorer's own check, which is what catches
    # a similarity on the 0..1 scale arriving where a percentage was meant.
    sig { params(value: T.untyped).void }
    def screening_threshold=(value)
      number = begin
        Float(value)
      rescue TypeError, ArgumentError
        raise ConfigurationError, "screening_threshold must be a number between 0 and 100, got #{value.inspect}"
      end
      unless number.between?(0.0, 100.0)
        raise ConfigurationError,
              "screening_threshold must be between 0 and 100, got #{value.inspect} -- " \
              "a screening score is a percentage, not a similarity on a 0..1 scale"
      end

      @screening_threshold = number
    end

    # How many results a screening call returns. Zero is refused for the
    # reason `candidate_limit` refuses it: a screening call that can return
    # nothing reports every customer clear.
    sig { params(value: T.untyped).void }
    def screening_limit=(value)
      integer = begin
        Integer(value)
      rescue TypeError, ArgumentError
        raise ConfigurationError, "screening_limit must be a whole number of results, got #{value.inspect}"
      end
      raise ConfigurationError, "screening_limit must be at least 1, got #{integer}" unless integer.positive?

      @screening_limit = integer
    end

    # Where synced lists are read from and written to. Defaults to gzipped
    # JSON under `storage_dir`, which is what makes this library screen a name
    # without an application having provisioned anything first.
    #
    #   c.storage = ActiveSanction::Storage::Memory.new
    #
    # Built on first use rather than at boot, because constructing it touches
    # the filesystem and a process that never screens should not pay for a
    # directory it will not read. `Client.new` reads it once on the way to
    # freezing, so a client's store is settled before any thread can race for
    # it -- see #freeze.
    sig { returns(Storage::Base) }
    def storage
      @storage || default_storage
    end

    # A Storage::Base subclass, which is the contract the whole query path is
    # written against -- see Storage::Base, and the conformance group an
    # adapter that is not this is held to.
    sig { params(value: T.untyped).void }
    def storage=(value)
      unless value.is_a?(Storage::Base)
        raise ConfigurationError,
              "storage must be an ActiveSanction::Storage::Base subclass, got #{value.class}"
      end

      @storage = value
    end

    # Every setting a caller may name, which is what `Client.new` and
    # `Configuration#with` accept as keyword arguments and what an unknown one
    # is reported against. Derived from the writers rather than listed, so a
    # setting added below is accepted here without anything remembering to say
    # so twice.
    sig { returns(T::Array[Symbol]) }
    def self.settings
      @settings ||= T.let(
        public_instance_methods(false).grep(/=\z/).map { |name| name.to_s.chomp("=").to_sym }.sort.freeze,
        T.nilable(T::Array[Symbol])
      )
    end

    # A copy of these settings with some of them changed:
    #
    #   audit = ActiveSanction.config.with(storage: pinned_store, sources: %i[ofac_sdn])
    #
    # The copy is mutable and unfrozen whatever this one is, which is what
    # makes a frozen configuration a value object rather than a dead end: a
    # client derives its neighbour from it instead of rebuilding the schema.
    sig { params(overrides: T.untyped).returns(Configuration) }
    def with(**overrides)
      dup.tap { |copy| copy.apply(**overrides) }
    end

    # Assigns through the writers, so a value given to `Client.new` is held to
    # exactly the rule the same value set in a `configure` block is held to,
    # and fails with the same message.
    sig { params(overrides: T.untyped).returns(T.self_type) }
    def apply(**overrides)
      unknown = overrides.keys - self.class.settings
      if unknown.any?
        raise ConfigurationError,
              "unknown setting(s): #{unknown.join(", ")}. Expected any of #{self.class.settings.join(", ")}"
      end

      overrides.each { |name, value| public_send(:"#{name}=", value) }
      self
    end

    # A built configuration is frozen, and a client freezes the one it holds.
    #
    # The default store is resolved on the way through, because it is the one
    # thing here that is built lazily and a frozen object cannot memoize. That
    # is also the point: a store settled at build time is a store no two
    # threads can race to construct, and a client that never screens pays for
    # a `File.expand_path` rather than for a directory.
    #
    # The dictionary and the weights are already frozen value objects, and the
    # source list is frozen here so that a caller holding the array it passed
    # in cannot edit the lists a running client syncs.
    sig { returns(T.self_type) }
    def freeze
      return self if frozen?

      storage
      @sources = T.let(@sources&.dup&.freeze, T.nilable(T::Array[Symbol]))
      super
    end

    # Anything Logger-shaped. The fetch layer says what it did at `info` --
    # which list was downloaded, which came back 304 -- because a sync that
    # transfers nothing looks identical to a sync that did not run, and an
    # operator needs to tell those apart.
    sig { params(value: T.untyped).void }
    def logger=(value)
      unless value.nil? || value.respond_to?(:info)
        raise ConfigurationError, "logger must respond to #info, got #{value.class}"
      end

      @logger = value
    end

    # Where this library's structured events go: a lambda, a Method, or any
    # object answering `#call(event)`.
    #
    #   c.instrumenter = ->(event) { StatsD.timing("sanctions.#{event.name}", event.duration_ms) }
    #   c.instrumenter = ActiveSanction::Instrumentation::Notifications.new   # a Rails host
    #
    # Six events -- `:fetch`, `:parse`, `:store`, `:"index.build"`, `:screen`
    # and `:sync` -- each carrying a duration and the ids needed to correlate
    # it. Their payload keys are public API; see Instrumentation, which is
    # where all of it is documented, and docs/api_stability.md, which
    # enumerates the keys.
    #
    # The default is nil, and nil is a branch rather than a no-op object: an
    # installation that instruments nothing pays nothing, which is the only
    # way a per-query event could be affordable at all.
    #
    # This is read where a stage is *built* rather than where it runs -- a
    # Matcher takes its instrumenter at `build` and freezes it, the way it
    # freezes its weights -- so changing it here affects the next matcher,
    # sync or fetcher and never one already running. That is the same rule
    # every other setting on the query path follows, and it is what keeps a
    # batch from being half one set of numbers and half another.
    sig { params(value: T.untyped).void }
    def instrumenter=(value)
      unless value.nil? || value.respond_to?(:call)
        raise ConfigurationError,
              "instrumenter must respond to #call(event), got #{value.class}. See ActiveSanction::Instrumentation."
      end

      @instrumenter = value
    end

    sig { returns(String) }
    def self.default_storage_dir
      -File.expand_path(File.join(Dir.home, DEFAULT_STORAGE_DIRNAME))
    end

    sig { returns(String) }
    def self.default_cache_dir
      home = ENV.fetch(XDG_CACHE_HOME, nil)
      home = File.join(Dir.home, ".cache") if home.nil? || home.strip.empty?
      -File.expand_path(File.join(home, DEFAULT_CACHE_DIRNAME))
    end

    # Shared by PayloadCache, so a cache built with an explicit `retain:` fails
    # the same way as a misconfigured global. Zero is not allowed: a cache that
    # keeps nothing still writes every payload to disk before deleting it, and
    # an installation that wants no payload cache should not build one.
    sig { params(value: T.untyped).returns(Integer) }
    def self.retain_payloads!(value)
      integer = begin
        Integer(value)
      rescue TypeError, ArgumentError
        raise ConfigurationError, "retain_payloads must be a whole number of payloads, got #{value.inspect}"
      end
      raise ConfigurationError, "retain_payloads must be at least 1, got #{integer}" unless integer.positive?

      integer
    end

    # Shared by Sync, so a run given an explicit `concurrency:` fails the same
    # way as a misconfigured global. Zero is refused rather than read as "no
    # parallelism": a sync that runs no sources is a typo, and one is what
    # sequential is spelled as.
    sig { params(value: T.untyped).returns(Integer) }
    def self.sync_concurrency!(value)
      integer = begin
        Integer(value)
      rescue TypeError, ArgumentError
        raise ConfigurationError, "sync_concurrency must be a whole number of sources, got #{value.inspect}"
      end
      raise ConfigurationError, "sync_concurrency must be at least 1, got #{integer}" unless integer.positive?

      integer
    end

    # Shared with Doctor, so a per-run `tolerance:` is held to the same rule as
    # the configured default. A share of what a measurement was, so 1.0 is
    # "report nothing short of a doubling or a disappearance" and 0.0 is
    # "report every movement at all", both of which are legitimate settings for
    # somebody and neither of which is a default.
    sig { params(value: T.untyped).returns(Float) }
    def self.doctor_tolerance!(value)
      ratio = begin
        Float(value)
      rescue TypeError, ArgumentError
        raise ConfigurationError, "doctor_tolerance must be a share between 0 and 1, got #{value.inspect}"
      end
      return ratio if ratio.between?(0.0, 1.0)

      raise ConfigurationError, "doctor_tolerance must be a share between 0 and 1, got #{value.inspect}"
    end

    # Shared by HttpClient, so a client built with an explicit `user_agent:`
    # fails the same way and with the same message as a misconfigured global.
    # Whitespace counts as blank: a header of `" "` is what a publisher sees as
    # no header at all, and it would earn the same 403.
    sig { params(value: T.untyped).returns(String) }
    def self.user_agent!(value)
      string = value.to_s.strip
      if string.empty?
        raise ConfigurationError,
              "user_agent is required -- OFAC and other publishers reject requests without one. " \
              'Set ActiveSanction.configure { |c| c.user_agent = "my-app/1.0 (you@example.com)" }'
      end

      -string
    end

    private

    # The store `storage_dir` names, built once. Memoized rather than built on
    # every read because a FileSystem store is a directory and a checksum
    # pattern, and two of them would be two objects saying the same thing.
    sig { returns(Storage::Base) }
    def default_storage
      @default_storage ||= T.let(Storage::FileSystem.new(root: storage_dir), T.nilable(Storage::Base))
    end

    sig { params(value: T.untyped).returns(Normalizer::Dictionary) }
    def normalizer_dictionary!(value)
      return value if value.is_a?(Normalizer::Dictionary)

      unless value.is_a?(Hash)
        raise ConfigurationError,
              "normalizer_dictionary must be an ActiveSanction::Normalizer::Dictionary, or a Hash of " \
              "lists to add to the shipped ones, got #{value.class}"
      end

      lists = value.to_h { |list, entries| [list.to_s.to_sym, entries] }
      unknown = lists.keys - Normalizer::Dictionary::LISTS
      if unknown.any?
        raise ConfigurationError,
              "unknown normalizer dictionary list(s): #{unknown.join(", ")}. " \
              "Expected any of #{Normalizer::Dictionary::LISTS.join(", ")}"
      end

      T.unsafe(Normalizer::Dictionary.default).merge(**lists)
    end

    sig { params(name: Symbol, value: T.untyped).returns(String) }
    def directory!(name, value)
      path = value.to_s.strip
      raise ConfigurationError, "#{name} cannot be blank" if path.empty?

      path
    end

    sig { params(value: T.untyped).returns(T::Array[Symbol]) }
    def source_keys!(value)
      keys = Array(value).map { |key| key.to_s.strip }
      raise ConfigurationError, "sources cannot be empty -- use nil to mean every registered source" if keys.empty?
      raise ConfigurationError, "sources cannot contain a blank key, got #{value.inspect}" if keys.any?(&:empty?)

      keys.map(&:to_sym).uniq
    end

    sig { params(name: Symbol, value: T.untyped).returns(Numeric) }
    def positive_number!(name, value)
      number = begin
        Float(value)
      rescue TypeError, ArgumentError
        raise ConfigurationError, "#{name} must be a number of seconds, got #{value.inspect}"
      end
      raise ConfigurationError, "#{name} must be greater than zero, got #{value.inspect}" unless number.positive?

      number
    end

    sig { params(name: Symbol, value: T.untyped).returns(Integer) }
    def non_negative_integer!(name, value)
      integer = begin
        Integer(value)
      rescue TypeError, ArgumentError
        raise ConfigurationError, "#{name} must be a whole number, got #{value.inspect}"
      end
      raise ConfigurationError, "#{name} cannot be negative, got #{value.inspect}" if integer.negative?

      integer
    end
  end
end
