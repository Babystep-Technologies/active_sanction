# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  # The one rescue that covers this library.
  #
  #   begin
  #     ActiveSanction.sync!
  #   rescue ActiveSanction::Error => e
  #     raise unless e.retryable?
  #
  #     RetryLater.enqueue(e.source_id)
  #   end
  #
  # Every error raised out of a public method answers to this, and carries
  # what a caller needs to decide between the only three responses there are
  # to a screening failure: **retry this** (`retryable?`), **alert somebody**
  # (anything else that is not the caller's fault), and **this is a bug in my
  # call** (ConfigurationError, InvalidArgument, QueryError). None of those
  # decisions should be made by matching on a message string, so none of them
  # has to be.
  #
  # ### The hierarchy
  #
  #     Error                      the marker; rescue this
  #       ConfigurationError       this installation is set up wrong; never retry
  #       SourceError              something went wrong with one list
  #         FetchError             the bytes could not be obtained
  #         ParseError             the bytes could not be read
  #         IntegrityError         the bytes are not what they claim to be
  #       StorageError             the store could not answer
  #       UnsupportedError         this object cannot do that
  #       InvalidArgument          a public method was called wrongly
  #         QueryError             ...specifically, with an unusable query
  #       MissingKey               a field or column that does not exist
  #
  # ### Why this is a module and not a class
  #
  # Because two of its members have to be something else as well. A caller who
  # passes `threshold: 300` has made the mistake Ruby has had a class for since
  # 1995, and `rescue ArgumentError` is what the code around this library
  # already says; asking every host application to learn a private synonym for
  # it would be this library exporting its own taxonomy into code that has no
  # reason to care. So InvalidArgument is an `::ArgumentError` and MissingKey is
  # a `::KeyError` -- and Ruby has one superclass to give. A module is what lets
  # them be both, and `rescue ActiveSanction::Error` covers them anyway, because
  # `rescue` matches with `===`, which a module answers.
  #
  # The trade is that `ActiveSanction::Error` cannot be raised or instantiated
  # itself. That is not a loss: an error that says only "something in the
  # sanctions library went wrong" is not one a caller could act on, and every
  # member below names a response.
  #
  # ### Stability
  #
  # This hierarchy is public API. Within a major version an error will not move
  # to a different parent, and an attribute will not be removed. New subclasses
  # may be added under an existing parent -- that is what keeps `rescue
  # ActiveSanction::FetchError` working when a new transport failure is given a
  # name of its own -- so a `case` over error classes should carry an `else`.
  module Error
    extend T::Sig
    extend T::Helpers

    # Only ever mixed into an exception class -- this is a marker for the
    # library's own failures, not a bag of attributes anything can wear.
    requires_ancestor { Exception }

    # Which list the failure belongs to, as the key its adapter declared, or
    # nil for a failure that is not about one list -- a bad configuration, an
    # unusable query, a store that will not open at all.
    #
    # Always set on a SourceError by the time it leaves the source, even when
    # the layer that raised it could not know: an HTTP client knows a URL, not
    # which sanctions list is at the other end of it. See #in_source.
    sig { returns(T.nilable(Symbol)) }
    attr_reader :source_id

    # The HTTP status behind the failure, where there was one. Nil for
    # everything that failed before a server answered -- a timeout, a refused
    # connection -- and for everything that is not a fetch.
    sig { returns(T.nilable(Integer)) }
    attr_reader :status

    # `retryable:` overrides whatever the subclass would have decided, for the
    # cases only the raising code knows about. Everything else is a subclass's
    # own answer; see #retryable?.
    sig do
      params(message: T.untyped, source_id: T.untyped, status: T.untyped, retryable: T.nilable(T::Boolean)).void
    end
    def initialize(message = nil, source_id: nil, status: nil, retryable: nil)
      @source_id = T.let(source_id&.to_sym, T.nilable(Symbol))
      @status = T.let(status&.to_i, T.nilable(Integer))
      @retryable = T.let(retryable, T.nilable(T::Boolean))
      super(message)
    end

    # Whether running the same call again could plausibly succeed.
    #
    # A first-class predicate rather than something a consumer reconstructs
    # from the message, because backoff is the one decision a host application
    # has to make in the request path and it should not be making it out of
    # English. False is the default and the safe answer: a failure nobody has
    # classified is one to look at rather than one to hammer.
    sig { returns(T::Boolean) }
    def retryable? = retryable_or(false)

    # The failure as data, for a log line or a job record that has to survive
    # the process.
    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h
      { error: self.class.name, message: message, source_id: source_id, status: status, retryable: retryable? }
        .compact
    end

    # Stamps the list this failure belongs to onto an error raised by a layer
    # that did not know it, and returns self so a rescue can re-raise in one
    # line. Never overwrites a source already recorded -- the innermost layer
    # that knew is the one that was right.
    sig { params(key: T.untyped).returns(T.self_type) }
    def in_source(key)
      @source_id = T.let(key&.to_sym, T.nilable(Symbol)) if @source_id.nil?
      self
    end

    private

    # What a subclass answers with when the raising code did not override it.
    # The override exists because the classification is occasionally something
    # only the call site knows -- a 404 from a publisher that rotates its URLs
    # weekly is worth another look, and one from a URL we hardcoded is not.
    sig { params(default: T::Boolean).returns(T::Boolean) }
    def retryable_or(default) = @retryable.nil? ? default : @retryable
  end

  # This installation is set up wrong: a blank User-Agent, a negative timeout,
  # a source key nothing is registered under, an ActiveRecord store whose
  # migration was never run.
  #
  # Never retryable, by definition -- nothing about waiting changes an
  # initializer -- and raised as early as the bad value can be seen, which for
  # a setting is where it is set rather than during a sync three hours later.
  # Separate from InvalidArgument: this means "this installation is
  # misconfigured", that means "this call is wrong", and only one of them is
  # fixed by editing an initializer.
  class ConfigurationError < StandardError
    extend T::Sig
    include Error

    sig { returns(T::Boolean) }
    def retryable? = false
  end

  # Something went wrong with one list. Carries #source_id, so a caller
  # rescuing a whole sync knows which publisher to name.
  #
  # Raised directly only where the failure fits none of the three below --
  # a source adapter that declares no URL, a payload the publisher confirmed
  # but would not serve.
  class SourceError < StandardError
    include Error
  end

  # The bytes could not be obtained: a timeout, a refused connection, a
  # redirect chain that does not terminate, a status the caller declared fatal.
  #
  # Carries #status where a server produced one, and answers #retryable? from
  # it. This is the error a host application backs off on, and the reason the
  # predicate exists: 503 and 429 are the publisher having a bad afternoon,
  # 403 and 404 are a request that will be just as wrong in ten minutes.
  class FetchError < SourceError
    extend T::Sig

    # 408 and 429 are the server asking to be asked again; 5xx is it failing to
    # answer at all. A 4xx outside those two is never in here: a 403 for a
    # missing User-Agent or a 404 for a retired URL says the request is wrong,
    # and repeating it wastes the publisher's capacity to make the same point.
    RETRYABLE_STATUSES = T.let(([408, 425, 429] + (500..599).to_a).freeze, T::Array[Integer])

    sig { returns(T::Boolean) }
    def retryable? = retryable_or(RETRYABLE_STATUSES.include?(status))
  end

  # The bytes arrived and could not be read as the format they were declared
  # to be: an HTML error page served under a `.xml` URL, a truncated download,
  # an encoding that cannot be decoded, a ZIP member that will not inflate.
  #
  # Distinct from a Parsers::Warning, which is one *row* that could not be read
  # while the rest of the file could. A list is not a file we control, and
  # refusing 19,321 records because one of them is malformed fails exactly when
  # the list is most needed -- so a bad row is a warning, and only a payload
  # that cannot be read at all raises this.
  #
  # ### Where
  #
  # A 25 MB XML payload that "is not XML" is not a diagnosable complaint, so
  # this carries a locator whenever the parser can produce one:
  #
  #   rescue ActiveSanction::ParseError => e
  #     e.line     # => 418_223
  #     e.record   # => 12_004      (1-based, in the order the file yielded them)
  #     e.offset   # => 8_388_608   (byte offset into the payload)
  #     e.locator  # => "line 418223"
  #
  # All three are nil where the parser cannot say -- libxml2 reports no
  # position for some failures, and a ZIP directory that ends inside an entry
  # header has an offset but no line. An error that cannot point at a line
  # still says what went wrong rather than pointing at the wrong one.
  class ParseError < SourceError
    extend T::Sig

    # 1-based line within the payload, or nil.
    sig { returns(T.nilable(Integer)) }
    attr_reader :line

    # 1-based index of the record being read, in the order the parser yielded
    # them, or nil. The locator that means something for a format with no
    # lines -- a spreadsheet, a stream of XML elements on one line.
    sig { returns(T.nilable(Integer)) }
    attr_reader :record

    # Byte offset into the payload, or nil.
    sig { returns(T.nilable(Integer)) }
    attr_reader :offset

    sig do
      params(message: T.untyped, line: T.nilable(Integer), record: T.nilable(Integer), offset: T.nilable(Integer),
             options: T.untyped).void
    end
    def initialize(message = nil, line: nil, record: nil, offset: nil, **options)
      @line = T.let(line, T.nilable(Integer))
      @record = T.let(record, T.nilable(Integer))
      @offset = T.let(offset, T.nilable(Integer))
      super(message, **options)
    end

    # Where in the payload, in the terms the parser could supply, or nil when
    # it could supply none. Appended to #to_s -- and so to #message, which is
    # defined in terms of it -- so a log line that records nothing but the
    # message still says where.
    sig { returns(T.nilable(String)) }
    def locator
      parts = []
      parts << "line #{line}" if line
      parts << "record #{record}" if record
      parts << "byte #{offset}" if offset
      parts.empty? ? nil : parts.join(", ")
    end

    sig { returns(String) }
    def to_s
      where = locator
      where ? "#{super} (at #{where})" : super
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h = super.merge({ line: line, record: record, offset: offset }.compact)
  end

  # The bytes are not what they claim to be: content that no longer hashes to
  # the checksum stored beside it, a snapshot filed under one source that says
  # it is another.
  #
  # Never repaired, and never answered with whatever could still be read. A
  # store that hands back the 8,000 records it managed to parse out of 19,015
  # produces a report that looks exactly like a clean one, which is the most
  # expensive thing this library can get wrong. An operator can always discard
  # the copy and re-sync; nobody can recover a screening decision made against
  # a list that was quietly half there.
  class IntegrityError < SourceError; end

  # The store could not answer: a list that has never been synced, a snapshot
  # written under a schema this version does not read, a validator file that
  # is not readable as validators.
  #
  # About the *store* rather than about the publisher, which is the difference
  # that matters when deciding what to do: a FetchError is somebody else's
  # outage, and this is local state to repair or re-sync.
  class StorageError < StandardError
    include Error
  end

  # This object cannot do that: a backend without the capability asked for, an
  # abstract method a subclass never implemented.
  #
  # A StandardError rather than the `NotImplementedError` that reads more
  # naturally for the second case, deliberately. `NotImplementedError` is a
  # ScriptError, so it is not caught by `rescue StandardError` -- and one
  # adapter forgetting `#parse` would take down a sync run that is supposed to
  # isolate each source's failure from the others, which is the run's single
  # most important property.
  class UnsupportedError < StandardError
    include Error
  end

  # A public method was called with something it cannot use: a threshold of
  # 300, a Snapshot whose `record_count` disagrees with its entities, a name
  # value object built with no value.
  #
  # This is the "bug in my call" branch, and it is an `::ArgumentError` as well
  # as an ActiveSanction::Error so that it reads as one to code that has never
  # heard of this library. Messages are written for whoever has to fix the
  # call, or the record: `"limit must be at least 1, got 0"` rather than a type
  # name.
  class InvalidArgument < ::ArgumentError
    include Error
  end

  # A screening query that cannot be run: an empty `sources:` list, a threshold
  # outside 0..100, a limit of zero, a field spelled two ways at once.
  #
  # Its own class because a query is user input in a way the rest of this is
  # not -- it is frequently built from a form or an API request -- and a
  # service turning a bad query into a 422 and a bad configuration into a 500
  # should not have to tell them apart by reading messages.
  class QueryError < InvalidArgument; end

  # A field or column that does not exist, asked for by name: `row[:nmae]`, or
  # a path into an XML record that no element supplies.
  #
  # A `::KeyError`, because it is what `Hash#fetch` raises and these methods
  # are `fetch` in everything but name. Almost always a typo in an adapter
  # rather than a question about the data, so the message lists what *is*
  # there.
  class MissingKey < ::KeyError
    include Error
  end
end
