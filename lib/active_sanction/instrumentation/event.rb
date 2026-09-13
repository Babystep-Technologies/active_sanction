# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  module Instrumentation
    # One thing this library did, after it finished doing it.
    #
    #   ActiveSanction.configure do |c|
    #     c.instrumenter = ->(event) { StatsD.timing("sanctions.#{event.name}", event.duration_ms) }
    #   end
    #
    #   event.name       # => :fetch
    #   event.duration   # => 2.418, seconds
    #   event[:source]   # => :ofac_sdn
    #   event[:bytes]    # => 12_845_056
    #
    # A subscriber is handed a finished event and never a running one. That is
    # the difference between this and a block-based instrumenter, and it is
    # deliberate: a subscriber that cannot wrap the work cannot retry it,
    # cannot swallow its exception, and cannot leave a `begin` half-entered if
    # it raises. The cost is that nothing here can time a stage from the
    # outside -- which nothing needs to, since every event already carries its
    # own duration.
    #
    # ### Every event carries a duration and enough to correlate it
    #
    # There are no anonymous timings. `duration` is monotonic seconds, taken
    # across the stage this event describes, and `started_at` is the wall
    # clock at its start -- both, because one answers "how long did it take"
    # and the other answers "when, in the log I am reading beside this". Every
    # event but `screen` names a `source`; `screen` names the snapshot
    # checksums it consulted, which is the same question asked of a query.
    #
    # ### An event is emitted for work that raised
    #
    # With `error` set to the exception, and with whichever payload keys the
    # stage had filled in before it failed. A publisher that starts timing out
    # is exactly what a host is watching for, and an instrumentation layer
    # that only reports successes cannot see it. See Instrumentation.
    #
    # Frozen, and its payload with it, so a subscriber cannot edit what the
    # next one is handed.
    class Event
      extend T::Sig

      # The stage this event describes -- one of Instrumentation::EVENTS.
      sig { returns(Symbol) }
      attr_reader :name

      # What the stage measured, keyed as documented for each event name in
      # docs/api_stability.md. Frozen.
      sig { returns(T::Hash[Symbol, T.untyped]) }
      attr_reader :payload

      # The wall clock when the stage started, UTC. For lining an event up
      # against a log; `duration` is what to measure with.
      sig { returns(Time) }
      attr_reader :started_at

      # Seconds the stage took, from a monotonic clock, so it is not moved by
      # a clock adjustment mid-stage.
      sig { returns(Float) }
      attr_reader :duration

      sig do
        params(name: Symbol, payload: T::Hash[Symbol, T.untyped], started_at: Time, duration: Float).void
      end
      def initialize(name:, payload:, started_at:, duration:)
        @name = T.let(name, Symbol)
        @payload = T.let(payload.freeze, T::Hash[Symbol, T.untyped])
        @started_at = T.let(started_at, Time)
        @duration = T.let(duration, Float)
        freeze
      end

      # One payload key, or nil for one this event does not carry.
      sig { params(key: Symbol).returns(T.untyped) }
      def [](key) = payload[key]

      # Which list this was about, or nil for an event that is not about one
      # -- `screen`, which is about a query, and `sync`, which is about a run.
      sig { returns(T.nilable(Symbol)) }
      def source = payload[:source]

      # The exception the stage raised, or nil for one that finished. An event
      # carrying one is a partial measurement: the keys the stage had not
      # reached are absent rather than zero.
      sig { returns(T.nilable(StandardError)) }
      def error = payload[:error]

      sig { returns(T::Boolean) }
      def failed? = !error.nil?

      # The wall clock when the stage finished. Derived from `started_at` and
      # the monotonic duration rather than read again, so the two cannot
      # disagree about how long this took.
      sig { returns(Time) }
      def finished_at = started_at + duration

      # Milliseconds, which is what a metrics backend usually wants.
      sig { returns(Float) }
      def duration_ms = (duration * 1_000).round(3).to_f

      # The whole event as one Hash, for a subscriber that forwards it
      # somewhere structured. The payload is spread in at the top level, and
      # its keys win over nothing -- `name`, `started_at` and `duration` are
      # not payload keys on any event this library emits.
      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h
        { name: name, started_at: started_at, duration: duration }.merge(payload)
      end

      sig { returns(String) }
      def to_s = "#{name} #{format("%.3f", duration)}s#{" #{source}" if source}#{" failed" if failed?}"

      sig { returns(String) }
      def inspect = "#<#{self.class} #{name} #{payload.inspect} #{format("%.3f", duration)}s>"
    end
  end
end
