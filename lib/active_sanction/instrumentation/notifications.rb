# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"

module ActiveSanction
  module Instrumentation
    # Republishes every event into `ActiveSupport::Notifications`, for a host
    # that already has subscribers, log tags and a dashboard pointed there.
    #
    #   # config/initializers/active_sanction.rb
    #   ActiveSanction.configure do |c|
    #     c.instrumenter = ActiveSanction::Instrumentation::Notifications.new
    #   end
    #
    #   ActiveSupport::Notifications.subscribe("screen.active_sanction") do |event|
    #     Rails.logger.info("screened in #{event.duration.round(1)}ms: #{event.payload[:results]} hits")
    #   end
    #
    # Names are `<event>.active_sanction` -- `fetch.active_sanction`,
    # `index.build.active_sanction`, and so on -- which is the namespacing
    # convention every ActiveSupport subscriber already expects, so
    # `subscribe(/\.active_sanction\z/)` picks up all six.
    #
    # ### It is an adapter, not a dependency
    #
    # **Nothing in this gem requires ActiveSupport**, and this file does not
    # either -- it names `::ActiveSupport::Notifications` and never loads it.
    # Zero required runtime dependencies is a promise this library keeps for
    # the API container it is going to run in, and a notification adapter is
    # not a reason to break it. Building one in a process that has not loaded
    # ActiveSupport raises ConfigurationError rather than quietly instrumenting
    # nothing, because a subscriber that is not recording is a dashboard that
    # is wrong rather than missing.
    #
    # ### Events arrive finished
    #
    # `publish` rather than `instrument`: this library has already done the
    # work and timed it, and re-wrapping a finished event in a block would put
    # an ActiveSupport subscriber around a stage it cannot influence while
    # reporting a duration measured somewhere else. Subscribers see a normal
    # `ActiveSupport::Notifications::Event` with real start and finish times.
    #
    # A stage that raised carries the two keys ActiveSupport's own subscribers
    # look for -- `:exception`, the `[class, message]` pair, and
    # `:exception_object` -- beside this library's `:error`, so a Rails host's
    # existing error reporting sees it without being taught anything.
    class Notifications
      extend T::Sig

      # The suffix every published name carries.
      NAMESPACE = T.let("active_sanction", String)

      sig { returns(String) }
      attr_reader :namespace

      # Whatever the events are published through -- `ActiveSupport::Notifications`
      # itself unless a host named its own notifier.
      sig { returns(T.untyped) }
      attr_reader :notifier

      # @param namespace [String] the suffix published names carry. Change it
      #   only to keep two installations of this gem apart in one process.
      # @param notifier [#publish, nil] defaults to `ActiveSupport::Notifications`,
      #   resolved now rather than per event so that a process without it
      #   fails here, at the line that configured it.
      sig { params(namespace: String, notifier: T.untyped).void }
      def initialize(namespace: NAMESPACE, notifier: nil)
        @namespace = T.let(namespace.to_s, String)
        @notifier = T.let(notifier || default_notifier, T.untyped)
        return if @notifier.respond_to?(:publish)

        raise ConfigurationError, "an ActiveSupport::Notifications adapter needs a notifier answering " \
                                  "#publish, got #{@notifier.class}"
      end

      # Publishes one finished event. Called by Instrumentation, which has
      # already isolated it: an exception raised in here is reported and
      # dropped rather than reaching the sync that emitted the event.
      sig { params(event: Event).returns(T.untyped) }
      def call(event)
        notifier.publish("#{event.name}.#{namespace}", event.started_at, event.finished_at, event_id,
                         payload_for(event))
      end

      sig { returns(String) }
      def inspect = "#<#{self.class} #{notifier.class} *.#{namespace}>"

      private

      sig { returns(T.untyped) }
      def default_notifier
        unless defined?(::ActiveSupport::Notifications)
          raise ConfigurationError,
                "ActiveSupport::Notifications is not loaded. This gem does not depend on ActiveSupport and " \
                "will not require it -- load it yourself, or set c.instrumenter to any object answering " \
                "#call(event)."
        end

        ::ActiveSupport::Notifications
      end

      # ActiveSupport's own per-thread instrumenter id, so an event published
      # here is correlated with the ones a host's own `instrument` calls
      # publish on the same thread.
      sig { returns(String) }
      def event_id
        notifier.respond_to?(:instrumenter) ? notifier.instrumenter.id : "#{Process.pid}-#{Thread.current.object_id}"
      end

      sig { params(event: Event).returns(T::Hash[Symbol, T.untyped]) }
      def payload_for(event)
        error = event.error
        return event.payload if error.nil?

        event.payload.merge(exception: [error.class.name, error.message], exception_object: error)
      end
    end
  end
end
