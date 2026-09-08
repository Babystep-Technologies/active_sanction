# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "time"
require "active_sanction/error"
require "active_sanction/doctor/diagnosis"
require "active_sanction/doctor/finding"

module ActiveSanction
  class Doctor
    # What a whole diagnostic run found, one Diagnosis per source.
    #
    #   report = ActiveSanction.doctor
    #
    #   report.ok?          # => false
    #   report.findings     # => [Finding, ...]
    #   report[:ofac_sdn]   # => Diagnosis
    #   exit report.exit_code
    #   puts report
    #
    #   2 sources in 18.42s: 1 with findings
    #   ofac_sdn         WARN  3 findings
    #     warn   remarks coverage 71.4% (was 97.3%): "Passport No." x 1,880 unrecognized
    #     warn   individuals with a date of birth 12% (was 61%) of 11,704
    #     info   unknown SDN_Type "syndicate"; treated as an organization (41 rows)
    #   un_consolidated  OK
    #
    # ### It is an object, not console output
    #
    # The same split Sync::Report makes, for the same reason. The human form is
    # what a CLI verb (#36) prints; the serialized form is what a host
    # application alerts on, what a nightly job keeps so that next week's run
    # has a warning class to compare against, and what the instrumentation
    # hooks (#59) emit. A diagnostic that only existed as printed text would
    # mean every host that wants to notice a drifting source has to scrape a
    # log, which is precisely the state this exists to end.
    #
    # ### The exit code is a policy, and it is the caller's
    #
    # `exit_code` is 1 when anything failed at `error`, because a list that
    # cannot be read is not a matter of taste. Whether a `warn` should also
    # stop a deployment is, so it is a parameter: `exit_code(on: :warn)` is
    # what a team that treats drift as a build failure passes.
    #
    # Instances are frozen on construction and compare by value.
    class Report
      extend T::Sig
      extend T::Generic
      include Enumerable

      Elem = type_member { { fixed: Diagnosis } }

      MEMBERS = T.let(%i[diagnoses started_at duration].freeze, T::Array[Symbol])

      sig { returns(T::Array[Diagnosis]) }
      attr_reader :diagnoses

      # When the run began, UTC.
      sig { returns(Time) }
      attr_reader :started_at

      # Wall-clock seconds for the whole run.
      sig { returns(Float) }
      attr_reader :duration

      sig { params(hash: T.untyped).returns(T.attached_class) }
      def self.from_h(hash)
        attributes = hash.to_h.transform_keys(&:to_sym)
        unknown = attributes.keys - MEMBERS
        raise InvalidArgument, "unknown Doctor::Report attribute(s): #{unknown.join(", ")}" if unknown.any?

        T.unsafe(self).new(**attributes)
      end

      sig { params(diagnoses: T.untyped, started_at: T.untyped, duration: T.untyped).void }
      def initialize(diagnoses:, started_at: nil, duration: 0.0)
        @diagnoses = T.let(diagnoses!(diagnoses), T::Array[Diagnosis])
        @started_at = T.let(time!(started_at), Time)
        @duration = T.let(duration.to_f, Float)
        freeze
      end

      sig { override.params(block: T.nilable(T.proc.params(diagnosis: Diagnosis).void)).returns(T.untyped) }
      def each(&block)
        return enum_for(:each) unless block

        diagnoses.each(&block)
        self
      end

      # One source's diagnosis, or nil if the run did not cover it.
      sig { params(source: T.untyped).returns(T.nilable(Diagnosis)) }
      def [](source)
        key = source.to_sym
        diagnoses.find { |diagnosis| diagnosis.source == key }
      end

      sig { returns(T::Array[Symbol]) }
      def sources = diagnoses.map(&:source)

      # Every finding across every source, most serious first, and within a
      # severity in the order the sources were diagnosed.
      sig { returns(T::Array[Finding]) }
      def findings
        diagnoses.flat_map(&:findings)
                 .sort_by.with_index { |finding, at| [-Finding::SEVERITIES.index(finding.severity).to_i, at] }
      end

      sig { returns(T::Array[Finding]) }
      def errors = findings.select(&:error?)

      sig { returns(T::Array[Finding]) }
      def warnings = findings.select(&:warn?)

      sig { returns(T::Array[Finding]) }
      def infos = findings.select(&:info?)

      # Nothing above `info`, anywhere. What a nightly job alerts on when it
      # only wants one question answered.
      sig { returns(T::Boolean) }
      def ok? = diagnoses.all?(&:ok?)

      # The sources with something worth reading about them.
      sig { returns(T::Array[Diagnosis]) }
      def unhealthy = diagnoses.reject(&:ok?)

      # The sources that could not be diagnosed at all -- a publisher that is
      # down, a payload that is not the format it should be. Louder than a
      # finding, and a different question: nothing here knows whether those
      # lists have drifted.
      sig { returns(T::Array[Diagnosis]) }
      def failed = diagnoses.select(&:failed?)

      sig { returns(T::Boolean) }
      def failed? = diagnoses.any?(&:failed?)

      # The most serious severity anywhere in the run, or nil for a clean one.
      sig { returns(T.nilable(Symbol)) }
      def severity
        Finding::SEVERITIES.reverse.find { |level| diagnoses.any? { |one| one.severity == level } }
      end

      sig { returns(Integer) }
      def size = diagnoses.size

      sig { returns(T::Boolean) }
      def empty? = diagnoses.empty?

      # What a scheduled job should exit with. 1 on any `error` by default, and
      # `on: :warn` for a caller that wants drift to stop a build too. See the
      # class comment.
      sig { params(on: T.untyped).returns(Integer) }
      def exit_code(on: :error)
        level = on.to_sym
        findings.any? { |finding| finding.at_least?(level) } ? 1 : 0
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h
        { diagnoses: diagnoses.map(&:to_h), started_at: started_at.iso8601, duration: duration }
      end

      # The profile of each source, keyed by source -- what a nightly job keeps
      # so that the next run has last night's warning classes and free-text
      # coverage to compare against, which a stored snapshot cannot supply.
      # See Doctor#baseline.
      sig { returns(T::Hash[Symbol, Profile]) }
      def profiles
        diagnoses.each_with_object({}) do |diagnosis, all|
          profile = diagnosis.profile
          all[diagnosis.source] = profile unless profile.nil?
        end
      end

      sig { returns(String) }
      def summary
        counts = { "with findings" => unhealthy.size, "unreadable" => failed.size }
                 .reject { |_label, count| count.zero? }
                 .map { |label, count| "#{count} #{label}" }
        "#{size} #{size == 1 ? "source" : "sources"} in #{format("%.2f", duration)}s" \
          "#{": #{counts.empty? ? "all healthy" : counts.join(", ")}"}"
      end

      sig { returns(String) }
      def to_s = ([summary] + diagnoses.flat_map { |diagnosis| diagnosis.lines(width) }).join("\n")

      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.instance_of?(self.class)

        to_h == other.to_h
      end
      alias eql? ==

      sig { returns(Integer) }
      def hash = [self.class, to_h].hash

      sig { returns(String) }
      def inspect = "#<#{self.class} #{summary}>"

      private

      sig { returns(Integer) }
      def width = diagnoses.map { |diagnosis| diagnosis.source.to_s.length }.max.to_i

      sig { params(value: T.untyped).returns(T::Array[Diagnosis]) }
      def diagnoses!(value)
        Array(value).map { |one| one.is_a?(Diagnosis) ? one : Diagnosis.from_h(one) }.freeze
      end

      sig { params(value: T.untyped).returns(Time) }
      def time!(value)
        time = case value
               when nil then Time.now
               when Time then value
               when String then Time.parse(value)
               else raise InvalidArgument, "started_at is not a time: #{value.inspect}"
               end
        Time.at(time.to_i).utc
      end
    end
  end
end
