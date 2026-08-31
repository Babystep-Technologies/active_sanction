# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"
require "active_sanction/snapshot"
require "active_sanction/sources"
require "active_sanction/storage"
require "active_sanction/storage/meta"

module ActiveSanction
  module Storage
    # The persistence contract: one snapshot per source, written whole and read
    # back whole.
    #
    #   store = ActiveSanction::Storage::Memory.new
    #   store.write_snapshot(ActiveSanction::Sources[:ofac_sdn].new.sync)
    #
    #   store.sources                    # => [:ofac_sdn]
    #   store.read_snapshot(:ofac_sdn)   # => Snapshot, or nil
    #   store.snapshot_meta(:ofac_sdn)   # => Meta: fetched_at, checksum, record_count
    #   store.each_entity { |entity| ... }
    #
    # ### The rule this class exists to enforce
    #
    # **Nothing on the query path may name a concrete store.** The matcher
    # (#33) is written against these five methods and against nothing else,
    # which is what lets an installation put its lists in gzipped JSON, in
    # Postgres, or in a store it wrote itself without any of that reaching the
    # code that decides whether two names are the same person. It is also why
    # this interface lands before the matcher rather than after it: an
    # interface extracted from a matcher that already reads files is an
    # interface shaped like files.
    #
    # ### What an adapter implements
    #
    # Four methods, and they are deliberately coarse:
    #
    #   write_snapshot(snapshot)   # replace this source's list
    #   read_snapshot(source)      # => Snapshot, or nil if never synced
    #   delete_snapshot(source)    # => true if there was one
    #   sources                    # => [:ofac_sdn, ...], sorted
    #
    # A snapshot is the unit because it is the unit that carries a checksum. A
    # store that wrote entities one at a time could leave a list half-replaced
    # -- 8,000 of OFAC's 19,015 -- that still reads back as a valid list, and
    # nothing downstream would be able to tell. Both planned adapters can honour
    # that: #24 writes to a temporary file and renames it, #25 wraps the upsert
    # in a transaction. Neither needs a finer-grained interface to do it.
    #
    # Everything else here is derived from those four and inherited, so an
    # adapter that implements them gets the rest right by default. An adapter
    # that can answer one of them better should override it -- `snapshot_meta`
    # off a sidecar file rather than by reading the list, `each_entity` off a
    # cursor rather than by materializing a snapshot -- and the shared
    # conformance group ("a storage adapter") is what holds an override to
    # meaning the same thing.
    class Base
      extend T::Sig

      # Replaces everything stored for `snapshot.source` and returns the
      # snapshot. One source at a time: a sync isolates its lists from each
      # other (#34), so a write must not be able to disturb a list it was not
      # given.
      sig { params(_snapshot: T.untyped).returns(Snapshot) }
      def write_snapshot(_snapshot)
        raise NotImplementedError, "#{self.class} must implement #write_snapshot(snapshot)"
      end

      # The stored snapshot, or nil when the source has never been synced.
      #
      # Nil is the honest answer to "have we ever synced this?" and callers
      # that cannot proceed without a list should ask through #fetch_snapshot,
      # which raises. What an adapter must never do is answer an empty snapshot:
      # "nothing was ever fetched" and "this list has nobody on it" are
      # different states, and only one of them is safe to screen against.
      sig { params(_source: T.untyped).returns(T.nilable(Snapshot)) }
      def read_snapshot(_source)
        raise NotImplementedError, "#{self.class} must implement #read_snapshot(source)"
      end

      # Drops a source's snapshot and returns whether there was one to drop.
      # Deleting a source that was never stored is not an error: it is the
      # state the caller asked for.
      sig { params(_source: T.untyped).returns(T::Boolean) }
      def delete_snapshot(_source)
        raise NotImplementedError, "#{self.class} must implement #delete_snapshot(source)"
      end

      # Every source with a stored snapshot, sorted, so a CLI listing and a
      # sync summary do not reshuffle themselves between runs.
      sig { returns(T::Array[Symbol]) }
      def sources
        raise NotImplementedError, "#{self.class} must implement #sources"
      end

      # What is stored for a source without reading the list: fetched_at,
      # checksum, record_count. Nil when nothing is stored.
      #
      # Derived here by reading the snapshot, which is correct but is the thing
      # Meta exists to avoid. An adapter that keeps this separately -- #24's
      # `meta.json` sidecar, a metadata row -- overrides it and answers without
      # deserializing tens of megabytes to print an age.
      sig { params(source: T.untyped).returns(T.nilable(Meta)) }
      def snapshot_meta(source)
        snapshot = read_snapshot(source)
        snapshot && Meta.from_snapshot(snapshot)
      end

      # The stored snapshot, raising when there is none. For a caller that
      # named the source itself and cannot do its job without it -- screening
      # against a list that is not there returns a clean report, which is the
      # most expensive thing this library can get wrong.
      sig { params(source: T.untyped).returns(Snapshot) }
      def fetch_snapshot(source)
        key = source_key!(source)
        read_snapshot(key) || raise(MissingSnapshot, missing_message(key))
      end

      # Every entity from every stored list, or from the ones named:
      #
      #   store.each_entity { |entity| index.add(entity) }
      #   store.each_entity(sources: %i[ofac_sdn]).lazy.select { |e| e.type == :vessel }
      #
      # An Enumerator without a block, and it streams: the index build (#31)
      # walks every entity of every list, and materializing an array of ~25,000
      # entities across every source before the first one is yielded is a cost
      # nothing here needs to pay. Snapshots are read one at a time and each is
      # released before the next is opened.
      #
      # Naming sources changes what a missing one means. `sources: nil` asks
      # for whatever is stored, where there is nothing to be missing; naming a
      # list that has never been synced raises MissingSnapshot rather than
      # yielding fewer entities, because a screening run that quietly covers
      # two of the three lists it was configured with is indistinguishable from
      # one that covers all three.
      sig do
        params(sources: T.untyped, block: T.nilable(T.proc.params(entity: T.untyped).void)).returns(T.untyped)
      end
      def each_entity(sources: nil, &block)
        return enum_for(:each_entity, sources: sources) unless block

        each_snapshot(sources) { |snapshot| snapshot.entities.each(&block) }
        self
      end

      # Whether a source has a stored snapshot. Answered off #sources rather
      # than by reading one, so asking is cheap for every adapter.
      sig { params(source: T.untyped).returns(T::Boolean) }
      def stored?(source) = sources.include?(source_key!(source))

      sig { returns(Integer) }
      def size = sources.size

      sig { returns(T::Boolean) }
      def empty? = sources.empty?

      # Drops every snapshot and returns the store. Deliberately spelled out
      # rather than implemented as a truncation, so an adapter only ever has to
      # get one deletion path right.
      sig { returns(T.self_type) }
      def clear
        sources.each { |source| delete_snapshot(source) }
        self
      end

      sig { returns(String) }
      def inspect = "#<#{self.class} #{list}>"

      private

      # The snapshots a caller asked for, in the order they were asked for.
      sig { params(named: T.untyped, block: T.proc.params(snapshot: Snapshot).void).void }
      def each_snapshot(named, &block)
        return Array(named).each { |source| block.call(fetch_snapshot(source)) } unless named.nil?

        sources.each do |source|
          snapshot = read_snapshot(source)
          block.call(snapshot) if snapshot
        end
      end

      # The same rule the registry holds a source key to, applied here for the
      # reason that rule exists: a key is typed by a human -- into
      # configuration, into a CLI argument -- and it is a directory name to
      # every adapter that writes files. Sharing it means #24 cannot be handed
      # a key that escapes its root, and it means a name that is not a source
      # fails the same way wherever it is typed.
      sig { params(value: T.untyped).returns(Symbol) }
      def source_key!(value) = Sources::Definition.key!(value)

      # A Snapshot and not merely something snapshot-shaped. What makes a
      # stored list auditable is that its checksum was computed over its own
      # content by the class that knows how; a hash of the right shape carries
      # a checksum somebody typed.
      sig { params(value: T.untyped).returns(Snapshot) }
      def snapshot!(value)
        unless value.is_a?(Snapshot)
          raise ArgumentError, "write_snapshot takes an ActiveSanction::Snapshot, got #{value.class}"
        end

        value
      end

      sig { params(key: Symbol).returns(String) }
      def missing_message(key)
        "no snapshot stored for #{key.inspect}. Stored: #{list}. A source has to be synced before it can be " \
          "screened against -- ActiveSanction::Sources[#{key.inspect}].new.sync"
      end

      sig { returns(String) }
      def list = empty? ? "(nothing)" : sources.join(", ")
    end
  end
end
