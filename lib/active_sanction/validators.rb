# frozen_string_literal: true

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
    MEMBERS = %i[url etag last_modified checked_at updated_at].freeze

    attr_reader(*MEMBERS)

    # `url` is the caller's URL rather than `response.uri` for the reason in
    # the class comment: the response may have come from a redirect target.
    def self.from_response(response, url:, at: nil)
      new(url: url, etag: response.etag, last_modified: response.last_modified, checked_at: at)
    end

    # Rebuilds from #to_h output, accepting string keys so validators survive
    # the round-trip through the JSON the store writes.
    def self.from_h(hash)
      attributes = hash.to_h.transform_keys(&:to_sym)
      unknown = attributes.keys - MEMBERS
      raise ArgumentError, "unknown Validators attribute(s): #{unknown.join(", ")}" if unknown.any?

      new(**attributes)
    end

    # `checked_at` is when the publisher last confirmed this copy, whether by
    # 200 or by 304; `updated_at` is when the bytes themselves last changed.
    # Staleness follows the first, because "when did we last ask?" is the
    # question a sync schedule answers; the second is what a human wants when
    # reading why a list looks old.
    def initialize(url:, etag: nil, last_modified: nil, checked_at: nil, updated_at: nil)
      @url = url!(url)
      @etag = string_or_nil(etag)
      @last_modified = string_or_nil(last_modified)
      @checked_at = time!(checked_at)
      @updated_at = updated_at.nil? ? @checked_at : time!(updated_at)
      freeze
    end

    # True when the publisher gave us nothing to be conditional with. Such a
    # record is still worth storing -- it says we looked -- but it cannot save
    # a download, so callers treat it as no validators at all.
    def empty? = etag.nil? && last_modified.nil?

    def present? = !empty?

    # Both are sent when both are known. RFC 9110 has the server prefer
    # `If-None-Match` and ignore the date, but a cache in front of it may only
    # honour one, and the second header costs 40 bytes on a request that is
    # trying to avoid 126 MB.
    def request_headers
      headers = {}
      headers["If-None-Match"] = etag if etag
      headers["If-Modified-Since"] = last_modified if last_modified
      headers.freeze
    end

    # Validators belong to the URL they came from. A publisher that moves its
    # file gets a full download rather than a 304 from whatever is now at the
    # old address.
    def for?(other) = url == other.to_s

    # What to store after the publisher answered 304. The copy is unchanged,
    # so `updated_at` stands; only the moment we confirmed it moves. A 304 is
    # allowed to carry a fresh ETag, and when it does that value is the one to
    # send next time.
    def confirmed_by(response, at: nil)
      self.class.new(url: url, etag: response.etag || etag,
                     last_modified: response.last_modified || last_modified,
                     checked_at: at, updated_at: updated_at)
    end

    def to_h
      {
        url: url,
        etag: etag,
        last_modified: last_modified,
        checked_at: checked_at.iso8601,
        updated_at: updated_at.iso8601
      }
    end

    def ==(other)
      other.instance_of?(self.class) && other.to_h == to_h
    end
    alias eql? ==

    def hash = [self.class, to_h].hash

    def inspect
      "#<#{self.class} #{url} etag=#{etag.inspect} last_modified=#{last_modified.inspect} " \
        "checked_at=#{checked_at.iso8601}>"
    end

    private

    def url!(value)
      string = value.to_s.strip
      raise ArgumentError, "url is required" if string.empty?

      -string
    end

    # Truncated to the second, which is the precision #to_h serializes, so a
    # stored record reloads to a value equal to the one that was written.
    def time!(value)
      time = case value
             when nil then Time.now
             when Time then value
             when String then Time.parse(value)
             else raise ArgumentError, "not a time: #{value.inspect}"
             end
      Time.at(time.to_i).utc
    end

    def string_or_nil(value)
      return nil if value.nil?

      string = value.to_s.strip
      string.empty? ? nil : -string
    end
  end
end
