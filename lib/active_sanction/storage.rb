# frozen_string_literal: true

require "active_sanction/error"

module ActiveSanction
  # Where a synced list lives between the sync that fetched it and the
  # screening run that reads it.
  #
  #   store = ActiveSanction::Storage::Memory.new
  #   store.write_snapshot(ActiveSanction::Sources[:ofac_sdn].new.sync)
  #   store.read_snapshot(:ofac_sdn)   # => Snapshot
  #
  # The namespace holds one interface (Storage::Base), the in-memory
  # implementation of it, and the metadata object a store can answer with
  # without loading a list. The adapters that persist anywhere else -- gzipped
  # JSON on disk (#24), ActiveRecord (#25), whatever a host writes privately --
  # are subclasses of Base and nothing here has to know they exist.
  module Storage
    # A source that has never been synced, or whose snapshot has been deleted,
    # asked for by name. Raised rather than answered with nil wherever a caller
    # named the source itself: screening against a list that turns out not to
    # be there has to fail loudly, because the result of screening against
    # nothing is a clean report.
    class MissingSnapshot < Error; end
  end
end

require "active_sanction/storage/meta"
require "active_sanction/storage/base"
require "active_sanction/storage/memory"
