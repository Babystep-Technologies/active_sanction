# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"

module ActiveSanction
  class HttpClient
    # Base for every failure this client raises, all of them cases where the
    # server never produced a status to hand back. Statuses it *did* produce --
    # 403, 500, 304 -- come back as a Response instead; see Response.
    #
    # A FetchError, so a caller backing off on "the bytes could not be
    # obtained" does not have to know that this library speaks `net/http`. The
    # subclasses below split it further only where the fix differs.
    #
    # @api public
    class Error < FetchError; end

    # The connection or a read exceeded its timeout, and retries did not save
    # it. Kept distinct from ConnectionError because it is the failure that
    # usually means "the publisher is slow today", not "the URL is wrong".
    #
    # @api public
    class TimeoutError < Error
      extend T::Sig

      # No status to reason from, and the answer is still yes: a government
      # file server that timed out this afternoon serves the same file
      # tomorrow morning.
      sig { returns(T::Boolean) }
      def retryable? = retryable_or(true)
    end

    # The request never completed: DNS failure, refused or reset connection,
    # TLS failure.
    #
    # @api public
    class ConnectionError < Error
      extend T::Sig

      sig { returns(T::Boolean) }
      def retryable? = retryable_or(true)
    end

    # The redirect chain exceeded `max_redirects` without reaching a body. A
    # cap rather than an unbounded follow, because a publisher misconfiguring
    # a redirect should cost one request too many and not a crawl.
    #
    # Not retryable, and neither are the two below: a misrouted URL is routed
    # the same way on the next attempt, and this is the shape of failure that
    # needs somebody to look at where the publisher moved the file to.
    #
    # @api public
    class TooManyRedirects < Error; end

    # A redirect chain that returns to a URL already visited. It would trip the
    # hop cap on its own, but a loop and a genuinely long chain call for
    # different fixes, so they get different errors.
    #
    # @api public
    class RedirectLoop < Error; end

    # A `Location` that cannot be resolved, or that leaves HTTP entirely. A
    # sanctions file served over `ftp://` is a sign something is wrong upstream,
    # not an opportunity to be accommodating.
    #
    # @api public
    class InvalidRedirect < Error; end

    # Raised by Response#success! for a status the caller declared fatal. It
    # carries the response, so a rescuer can still log what came back, and the
    # status, so `retryable?` answers from it without anybody unwrapping the
    # response to look: a 503 is retryable, a 403 for a missing User-Agent is
    # not. See FetchError::RETRYABLE_STATUSES.
    #
    # @api public
    class ResponseError < Error
      extend T::Sig

      sig { returns(Response) }
      attr_reader :response

      # Which list this was is stamped on afterwards, by the adapter -- see
      # Error#in_source. This layer has a URL and no idea what is behind it.
      sig { params(response: Response).void }
      def initialize(response)
        @response = T.let(response, Response)
        super("#{response.uri} returned #{response.status}", status: response.status)
      end
    end
  end
end
