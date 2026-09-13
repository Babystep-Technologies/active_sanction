# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"
require "active_sanction/instrumentation/event"
require "active_sanction/instrumentation/notifications"

module ActiveSanction
  # Structured events from every stage, so a host can measure this library
  # without monkeypatching it.
  #
  #   ActiveSanction.configure do |c|
  #     c.instrumenter = ->(event) do
  #       StatsD.timing("sanctions.#{event.name}", event.duration_ms, tags: ["source:#{event.source}"])
  #     end
  #   end
  #
  # Six events, and they are the operational questions a compliance
  # installation is actually asked: is the data fresh, did a fetch fail, how
  # long did screening take, which source is degrading.
  #
  # | Event | Emitted by | Asks |
  # |---|---|---|
  # | `:fetch` | Fetcher | Did bytes move, and what did the publisher answer? |
  # | `:parse` | Sources::Base | How many records came out, and how many rows could not be read? |
  # | `:store` | Sync, Client#import | Which list version was written, and how big is it? |
  # | `:"index.build"` | Matcher.build | What did building the index cost, and how much is resident? |
  # | `:screen` | Matcher | How long did a query take, and what did it consult? |
  # | `:sync` | Sync | What did a whole run do? |
  #
  # The payload keys of each are enumerated in
  # [`docs/api_stability.md`](../../docs/api_stability.md) and are public API:
  # a dashboard built on them is held to the same promise as a method call, and
  # a key is not removed or repurposed without the deprecation path. Keys may
  # be **added** to an event, so a subscriber reads the keys it knows and
  # ignores the rest.
  #
  # ### A subscriber is anything answering `#call(event)`
  #
  # A lambda, a Method, an object with a `call`. There is no registry and no
  # base class to inherit, because the whole interface is one method and a
  # registry would be a second thing to configure. A host wanting several
  # subscribers composes them itself -- `->(event) { subscribers.each { |s| s.call(event) } }` --
  # which is one line and is exactly what a fan-out registry here would be.
  #
  # Rails hosts have one already: see Notifications, which republishes every
  # event into `ActiveSupport::Notifications` under `<name>.active_sanction`.
  # It is an adapter rather than a dependency -- nothing here requires
  # ActiveSupport, and the class refuses to build in a process that has not
  # loaded it.
  #
  # ### Nothing is listening by default, and that costs nothing
  #
  # `instrumenter` defaults to nil, and a nil instrumenter is not a no-op
  # object that gets called and returns -- it is a branch taken before
  # anything is allocated. `.instrument` with no instrumenter calls the block
  # with a payload that discards writes and returns, so a stage that fills in
  # fifteen fields allocates no Hash and builds no Event. This is what keeps
  # the #37 benchmarks where they were.
  #
  # ### A subscriber must be safe to call from several threads
  #
  # `sync!(concurrency: 3)` fetches from three publishers at once, and the
  # `:fetch`, `:parse` and `:store` events of those three arrive on three
  # threads. Nothing here serializes them -- a lock around a subscriber would
  # make instrumentation a source of contention in the one place this library
  # deliberately fans out. A subscriber that appends to a plain Array wants a
  # Mutex of its own; one that hands an event to a metrics client is already
  # fine, because those are.
  #
  # The `:screen` event is the same statement from the other direction: a
  # Matcher is screened from every thread a host has, so a subscriber counting
  # queries is counting them concurrently.
  #
  # ### A raising subscriber cannot break a sync
  #
  # Instrumentation is a measurement of the work and is never part of it.
  # A subscriber that raises has its exception caught, reported once, and
  # dropped; the stage it was measuring carries on and returns what it was
  # going to return. The converse is equally deliberate: **instrumentation
  # never swallows the library's own exceptions**. An event is emitted for a
  # stage that raised, carrying `error:`, and then the exception continues
  # exactly as if nothing were listening.
  #
  # @see Event
  # @see Notifications
  module Instrumentation
    extend T::Sig

    # Every event name this library emits. Enumerated so a host can assert
    # against the list rather than discovering a name in production, and
    # frozen because it is the published vocabulary -- see the class comment
    # on what may and may not change about it.
    EVENTS = T.let(%i[fetch parse store index.build screen sync].freeze, T::Array[Symbol])

    # What a stage's block is handed when nothing is listening.
    #
    # A stage writes its measurements into the payload as it goes --
    # `event[:records] = parsed.size` -- and those writes have to go
    # somewhere even when there is no subscriber to read them. Somewhere is
    # here, and it is one frozen object shared by every call rather than a
    # Hash allocated per stage, which is what makes an uninstrumented
    # screening call cost a branch.
    #
    # @api private
    class Discard
      extend T::Sig

      sig { params(_key: Symbol, value: T.untyped).returns(T.untyped) }
      def []=(_key, value)
        value
      end

      sig { params(_key: Symbol).returns(NilClass) }
      def [](_key) = nil

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h = {}
    end
    private_constant :Discard

    DISCARD = T.let(Discard.new.freeze, Discard)
    private_constant :DISCARD

    @failures = T.let({}, T::Hash[String, TrueClass])
    @mutex = T.let(Mutex.new, Mutex)

    class << self
      extend T::Sig

      # Times a stage, hands the finished Event to `instrumenter`, and returns
      # whatever the stage returned.
      #
      #   Instrumentation.instrument(instrumenter, :parse, { source: :ofac_sdn }) do |event|
      #     entities = parse(raw)
      #     event[:records] = entities.size
      #     entities
      #   end
      #
      # The block is handed the payload so it can record what is only known
      # once the work is done, which is most of what is worth recording. What
      # it is handed when nobody is listening discards those writes -- so the
      # block reads the same either way and the uninstrumented path allocates
      # nothing.
      #
      # A stage that raises still emits, with `error:` set, and then the
      # exception goes on. A subscriber that raises does not.
      #
      # @param instrumenter [#call, nil] nil means nothing is listening
      # @param name [Symbol] one of EVENTS
      # @param payload [Hash, nil] what is known before the stage runs
      # @api private
      sig do
        params(instrumenter: T.untyped, name: Symbol, payload: T.nilable(T::Hash[Symbol, T.untyped]),
               block: T.proc.params(payload: T.untyped).returns(T.untyped)).returns(T.untyped)
      end
      def instrument(instrumenter, name, payload = nil, &block)
        return block.call(DISCARD) if instrumenter.nil?

        fields = payload.nil? ? {} : payload.dup
        started_at = Time.now.utc
        began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          block.call(fields)
        rescue StandardError => e
          fields[:error] = e
          raise
        ensure
          emit(instrumenter, name, fields, started_at,
               (Process.clock_gettime(Process::CLOCK_MONOTONIC) - began).to_f)
        end
      end

      # Publishes one already-measured event. For a stage whose duration is
      # known without wrapping it -- Sync measures each source itself, because
      # a run is several sources deep and the timings have to agree with the
      # Report it returns.
      #
      # @api private
      sig do
        params(instrumenter: T.untyped, name: Symbol, payload: T::Hash[Symbol, T.untyped], started_at: Time,
               duration: Float).void
      end
      def emit(instrumenter, name, payload, started_at, duration)
        return if instrumenter.nil?

        deliver(instrumenter, Event.new(name: name, payload: payload, started_at: started_at, duration: duration))
      end

      # Forget which subscriber failures have already been reported, so the
      # next one is reported again. For a spec that asserts a broken
      # subscriber is reported; nothing in a running application should call
      # it.
      sig { void }
      def reset!
        @mutex.synchronize { @failures.clear }
      end

      private

      # The isolation. A subscriber is a host's code running inside our stack,
      # and a metrics client with a full queue or a typo in a tag must not be
      # able to fail a sanctions sync.
      sig { params(instrumenter: T.untyped, event: Event).void }
      def deliver(instrumenter, event)
        instrumenter.call(event)
      rescue StandardError => e
        report(instrumenter, event, e)
      end

      # Dropped, but never silently: a subscriber that is not recording
      # anything is a dashboard that is quietly wrong, which is worse than one
      # that is visibly missing.
      #
      # Reported once per subscriber, event name and exception class, the way
      # Deprecation reports once per call site and for the same reason -- a
      # subscriber that raises on `:screen` raises on every query, and a
      # service at any volume would spend more of its log on this than on its
      # own work. Call .reset! to hear about it again.
      sig { params(instrumenter: T.untyped, event: Event, error: StandardError).void }
      def report(instrumenter, event, error)
        return unless first_time?("#{instrumenter.class}/#{event.name}/#{error.class}")

        message = "[active_sanction] instrumenter #{instrumenter.class} raised on the #{event.name} event " \
                  "(#{error.class}: #{error.message}); the event was dropped and the work carried on. " \
                  "Further failures of this shape are not reported."
        logger = ActiveSanction.config.logger
        return Kernel.warn(message) if logger.nil?

        logger.respond_to?(:warn) ? logger.warn(message) : logger.info(message)
      end

      sig { params(key: String).returns(T::Boolean) }
      def first_time?(key)
        @mutex.synchronize do
          next false if @failures.key?(key)

          @failures[key] = true
        end
      end
    end
  end
end
