# frozen_string_literal: true

require "active_sanction/storage/base"

module ActiveSanction
  module Storage
    # Snapshots for the life of one process, and no longer.
    #
    #   store = ActiveSanction::Storage::Memory.new
    #   store.write_snapshot(source.sync)
    #
    #   ActiveSanction::Storage::Memory.new([ofac, un])   # seeded, for a spec
    #
    # Two jobs, and the second is the one that keeps it honest. It is a real
    # storage adapter -- a process that syncs and screens without wanting to
    # own a directory should use it, and pays only a full download on each
    # boot. It is also the test double for storage everywhere in this suite,
    # which is why it is written as a subclass of Base implementing the same
    # four methods as everything else rather than as a Hash a spec passes
    # around: a double that is not held to the contract stops describing what
    # the real adapters do, usually a release or two before anybody notices.
    #
    # Snapshots are frozen by construction, so what is handed back is the
    # object that was stored and nothing has to be copied to keep a caller from
    # editing the list underneath the store. The hash itself is guarded by a
    # mutex: a web process screens on many threads (#33) while a scheduled sync
    # replaces a list under them, and a replacement has to be atomic from a
    # reader's point of view -- a thread mid-screen holds the snapshot it
    # started with and finishes against a consistent list.
    class Memory < Base
      def initialize(snapshots = [])
        @snapshots = {}
        @mutex = Mutex.new
        Array(snapshots).each { |snapshot| write_snapshot(snapshot) }
        super()
      end

      def write_snapshot(snapshot)
        stored = snapshot!(snapshot)
        @mutex.synchronize { @snapshots[stored.source] = stored }
        stored
      end

      def read_snapshot(source)
        key = source_key!(source)
        @mutex.synchronize { @snapshots[key] }
      end

      def delete_snapshot(source)
        key = source_key!(source)
        @mutex.synchronize { !@snapshots.delete(key).nil? }
      end

      def sources = @mutex.synchronize { @snapshots.keys.sort }
    end
  end
end
