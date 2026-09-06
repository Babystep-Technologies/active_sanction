# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"
require "active_sanction/normalizer"
require "active_sanction/scorer/weights"
require "active_sanction/version"

module ActiveSanction
  # Raised when the library is asked to work with settings it cannot honour --
  # a blank User-Agent, a negative timeout. Separate from the ArgumentErrors
  # the value objects raise: those mean "this record is malformed", this means
  # "this installation is misconfigured", and only one of them is fixed by
  # editing an initializer.
  class ConfigurationError < Error; end

  # Library-wide settings, set once at boot:
  #
  #   ActiveSanction.configure do |c|
  #     c.user_agent = "my-app/1.0 (compliance@example.com)"
  #   end
  #
  # The fetch layer's settings live here, plus which sources a sync runs;
  # storage and matcher thresholds join them as those milestones land. Every
  # value has a working default, so an application that configures nothing
  # still runs -- the point of `configure` is that a caller *can* identify
  # itself, not that it must recite the whole schema.
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
    DEFAULT_READ_TIMEOUT = T.let(60, Numeric)

    # OFAC's download URLs 302 to blob storage, one hop. Five leaves room for
    # a publisher to add a vanity domain or a region redirect without a release
    # of this gem, and still stops a redirect chain from becoming a crawl.
    DEFAULT_MAX_REDIRECTS = T.let(5, Integer)

    # Three attempts total for a transient failure. Sanctions syncs are batch
    # work with no user waiting on them, but they are also not worth an hour of
    # a government server's patience.
    DEFAULT_MAX_RETRIES = T.let(2, Integer)
    DEFAULT_RETRY_BACKOFF = T.let(1.0, Numeric)

    # Cache validators and raw payloads live under here. The XDG base directory
    # is the right default for data a user is entitled to delete: everything
    # here is recoverable by fetching again, with one honest caveat -- once a
    # publisher overwrites its file the previous payload is gone, whether or
    # not this directory still holds a copy. PayloadCache is a bounded aid to
    # re-parsing and auditing, not the system of record; storage (#24) is.
    XDG_CACHE_HOME = T.let("XDG_CACHE_HOME", String)
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

    # See DEFAULT_CANDIDATE_LIMIT. A per-query `limit:` overrides it.
    sig { returns(Integer) }
    attr_reader :candidate_limit

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
      @candidate_limit = T.let(DEFAULT_CANDIDATE_LIMIT, Integer)
      @normalizer_dictionary = T.let(Normalizer::Dictionary.default, Normalizer::Dictionary)
      @scorer_weights = T.let(Scorer::Weights.default, Scorer::Weights)
      @logger = T.let(nil, T.untyped)
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
