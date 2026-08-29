# frozen_string_literal: true

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
      # `key` is what the validators were filed under, `url` the URL asked for.
      # `validators` is what is now filed there: after a 304 the previous
      # record with its clock moved forward, after a 200 the publisher's new
      # ETag and Last-Modified, after a failure whatever was already stored --
      # a bad afternoon at a file server teaches us nothing. It is nil only
      # when nothing is stored, which for a 200 means a publisher that served
      # no validators at all, and so a full download again next time.
      attr_reader :key, :url, :response, :validators

      def initialize(key:, url:, response:, validators: nil)
        @key = key
        @url = url
        @response = response
        @validators = validators
        freeze
      end

      def unchanged? = response.not_modified?
      def changed? = response.success?
      def failed? = !changed? && !unchanged?

      def status = response.status
      def body = response.body
      def uri = response.uri
      def etag = response.etag
      def last_modified = response.last_modified
      def [](name) = response[name]

      # True when the publisher answered at all -- 200 or 304. What a caller
      # checks before deciding a sync succeeded, as against what it checks
      # before deciding there is anything new to parse.
      def ok? = changed? || unchanged?

      # For callers that want a failed fetch to be fatal. A 304 passes here,
      # unlike Response#success!, because an unchanged list is the outcome this
      # whole mechanism exists to produce.
      def success!
        return self if ok?

        response.success!
      end

      def to_s = "#{status} #{url}#{" (unchanged)" if unchanged?}"

      def inspect
        "#<#{self.class} #{key} #{status}#{" unchanged" if unchanged?}#{" body=#{body.bytesize}B" if body}>"
      end
    end
  end
end
