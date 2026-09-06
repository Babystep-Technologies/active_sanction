# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"

module ActiveSanction
  class HttpClient
    # Base for every failure this client raises, all of them cases where the
    # server never produced a status to hand back. Statuses it *did* produce --
    # 403, 500, 304 -- come back as a Response instead; see Response.
    class Error < ActiveSanction::Error; end

    # The connection or a read exceeded its timeout, and retries did not save
    # it. Kept distinct from ConnectionError because it is the failure that
    # usually means "the publisher is slow today", not "the URL is wrong".
    class TimeoutError < Error; end

    # The request never completed: DNS failure, refused or reset connection,
    # TLS failure.
    class ConnectionError < Error; end

    # The redirect chain exceeded `max_redirects` without reaching a body. A
    # cap rather than an unbounded follow, because a publisher misconfiguring
    # a redirect should cost one request too many and not a crawl.
    class TooManyRedirects < Error; end

    # A redirect chain that returns to a URL already visited. It would trip the
    # hop cap on its own, but a loop and a genuinely long chain call for
    # different fixes, so they get different errors.
    class RedirectLoop < Error; end

    # A `Location` that cannot be resolved, or that leaves HTTP entirely. A
    # sanctions file served over `ftp://` is a sign something is wrong upstream,
    # not an opportunity to be accommodating.
    class InvalidRedirect < Error; end

    # Raised by Response#success! for a status the caller declared fatal. It
    # carries the response, so a rescuer can still log what came back.
    class ResponseError < Error
      extend T::Sig

      sig { returns(Response) }
      attr_reader :response

      sig { params(response: Response).void }
      def initialize(response)
        @response = T.let(response, Response)
        super("#{response.uri} returned #{response.status}")
      end
    end
  end
end
