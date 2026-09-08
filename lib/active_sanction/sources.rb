# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/configuration"
require "active_sanction/error"

module ActiveSanction
  # Every sanctions list this library knows how to read, filed under the key
  # its adapter declares.
  #
  #   ActiveSanction::Sources[:un_consolidated]   # => the adapter class
  #   ActiveSanction::Sources.keys                # => [:ofac_sdn, :un_consolidated, ...]
  #
  # The registry is open, and that is the point of this milestone. A bank with
  # an internal watchlist, or a gem adding a jurisdiction this one has not got
  # to, registers an adapter of its own without forking:
  #
  #   ActiveSanction::Sources.register(MyCompany::InternalWatchlist)
  #   ActiveSanction.configure { |c| c.sources = %i[ofac_sdn my_internal_watchlist] }
  #
  # Nothing here requires Sources::Base. Registration is duck-typed on `.key`
  # and `.new`, so a source backed by a database table rather than a published
  # file -- which has no URL to declare and no payload to fetch -- is a
  # first-class citizen rather than something that has to pretend to be a file
  # download. Base is the convenient way to write an adapter, not the price of
  # admission.
  #
  # Built-in adapters register themselves at the bottom of their own file, one
  # explicit `Sources.register(self)` line each, rather than being enrolled by
  # `inherited`. Auto-registering every subclass would also enrol the abstract
  # intermediates that adapters sharing a publisher will want (an OFAC base
  # holding the authority and the format for SDN and Consolidated both) and
  # every throwaway subclass a test defines.
  module Sources
    # Two lists cannot answer to one name. Raised at load time, which is where
    # this collision is cheap to fix.
    #
    # A ConfigurationError, like the two below it: all three are an
    # installation wired up wrong -- a key typed twice, a key typed wrong, an
    # adapter that never declared what it is -- and none of them is fixed by
    # waiting and trying again.
    class DuplicateKey < ConfigurationError; end

    # A key nothing is registered under: a typo in `config.sources`, a CLI
    # argument, or an adapter whose file was never required.
    class UnknownSource < ConfigurationError; end

    # An adapter that does not declare what the contract requires, or is asked
    # for a declaration it never made.
    class DeclarationError < ConfigurationError; end

    # The bytes of one of a source's files could not be obtained -- the
    # publisher confirmed a copy we do not hold, and re-asking for it in full
    # did not produce one either.
    #
    # Retryable: it is a publisher or an intermediary cache in a state it will
    # not be in an hour from now, and the next run usually just works.
    class MissingPayload < FetchError
      extend T::Sig

      sig { returns(T::Boolean) }
      def retryable? = retryable_or(true)
    end

    MUTEX = T.let(Mutex.new, Mutex)
    private_constant :MUTEX

    class << self
      extend T::Sig

      # An adapter is anything answering `.key` and `.new`, which is why every
      # signature here says `T.untyped` where a class goes and none of them
      # says `T.class_of(Sources::Base)`. That is the milestone this registry
      # exists for: a bank's internal watchlist, backed by a database table
      # with no URL and no payload, is a first-class source rather than
      # something pretending to be a file download. Narrowing these types would
      # quietly close what the class comment above promises is open.

      # Adds a source to the registry and returns it. Registering the same
      # class twice is a no-op, so a file that manages to get loaded under two
      # paths does not take the whole process down with it.
      sig { params(source: T.untyped).returns(T.untyped) }
      def register(source)
        key = registrable!(source)
        MUTEX.synchronize do
          claimed = registry[key]
          raise DuplicateKey, duplicate_message(key, source, claimed) if claimed && claimed != source

          registry[key] = source
        end
        source
      end

      # The adapter registered under a key.
      #
      # Raises rather than returning nil, because every caller of this method
      # is resolving a name a human typed -- into `config.sources`, into
      # `activesanction sync ofac_sdb` -- and a nil surfaces three layers later
      # as a NoMethodError that says nothing about the misspelling. The message
      # lists what *is* registered, which is also the answer to "why is my
      # adapter not being picked up" (its file was never required).
      sig { params(key: T.untyped).returns(T.untyped) }
      def [](key)
        name = key.to_sym
        registry.fetch(name) do
          raise UnknownSource, "no source registered as #{name.inspect}. Registered: #{list}"
        end
      end

      sig { params(key: T.untyped).returns(T::Boolean) }
      def registered?(key) = registry.key?(key.to_sym)

      # Every registered adapter, ordered by key so a CLI listing and a sync
      # summary do not reshuffle themselves between runs.
      sig { returns(T::Array[T.untyped]) }
      def all = registry.keys.sort.map { |key| registry[key] }

      sig { returns(T::Array[Symbol]) }
      def keys = registry.keys.sort

      sig { returns(Integer) }
      def size = registry.size

      sig { returns(T::Boolean) }
      def empty? = registry.empty?

      # The adapters a sync should run: what `config.sources` names, or every
      # registered source when it names nothing. An unknown key raises here,
      # at the start of the run, rather than after the other lists have been
      # downloaded.
      sig { params(configured: T.nilable(T::Array[Symbol])).returns(T::Array[T.untyped]) }
      def enabled(configured = ActiveSanction.config.sources)
        return all if configured.nil?

        configured.map { |key| self[key] }
      end

      # Drops a key and returns what was registered there, or nil. The
      # supported way to replace a built-in adapter with a patched one:
      #
      #   ActiveSanction::Sources.unregister(:ofac_sdn)
      #   ActiveSanction::Sources.register(MyCompany::PatchedOfacSdn)
      #
      # There is deliberately no `clear!`. Built-in adapters register on
      # require, and `require` runs once per process: a suite that emptied the
      # registry between examples would leave every later example running
      # against a library that has forgotten its own sources.
      sig { params(key: T.untyped).returns(T.untyped) }
      def unregister(key)
        MUTEX.synchronize { registry.delete(key.to_sym) }
      end

      private

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def registry
        @registry ||= T.let({}, T.nilable(T::Hash[Symbol, T.untyped]))
      end

      sig { returns(String) }
      def list = registry.empty? ? "(nothing)" : keys.join(", ")

      sig { params(source: T.untyped).returns(Symbol) }
      def registrable!(source)
        unless source.respond_to?(:key) && source.respond_to?(:new)
          raise InvalidArgument, "a source must answer .key and .new, got #{source.inspect}"
        end

        Definition.key!(source.key)
      end

      sig { params(key: Symbol, source: T.untyped, claimed: T.untyped).returns(String) }
      def duplicate_message(key, source, claimed)
        "cannot register #{source} as #{key.inspect}: #{claimed} already claims that key. A key is the public " \
          "name of a list -- in configuration, in stored snapshots, in every match result that cites it -- so two " \
          "lists cannot share one. Give the new source a different key, or call " \
          "ActiveSanction::Sources.unregister(#{key.inspect}) first if you mean to replace #{claimed}."
      end
    end
  end
end

require "active_sanction/sources/definition"
require "active_sanction/sources/base"
