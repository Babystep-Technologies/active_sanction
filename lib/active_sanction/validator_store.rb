# frozen_string_literal: true

require "active_sanction/error"
require "active_sanction/validators"

module ActiveSanction
  # Where a process remembers what a publisher last said about a list, so the
  # next fetch can ask "still this?" instead of "give me everything".
  #
  #   store = ActiveSanction::ValidatorStore::FileSystem.new
  #   store[:ofac_sdn]          #=> #<ActiveSanction::Validators ...> or nil
  #   store.delete(:ofac_sdn)   # next fetch downloads in full
  #
  # Keys are the caller's: a URL by default, or a stable source name for an
  # adapter (#12) whose publisher may move its file. Validators carry the URL
  # they came from either way, so a moved file is detected rather than sent a
  # meaningless `If-None-Match`.
  #
  # This is a base class rather than an interface document: subclasses supply
  # the two lines that differ -- how the entries are read and how a change to
  # them is committed -- and inherit the rest. #24 will do the same for
  # snapshots, at a scale where the difference matters more.
  class ValidatorStore
    # A store whose backing bytes cannot be read as validators. Deliberately
    # fatal rather than treated as an empty store: silently re-downloading tens
    # of megabytes on every sync is the kind of failure that hides for months,
    # and the fix -- delete the file -- is in the message.
    class CorruptStore < Error; end

    # Reads validators, or nil when nothing is stored under the key. Nil is the
    # answer to "have we ever fetched this?", so it is not conflated with a
    # record that exists but carries no validators.
    def [](key)
      entries[key!(key)]
    end

    # Storing nil, or validators the publisher gave nothing to be conditional
    # with, is a delete: a record that cannot save a download is not worth
    # keeping, and leaving one behind makes #stale? lie about having a usable
    # copy.
    def []=(key, validators)
      normalized = key!(key)
      commit do |all|
        if validators.nil? || validators.empty?
          all.delete(normalized)
        else
          all[normalized] = validators
        end
      end
      validators
    end
    alias store []=

    def delete(key)
      normalized = key!(key)
      commit { |all| all.delete(normalized) }
    end

    def key?(key) = entries.key?(key!(key))

    def keys = entries.keys

    def size = entries.size

    def empty? = entries.empty?

    def clear
      commit(&:clear)
      self
    end

    def to_h = entries.transform_values(&:to_h)

    def inspect = "#<#{self.class} #{size} entr#{size == 1 ? "y" : "ies"}>"

    private

    # Keys reach here as symbols from source adapters and as URL strings from
    # ad-hoc callers; both have to survive a round-trip through JSON, which has
    # only strings.
    def key!(key)
      string = key.to_s.strip
      raise ArgumentError, "a validator key is required" if string.empty?

      -string
    end

    # A hash of key => Validators. Subclasses may rebuild it per call.
    def entries
      raise NotImplementedError, "#{self.class} must implement #entries"
    end

    # Yields the current entries for mutation and persists the result.
    def commit
      raise NotImplementedError, "#{self.class} must implement #commit"
    end
  end
end

require "active_sanction/validator_store/memory"
require "active_sanction/validator_store/file_system"
