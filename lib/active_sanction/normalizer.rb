# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/normalizer/cache"
require "active_sanction/normalizer/dictionary"
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
  #   ActiveSanction::Normalizer.call("PJSC Gazprom", type: :organization).value
  #   # => "gazprom"
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
  # ### The dictionaries
  #
  # `type:` is what turns on stage 6, the pass that drops the tokens carrying
  # no identifying information: `LTD` and `COMPANY` from an organization,
  # `SHAYKH` from a person. It attaches here rather than to Form because the
  # lists apply per entity type and are configurable, neither of which a string
  # knows anything about; Dictionary is what is on them and why.
  #
  # Passing no type is not a lesser answer, it is a different question:
  # "AERO-CARIBBEAN" as a bare string folds to `aero caribbean` whatever a
  # dictionary says. A caller that has an Entity in hand should pass
  # `entity.type`, and both sides of a comparison have to pass the same one --
  # a query folded as an organization against an index folded as nothing is
  # the same silent mismatch this class exists to prevent, one stage further
  # down.
  #
  # A host's own lists reach the process-wide instance through configuration:
  #
  #   ActiveSanction.configure do |c|
  #     c.normalizer_dictionary = { legal_forms: %w[OYJ TBK] }
  #   end
  #
  # An instance can pin one instead -- `Normalizer.new(dictionary:)` -- which
  # is what makes a fold reproducible against a dictionary that is not the one
  # the host configured.
  class Normalizer
    extend T::Sig

    sig { returns(Cache) }
    attr_reader :cache

    sig { params(cache_limit: Integer, dictionary: T.nilable(Dictionary)).void }
    def initialize(cache_limit: Cache::DEFAULT_LIMIT, dictionary: nil)
      @cache = T.let(Cache.new(limit: cache_limit), Cache)
      @dictionary = T.let(dictionary, T.nilable(Dictionary))
    end

    # The pinned dictionary, or the configured one. Resolved per call rather
    # than captured at construction because DEFAULT is built at load, which is
    # before an application's initializer has run.
    sig { returns(Dictionary) }
    def dictionary = @dictionary || ActiveSanction.config.normalizer_dictionary

    # The folded form of anything that responds to `to_s`, which is a String or
    # a Name, optionally for a given entity type -- `:individual`,
    # `:organization`, `:vessel`, `:aircraft`, or none.
    #
    # Idempotent in the sense the acceptance criterion asks for --
    # `call(call(x).value, type:).value == call(x, type:).value` -- because the
    # fold's output is already lowercase, unmarked, punctuation-free and
    # single-spaced, and a stripped token cannot come back to be stripped
    # again.
    sig { params(value: T.untyped, type: T.nilable(Symbol)).returns(Form).checked(:tests) }
    def call(value, type: nil)
      string = value.to_s
      stoplist = dictionary.stoplist(type)
      return cache.fetch(string) { Form.new(string) } if stoplist.nil?

      # The type and the lists in force are both part of the answer, so both
      # are part of the key. The leading NUL is what keeps a composite key from
      # colliding with the bare string of an untyped call; no name a publisher
      # writes begins with one.
      cache.fetch("\u0000#{stoplist.key}\u0000#{string}") { Form.new(string, stoplist: stoplist) }
    end

    class << self
      extend T::Sig

      # Delegates to DEFAULT. This is the call site everything in the library
      # uses; see the class comment for why there is only one.
      sig { params(value: T.untyped, type: T.nilable(Symbol)).returns(Form).checked(:tests) }
      def call(value, type: nil) = DEFAULT.call(value, type: type)
    end

    # Built at load rather than memoized on first use, so nothing has to
    # synchronize its construction. It holds a cache and a mutex, and reads its
    # dictionary from the configuration on each call rather than holding one,
    # which is why one process-wide instance is enough.
    DEFAULT = T.let(new, Normalizer)
  end
end
