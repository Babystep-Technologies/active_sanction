# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/normalizer/cache"
require "active_sanction/normalizer/form"

module ActiveSanction
  # The one place a name is folded into the form a comparison runs against.
  #
  #   form = ActiveSanction::Normalizer.call("Bélarus")
  #   form.value       # => "belarus"
  #   form.original    # => "Bélarus"
  #
  #   ActiveSanction::Normalizer.call("CO., LTD.").tokens   # => ["co", "ltd"]
  #   ActiveSanction::Normalizer.call(name)                 # a Name works too
  #
  # Stage 1 of the matching pipeline: everything a query is compared against
  # has been through here, and so has the query. Form documents what the fold
  # does and why each stage is there; this class is the entry point and the
  # cache in front of it.
  #
  # ### Why one entry point rather than a method on each side
  #
  # Because a matcher whose index and query fold differently does not fail --
  # it silently stops matching, on exactly the records the difference touches.
  # If the indexer strips `'` and the query path does not, `O'Brien` is
  # unreachable from `O'Brien`, the suite still passes, and the symptom is a
  # sanctioned person reported clean. That is the most expensive bug this
  # library can have and it is invisible from either side alone, so there is
  # one code path and both sides call it. `Normalizer.call` is that path.
  #
  # It also means normalization is a versioned decision. Changing anything in
  # Form changes every folded string in the library at once, which is what a
  # stored index (#31) has to be rebuilt against and what a screening decision
  # recorded under an older gem was made under -- see MatchResult's
  # reproducibility stamp (#33).
  #
  # ### Instances
  #
  # `Normalizer.call` runs against DEFAULT, a process-wide instance whose cache
  # is shared and internally synchronized. An instance exists as a seam rather
  # than for configuration: a caller that wants its own cache -- a smaller one,
  # or one it can discard after a batch -- builds `Normalizer.new`, and the
  # fold it gets is identical.
  #
  #   normalizer = ActiveSanction::Normalizer.new(cache_limit: 1_000)
  #   normalizer.call("Al-Qaida").value    # => "al qaida"
  #
  # The dictionaries that strip legal forms and honorifics (#27) attach here,
  # not to Form: they apply per entity type, so they are a second stage over
  # tokens rather than another pass over the string.
  class Normalizer
    extend T::Sig

    sig { returns(Cache) }
    attr_reader :cache

    sig { params(cache_limit: Integer).void }
    def initialize(cache_limit: Cache::DEFAULT_LIMIT)
      @cache = T.let(Cache.new(limit: cache_limit), Cache)
    end

    # The folded form of anything that responds to `to_s`, which is a String or
    # a Name. Idempotent in the sense the acceptance criterion asks for --
    # `call(call(x).value).value == call(x).value` -- because the fold's output
    # is already lowercase, unmarked, punctuation-free and single-spaced, so
    # every stage has nothing left to do on a second pass.
    sig { params(value: T.untyped).returns(Form).checked(:tests) }
    def call(value)
      string = value.to_s
      cache.fetch(string) { Form.new(string) }
    end

    class << self
      extend T::Sig

      # Delegates to DEFAULT. This is the call site everything in the library
      # uses; see the class comment for why there is only one.
      sig { params(value: T.untyped).returns(Form).checked(:tests) }
      def call(value) = DEFAULT.call(value)
    end

    # Built at load rather than memoized on first use, so nothing has to
    # synchronize its construction. It holds a cache and a mutex and no
    # configuration, which is why one process-wide instance is enough.
    DEFAULT = T.let(new, Normalizer)
  end
end
