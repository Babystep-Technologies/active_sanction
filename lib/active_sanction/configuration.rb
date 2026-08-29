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
  # Only the fetch layer's settings live here so far; storage, sources and
  # matcher thresholds join them as those milestones land. Every value has a
  # working default, so an application that configures nothing still runs --
  # the point of `configure` is that a caller *can* identify itself, not that
  # it must recite the whole schema.
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

    attr_reader :user_agent, :open_timeout, :read_timeout, :max_redirects, :max_retries, :retry_backoff

    def initialize
      @user_agent = DEFAULT_USER_AGENT
      @open_timeout = DEFAULT_OPEN_TIMEOUT
      @read_timeout = DEFAULT_READ_TIMEOUT
      @max_redirects = DEFAULT_MAX_REDIRECTS
      @max_retries = DEFAULT_MAX_RETRIES
      @retry_backoff = DEFAULT_RETRY_BACKOFF
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
