# frozen_string_literal: true

require "active_sanction/error"
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
    # OFAC returns 403 to a request with no User-Agent, so this cannot be nil.
    # The default identifies the library and points at its source, which is
    # what a publisher watching its logs actually wants; applications should
    # still override it with their own contact address, because a publisher
    # that needs to reach whoever is hammering an endpoint can only reach the
    # gem's repository otherwise.
    DEFAULT_USER_AGENT = -"active_sanction/#{VERSION} (+https://github.com/Babystep-Technologies/active_sanction)"

    # Generous by list-download standards: these are government file servers
    # redirecting to blob storage, and a 126 MB XML body arrives in bursts with
    # real gaps between them. The read timeout is per-read, not per-request, so
    # it does not cap how long a large download may take overall.
    DEFAULT_OPEN_TIMEOUT = 10
    DEFAULT_READ_TIMEOUT = 60

    # OFAC's download URLs 302 to blob storage, one hop. Five leaves room for
    # a publisher to add a vanity domain or a region redirect without a release
    # of this gem, and still stops a redirect chain from becoming a crawl.
    DEFAULT_MAX_REDIRECTS = 5

    # Three attempts total for a transient failure. Sanctions syncs are batch
    # work with no user waiting on them, but they are also not worth an hour of
    # a government server's patience.
    DEFAULT_MAX_RETRIES = 2
    DEFAULT_RETRY_BACKOFF = 1.0

    # Cache validators and raw payloads live under here. The XDG base directory
    # is the right default for data a user is entitled to delete: everything
    # here is recoverable by fetching again, with one honest caveat -- once a
    # publisher overwrites its file the previous payload is gone, whether or
    # not this directory still holds a copy. PayloadCache is a bounded aid to
    # re-parsing and auditing, not the system of record; storage (#24) is.
    XDG_CACHE_HOME = "XDG_CACHE_HOME"
    DEFAULT_CACHE_DIRNAME = "active_sanction"

    # How many raw payloads PayloadCache keeps per source. Three is enough to
    # diff a suspicious list against the two that came before it, and small
    # enough that a cache directory does not quietly grow by 126 MB a day. An
    # installation that must keep every version it ever screened against wants
    # its own retention storage, not a bigger number here.
    DEFAULT_RETAIN_PAYLOADS = 3

    # The launch lists change roughly daily at most, so a source last confirmed
    # within a day is not worth asking about again when a caller is only trying
    # to decide whether a sync is due. This is what #stale? measures against;
    # it does not cap how long a cached copy may be used, which is the calling
    # application's policy to set.
    DEFAULT_STALE_AFTER = 86_400

    # Which XML library the XML toolkit parses with. REXML is stdlib, needs no
    # build step, and -- the part that decides it -- gives every installation
    # the same answer. Snapshot checksums a list's parsed content and a
    # screening decision has to be re-derivable months later, so the parser
    # must not be chosen by whether the host app happened to load Nokogiri.
    #
    #   c.xml_backend = :nokogiri   # libxml2, for a host parsing OFAC's 126 MB XML
    #
    # See Parsers::XmlRecords::Backends for the contract a backend implements.
    DEFAULT_XML_BACKEND = :rexml

    # Which lists a sync runs, by key. nil means every registered source,
    # which is what an application that has not thought about it should get:
    # requiring an explicit list would mean a gem adding a jurisdiction had no
    # way to take effect without an edit to the host app's initializer.
    DEFAULT_SOURCES = nil

    attr_reader :user_agent, :open_timeout, :read_timeout, :max_redirects, :max_retries, :retry_backoff,
                :cache_dir, :retain_payloads, :stale_after, :sources, :xml_backend, :logger

    def initialize
      @user_agent = DEFAULT_USER_AGENT
      @open_timeout = DEFAULT_OPEN_TIMEOUT
      @read_timeout = DEFAULT_READ_TIMEOUT
      @max_redirects = DEFAULT_MAX_REDIRECTS
      @max_retries = DEFAULT_MAX_RETRIES
      @retry_backoff = DEFAULT_RETRY_BACKOFF
      @cache_dir = self.class.default_cache_dir
      @retain_payloads = DEFAULT_RETAIN_PAYLOADS
      @stale_after = DEFAULT_STALE_AFTER
      @sources = DEFAULT_SOURCES
      @xml_backend = DEFAULT_XML_BACKEND
      @logger = nil
    end

    def user_agent=(value)
      @user_agent = self.class.user_agent!(value)
    end

    def open_timeout=(value)
      @open_timeout = positive_number!(:open_timeout, value)
    end

    def read_timeout=(value)
      @read_timeout = positive_number!(:read_timeout, value)
    end

    def max_redirects=(value)
      @max_redirects = non_negative_integer!(:max_redirects, value)
    end

    def max_retries=(value)
      @max_retries = non_negative_integer!(:max_retries, value)
    end

    def retry_backoff=(value)
      @retry_backoff = positive_number!(:retry_backoff, value)
    end

    def cache_dir=(value)
      path = value.to_s.strip
      raise ConfigurationError, "cache_dir cannot be blank" if path.empty?

      @cache_dir = -File.expand_path(path)
    end

    def retain_payloads=(value)
      @retain_payloads = self.class.retain_payloads!(value)
    end

    # `nil` disables the staleness clock entirely: a source with stored
    # validators is then never stale, and the publisher's 304 is the only thing
    # that decides whether a sync did any work.
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
    def sources=(value)
      @sources = value.nil? ? nil : source_keys!(value)
    end

    # Not resolved here, for the reason `sources=` is not: an initializer runs
    # before a gem that registers a backend may have been required, and load
    # order should not decide whether a configuration is valid. XmlRecords
    # resolves the name when it parses, where an unknown one is an error about
    # a typo and lists what is registered.
    def xml_backend=(value)
      name = value.to_s.strip
      raise ConfigurationError, "xml_backend cannot be blank" if name.empty?

      @xml_backend = name.to_sym
    end

    # Anything Logger-shaped. The fetch layer says what it did at `info` --
    # which list was downloaded, which came back 304 -- because a sync that
    # transfers nothing looks identical to a sync that did not run, and an
    # operator needs to tell those apart.
    def logger=(value)
      unless value.nil? || value.respond_to?(:info)
        raise ConfigurationError, "logger must respond to #info, got #{value.class}"
      end

      @logger = value
    end

    def self.default_cache_dir
      home = ENV.fetch(XDG_CACHE_HOME, nil)
      home = File.join(Dir.home, ".cache") if home.nil? || home.strip.empty?
      -File.expand_path(File.join(home, DEFAULT_CACHE_DIRNAME))
    end

    # Shared by PayloadCache, so a cache built with an explicit `retain:` fails
    # the same way as a misconfigured global. Zero is not allowed: a cache that
    # keeps nothing still writes every payload to disk before deleting it, and
    # an installation that wants no payload cache should not build one.
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

    def source_keys!(value)
      keys = Array(value).map { |key| key.to_s.strip }
      raise ConfigurationError, "sources cannot be empty -- use nil to mean every registered source" if keys.empty?
      raise ConfigurationError, "sources cannot contain a blank key, got #{value.inspect}" if keys.any?(&:empty?)

      keys.map(&:to_sym).uniq
    end

    def positive_number!(name, value)
      number = begin
        Float(value)
      rescue TypeError, ArgumentError
        raise ConfigurationError, "#{name} must be a number of seconds, got #{value.inspect}"
      end
      raise ConfigurationError, "#{name} must be greater than zero, got #{value.inspect}" unless number.positive?

      number
    end

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
