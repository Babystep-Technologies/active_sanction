# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  class Fetcher
    # What one conditional fetch came back with, in the terms a caller cares
    # about: did the list change, and if not, may we keep what we have.
    #
    #   result = fetcher.fetch(url, key: :ofac_sdn)
    #   return storage.latest(:ofac_sdn) if result.unchanged?
    #
    #   parse(result.body)
    #
    # Three outcomes, not two. `changed?` is a fresh payload to parse,
    # `unchanged?` is the publisher confirming the copy already held, and
    # `failed?` is any status that is neither -- a 403 for a missing header, a
    # 404 for a retired URL, a 500 the retries could not get past. Sync
    # orchestration (#34) needs to tell the second from the third: one source
    # answering 304 while another answers 500 is a successful run with one
    # failure in it, not a run that transferred nothing.
    #
    # `body` is nil for both an unchanged result -- a 304 has none by
    # definition -- and a streamed download, where the bytes went to disk.
    #
    # Instances are frozen on construction.
    class Result
      extend T::Sig

      # `key` is what the validators were filed under, `url` the URL asked for.
      # `validators` is what is now filed there: after a 304 the previous
      # record with its clock moved forward, after a 200 the publisher's new
      # ETag and Last-Modified, after a failure whatever was already stored --
      # a bad afternoon at a file server teaches us nothing. It is nil only
      # when nothing is stored, which for a 200 means a publisher that served
      # no validators at all, and so a full download again next time.
      sig { returns(T.untyped) }
      attr_reader :key

      sig { returns(T.untyped) }
      attr_reader :url

      sig { returns(HttpClient::Response) }
      attr_reader :response

      sig { returns(T.nilable(Validators)) }
      attr_reader :validators

      sig do
        params(key: T.untyped, url: T.untyped, response: HttpClient::Response,
               validators: T.nilable(Validators)).void
      end
      def initialize(key:, url:, response:, validators: nil)
        @key = T.let(key, T.untyped)
        @url = T.let(url, T.untyped)
        @response = T.let(response, HttpClient::Response)
        @validators = T.let(validators, T.nilable(Validators))
        freeze
      end

      sig { returns(T::Boolean) }
      def unchanged? = response.not_modified?

      sig { returns(T::Boolean) }
      def changed? = response.success?

      sig { returns(T::Boolean) }
      def failed? = !changed? && !unchanged?

      sig { returns(Integer) }
      def status = response.status

      sig { returns(T.nilable(String)) }
      def body = response.body

      sig { returns(URI::Generic) }
      def uri = response.uri

      sig { returns(T.nilable(String)) }
      def etag = response.etag

      sig { returns(T.nilable(String)) }
      def last_modified = response.last_modified

      sig { params(name: T.untyped).returns(T.nilable(String)) }
      def [](name) = response[name]

      # True when the publisher answered at all -- 200 or 304. What a caller
      # checks before deciding a sync succeeded, as against what it checks
      # before deciding there is anything new to parse.
      sig { returns(T::Boolean) }
      def ok? = changed? || unchanged?

      # For callers that want a failed fetch to be fatal. A 304 passes here,
      # unlike Response#success!, because an unchanged list is the outcome this
      # whole mechanism exists to produce.
      sig { returns(T.self_type) }
      def success!
        return self if ok?

        response.success!
        self
      end

      sig { returns(String) }
      def to_s = "#{status} #{url}#{" (unchanged)" if unchanged?}"

      sig { returns(String) }
      def inspect
        bytes = body
        "#<#{self.class} #{key} #{status}#{" unchanged" if unchanged?}#{" body=#{bytes.bytesize}B" if bytes}>"
      end
    end
  end
end
