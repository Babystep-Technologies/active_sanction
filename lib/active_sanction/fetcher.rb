# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"
require "active_sanction/http_client"
require "active_sanction/validators"
require "active_sanction/validator_store"
require "active_sanction/fetcher/result"

module ActiveSanction
  # An HttpClient that remembers what it fetched last time.
  #
  #   fetcher = ActiveSanction::Fetcher.new
  #   result  = fetcher.fetch(url, key: :ofac_sdn)
  #
  #   result.unchanged?   # publisher answered 304; keep the snapshot we have
  #   result.changed?     # a new payload to parse
  #
  # Every launch source serves both `ETag` and `Last-Modified`, verified live:
  #
  #   OFAC SDN.CSV        "0953154d0fb5aff918c5ec1daf6e9c0e"
  #   UN consolidated.xml "0x8DF0558663FC719"
  #   Canada sema-lmes    "0bf613fb33dd1:0"
  #
  # and they publish changes daily at most. So a sync that runs hourly should
  # move tens of megabytes once a day and three empty 304 responses the other
  # twenty-three times. That is the whole purpose of this class: it holds the
  # validators, sends them, and reports "unchanged" in a form a caller can act
  # on without inspecting a status code.
  #
  # The saving is not only bandwidth. Skipping the download also skips the
  # parse, which for OFAC's SDN join (#18) is the expensive half.
  #
  # What it deliberately does not do is decide what "unchanged" means for the
  # application. It reuses no snapshot and returns no cached body -- storage
  # (#23, #24) owns those, and a fetch layer that quietly handed back a
  # previous payload would make it impossible to tell a list that did not
  # change from a sync that did not run.
  #
  # @api private
  class Fetcher
    extend T::Sig

    # Sent by us unless the caller sent its own. A caller doing its own
    # conditional request -- a range fetch, a probe against a mirror -- has a
    # reason we do not know, and layering a stored ETag on top of it would
    # produce a request neither side meant.
    CONDITIONAL_HEADERS = T.let(%w[if-none-match if-modified-since].freeze, T::Array[String])

    sig { returns(HttpClient) }
    attr_reader :client

    # Any store answering the ValidatorStore contract -- see #initialize.
    sig { returns(T.untyped) }
    attr_reader :store

    # Seconds, or nil to disable the staleness clock -- see #stale?.
    sig { returns(T.nilable(Numeric)) }
    attr_reader :stale_after

    # Anything Logger-shaped, or nil, as Configuration#logger has it.
    sig { returns(T.untyped) }
    attr_reader :logger

    # The store defaults to disk, so the second run of a cron job benefits and
    # not merely the second call in one process. A caller that would rather
    # keep nothing between runs passes ValidatorStore::Memory.new.
    sig do
      params(client: HttpClient, store: T.untyped, stale_after: T.nilable(Numeric), logger: T.untyped).void
    end
    def initialize(client: HttpClient.new,
                   store: ValidatorStore::FileSystem.new,
                   stale_after: ActiveSanction.config.stale_after,
                   logger: ActiveSanction.config.logger)
      @client = T.let(client, HttpClient)
      @store = T.let(store, T.untyped)
      @stale_after = T.let(stale_after, T.nilable(Numeric))
      @logger = T.let(logger, T.untyped)
    end

    # Fetches conditionally and buffers the body, like HttpClient#get.
    #
    # `key` is what the validators are filed under, defaulting to the URL. A
    # source adapter (#12) passes its own name instead, so that a publisher
    # moving a file changes which URL is fetched without orphaning the record
    # of what was fetched -- the stored URL is compared before its validators
    # are used, and a moved file downloads in full exactly once.
    #
    # `force: true` sends no validators, so the publisher has no way to answer
    # 304. For the operator who suspects the cached copy is wrong and wants the
    # bytes regardless of what the ETag says.
    sig do
      params(url: T.untyped, key: T.untyped, force: T::Boolean, headers: T::Hash[T.untyped, T.untyped])
        .returns(Result)
    end
    def fetch(url, key: url, force: false, headers: {})
      conditional(url, key, force, headers) { |request| client.get(url, headers: request) }
    end

    # Streams conditionally to disk, like HttpClient#download. A 304 writes
    # nothing: HttpClient only streams a 2xx body, so the file already at `to:`
    # is left exactly as the last download left it.
    sig do
      params(url: T.untyped, to: T.untyped, key: T.untyped, force: T::Boolean,
             headers: T::Hash[T.untyped, T.untyped]).returns(Result)
    end
    def download(url, to:, key: url, force: false, headers: {})
      conditional(url, key, force, headers) { |request| client.download(url, to: to, headers: request) }
    end

    # Whether a sync is due, answered locally and without a request.
    #
    # True when the key has never been fetched, when its validators were stored
    # against a different URL, or when nothing has confirmed the copy within
    # `stale_after` (default 24 hours; nil disables the clock). It is a
    # scheduling predicate -- what #36's `sources` command prints, and what a
    # caller checks before deciding to spend a round-trip -- not a claim about
    # the publisher's current file. Only a fetch can make that claim, and a
    # cheap #fetch that comes back `unchanged?` is how to ask for it.
    sig { params(key: T.untyped, url: T.untyped).returns(T::Boolean) }
    def stale?(key, url: nil)
      stored = store[key]
      return true if stored.nil? || stored.empty?
      return true if url && !stored.for?(url)

      after = stale_after
      return false if after.nil?

      Time.now - stored.checked_at >= after.to_f
    end

    sig { params(key: T.untyped, url: T.untyped).returns(T::Boolean) }
    def fresh?(key, url: nil) = !stale?(key, url: url)

    # What is stored for a key, or nil. Mostly for a CLI that wants to print
    # when a source was last confirmed.
    sig { params(key: T.untyped).returns(T.nilable(Validators)) }
    def validators(key) = store[key]

    # Drops a key's validators, so the next fetch downloads in full. The
    # supported way to do what deleting the store file does for every source at
    # once.
    sig { params(key: T.untyped).returns(T.untyped) }
    def forget(key) = store.delete(key)

    private

    sig do
      params(url: T.untyped, key: T.untyped, force: T::Boolean, headers: T::Hash[T.untyped, T.untyped],
             block: T.proc.params(request: T::Hash[T.untyped, T.untyped]).returns(HttpClient::Response))
        .returns(Result)
    end
    def conditional(url, key, force, headers, &block)
      stored = force ? nil : usable(key, url)
      log_request(key, url, stored, force)
      response = block.call(merge(headers, stored))
      record(key, url, stored, response)
    end

    # Validators stored against a different URL are not merely useless, they
    # are dangerous: a 304 from the new address would say "the file you have is
    # current" about a file that came from somewhere else.
    sig { params(key: T.untyped, url: T.untyped).returns(T.nilable(Validators)) }
    def usable(key, url)
      stored = store[key]
      return nil if stored.nil? || stored.empty?
      return stored if stored.for?(url)

      logger&.info("[active_sanction] #{key} moved from #{stored.url} to #{url}; fetching in full")
      nil
    end

    sig do
      params(headers: T::Hash[T.untyped, T.untyped], stored: T.nilable(Validators))
        .returns(T::Hash[T.untyped, T.untyped])
    end
    def merge(headers, stored)
      return headers.to_h if stored.nil?

      supplied = headers.to_h.keys.map { |name| name.to_s.downcase }
      return headers.to_h if CONDITIONAL_HEADERS.any? { |name| supplied.include?(name) }

      stored.request_headers.merge(headers.to_h)
    end

    # Only an answer the publisher stands behind updates the store. A 500 that
    # outlived its retries, or a 403, says nothing about whether the list
    # changed, and letting one clear the validators would turn a bad afternoon
    # at a government file server into a full re-download of every list.
    sig do
      params(key: T.untyped, url: T.untyped, stored: T.nilable(Validators),
             response: HttpClient::Response).returns(Result)
    end
    def record(key, url, stored, response)
      learned = validators_for(url, stored, response)
      store[key] = learned if learned
      log_response(key, response, learned)
      Result.new(key: key, url: url, response: response, validators: store[key])
    end

    sig do
      params(url: T.untyped, stored: T.nilable(Validators), response: HttpClient::Response)
        .returns(T.nilable(Validators))
    end
    def validators_for(url, stored, response)
      if response.not_modified?
        # A caller may have sent its own conditional headers, in which case a
        # 304 arrives with nothing stored behind it; the response still says
        # what the current validators are.
        stored ? stored.confirmed_by(response) : Validators.from_response(response, url: url)
      elsif response.success?
        Validators.from_response(response, url: url)
      end
    end

    sig { params(key: T.untyped, url: T.untyped, stored: T.nilable(Validators), force: T::Boolean).void }
    def log_request(key, url, stored, force)
      return unless logger

      logger.info("[active_sanction] fetching #{key} #{url}#{" (forced)" if force}" \
                  "#{" if-none-match=#{stored.etag}" if stored&.etag}")
    end

    # The line an operator greps for to answer "did last night's sync actually
    # transfer anything?".
    sig { params(key: T.untyped, response: HttpClient::Response, learned: T.nilable(Validators)).void }
    def log_response(key, response, learned)
      return unless logger

      if response.not_modified?
        logger.info("[active_sanction] #{key} 304 Not Modified; unchanged since " \
                    "#{learned&.updated_at&.iso8601 || "the last download"}")
      elsif response.success?
        logger.info("[active_sanction] #{key} #{response.status} changed; etag=#{response.etag.inspect}")
      else
        logger.info("[active_sanction] #{key} #{response.status}; keeping stored validators")
      end
    end
  end
end
