# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"

module ActiveSanction
  class Doctor
    # One thing a diagnosis noticed about one source.
    #
    #   finding.source     # => :ofac_sdn
    #   finding.severity   # => :warn
    #   finding.check      # => :remarks_coverage
    #   finding.observed   # => 0.714
    #   finding.baseline   # => 0.973
    #   finding.to_s       # => "remarks coverage 71.4% (was 97.3%): \"Passport No.\" x 1880 unrecognized"
    #
    # ### Three severities, and what separates them
    #
    #   :error  this list is not what it was, and screening against it is
    #           unsafe -- it did not parse, it parsed to nothing, a column
    #           holds something else now, a field that every record carried
    #           is gone from all of them
    #   :warn   a measurement moved further than a list of this kind moves in
    #           a day, and a human should look at it before the next sync
    #   :info   something changed, or something is unrecognized, and it is
    #           within what these files do on their own
    #
    # The line between `error` and `warn` is not how big the number is. It is
    # whether the reading can be explained by the list changing rather than by
    # the *file* changing. A quarter of the records disappearing is a `warn`,
    # because a delisting wave looks exactly like that and deciding which one
    # it was is a judgment nothing here is entitled to make. A column that used
    # to be numeric and is now full of company names is an `error`, because
    # nothing a publisher does to its list can do that to its file.
    #
    # ### Observed and baseline are numbers, not prose
    #
    # `message` is written for a person reading a terminal at three in the
    # morning. `observed` and `baseline` are for everything else: a threshold
    # in a monitoring rule, a graph of a fill rate over ninety days, the
    # instrumentation hooks (#59) a host application alerts through. Both are
    # nil for a finding that is not a measurement -- a parse failure has no
    # number.
    #
    # Instances are frozen on construction and compare by value.
    class Finding
      extend T::Sig

      # Ordered, least serious first: comparing two severities is comparing
      # their positions here.
      SEVERITIES = T.let(%i[info warn error].freeze, T::Array[Symbol])

      MEMBERS = T.let(%i[source severity check message observed baseline].freeze, T::Array[Symbol])

      sig { returns(Symbol) }
      attr_reader :source

      # One of SEVERITIES.
      sig { returns(Symbol) }
      attr_reader :severity

      # Which check produced this, as a stable machine name -- `:record_count`,
      # `:fill_identifiers`, `:column_ent_num`. What a monitoring rule is
      # written against, and what stays the same when the message is reworded.
      sig { returns(Symbol) }
      attr_reader :check

      sig { returns(String) }
      attr_reader :message

      # What was measured this run, and what it was measured against. nil for a
      # finding that is not a measurement, and `baseline` is nil as well for
      # the first run of a source, where there was nothing to compare with.
      sig { returns(T.untyped) }
      attr_reader :observed

      sig { returns(T.untyped) }
      attr_reader :baseline

      sig { params(hash: T.untyped).returns(T.attached_class) }
      def self.from_h(hash)
        attributes = hash.to_h.transform_keys(&:to_sym)
        unknown = attributes.keys - MEMBERS
        raise InvalidArgument, "unknown Doctor::Finding attribute(s): #{unknown.join(", ")}" if unknown.any?

        T.unsafe(self).new(**attributes)
      end

      # Whether `first` is at least as serious as `second`.
      sig { params(first: Symbol, second: Symbol).returns(T::Boolean) }
      def self.at_least?(first, second)
        SEVERITIES.index(first).to_i >= SEVERITIES.index(second).to_i
      end

      sig do
        params(source: T.untyped, severity: T.untyped, check: T.untyped, message: T.untyped,
               observed: T.untyped, baseline: T.untyped).void
      end
      def initialize(source:, severity:, check:, message:, observed: nil, baseline: nil)
        @source = T.let(symbol!(:source, source), Symbol)
        @severity = T.let(severity!(severity), Symbol)
        @check = T.let(symbol!(:check, check), Symbol)
        @message = T.let(message!(message), String)
        @observed = T.let(observed, T.untyped)
        @baseline = T.let(baseline, T.untyped)
        freeze
      end

      sig { returns(T::Boolean) }
      def error? = severity == :error

      sig { returns(T::Boolean) }
      def warn? = severity == :warn

      sig { returns(T::Boolean) }
      def info? = severity == :info

      # Whether this finding is at least as serious as `level`.
      sig { params(level: T.untyped).returns(T::Boolean) }
      def at_least?(level) = Finding.at_least?(severity, symbol!(:severity, level))

      # Whether there was anything to compare against. False says the reading
      # was held to a committed floor rather than to the last sync.
      sig { returns(T::Boolean) }
      def compared? = !baseline.nil?

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h
        { source: source, severity: severity, check: check, message: message,
          observed: observed, baseline: baseline }
      end

      sig { returns(String) }
      def to_s = message

      # The line the report prints under a source.
      sig { returns(String) }
      def to_line = "  #{severity.to_s.ljust(5)}  #{message}"

      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.instance_of?(self.class)

        to_h == other.to_h
      end
      alias eql? ==

      sig { returns(Integer) }
      def hash = [self.class, to_h].hash

      sig { returns(String) }
      def inspect = "#<#{self.class} #{source} #{severity} #{check}: #{message}>"

      private

      sig { params(value: T.untyped).returns(Symbol) }
      def severity!(value)
        severity = symbol!(:severity, value)
        return severity if SEVERITIES.include?(severity)

        raise InvalidArgument, "severity must be one of #{SEVERITIES.join(", ")}, got #{value.inspect}"
      end

      sig { params(member: Symbol, value: T.untyped).returns(Symbol) }
      def symbol!(member, value)
        raise InvalidArgument, "#{member} is required" if value.nil? || value.to_s.empty?

        value.to_sym
      end

      sig { params(value: T.untyped).returns(String) }
      def message!(value)
        string = value.to_s.strip
        raise InvalidArgument, "message is required" if string.empty?

        -string
      end
    end
  end
end
