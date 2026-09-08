# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"
require "active_sanction/fetcher"
require "active_sanction/sources"
require "active_sanction/storage"
require "active_sanction/validator_store"
require "active_sanction/doctor/checkup"
require "active_sanction/doctor/diagnosis"
require "active_sanction/doctor/finding"
require "active_sanction/doctor/profile"
require "active_sanction/doctor/report"

module ActiveSanction
  # Diagnoses whether a source's format has drifted: fetches each list, parses
  # it, measures it, and compares the measurements against the last version
  # that was stored.
  #
  #   report = ActiveSanction.doctor              # every configured source
  #   report = ActiveSanction.doctor(:ofac_sdn)   # one
  #
  #   report.ok?        # => false
  #   report.findings   # => [Finding(source:, severity:, check:, message:, observed:, baseline:)]
  #   exit report.exit_code
  #
  # ### The failure this exists to catch
  #
  # Sanctions lists change format on three clocks. A whole-format migration is
  # announced years ahead and fails loudly. A column added or an element
  # renamed happens quietly, in months. A new document label or a new
  # designation vocabulary happens continuously, weekly.
  #
  # Only the first of those fails loudly. The dangerous ones are the changes
  # where the file still parses cleanly and means something different: 19,321
  # entities carrying zero passports looks exactly as healthy as 19,321
  # carrying 23,429 if all anyone counts is records. Nothing in a sync would
  # notice that for months, and a screening run against it returns a clean
  # result for a customer whose passport is on the list.
  #
  # So this measures what a sync does not: the share of records carrying each
  # field, the vocabulary the parser recognized, the shape of the values in a
  # positional column, the classes of warning the parse produced. See Profile
  # for what is measured and Checkup for what is made of it.
  #
  # ### It never writes anything
  #
  # Not the snapshot, not the payload cache, not the conditional-GET
  # validators. Each adapter the doctor builds gets a fetcher over an in-memory
  # validator store and no payload cache, which has two consequences worth
  # stating:
  #
  # - every run downloads every list in full, because a diagnosis of a list the
  #   publisher answered 304 for is a diagnosis of nothing; and
  # - a doctor run before a sync cannot make that sync skip a changed list.
  #   Sharing the validators would do exactly that -- the doctor's fetch would
  #   learn the new ETag, the sync that followed would be answered 304, and the
  #   list it decided was unchanged would be the one the doctor had just seen
  #   change. Diagnosing a source must not be able to stop it being updated.
  #
  # Nothing is repaired either. Deciding that a 40% drop in record count is a
  # delisting wave rather than a broken parse is a judgment call, and making it
  # automatically is how a compliance tool ends up quietly screening against
  # nothing.
  #
  # It is not a cheap run, and it is not meant to be: every list is downloaded,
  # parsed, and parsed again where a positional file's columns are asserted,
  # and the stored snapshot is read in full so its fill rates can be recomputed
  # as the baseline. That is the price of comparing two parses rather than two
  # file sizes, and it is charged once a night rather than once a sync.
  #
  # ### One source failing does not stop the others
  #
  # The same rule sync orchestration runs under, and for the same reason:
  # government endpoints go down, and a UN outage must not stop OFAC being
  # diagnosed. Each source runs inside its own rescue and a failure becomes an
  # `error` finding on that source alone.
  #
  # ### Where this is meant to run
  #
  # In a nightly job, not in a terminal. A `doctor` invoked by hand only
  # confirms a regression that was already suspected; the whole value here is
  # noticing one nobody suspected, which means something has to run it when
  # nobody is looking and alert when it says something. `exit_code` is for the
  # cron job, `to_h` is for the metrics pipeline, and `to_s` is for the CLI
  # verb (#36) that will print it.
  class Doctor
    extend T::Sig

    # The adapters this run covers.
    sig { returns(T::Array[T.untyped]) }
    attr_reader :sources

    sig { returns(T::Array[Symbol]) }
    attr_reader :keys

    sig { returns(T.untyped) }
    attr_reader :store

    # How far a measurement may move from its baseline before it is worth a
    # finding, as a share of what it was.
    sig { returns(Float) }
    attr_reader :tolerance

    sig { returns(T.untyped) }
    attr_reader :logger

    sig { params(options: T.untyped, block: T.untyped).returns(Report) }
    def self.call(**options, &block) = T.unsafe(self).new(**options).call(&block)

    # `sources:` takes source keys, adapter classes, adapter instances, or nil
    # for whatever `config.sources` names.
    #
    # `baseline:` is what a previous run measured -- a Doctor::Report, or a
    # Hash of source to Profile -- for the checks a stored snapshot cannot
    # supply. Everything derived from the entities is recomputed from what is
    # in storage and needs nothing passed here; the warning classes and the
    # free-text coverage exist only during a parse, so a host that wants those
    # compared week to week keeps the last report and hands it back:
    #
    #   yesterday = JSON.parse(File.read("doctor.json"))
    #   report = ActiveSanction.doctor(baseline: Doctor::Report.from_h(yesterday))
    #   File.write("doctor.json", JSON.generate(report.to_h))
    #
    # A supplied profile is used only where it describes the same list version
    # that is in storage; where it does not, storage wins, because a profile
    # from three syncs ago would report drift that has already been reviewed.
    sig do
      params(sources: T.untyped, store: T.untyped, baseline: T.untyped, tolerance: T.untyped,
             logger: T.untyped).void
    end
    def initialize(sources: nil, store: nil, baseline: nil, tolerance: nil, logger: ActiveSanction.config.logger)
      @sources = T.let(resolve(sources), T::Array[T.untyped])
      @keys = T.let(@sources.map { |source| Sources::Definition.key!(source.key) }, T::Array[Symbol])
      @store = T.let(store || ActiveSanction.storage, T.untyped)
      @recorded = T.let(baselines!(baseline), T::Hash[Symbol, Profile])
      @tolerance = T.let(
        Configuration.doctor_tolerance!(tolerance || ActiveSanction.config.doctor_tolerance), Float
      )
      @logger = T.let(logger, T.untyped)
    end

    # Runs the diagnosis and returns the Report. Never raises for a source that
    # could not be read -- that is what an `error` finding is for.
    #
    # The optional block is the progress hook: it is called with each Diagnosis
    # as that source finishes. Sources are diagnosed one at a time, because
    # this is a job nobody is waiting on and downloading four government lists
    # at once to save four minutes of it is not a trade worth making.
    sig { params(block: T.nilable(T.proc.params(diagnosis: Diagnosis).void)).returns(Report) }
    def call(&block)
      started_at = Time.now.utc
      began = monotonic
      log(:info, "diagnosing #{keys.size} source(s): #{keys.join(", ")}")
      diagnoses = keys.each_with_index.map do |key, at|
        diagnose(key, sources.fetch(at)).tap do |diagnosis|
          log_diagnosis(diagnosis)
          block&.call(diagnosis)
        end
      end
      report = Report.new(diagnoses: diagnoses, started_at: started_at, duration: elapsed(began))
      log(report.ok? ? :info : :warn, "diagnosed #{report.summary}")
      report
    end

    sig { returns(String) }
    def inspect = "#<#{self.class} #{keys.join(", ")} tolerance=#{tolerance}>"

    private

    # One source, start to finish, inside its own rescue. Nothing in here may
    # raise past this method, and nothing in here may write anything.
    sig { params(key: Symbol, source: T.untyped).returns(Diagnosis) }
    def diagnose(key, source)
      started = monotonic
      baseline = T.let(nil, T.nilable(Profile))
      begin
        adapter = isolate(source)
        baseline, findings = baseline_for(key)
        observed = measure(key, adapter)
        findings += Checkup.new(source: key, observed: observed, baseline: baseline, floors: floors(adapter),
                                tolerance: tolerance).findings
        Diagnosis.new(source: key, status: :checked, findings: findings, profile: observed,
                      baseline: baseline, duration: elapsed(started))
      rescue StandardError => e
        failure(key, stamp(key, e), baseline, started)
      end
    end

    # Fetch, parse, measure. `force: true` because the diagnosis is of the
    # bytes the publisher is serving now, and a 304 would have this reporting
    # on a parse that did not happen.
    sig { params(key: Symbol, adapter: T.untyped).returns(Profile) }
    def measure(key, adapter)
      payloads = adapter.retrieve(force: true)
      raise Sources::MissingPayload, "#{key} answered nothing to an unconditional request" if payloads.nil?

      snapshot = adapter.snapshot(payloads)
      Profile.measure(snapshot, adapter: adapter, columns: tallies(key, adapter, payloads))
    end

    # The positional-column assertions, for an adapter that declares any. A
    # source is still diagnosed when they cannot be run: the rest of the
    # checkup is worth having, and the reason they could not be run is a bug
    # here rather than a fact about the publisher's file.
    sig { params(key: Symbol, adapter: T.untyped, payloads: T.untyped).returns(T::Array[T.untyped]) }
    def tallies(key, adapter, payloads)
      return [] unless adapter.respond_to?(:column_tallies)

      adapter.column_tallies(payloads)
    rescue StandardError => e
      log(:warn, "#{key} column shapes could not be checked (#{e.class}: #{e.message})")
      []
    end

    # What this source was last measured to be, and any findings raised by
    # trying to find out. A stored snapshot that no longer hashes to its
    # checksum is an `error` in its own right -- the list being screened
    # against cannot prove what it contains -- and leaves the run with no
    # baseline, which is a different thing from a clean comparison.
    sig { params(key: Symbol).returns([T.nilable(Profile), T::Array[Finding]]) }
    def baseline_for(key)
      stored = Profile.measure(store.fetch_snapshot(key))
      recorded = @recorded[key]
      [recorded && recorded.checksum == stored.checksum ? recorded : stored, []]
    rescue Storage::MissingSnapshot
      [@recorded[key], []]
    rescue StandardError => e
      [nil, [Finding.new(source: key, severity: :error, check: :baseline,
                         message: "the stored snapshot could not be read, so nothing was compared: " \
                                  "#{e.class}: #{e.message}")]]
    end

    sig do
      params(key: Symbol, error: StandardError, baseline: T.nilable(Profile), started: Float).returns(Diagnosis)
    end
    def failure(key, error, baseline, started)
      finding = Finding.new(source: key, severity: :error, check: :parse,
                            message: "could not be read: #{error.class}: #{error.message}")
      Diagnosis.new(source: key, status: :failed, findings: [finding], baseline: baseline,
                    duration: elapsed(started), error: error)
    end

    # An adapter built to leave no trace: no payload cache, and validators that
    # live and die with this run. See the class comment on why sharing them
    # would be unsafe. An instance a caller built themselves is used as it
    # stands, and fetches through whatever it was built with.
    sig { params(source: T.untyped).returns(T.untyped) }
    def isolate(source)
      return source unless source.is_a?(Class)
      return T.unsafe(source).new unless isolatable?(source)

      T.unsafe(source).new(fetcher: Fetcher.new(store: ValidatorStore::Memory.new, logger: logger),
                           cache: nil, logger: logger)
    end

    # Whether a source class takes the keywords Sources::Base does. A third
    # party's adapter that does not is built plainly rather than not at all.
    sig { params(klass: T.untyped).returns(T::Boolean) }
    def isolatable?(klass)
      parameters = klass.instance_method(:initialize).parameters
      return true if parameters.any? { |(kind, _name)| kind == :keyrest }

      named = parameters.select { |(kind, _name)| %i[key keyreq].include?(kind) }.map(&:last)
      (%i[fetcher cache logger] - named).empty?
    end

    # The lower bounds this adapter committed to, for the checks that have no
    # baseline to compare against. See Sources::Definition#floor.
    sig { params(adapter: T.untyped).returns(T::Hash[Symbol, Numeric]) }
    def floors(adapter) = adapter.respond_to?(:floors) ? adapter.floors : {}

    sig { params(requested: T.untyped).returns(T::Array[T.untyped]) }
    def resolve(requested)
      listed = Array(requested).flatten.compact
      return Sources.enabled if listed.empty?

      listed.map { |source| adapter!(source) }
    end

    sig { params(source: T.untyped).returns(T.untyped) }
    def adapter!(source)
      return Sources[source] if source.is_a?(Symbol) || source.is_a?(String)
      return source if source.respond_to?(:key) && source.respond_to?(source.is_a?(Class) ? :new : :retrieve)

      raise InvalidArgument, "a source must be a registered key, or answer .key and .new, got #{source.inspect}"
    end

    # Takes a Report, a Hash of source to Profile, or the `#to_h` of either,
    # so that a job which round-tripped last night's report through JSON does
    # not have to rebuild it itself.
    sig { params(value: T.untyped).returns(T::Hash[Symbol, Profile]) }
    def baselines!(value)
      case value
      when nil then {}
      when Report then value.profiles
      when Hash then report?(value) ? Report.from_h(value).profiles : profiles!(value)
      else raise InvalidArgument, "baseline must be a Doctor::Report or a Hash of source => Profile"
      end
    end

    # A serialized Report rather than a Hash of profiles. String keys as well
    # as symbols, since a report that has been through JSON has string keys all
    # the way down.
    sig { params(value: T::Hash[T.untyped, T.untyped]).returns(T::Boolean) }
    def report?(value) = value.key?(:diagnoses) || value.key?("diagnoses")

    sig { params(value: T::Hash[T.untyped, T.untyped]).returns(T::Hash[Symbol, Profile]) }
    def profiles!(value)
      value.to_h do |source, profile|
        [source.to_sym, profile.is_a?(Profile) ? profile : Profile.from_h(profile)]
      end
    end

    # A failure captured for a source names that source, even when it was
    # raised somewhere that could not know. See Error#in_source.
    sig { params(key: Symbol, error: StandardError).returns(StandardError) }
    def stamp(key, error) = error.is_a?(ActiveSanction::Error) ? error.in_source(key) : error

    sig { returns(Float) }
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f

    sig { params(started: Float).returns(Float) }
    def elapsed(started) = (monotonic - started).round(3).to_f

    sig { params(diagnosis: Diagnosis).void }
    def log_diagnosis(diagnosis)
      level = diagnosis.ok? ? :info : :warn
      log(level, "#{diagnosis.source} #{diagnosis.label}: #{diagnosis.findings.size} finding(s) " \
                 "in #{format("%.2f", diagnosis.duration)}s")
      diagnosis.findings.each { |finding| log(finding.at_least?(:warn) ? :warn : :info, finding.to_s) }
    end

    # Configuration only promises a logger that answers #info, so a finding is
    # logged at warn where the logger has one and at info where it does not --
    # rather than not at all.
    sig { params(level: Symbol, message: String).void }
    def log(level, message)
      return unless logger

      line = "[active_sanction] #{message}"
      logger.respond_to?(level) ? logger.public_send(level, line) : logger.info(line)
    end
  end
end
