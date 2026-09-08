# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/configuration"
require "active_sanction/doctor/finding"
require "active_sanction/doctor/profile"

module ActiveSanction
  class Doctor
    # One source's fresh profile held against what it was last time, and
    # against the floors its adapter committed to. Produces findings and
    # nothing else -- it never fetches, never stores, and never decides what to
    # do about what it found.
    #
    #   Checkup.new(source: :ofac_sdn, observed: today, baseline: yesterday).findings
    #
    # ### The baseline is the last stored snapshot, not a committed number
    #
    # A threshold committed per adapter ("expect ~19,321 rows +/- 2,000") goes
    # stale on its own, and the day somebody bumps it to make the build pass is
    # the day it stops being read. The previous snapshot does not go stale,
    # costs nothing to maintain, and catches what a fixed threshold cannot: a
    # fill rate that has drifted from 61% to 12% is invisible to any bound
    # wide enough to have survived three years of a list growing.
    #
    # Floors are the coarse backstop underneath it, for the run that has
    # nothing to compare against -- a first sync, a new source, a store that
    # was cleared. Without them a first run would have to either pass silently
    # or fail loudly, and both are wrong.
    #
    # ### What separates a warn from an error
    #
    # Not the size of the number. Whether the reading can be explained by the
    # list changing rather than by the file changing.
    #
    # A third of the records disappearing is a `warn`: a delisting wave looks
    # exactly like a truncated download, and deciding automatically that it was
    # the first is how a compliance tool ends up quietly screening against a
    # list it has thrown half of away. A column that used to hold numbers and
    # now holds company names is an `error`, and so is every record on a list
    # losing a field all of them used to carry, because nothing a publisher
    # does to *its list* produces either -- only something done to its *file*
    # does.
    class Checkup
      extend T::Sig

      # A field's fill rate reads better as a sentence than as a name, and the
      # sentence is what an operator scans at three in the morning.
      FIELD_PHRASES = T.let({
        names: "a name",
        aliases: "an alternate name",
        addresses: "an address",
        identifiers: "an identifier",
        programs: "a program",
        remarks: "remarks",
        dates_of_birth: "a date of birth",
        nationalities: "a nationality"
      }.freeze, T::Hash[Symbol, String])

      # Warning classes reported per source. A parse that has gone wrong
      # produces one warning per row, and 19,000 findings help nobody read
      # the one that matters.
      TOP_WARNINGS = T.let(5, Integer)

      sig { returns(Symbol) }
      attr_reader :source

      sig { returns(Profile) }
      attr_reader :observed

      # What this source measured last time, or nil for a run with nothing to
      # compare against.
      sig { returns(T.nilable(Profile)) }
      attr_reader :baseline

      # Check name to the value the adapter committed to as a lower bound. See
      # Sources::Definition#floor.
      sig { returns(T::Hash[Symbol, Numeric]) }
      attr_reader :floors

      # How far a measurement may move before it is worth a finding, as a share
      # of what it was.
      sig { returns(Float) }
      attr_reader :tolerance

      sig do
        params(source: T.untyped, observed: Profile, baseline: T.nilable(Profile), floors: T.untyped,
               tolerance: T.untyped).void
      end
      def initialize(source:, observed:, baseline: nil, floors: {}, tolerance: Configuration::DEFAULT_DOCTOR_TOLERANCE)
        @source = T.let(source.to_sym, Symbol)
        @observed = T.let(observed, Profile)
        @baseline = T.let(baseline, T.nilable(Profile))
        @floors = T.let(floors.to_h { |name, value| [name.to_sym, value] }.freeze, T::Hash[Symbol, Numeric])
        @tolerance = T.let(Float(tolerance), Float)
      end

      # Every finding, most serious first and stable within a severity so that
      # two runs of an unchanged list produce identical output.
      sig { returns(T::Array[Finding]) }
      def findings
        collected = empty_finding || (columns + record_count + fill + remarks_coverage + warnings + orphans)
        collected.sort_by { |finding| [-Finding::SEVERITIES.index(finding.severity).to_i, finding.check.to_s] }
      end

      private

      # A list that parsed to nothing is the one reading that stops every other
      # check being worth running: every fill rate is 0% and every one of them
      # would be reported as its own collapse.
      sig { returns(T.nilable(T::Array[Finding])) }
      def empty_finding
        return nil unless observed.empty?

        [finding(:error, :empty, "parsed to no records at all", observed: 0, baseline: baseline&.record_count)]
      end

      # A positional column holding something other than what it held is the
      # one finding here that needs no baseline: it is an assertion about the
      # file, and a file that fails it is not the file this adapter reads.
      sig { returns(T::Array[Finding]) }
      def columns
        observed.columns.reject { |column| column[:ratio].to_f >= column[:at_least].to_f }.map do |column|
          finding(:error, :"column_#{column[:column]}", column_message(column),
                  observed: column[:ratio], baseline: column[:at_least])
        end
      end

      sig { params(column: T::Hash[Symbol, T.untyped]).returns(String) }
      def column_message(column)
        sample = Array(column[:sample])
        "#{column[:column]} #{column[:description]} on #{percentage(column[:ratio].to_f)} of " \
          "#{number(column[:checked].to_i)} rows, expected #{percentage(column[:at_least].to_f)}" \
          "#{": #{sample.map(&:inspect).join(", ")}" if sample.any?}"
      end

      sig { returns(T::Array[Finding]) }
      def record_count
        now = observed.record_count
        was = baseline&.record_count
        return record_count_floor(now) if was.nil?
        return [] if within?(now, was)

        [finding(now < was ? :warn : :info, :record_count,
                 "#{number(now)} records, was #{number(was)} (#{movement(now, was)})",
                 observed: now, baseline: was)]
      end

      sig { params(now: Integer).returns(T::Array[Finding]) }
      def record_count_floor(now)
        floor_finding(:record_count, now) do |floor|
          "#{number(now)} records, below the floor of #{number(floor.to_i)}"
        end
      end

      # The check that catches a file which changed shape and still parses. See
      # Profile.
      sig { returns(T::Array[Finding]) }
      def fill
        observed.fill.flat_map do |field, now|
          was = baseline&.fill&.[](field)
          next fill_floor(field, now) if was.nil?

          fill_movement(field, now, was)
        end
      end

      sig { params(field: Symbol, now: Float).returns(T::Array[Finding]) }
      def fill_floor(field, now)
        floor_finding(:"fill_#{field}", now) { |floor| fill_floor_message(field, now, floor) }
      end

      sig { params(field: Symbol, now: Float, was: Float).returns(T::Array[Finding]) }
      def fill_movement(field, now, was)
        return lost(field, was) if now.zero? && was.positive?
        return [] if within?(now, was)

        [finding(now < was ? :warn : :info, :"fill_#{field}", fill_message(field, now, was),
                 observed: now, baseline: was)]
      end

      # Every record on the list losing a field all of them carried. The record
      # count is unchanged, nothing raised, and the list now means something
      # different -- which is the failure this whole diagnostic exists for.
      sig { params(field: Symbol, was: Float).returns(T::Array[Finding]) }
      def lost(field, was)
        [finding(:error, :"fill_#{field}",
                 "no #{singular(field)} carries #{phrase(field)} any more, #{percentage(was)} did",
                 observed: 0.0, baseline: was)]
      end

      sig { params(field: Symbol, now: Float, was: Float).returns(String) }
      def fill_message(field, now, was)
        "#{observed.cohort_name(field)} with #{phrase(field)} #{percentage(now)} (was #{percentage(was)}) " \
          "of #{number(observed.cohort_size(field))}"
      end

      sig { params(field: Symbol, now: Float, floor: Numeric).returns(String) }
      def fill_floor_message(field, now, floor)
        "#{observed.cohort_name(field)} with #{phrase(field)} #{percentage(now)}, " \
          "below the floor of #{percentage(floor.to_f)}"
      end

      # How much of the publisher's free text the parser understood. The one
      # measurement here that moves when a publisher re-spells a label rather
      # than when it changes a format, which is the most common way one of
      # these lists quietly stops yielding passports.
      sig { returns(T::Array[Finding]) }
      def remarks_coverage
        now = observed.remarks_coverage
        return [] if now.nil?

        was = baseline&.remarks_coverage
        return floor_finding(:remarks_coverage, now) { |floor| coverage_message(now, nil, floor) } if was.nil?
        return [] if within?(now, was)

        [finding(now < was ? :warn : :info, :remarks_coverage, coverage_message(now, was, nil),
                 observed: now, baseline: was)]
      end

      sig { params(now: Float, was: T.nilable(Float), floor: T.nilable(Numeric)).returns(String) }
      def coverage_message(now, was, floor)
        against = was.nil? ? "below the floor of #{percentage(T.must(floor).to_f)}" : "was #{percentage(was)}"
        "remarks coverage #{percentage(now)} (#{against})#{unrecognized}"
      end

      # The shape that cost the most segments, which is the new spelling if
      # there is one.
      sig { returns(String) }
      def unrecognized
        worst = observed.worst_unrecognized
        worst.nil? ? "" : ": #{worst.first.inspect} x #{number(worst.last.to_i)} unrecognized"
      end

      # A warning class that was not there last time is the signal; the
      # absolute count is not, because these files always carry a few rows
      # nobody can read.
      sig { returns(T::Array[Finding]) }
      def warnings
        return [] if observed.warnings.nil?

        previous = baseline&.warnings
        observed.top_warnings(TOP_WARNINGS).map do |shape, rows|
          was = previous&.fetch(shape, 0)
          share = rows.fdiv([observed.record_count, 1].max)
          warning_finding(warning_severity(share, was), shape, rows, was)
        end
      end

      # Judged as a share of the list rather than as a count, so that a
      # complaint about 41 rows of 19,321 stays informational whichever list it
      # is on. New since the last sync is what raises it: a class that was
      # absent and is now on a tenth of the file is a format change.
      sig { params(share: Float, was: T.nilable(Integer)).returns(Symbol) }
      def warning_severity(share, was)
        return :info if share < tolerance

        was.nil? || was.zero? ? :warn : :info
      end

      sig { params(severity: Symbol, shape: String, rows: Integer, was: T.nilable(Integer)).returns(Finding) }
      def warning_finding(severity, shape, rows, was)
        history = if was.nil?
                    ""
                  else
                    was.zero? ? ", new since the last sync" : ", was #{number(was)}"
                  end
        finding(severity, :warnings, "#{shape} (#{number(rows)} rows#{history})", observed: rows, baseline: was)
      end

      # Child rows that matched no parent. On OFAC's three-file join a nonzero
      # count means the files were downloaded at different moments; it is
      # informational because that resolves itself on the next sync, and worth
      # saying because a join that has stopped joining does not.
      sig { returns(T::Array[Finding]) }
      def orphans
        counts = observed.orphans
        return [] if counts.nil? || observed.orphan_count.zero?

        total = observed.orphan_count
        share = total.fdiv([observed.record_count, 1].max)
        detail = counts.reject { |_file, rows| rows.zero? }.map { |file, rows| "#{number(rows)} in #{file}" }
        [finding(share > tolerance ? :warn : :info, :orphans,
                 "#{number(total)} child row(s) matched no record: #{detail.join(", ")}",
                 observed: total, baseline: baseline&.orphan_count)]
      end

      # The coarse backstop, and only where the adapter committed to one.
      # Silence for a check with no floor is deliberate: a first run reporting
      # every unmeasurable thing as a problem is a first run nobody reads.
      sig do
        params(check: Symbol, value: Numeric, block: T.proc.params(floor: Numeric).returns(String))
          .returns(T::Array[Finding])
      end
      def floor_finding(check, value, &block)
        floor = floors[check]
        return [] if floor.nil? || value >= floor

        [finding(:warn, check, block.call(floor), observed: value, baseline: nil)]
      end

      # Whether a reading moved far enough from what it was to be worth saying,
      # as a share of what it was. A baseline of zero has no share to be a
      # fraction of, so anything above it counts as movement.
      sig { params(now: Numeric, was: Numeric).returns(T::Boolean) }
      def within?(now, was)
        return now == was if was.zero?

        (now - was).abs.fdiv(was) <= tolerance
      end

      sig { params(now: Numeric, was: Numeric).returns(String) }
      def movement(now, was)
        share = (now - was).abs.fdiv(was).to_f
        "#{now < was ? "down" : "up"} #{percentage(share)}"
      end

      sig do
        params(severity: Symbol, check: Symbol, message: String, observed: T.untyped, baseline: T.untyped)
          .returns(Finding)
      end
      def finding(severity, check, message, observed: nil, baseline: nil)
        Finding.new(source: source, severity: severity, check: check, message: message,
                    observed: observed, baseline: baseline)
      end

      sig { params(field: Symbol).returns(String) }
      def phrase(field) = FIELD_PHRASES.fetch(field, field.to_s.tr("_", " "))

      # "no individual carries a date of birth any more" -- the cohort name in
      # the singular, which is the only place a fill message needs one.
      sig { params(field: Symbol).returns(String) }
      def singular(field)
        name = observed.cohort_name(field)
        name.end_with?("s") ? T.must(name[0..-2]) : name
      end

      sig { params(ratio: Float).returns(String) }
      def percentage(ratio)
        value = (ratio * 100).round(1)
        value == value.to_i ? "#{value.to_i}%" : "#{value}%"
      end

      # Thousands separated, because the numbers this reports are list-sized
      # and "19321" and "1932" are one glance apart.
      sig { params(value: Integer).returns(String) }
      def number(value) = value.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
    end
  end
end
