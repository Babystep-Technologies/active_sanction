# frozen_string_literal: true

RSpec.describe ActiveSanction::Instrumentation do
  # `described_class` is shadowed inside the nested Event and Notifications
  # groups below, and this hook has to mean the module either way.
  after do
    ActiveSanction::Instrumentation.reset! # rubocop:disable RSpec/DescribedClass
    ActiveSanction.reset!
  end

  # A subscriber, and the thing every example here asserts against. Recording
  # the events rather than stubbing `#call` because what is being measured is
  # what a host is handed, not that something was called.
  def collector = @collector ||= ->(event) { (@events ||= []) << event }

  # `raise` is the subject in several examples below, and the exception has to
  # be let past instrumentation and then dropped by the example rather than by
  # the code under test.
  def swallowing(error)
    yield
  rescue error
    nil
  end

  def events = @events ||= []

  def instrument(instrumenter, name = :fetch, payload = nil, &block)
    described_class.instrument(instrumenter, name, payload, &block || proc { :result })
  end

  describe "EVENTS" do
    # The published vocabulary. A name added here is a name a dashboard may be
    # written against, and one removed is a dashboard that goes blank.
    it "names the six stages" do
      expect(described_class::EVENTS).to eq(%i[fetch parse store index.build screen sync])
    end

    it "is frozen" do
      expect(described_class::EVENTS).to be_frozen
    end
  end

  describe ".instrument" do
    it "returns what the stage returned" do
      expect(instrument(collector) { :entities }).to eq(:entities)
    end

    it "returns what the stage returned with nothing listening" do
      expect(instrument(nil) { :entities }).to eq(:entities)
    end

    it "hands the subscriber one event per stage" do
      instrument(collector)

      expect(events.map(&:name)).to eq([:fetch])
    end

    it "carries what was known before the stage ran" do
      instrument(collector, :parse, { source: :ofac_sdn })

      expect(events.first[:source]).to eq(:ofac_sdn)
    end

    it "carries what the stage recorded while it ran" do
      instrument(collector, :parse) { |event| event[:records] = 19_321 }

      expect(events.first[:records]).to eq(19_321)
    end

    # #59's rule: no anonymous timings.
    it "carries a duration and a start" do
      instrument(collector)

      expect(events.first).to have_attributes(duration: be_a(Float), started_at: be_a(Time))
    end

    it "times the stage rather than the call" do
      instrument(collector) { sleep 0.01 }

      expect(events.first.duration).to be >= 0.01
    end

    # The payload handed in belongs to the caller, and a stage that fills in
    # fifteen fields must not be editing a Hash the caller is still holding.
    it "does not write into the payload it was given" do
      given = { source: :ofac_sdn }
      instrument(collector, :parse, given) { |event| event[:records] = 1 }

      expect(given).to eq({ source: :ofac_sdn })
    end

    it "freezes the payload the subscriber sees" do
      instrument(collector)

      expect(events.first.payload).to be_frozen
    end

    describe "when the stage raises" do
      def failing(instrumenter)
        instrument(instrumenter, :parse, { source: :ofac_sdn }) do |event|
          event[:bytes] = 12
          raise ActiveSanction::ParseError, "unbalanced quote"
        end
      end

      # Instrumentation never alters control flow.
      it "lets the exception through" do
        expect { failing(collector) }.to raise_error(ActiveSanction::ParseError, /unbalanced quote/)
      end

      it "lets the exception through with nothing listening" do
        expect { failing(nil) }.to raise_error(ActiveSanction::ParseError)
      end

      # A publisher that starts failing is exactly what a host is watching for,
      # so the event is emitted rather than skipped.
      it "still emits the event" do
        swallowing(ActiveSanction::ParseError) { failing(collector) }

        expect(events.first).to have_attributes(name: :parse, failed?: true)
      end

      it "carries the exception" do
        swallowing(ActiveSanction::ParseError) { failing(collector) }

        expect(events.first.error).to be_a(ActiveSanction::ParseError)
      end

      it "carries whatever the stage had filled in before it failed" do
        swallowing(ActiveSanction::ParseError) { failing(collector) }

        expect(events.first[:bytes]).to eq(12)
      end
    end

    # The acceptance criterion behind the whole design: an installation that
    # instruments nothing pays nothing, so a stage may record as much as it
    # likes. Stated as what is not built rather than as a timing, because a
    # timing on a busy machine measures the machine -- the numbers themselves
    # are `rake benchmark:latency`.
    describe "with nothing listening" do
      it "builds no event" do
        allow(ActiveSanction::Instrumentation::Event).to receive(:new).and_call_original
        instrument(nil, :screen) { |event| event[:results] = 0 }

        expect(ActiveSanction::Instrumentation::Event).not_to have_received(:new)
      end

      # One shared object rather than a Hash apiece, which is what makes a
      # per-query event affordable at all.
      it "allocates no payload, however many stages run" do
        seen = Array.new(2) { instrument(nil, :screen, &:object_id) }

        expect(seen.uniq.size).to eq(1)
      end

      it "hands the stage something that reads back as empty" do
        seen = instrument(nil, :screen) { |event| [event[:anything], (event[:records] = 3)] }

        expect(seen).to eq([nil, 3])
      end
    end
  end

  describe "a subscriber that raises" do
    let(:broken) { ->(_event) { raise "the metrics socket is closed" } }

    def logger
      @logger ||= Class.new do
        def lines = @lines ||= []
        def info(message) = lines << message
        def warn(message) = lines << message
      end.new
    end

    # Every example here provokes a report, and a report with no logger goes
    # to stderr. Configured once so the suite's own output stays readable, and
    # taken away again by the one example that is about not having one.
    before { ActiveSanction.configure { |c| c.logger = logger } }

    it "does not reach the stage it was measuring" do
      expect { instrument(broken) }.not_to raise_error
    end

    it "does not change what the stage returned" do
      expect(instrument(broken) { :entities }).to eq(:entities)
    end

    # The failure the whole isolation exists for: a sanctions sync must not be
    # failed by a host's metrics client.
    it "does not stop a sync" do
      ActiveSanction.configure { |c| c.instrumenter = broken }
      store = ActiveSanction::Storage::Memory.new
      source = FakeSyncSource.new(:ofac_sdn, entities: [FakeSyncSource.entity(:ofac_sdn)])

      report = ActiveSanction::Sync.new(sources: [source], store: store).call

      expect(report).to have_attributes(failed?: false, record_count: 1)
    end

    # Dropped, but never silently -- a subscriber recording nothing is a
    # dashboard that is quietly wrong.
    it "is reported through the logger" do
      instrument(broken)

      expect(logger.lines.first).to match(/instrumenter .* raised on the fetch event .*RuntimeError/)
    end

    it "says the event was dropped and the work carried on" do
      instrument(broken)

      expect(logger.lines.first).to include("the event was dropped and the work carried on")
    end

    # A subscriber that raises on :screen raises on every query, and a service
    # at any volume would spend more of its log on this than on its own work.
    it "is reported once for a shape, however many times it happens" do
      3.times { instrument(broken) }

      expect(logger.lines.size).to eq(1)
    end

    it "is reported again for a different event" do
      instrument(broken, :fetch)
      instrument(broken, :screen)

      expect(logger.lines.size).to eq(2)
    end

    it "warns when there is no logger to report through" do
      ActiveSanction.configure { |c| c.logger = nil }

      expect { instrument(broken) }.to output(/instrumenter .* raised/).to_stderr
    end
  end

  describe ActiveSanction::Instrumentation::Event do
    def event(name: :fetch, payload: { source: :ofac_sdn, bytes: 12 }, duration: 1.5)
      described_class.new(name: name, payload: payload, started_at: Time.utc(2026, 9, 13), duration: duration)
    end

    it "reads a payload key" do
      expect(event[:bytes]).to eq(12)
    end

    it "reads nothing for a key it does not carry" do
      expect(event[:candidates]).to be_nil
    end

    it "names the list it was about" do
      expect(event.source).to eq(:ofac_sdn)
    end

    it "reports milliseconds, which is what a metrics backend wants" do
      expect(event(duration: 0.0125).duration_ms).to eq(12.5)
    end

    # Derived rather than read again, so the two cannot disagree about how
    # long the stage took.
    it "derives when it finished from when it started" do
      expect(event(duration: 2.0).finished_at).to eq(Time.utc(2026, 9, 13, 0, 0, 2))
    end

    it "flattens into one hash for a subscriber that forwards it" do
      expect(event.to_h).to include(name: :fetch, duration: 1.5, source: :ofac_sdn, bytes: 12)
    end

    it "is frozen" do
      expect(event).to be_frozen
    end
  end

  describe ActiveSanction::Instrumentation::Notifications do
    # A notifier standing in for ActiveSupport::Notifications, so these
    # examples state the contract this adapter is written against rather than
    # depending on a gem this library does not.
    def notifier
      @notifier ||= Class.new do
        def published = @published ||= []
        def publish(*args) = published << args
      end.new
    end

    def adapter = described_class.new(notifier: notifier)

    def published = notifier.published.first

    def event(name: :screen, payload: { results: 2 })
      ActiveSanction::Instrumentation::Event.new(name: name, payload: payload,
                                                 started_at: Time.utc(2026, 9, 13), duration: 0.5)
    end

    it "publishes under the namespaced name every ActiveSupport subscriber expects" do
      adapter.call(event)

      expect(published.first).to eq("screen.active_sanction")
    end

    it "namespaces a dotted event name without mangling it" do
      adapter.call(event(name: :"index.build"))

      expect(published.first).to eq("index.build.active_sanction")
    end

    # Already finished, with real start and finish times, because this library
    # has done the work and timed it.
    it "publishes the start and finish of a stage that is already over" do
      adapter.call(event)

      expect(published[1..2]).to eq([Time.utc(2026, 9, 13), Time.utc(2026, 9, 13, 0, 0, 0, 500_000)])
    end

    it "publishes the payload" do
      adapter.call(event)

      expect(published.last).to include(results: 2)
    end

    # So a Rails host's existing error reporting sees a failed stage without
    # being taught anything about this gem.
    it "adds ActiveSupport's own exception keys for a stage that raised" do
      error = ActiveSanction::ParseError.new("unbalanced quote")

      adapter.call(event(payload: { source: :ofac_sdn, error: error }))

      expect(published.last).to include(exception: ["ActiveSanction::ParseError", "unbalanced quote"],
                                        exception_object: error)
    end

    it "leaves the payload alone for a stage that finished" do
      adapter.call(event)

      expect(published.last.keys).to eq([:results])
    end

    # Zero required runtime dependencies is a promise, and a notification
    # adapter is not a reason to break it.
    it "refuses to build when ActiveSupport::Notifications is not loaded" do
      hide_const("ActiveSupport::Notifications")

      expect { described_class.new }
        .to raise_error(ActiveSanction::ConfigurationError, /does not depend on ActiveSupport/)
    end

    it "refuses a notifier that cannot publish" do
      expect { described_class.new(notifier: Object.new) }
        .to raise_error(ActiveSanction::ConfigurationError, /#publish/)
    end
  end

  describe "ActiveSanction::Configuration#instrumenter" do
    it "defaults to nothing listening" do
      expect(ActiveSanction::Configuration.new.instrumenter).to be_nil
    end

    it "takes anything answering #call" do
      expect(ActiveSanction.configure { |c| c.instrumenter = collector }.instrumenter).to eq(collector)
    end

    # A misspelled subscriber that is silently ignored is an installation
    # measuring nothing and believing it is measuring everything.
    it "refuses something that cannot be called" do
      expect { ActiveSanction.configure { |c| c.instrumenter = "statsd" } }
        .to raise_error(ActiveSanction::ConfigurationError, /#call\(event\)/)
    end

    it "can be set back to nothing listening" do
      expect { ActiveSanction.configure { |c| c.instrumenter = nil } }.not_to raise_error
    end
  end
end
