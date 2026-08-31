# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  class HttpClient
    # What a server said, after redirects were followed and retries exhausted.
    #
    # Any status the server actually produced comes back as one of these
    # rather than as an exception, including 403 and 500. The fetch layer has
    # to reason about statuses -- conditional GET (#10) treats 304 as
    # success-unchanged, sync orchestration (#34) isolates a single source's
    # failure rather than aborting the run -- and a client that raised on
    # everything but 200 would force each of them to rescue what it wanted
    # back. Failures the server never got to answer (timeouts, refused
    # connections, redirect loops) do raise: there is no status to hand over.
    #
    # `body` is nil for a streamed download, where the bytes went to disk
    # instead, and for a 304, which has none by definition.
    #
    # Instances are frozen on construction.
    class Response
      extend T::Sig

      # `uri` is where the response finally came from, which is not the URL
      # asked for when redirects were followed, and `redirects` is the hops it
      # took to get there. #11 stores both beside the cached payload: a bug
      # report about an OFAC download is much easier to read when it names the
      # blob-storage host that actually served the bytes.
      sig { returns(Integer) }
      attr_reader :status

      # Downcased, and each value joined the way the wire format does -- see
      # #normalize.
      sig { returns(T::Hash[String, String]) }
      attr_reader :headers

      # nil for a streamed download, where the bytes went to disk, and for a
      # 304, which has none by definition.
      sig { returns(T.nilable(String)) }
      attr_reader :body

      sig { returns(URI::Generic) }
      attr_reader :uri

      sig { returns(T::Array[URI::Generic]) }
      attr_reader :redirects

      sig do
        params(status: T.untyped, headers: T.untyped, uri: URI::Generic, body: T.nilable(String),
               redirects: T::Array[URI::Generic]).void
      end
      def initialize(status:, headers:, uri:, body: nil, redirects: [])
        @status = T.let(Integer(status), Integer)
        @headers = T.let(normalize(headers), T::Hash[String, String])
        @body = T.let(body, T.nilable(String))
        @uri = T.let(uri.freeze, URI::Generic)
        @redirects = T.let(redirects.dup.freeze, T::Array[URI::Generic])
        freeze
      end

      # Header lookup is case-insensitive because HTTP header names are, and
      # because the same header reaches us capitalized differently depending on
      # which CDN a publisher put in front of its file this quarter.
      sig { params(name: T.untyped).returns(T.nilable(String)) }
      def [](name)
        headers[name.to_s.downcase]
      end

      sig { returns(T::Boolean) }
      def success? = status.between?(200, 299)

      sig { returns(T::Boolean) }
      def not_modified? = status == 304

      sig { returns(T::Boolean) }
      def redirect? = REDIRECT_STATUSES.include?(status)

      sig { returns(T::Boolean) }
      def client_error? = status.between?(400, 499)

      sig { returns(T::Boolean) }
      def server_error? = status.between?(500, 599)

      sig { returns(T.nilable(String)) }
      def content_type = self["content-type"]

      sig { returns(T.nilable(String)) }
      def etag = self["etag"]

      sig { returns(T.nilable(String)) }
      def last_modified = self["last-modified"]

      # For callers that want a non-2xx to be fatal without writing the check
      # themselves. Deliberately not the default path -- see the class comment.
      sig { returns(T.self_type) }
      def success!
        return self if success?

        raise ResponseError, self
      end

      sig { returns(String) }
      def to_s = "#{status} #{uri}"

      sig { returns(String) }
      def inspect
        bytes = body
        "#<#{self.class} #{status} #{uri}#{" body=#{bytes.bytesize}B" if bytes}>"
      end

      private

      # Net::HTTPResponse hands back each header as an array of values, since
      # a header may legally repeat. Repeats are vanishingly rare on the ones
      # this library reads, so they are joined the way the wire format does it
      # and the caller sees a plain string.
      sig { params(headers: T.untyped).returns(T::Hash[String, String]) }
      def normalize(headers)
        headers.to_h do |name, value|
          [-name.to_s.downcase, value.is_a?(Array) ? value.join(", ") : value.to_s]
        end.freeze
      end
    end
  end
end
