# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "fileutils"
require "net/http"
require "uri"
require "active_sanction/error"
require "active_sanction/configuration"
require "active_sanction/http_client/errors"
require "active_sanction/http_client/response"

module ActiveSanction
  # A small GET client over `net/http`, built for one job: pulling published
  # sanctions files off government servers.
  #
  #   client = ActiveSanction::HttpClient.new
  #   client.get("https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV").body
  #   client.download("https://.../SDN_ADVANCED.XML", to: "/tmp/sdn_advanced.xml")
  #
  # No HTTP gem: the stdlib covers every need here, and the gem's zero-runtime-
  # dependency promise is worth more to an application embedding it than the
  # ergonomics of a nicer adapter layer would be.
  #
  # What the endpoints force on us, all verified live:
  #
  # * **OFAC returns 403 to a request with no User-Agent**, so the header is
  #   mandatory rather than defaulted-and-forgotten, and a blank one raises
  #   before a socket is opened.
  # * **OFAC's download URLs 302 to blob storage**, so following redirects is
  #   part of a working GET, not an option a caller might switch on.
  # * **SDN_ADVANCED.XML is 126 MB**, so #download streams to disk. Holding a
  #   list that size in a String to write it out again is how a sync job gets
  #   itself OOM-killed in a container.
  #
  # Bodies come back as the server sent them, with no transcoding: OFAC's CSV
  # and the UN's XML disagree about encoding, and guessing here would corrupt
  # one of them. Parsers (#14, #15) declare what they expect.
  class HttpClient
    extend T::Sig

    # 303 is included even though it is defined to change the method, because
    # this client only ever issues GET and so already complies.
    REDIRECT_STATUSES = T.let([301, 302, 303, 307, 308].freeze, T::Array[Integer])

    # Failures worth trying again. A 4xx is never in here: a 403 for a missing
    # User-Agent or a 404 for a retired URL says the request is wrong, and
    # repeating it wastes the publisher's capacity to make the same point.
    #
    # OpenSSL errors are deliberately absent: a certificate that does not
    # verify will not verify a second later either, and quietly retrying a TLS
    # failure against a government endpoint is not a behaviour worth having.
    # See FATAL_ERRORS, which is where they go instead.
    TRANSIENT_ERRORS = T.let(
      [
        EOFError, IOError, SocketError, Net::HTTPBadResponse, Net::ProtocolError,
        Errno::ECONNABORTED, Errno::ECONNREFUSED, Errno::ECONNRESET,
        Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EPIPE, Errno::ETIMEDOUT
      ].freeze,
      T::Array[T.class_of(StandardError)]
    )

    # Failures translated on the first attempt rather than retried. A caller
    # rescuing FetchError should not have to know that this client speaks
    # `net/http`, and it certainly should not have to know that `net/http`
    # speaks OpenSSL -- but a bad certificate is still not worth a second
    # request, so it becomes a ConnectionError that says `retryable?` is false.
    #
    # Guarded because `net/http` loads OpenSSL optionally, and a Ruby built
    # without it can still fetch a list over plain HTTP.
    FATAL_ERRORS = T.let(
      (defined?(::OpenSSL::SSL::SSLError) ? [::OpenSSL::SSL::SSLError] : []).freeze,
      T::Array[T.class_of(StandardError)]
    )

    # Checked when the client is built, so a blank one raises before a socket
    # is opened rather than earning a 403 from OFAC.
    sig { returns(String) }
    attr_reader :user_agent

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

    # Settings default to the global configuration, read at construction, so a
    # client built inside a source adapter honours whatever the host
    # application set at boot without threading a config object through every
    # adapter.
    sig do
      params(user_agent: T.untyped, open_timeout: Numeric, read_timeout: Numeric, max_redirects: Integer,
             max_retries: Integer, retry_backoff: Numeric).void
    end
    def initialize(user_agent: ActiveSanction.config.user_agent,
                   open_timeout: ActiveSanction.config.open_timeout,
                   read_timeout: ActiveSanction.config.read_timeout,
                   max_redirects: ActiveSanction.config.max_redirects,
                   max_retries: ActiveSanction.config.max_retries,
                   retry_backoff: ActiveSanction.config.retry_backoff)
      @user_agent = T.let(Configuration.user_agent!(user_agent), String)
      @open_timeout = T.let(open_timeout, Numeric)
      @read_timeout = T.let(read_timeout, Numeric)
      @max_redirects = T.let(max_redirects, Integer)
      @max_retries = T.let(max_retries, Integer)
      @retry_backoff = T.let(retry_backoff, Numeric)
    end

    # Fetches a URL and buffers the body in memory. Right for the index pages
    # and small XML lists; use #download for anything list-sized.
    sig { params(url: T.untyped, headers: T::Hash[T.untyped, T.untyped]).returns(Response) }
    def get(url, headers: {})
      fetch(url, headers: headers)
    end

    # Streams a URL to disk, returning a Response whose body is nil -- the
    # bytes are in the file, and materializing them twice defeats the point.
    #
    # `to:` is a path, or any IO-ish object that responds to #write, which is
    # what the payload cache (#11) passes so it can own its own atomicity.
    # Given a path, the download lands on a sibling `.part` file and is renamed
    # only once the server has answered 2xx, so an interrupted or 404'd fetch
    # never leaves something at the destination that looks like a list.
    sig { params(url: T.untyped, to: T.untyped, headers: T::Hash[T.untyped, T.untyped]).returns(Response) }
    def download(url, to:, headers: {})
      return fetch(url, headers: headers, sink: to) if to.respond_to?(:write)

      stream_to_path(url, to.to_s, headers)
    end

    private

    sig { params(url: T.untyped, path: String, headers: T::Hash[T.untyped, T.untyped]).returns(Response) }
    def stream_to_path(url, path, headers)
      partial = "#{path}.part"
      response = T.let(File.open(partial, "wb") { |file| fetch(url, headers: headers, sink: file) }, Response)
      File.rename(partial, path) if response.success?
      response
    ensure
      # `T.must` because Sorbet reads an `ensure` as reachable before the first
      # assignment in the body; `partial` is that assignment.
      FileUtils.rm_f(T.must(partial))
    end

    # One hop at a time: each is retried on its own, so a 500 from the blob
    # store the second hop landed on does not replay the first.
    sig { params(url: T.untyped, headers: T::Hash[T.untyped, T.untyped], sink: T.untyped).returns(Response) }
    def fetch(url, headers:, sink: nil)
      uri = uri!(url)
      request_headers = headers!(headers)
      seen = [uri.to_s]
      redirects = []

      loop do
        response = with_retries(uri) { perform(uri, request_headers, sink, redirects) }
        return response unless response.redirect? && response["location"]

        redirects << uri
        raise TooManyRedirects, chain_message(redirects) if redirects.size > max_redirects

        uri = next_hop(uri, response["location"], seen)
      end
    end

    sig do
      params(uri: URI::Generic, headers: T::Hash[String, String], sink: T.untyped,
             redirects: T::Array[URI::Generic]).returns(Response)
    end
    def perform(uri, headers, sink, redirects)
      response = T.let(nil, T.nilable(Response))
      build_http(uri).start do |session|
        session.request(Net::HTTP::Get.new(uri, headers)) do |raw|
          response = receive(raw, uri, sink, redirects)
        end
      end
      T.must(response)
    end

    # Only a successful body is streamed. An error page is small and the caller
    # will want to read it, and writing one into the sink would hand the
    # payload cache a 404 notice to checksum as though it were a list.
    #
    # A 304 is the one status with nothing to read either way: it is defined to
    # carry no body, and handing back the empty string `read_body` produces
    # would give conditional GET (#10) something a caller could try to parse.
    sig do
      params(raw: T.untyped, uri: URI::Generic, sink: T.untyped,
             redirects: T::Array[URI::Generic]).returns(Response)
    end
    def receive(raw, uri, sink, redirects)
      status = raw.code.to_i
      body = T.let(nil, T.nilable(String))
      if status == 304
        nil
      elsif sink && status.between?(200, 299)
        rewind(sink)
        raw.read_body { |chunk| sink.write(chunk) }
      else
        body = raw.read_body
      end
      Response.new(status: status, headers: raw.to_hash, uri: uri, body: body, redirects: redirects)
    end

    # A read that dies mid-body has already written part of the file, so a
    # retry has to start the sink over rather than append a second prefix to
    # the first. An append-only sink cannot be reset; it is the caller's to
    # handle, and #download's own path never produces one.
    sig { params(sink: T.untyped).void }
    def rewind(sink)
      return unless sink.respond_to?(:truncate) && sink.respond_to?(:rewind)

      sink.rewind
      sink.truncate(0)
    end

    # Exponential backoff, no jitter: this is one process fetching a handful of
    # files on a schedule, not a fleet that needs de-synchronizing, and a
    # deterministic delay is one less thing for a stuck sync to explain.
    sig { params(uri: URI::Generic, block: T.proc.returns(Response)).returns(Response) }
    def with_retries(uri, &block)
      attempt = 0
      loop do
        attempt += 1
        begin
          response = block.call
          return response unless retry_status?(response, attempt)
        rescue *FATAL_ERRORS => e
          raise ConnectionError.new(failure_message(uri, e, attempt), retryable: false)
        rescue Timeout::Error => e
          raise TimeoutError, failure_message(uri, e, attempt) unless attempt <= max_retries
        rescue *TRANSIENT_ERRORS => e
          raise ConnectionError, failure_message(uri, e, attempt) unless attempt <= max_retries
        end
        sleep(backoff_for(attempt))
      end
    end

    sig { params(response: Response, attempt: Integer).returns(T::Boolean) }
    def retry_status?(response, attempt)
      response.server_error? && attempt <= max_retries
    end

    sig { params(attempt: Integer).returns(Numeric) }
    def backoff_for(attempt)
      retry_backoff * (2**(attempt - 1))
    end

    sig { params(uri: URI::Generic).returns(Net::HTTP) }
    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = open_timeout
      http.read_timeout = read_timeout
      http
    end

    # The configured agent unless the caller overrode it, compared case-
    # insensitively because HTTP header names are. Validating the merged value
    # rather than only the configured one is what makes the guarantee real: the
    # request that goes out is the one checked, and it is checked here, before
    # a socket is opened.
    sig { params(extra: T.untyped).returns(T::Hash[String, String]) }
    def headers!(extra)
      headers = extra.to_h.to_h { |name, value| [name.to_s, value.to_s] }
      key = headers.keys.find { |name| name.casecmp?("user-agent") }
      agent = key ? headers[key] : user_agent
      Configuration.user_agent!(agent)
      headers.delete(key) if key
      headers.merge("User-Agent" => agent)
    end

    sig { params(url: T.untyped).returns(URI::Generic) }
    def uri!(url)
      uri = url.is_a?(URI::Generic) ? url : URI.parse(url.to_s)
      raise InvalidArgument, "#{url.inspect} is not an http(s) URL" unless uri.is_a?(URI::HTTP) && uri.host

      uri
    rescue URI::InvalidURIError => e
      raise InvalidArgument, "#{url.inspect} is not a URL: #{e.message}"
    end

    # `Location` is allowed to be relative, and publishers use that, so it is
    # resolved against the URL that produced it rather than parsed alone.
    sig { params(from: URI::Generic, location: T.untyped, seen: T::Array[String]).returns(URI::Generic) }
    def next_hop(from, location, seen)
      target = URI.join(from, location)
      raise InvalidRedirect, "#{from} redirected to #{location.inspect}" unless target.is_a?(URI::HTTP) && target.host
      raise RedirectLoop, "#{from} redirected back to #{target}" if seen.include?(target.to_s)

      seen << target.to_s
      target
    rescue URI::Error => e
      raise InvalidRedirect, "#{from} redirected to an unusable location #{location.inspect}: #{e.message}"
    end

    sig { params(redirects: T::Array[URI::Generic]).returns(String) }
    def chain_message(redirects)
      "#{redirects.first} exceeded #{max_redirects} redirects: #{redirects.join(" -> ")}"
    end

    sig { params(uri: URI::Generic, error: Exception, attempts: Integer).returns(String) }
    def failure_message(uri, error, attempts)
      "GET #{uri} failed after #{attempts} attempt#{"s" unless attempts == 1}: #{error.class}: #{error.message}"
    end
  end
end
