# frozen_string_literal: true

module Canary
  # One canary run: every registered source fetched from its real publisher,
  # parsed, and held against its committed baseline.
  #
  #   report = Canary::Run.new(previous: Canary::Report.read("previous.json")).call
  #
  # ### It is the doctor, pointed at a file instead of a snapshot
  #
  # Every measurement and every check here is `ActiveSanction::Doctor`'s. What
  # this adds is the three things a stateless runner needs and an operator's
  # deployment does not: a baseline that is a file in the repository rather than
  # the last sync, a tolerance per key rather than one for the whole run, and a
  # classification of what went wrong into something a maintainer can act on.
  #
  # Nothing is written by the run. The doctor already promises that -- no
  # snapshot, no payload cache, no conditional-GET validators -- and this hands
  # it an empty in-memory store as well, so a canary run on a laptop cannot read
  # or disturb whatever that laptop has synced.
  #
  # ### One source at a time, and one source failing does not stop the others
  #
  # The doctor's rule, kept: a UN outage must not stop OFAC being examined, and
  # downloading seven government lists at once to save four minutes of a job
  # nobody is waiting on is not a trade worth making. Be a good citizen about
  # it -- this is roughly 40 MB across seven publishers, once a day.
  class Run
    # What the publishers see in their logs. The gem's own default names the
    # repository; this names the job as well, so that a publisher deciding
    # whether to block something can tell a nightly format check from an
    # application syncing its lists.
    USER_AGENT = "active_sanction-canary/#{ActiveSanction::VERSION} " \
                 "(+https://github.com/Babystep-Technologies/active_sanction)".freeze

    attr_reader :sources, :baselines, :previous, :logger

    # `sources:` names the keys to examine, or nothing for every registered
    # source. `previous:` is the Report the last run wrote, and is what makes
    # a finding confirmable; without one nothing this run finds can be opened
    # as an issue. See Report.
    def initialize(sources: nil, baselines: nil, previous: nil, logger: nil)
      @sources = keys!(sources)
      @baselines = baselines || Baseline.directory
      @previous = previous
      @logger = logger
    end

    def call(&block)
      started_at = Time.now.utc
      began = monotonic
      results = sources.map { |key| examine(key).tap { |result| block&.call(result) } }
      Report.new(results: results, started_at: started_at, duration: elapsed(began))
            .confirmed_against(previous)
    end

    # The baseline this run compared a source against, for a caller that wants
    # to say when it was captured.
    def baseline(source) = Baseline.load(source, directory: baselines)

    def inspect = "#<#{self.class} #{sources.join(", ")}>"

    private

    def examine(key)
      committed = baseline(key)
      Result.from(diagnose(key, committed), baseline: committed)
    end

    # The doctor, run at the tightest tolerance this source's baseline names so
    # that every finding a per-key tolerance might keep is produced. Discarding
    # is Baseline#allows?'s job, and it can only ever discard.
    def diagnose(key, committed)
      ActiveSanction::Doctor.new(
        sources: [key], store: ActiveSanction::Storage::Memory.new, logger: logger,
        baseline: committed.present? ? { key => committed.profile } : nil, tolerance: committed.finest
      ).call.diagnoses.fetch(0)
    end

    def keys!(requested)
      listed = Array(requested).flatten.compact.map(&:to_sym)
      listed.empty? ? ActiveSanction::Sources.keys : listed
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f

    def elapsed(began) = (monotonic - began).round(3)
  end
end
