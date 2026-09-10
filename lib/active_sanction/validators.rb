# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "time"
require "active_sanction/error"

module ActiveSanction
  # The cache validators a publisher handed back with a list, plus enough
  # context to know whether they still apply.
  #
  #   validators.request_headers
  #   # => { "If-None-Match" => "\"0953154d0fb5aff918c5ec1daf6e9c0e\"",
  #   #      "If-Modified-Since" => "Fri, 28 Aug 2026 14:02:55 GMT" }
  #
  # Every launch source serves both, verified live -- OFAC's SDN.CSV, the UN's
  # consolidated.xml and Canada's sema-lmes.xml -- so a routine sync of lists
  # that change daily at most costs three 304s instead of tens of megabytes.
  #
  # Both values are stored and echoed back verbatim. An `ETag` is an opaque
  # string that only its origin server can interpret, and `Last-Modified` is an
  # HTTP-date whose formatting is the server's business; parsing either one to
  # re-render it is how a working conditional GET turns into a full download
  # nobody notices.
  #
  # `url` is the URL that was *requested*, not the one that finally answered:
  # OFAC redirects to blob storage, and the hop it lands on is not stable
  # enough to key a cache by. It is kept so validators can be discarded when a
  # publisher moves its file -- sending a previous file's ETag to a new URL
  # invites a 304 that means nothing.
  #
  # Instances are frozen on construction and compare by value.
  class Validators
    extend T::Sig

    # @api private
    MEMBERS = T.let(%i[url etag last_modified checked_at updated_at].freeze, T::Array[Symbol])

    # The URL that was requested, not the one that finally answered -- see the
    # class comment.
    sig { returns(String) }
    attr_reader :url

    # Opaque, and echoed back verbatim: only the origin server can interpret
    # either of them.
    sig { returns(T.nilable(String)) }
    attr_reader :etag

    sig { returns(T.nilable(String)) }
    attr_reader :last_modified

    sig { returns(Time) }
    attr_reader :checked_at

    sig { returns(Time) }
    attr_reader :updated_at

    # `url` is the caller's URL rather than `response.uri` for the reason in
    # the class comment: the response may have come from a redirect target.
    sig { params(response: T.untyped, url: T.untyped, at: T.untyped).returns(T.attached_class) }
    def self.from_response(response, url:, at: nil)
      new(url: url, etag: response.etag, last_modified: response.last_modified, checked_at: at)
    end

    # Rebuilds from #to_h output, accepting string keys so validators survive
    # the round-trip through the JSON the store writes.
    sig { params(hash: T.untyped).returns(T.attached_class) }
    def self.from_h(hash)
      attributes = hash.to_h.transform_keys(&:to_sym)
      unknown = attributes.keys - MEMBERS
      raise InvalidArgument, "unknown Validators attribute(s): #{unknown.join(", ")}" if unknown.any?

      # `new(**hash)` past a required keyword parameter is one of the few
      # things Sorbet cannot check statically. #initialize validates what
      # arrives, which is where a bad round-trip is caught.
      T.unsafe(self).new(**attributes)
    end

    # `checked_at` is when the publisher last confirmed this copy, whether by
    # 200 or by 304; `updated_at` is when the bytes themselves last changed.
    # Staleness follows the first, because "when did we last ask?" is the
    # question a sync schedule answers; the second is what a human wants when
    # reading why a list looks old.
    sig do
      params(url: T.untyped, etag: T.untyped, last_modified: T.untyped, checked_at: T.untyped,
             updated_at: T.untyped).void
    end
    def initialize(url:, etag: nil, last_modified: nil, checked_at: nil, updated_at: nil)
      @url = T.let(url!(url), String)
      @etag = T.let(string_or_nil(etag), T.nilable(String))
      @last_modified = T.let(string_or_nil(last_modified), T.nilable(String))
      @checked_at = T.let(time!(checked_at), Time)
      @updated_at = T.let(updated_at.nil? ? @checked_at : time!(updated_at), Time)
      freeze
    end

    # True when the publisher gave us nothing to be conditional with. Such a
    # record is still worth storing -- it says we looked -- but it cannot save
    # a download, so callers treat it as no validators at all.
    sig { returns(T::Boolean) }
    def empty? = etag.nil? && last_modified.nil?

    sig { returns(T::Boolean) }
    def present? = !empty?

    # Both are sent when both are known. RFC 9110 has the server prefer
    # `If-None-Match` and ignore the date, but a cache in front of it may only
    # honour one, and the second header costs 40 bytes on a request that is
    # trying to avoid 126 MB.
    sig { returns(T::Hash[String, String]) }
    def request_headers
      headers = {}
      headers["If-None-Match"] = etag if etag
      headers["If-Modified-Since"] = last_modified if last_modified
      headers.freeze
    end

    # Validators belong to the URL they came from. A publisher that moves its
    # file gets a full download rather than a 304 from whatever is now at the
    # old address.
    sig { params(other: T.untyped).returns(T::Boolean) }
    def for?(other) = url == other.to_s

    # What to store after the publisher answered 304. The copy is unchanged,
    # so `updated_at` stands; only the moment we confirmed it moves. A 304 is
    # allowed to carry a fresh ETag, and when it does that value is the one to
    # send next time.
    sig { params(response: T.untyped, at: T.untyped).returns(Validators) }
    def confirmed_by(response, at: nil)
      self.class.new(url: url, etag: response.etag || etag,
                     last_modified: response.last_modified || last_modified,
                     checked_at: at, updated_at: updated_at)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h
      {
        url: url,
        etag: etag,
        last_modified: last_modified,
        checked_at: checked_at.iso8601,
        updated_at: updated_at.iso8601
      }
    end

    sig { params(other: T.untyped).returns(T::Boolean) }
    def ==(other)
      return false unless other.instance_of?(self.class)

      to_h == other.to_h
    end
    alias eql? ==

    sig { returns(Integer) }
    def hash = [self.class, to_h].hash

    sig { returns(String) }
    def inspect
      "#<#{self.class} #{url} etag=#{etag.inspect} last_modified=#{last_modified.inspect} " \
        "checked_at=#{checked_at.iso8601}>"
    end

    private

    sig { params(value: T.untyped).returns(String) }
    def url!(value)
      string = value.to_s.strip
      raise InvalidArgument, "url is required" if string.empty?

      -string
    end

    # Truncated to the second, which is the precision #to_h serializes, so a
    # stored record reloads to a value equal to the one that was written.
    sig { params(value: T.untyped).returns(Time) }
    def time!(value)
      time = case value
             when nil then Time.now
             when Time then value
             when String then Time.parse(value)
             else raise InvalidArgument, "not a time: #{value.inspect}"
             end
      Time.at(time.to_i).utc
    end

    sig { params(value: T.untyped).returns(T.nilable(String)) }
    def string_or_nil(value)
      return nil if value.nil?

      string = value.to_s.strip
      string.empty? ? nil : -string
    end
  end
end
