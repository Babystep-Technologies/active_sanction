# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  class Normalizer
    # A bounded memo of folded names, because the same string is normalized
    # over and over: an index build (#31) folds every name once per index it
    # feeds it to, an entity's aliases repeat across records, and a rescreening
    # run (#60) folds the same book of subjects against every new snapshot.
    # Folding is five passes over a string and a Unicode normalization, which
    # is cheap once and worth not doing 200,000 times.
    #
    # Thread-safe, because the query path is shared: one web process screens on
    # many threads against one index, and they all reach the same normalizer.
    # The value being memoized is a pure function of the key, so the only thing
    # the lock protects is the Hash's own consistency -- never the computation,
    # which runs outside it. Two threads racing on a cold key both fold the
    # string and store equal results, which costs one redundant fold and is
    # much cheaper than serializing every normalization behind one mutex.
    #
    # @api private
    class Cache
      extend T::Sig

      # Sized to hold the whole searchable corpus, which is roughly 46,000 name
      # strings across the launch lists, with room for the query names a
      # long-running process accumulates beside them. At that ceiling the cache
      # is on the order of 20 MB -- against an inverted index over the same
      # corpus, which is considerably larger.
      #
      # A host that screens rarely and cares about resident memory can build
      # its own `Normalizer.new(cache_limit:)` with a smaller one; nothing is
      # lost but the memoization.
      DEFAULT_LIMIT = T.let(50_000, Integer)

      sig { returns(Integer) }
      attr_reader :limit

      sig { params(limit: Integer).void }
      def initialize(limit: DEFAULT_LIMIT)
        raise InvalidArgument, "limit must be at least 1, got #{limit}" unless limit.positive?

        @limit = T.let(limit, Integer)
        @mutex = T.let(Mutex.new, Mutex)
        @entries = T.let({}, T::Hash[String, Form])
      end

      # The memoized fold of `key`, computed by the block on a miss.
      #
      # A full cache is emptied rather than evicted from one entry at a time.
      # An LRU would need a write on every read, which turns a hit -- the case
      # this exists for -- into lock contention on the query path. The trade is
      # that a process which does cross the ceiling occasionally refolds a warm
      # set, costing microseconds; the case the cache is actually for is an
      # index build, where the corpus fits under the ceiling and the clear
      # never fires at all.
      sig { params(key: String, block: T.proc.returns(Form)).returns(Form).checked(:tests) }
      def fetch(key, &block)
        cached = @mutex.synchronize { @entries[key] }
        return cached if cached

        form = block.call
        @mutex.synchronize do
          @entries.clear if @entries.size >= @limit
          @entries[key] = form
        end
        form
      end

      sig { returns(Integer) }
      def size = @mutex.synchronize { @entries.size }

      sig { void }
      def clear
        @mutex.synchronize { @entries.clear }
        nil
      end
    end
  end
end
