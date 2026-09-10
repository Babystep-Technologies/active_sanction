# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"
require "active_sanction/doctor/finding"
require "active_sanction/doctor/profile"

module ActiveSanction
  class Doctor
    # What the doctor found out about one source.
    #
    #   diagnosis.source     # => :ofac_sdn
    #   diagnosis.ok?        # => false
    #   diagnosis.severity   # => :warn
    #   diagnosis.findings   # => [Finding, ...]
    #   diagnosis.profile    # => Profile, what this run measured
    #   diagnosis.compared?  # => true, there was a previous list to compare with
    #
    # Two statuses, and they are about the diagnosis rather than about the
    # list:
    #
    #   :checked  the list was fetched, parsed and measured
    #   :failed   it could not be, and the exception is the finding
    #
    # A source that fails to fetch is not a source in good health, but nor is
    # it one this can say anything about -- which is why the failure is
    # recorded as an `error` finding and the profile is nil, rather than a
    # profile of nothing being compared against the last good one and reported
    # as every field collapsing at once.
    #
    # Nothing here is stored. A diagnosis is what the doctor returns, and
    # keeping it -- to compare a warning class against next week, to graph a
    # fill rate -- is the host application's decision, which is why #to_h
    # serializes the profile along with the findings.
    #
    # Instances are frozen on construction and compare by value.
    class Diagnosis
      extend T::Sig

      # Whether the doctor got far enough to have an opinion. `failed` means
      # the list could not be read at all, which is a different report from
      # one that read it and found something wrong with it.
      STATUSES = T.let(%i[checked failed].freeze, T::Array[Symbol])

      # @api private
      MEMBERS = T.let(%i[source status findings profile baseline duration error].freeze, T::Array[Symbol])

      sig { returns(Symbol) }
      attr_reader :source

      sig { returns(Symbol) }
      attr_reader :status

      sig { returns(T::Array[Finding]) }
      attr_reader :findings

      # What this run measured, or nil for a source that could not be read.
      sig { returns(T.nilable(Profile)) }
      attr_reader :profile

      # What it was measured against: the profile of the snapshot in storage,
      # or the one a caller kept from the last run. nil when there was nothing
      # to compare with, which is what makes the difference between "this is
      # the first look" and "nothing changed".
      sig { returns(T.nilable(Profile)) }
      attr_reader :baseline

      sig { returns(Float) }
      attr_reader :duration

      # The exception behind a `:failed` diagnosis, for a caller that wants the
      # backtrace. nil after a round-trip through #to_h, exactly as
      # Sync::Result has it.
      sig { returns(T.nilable(Exception)) }
      attr_reader :exception

      sig { params(hash: T.untyped).returns(T.attached_class) }
      def self.from_h(hash)
        attributes = hash.to_h.transform_keys(&:to_sym)
        unknown = attributes.keys - MEMBERS
        raise InvalidArgument, "unknown Doctor::Diagnosis attribute(s): #{unknown.join(", ")}" if unknown.any?

        T.unsafe(self).new(**attributes)
      end

      sig do
        params(source: T.untyped, status: T.untyped, findings: T.untyped, profile: T.untyped,
               baseline: T.untyped, duration: T.untyped, error: T.untyped).void
      end
      def initialize(source:, status:, findings: [], profile: nil, baseline: nil, duration: 0.0, error: nil)
        @source = T.let(symbol!(:source, source), Symbol)
        @status = T.let(status!(status), Symbol)
        @findings = T.let(findings!(findings), T::Array[Finding])
        @profile = T.let(profile!(profile), T.nilable(Profile))
        @baseline = T.let(profile!(baseline), T.nilable(Profile))
        @duration = T.let(duration.to_f, Float)
        @exception = T.let(error.is_a?(Exception) ? error : nil, T.nilable(Exception))
        @failure = T.let(failure!(error), T.nilable(T::Hash[Symbol, String]))
        freeze
      end

      sig { returns(T::Boolean) }
      def checked? = status == :checked

      sig { returns(T::Boolean) }
      def failed? = status == :failed

      # Whether there was a previous list to measure this one against. A run
      # with no baseline is held to the adapter's committed floors instead, and
      # says so rather than treating a first look as a regression.
      sig { returns(T::Boolean) }
      def compared? = !baseline.nil?

      # Nothing above `info`. The question the CLI's `OK` answers, and the one
      # a nightly job alerts on.
      sig { returns(T::Boolean) }
      def ok? = findings.none? { |finding| finding.at_least?(:warn) }

      # The most serious severity found, or nil for a source with nothing to
      # say about it at all.
      sig { returns(T.nilable(Symbol)) }
      def severity
        Finding::SEVERITIES.reverse.find { |level| findings.any? { |finding| finding.severity == level } }
      end

      sig { returns(T::Array[Finding]) }
      def errors = findings.select(&:error?)

      sig { returns(T::Array[Finding]) }
      def warnings = findings.select(&:warn?)

      sig { returns(T::Array[Finding]) }
      def infos = findings.select(&:info?)

      sig { returns(T.nilable(String)) }
      def error_class = @failure&.fetch(:class)

      sig { returns(T.nilable(String)) }
      def error_message = @failure&.fetch(:message)

      # The failure on one line, for a log or a table. nil when nothing failed.
      sig { returns(T.nilable(String)) }
      def error
        return nil unless error_class

        message = error_message
        return error_class if message.nil? || message.empty? || message == error_class

        "#{error_class}: #{message}"
      end

      sig { returns(Integer) }
      def record_count = profile&.record_count || 0

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h
        { source: source, status: status, findings: findings.map(&:to_h), profile: profile&.to_h,
          baseline: baseline&.to_h, duration: duration, error: @failure }
      end

      # The heading a source gets in the report, followed by its findings:
      #
      #   ofac_sdn         WARN  3 findings
      #   un_consolidated  OK
      sig { params(width: Integer).returns(String) }
      def headline(width = 0)
        heading = "#{source.to_s.ljust(width)}  #{label}"
        return heading if findings.empty?

        "#{heading}  #{findings.size} finding#{"s" unless findings.size == 1}"
      end

      # This source's block of the report: its heading, then one line per
      # finding. `width` is how wide the source column is across the whole
      # run, so that the labels line up in a column an eye can run down.
      sig { params(width: Integer).returns(T::Array[String]) }
      def lines(width = 0) = [headline(width)] + findings.map(&:to_line)

      sig { returns(String) }
      def to_s = lines.join("\n")

      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.instance_of?(self.class)

        to_h == other.to_h
      end
      alias eql? ==

      sig { returns(Integer) }
      def hash = [self.class, to_h].hash

      sig { returns(String) }
      def inspect = "#<#{self.class} #{source} #{label} #{findings.size} finding(s)>"

      # `OK`, `INFO`, `WARN` or `ERROR` -- what an operator's eye goes down the
      # left-hand column looking for.
      sig { returns(String) }
      def label = (severity || :ok).to_s.upcase

      private

      sig { params(value: T.untyped).returns(Symbol) }
      def status!(value)
        status = symbol!(:status, value)
        return status if STATUSES.include?(status)

        raise InvalidArgument, "status must be one of #{STATUSES.join(", ")}, got #{value.inspect}"
      end

      sig { params(value: T.untyped).returns(T::Array[Finding]) }
      def findings!(value)
        Array(value).map { |finding| finding.is_a?(Finding) ? finding : Finding.from_h(finding) }.freeze
      end

      sig { params(value: T.untyped).returns(T.nilable(Profile)) }
      def profile!(value)
        return nil if value.nil?

        value.is_a?(Profile) ? value : Profile.from_h(value)
      end

      sig { params(value: T.untyped).returns(T.nilable(T::Hash[Symbol, String])) }
      def failure!(value)
        case value
        when nil then nil
        when Exception then { class: value.class.name.to_s, message: value.message.to_s }.freeze
        else
          pair = value.to_h.transform_keys(&:to_sym)
          name = pair[:class]&.to_s
          name && !name.empty? ? { class: -name, message: pair[:message].to_s }.freeze : nil
        end
      end

      sig { params(member: Symbol, value: T.untyped).returns(Symbol) }
      def symbol!(member, value)
        raise InvalidArgument, "#{member} is required" if value.nil? || value.to_s.empty?

        value.to_sym
      end
    end
  end
end
