# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "time"
require "active_sanction/sync/result"

module ActiveSanction
  class Sync
    # What a whole sync run did, one Result per source.
    #
    #   report = ActiveSanction.sync!
    #
    #   report.failed?                  # => true
    #   report[:un_consolidated].error  # => "Net::ReadTimeout: ..."
    #   report.updated.map(&:source)    # => [:ofac_sdn]
    #   puts report                     # => the table below
    #
    #   4 sources in 13.08s: 1 updated, 2 unchanged, 1 failed
    #     ofac_sdn           updated    19015 records  just fetched   12.41s
    #     ofac_consolidated  unchanged   1203 records  2h old          0.28s
    #     canada_sema        unchanged    684 records  2h old          0.19s
    #     un_consolidated    failed       612 records  3d old          1.11s  Net::ReadTimeout: execution expired
    #
    # ### It is an object, not console output
    #
    # This is the operational surface of a sync: it is what a host application
    # alerts on, what a scheduled job exits with, and what the instrumentation
    # hooks (#59) emit. So it serializes to a documented shape and `.from_h`
    # rebuilds it -- a summary that only existed as printed text would mean
    # every host that wants to notice a degrading source has to scrape a log.
    #
    # Note what the table prints beside a failure: the record count and age of
    # the snapshot that source is *still* being screened against. A failed sync
    # keeps its previous snapshot, which is the right call and is only safe
    # while the age of what is being screened against is visible.
    #
    # Instances are frozen on construction and compare by value.
    class Report
      extend T::Sig
      extend T::Generic
      include Enumerable

      # @api private
      Elem = type_member { { fixed: Result } }

      # @api private
      MEMBERS = T.let(%i[results started_at duration].freeze, T::Array[Symbol])

      sig { returns(T::Array[Result]) }
      attr_reader :results

      # When the run began, UTC.
      sig { returns(Time) }
      attr_reader :started_at

      # Wall-clock seconds for the whole run, which is less than the sum of the
      # per-source durations when sources ran in parallel.
      sig { returns(Float) }
      attr_reader :duration

      # Rebuilds from #to_h output, accepting string keys so a report survives
      # the trip through JSON.
      sig { params(hash: T.untyped).returns(T.attached_class) }
      def self.from_h(hash)
        attributes = hash.to_h.transform_keys(&:to_sym)
        unknown = attributes.keys - MEMBERS
        raise InvalidArgument, "unknown Sync::Report attribute(s): #{unknown.join(", ")}" if unknown.any?

        T.unsafe(self).new(**attributes)
      end

      sig { params(results: T.untyped, started_at: T.untyped, duration: T.untyped).void }
      def initialize(results:, started_at: nil, duration: 0.0)
        @results = T.let(results!(results), T::Array[Result])
        @started_at = T.let(time!(started_at), Time)
        @duration = T.let(duration.to_f, Float)
        freeze
      end

      sig { override.params(block: T.nilable(T.proc.params(result: Result).void)).returns(T.untyped) }
      def each(&block)
        return enum_for(:each) unless block

        results.each(&block)
        self
      end

      # One source's result, or nil if the run did not cover it. A run that did
      # not cover a source is not the same as one where it succeeded, which is
      # why this does not raise: a caller asking about a source it did not sync
      # is asking a question with an answer.
      sig { params(source: T.untyped).returns(T.nilable(Result)) }
      def [](source)
        key = source.to_sym
        results.find { |result| result.source == key }
      end

      sig { returns(T::Array[Symbol]) }
      def sources = results.map(&:source)

      sig { returns(T::Array[Result]) }
      def updated = results.select(&:updated?)

      sig { returns(T::Array[Result]) }
      def unchanged = results.select(&:unchanged?)

      sig { returns(T::Array[Result]) }
      def failed = results.select(&:failed?)

      # Sources that came out of this run with no snapshot stored at all, and
      # so are not covered by screening. Louder than `failed` and rarer: a
      # source that failed but kept its previous list is stale, one that has
      # nothing stored is missing.
      sig { returns(T::Array[Result]) }
      def unscreenable = results.reject(&:stored?)

      sig { returns(T::Boolean) }
      def failed? = results.any?(&:failed?)

      sig { returns(T::Boolean) }
      def success? = !failed?

      sig { returns(Integer) }
      def size = results.size

      sig { returns(T::Boolean) }
      def empty? = results.empty?

      # Records stored across every source the run covered, failures included:
      # what is screenable now, rather than what was downloaded.
      sig { returns(Integer) }
      def record_count = results.sum { |result| result.record_count || 0 }

      # The age of the stalest list this run left behind, in seconds. The one
      # number to alert on if a host only wants one.
      sig { returns(T.nilable(Integer)) }
      def oldest_age = results.filter_map(&:age).max

      # What a scheduled job should exit with, so that cron mails somebody and
      # CI goes red when a source is failing. Deliberately here rather than
      # left to each caller to derive: "one source failed" has to mean the same
      # thing to every wrapper anyone writes around a sync.
      #
      #   exit ActiveSanction.sync!.exit_code
      sig { returns(Integer) }
      def exit_code = failed? ? 1 : 0

      # For a caller that wants any failure to be fatal, in the manner of
      # Fetcher::Result#success!. Note that this is not what `sync!` does: the
      # run has already finished and every other source has already been
      # stored, so raising here reports a failure rather than causing one.
      sig { returns(T.self_type) }
      def success!
        return self if success?

        raise Failed, self
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h
        {
          results: results.map(&:to_h),
          started_at: started_at.iso8601,
          duration: duration
        }
      end

      # The sentence a failing run should put in front of a human: which
      # sources failed, out of how many, and why.
      sig { params(result: Result).returns(String) }
      def records(result) = result.record_count&.to_s || "-"

      sig { params(block: T.proc.params(result: Result).returns(String)).returns(Integer) }
      def width(&block) = results.map { |result| block.call(result).length }.max.to_i

      sig { returns(String) }
      def failure_message
        "#{failed.size} of #{size} source(s) failed to sync: " +
          failed.map { |result| "#{result.source} (#{result.error})" }.join("; ")
      end

      sig { returns(String) }
      def summary
        counts = { updated: updated.size, unchanged: unchanged.size, failed: failed.size }
                 .reject { |_status, count| count.zero? }
                 .map { |status, count| "#{count} #{status}" }
        "#{size} #{size == 1 ? "source" : "sources"} in #{format("%.2f", duration)}s" \
          "#{": #{counts.join(", ")}" unless counts.empty?}"
      end

      sig { returns(String) }
      def to_s = ([summary] + rows).join("\n")

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

      # One padded line per source. Columns rather than sentences because the
      # thing an operator is doing with this is scanning down it for the row
      # that is not like the others.
      sig { returns(T::Array[String]) }
      def rows
        name = width { |result| result.source.to_s }
        count = width { |result| records(result) }
        age = width(&:age_in_words)
        results.map do |result|
          "  #{result.source.to_s.ljust(name)}  #{result.status.to_s.ljust(9)}  " \
            "#{records(result).rjust(count)} records  #{result.age_in_words.ljust(age)}  " \
            "#{format("%.2f", result.duration).rjust(6)}s#{"  #{result.error}" if result.failed?}"
        end
      end

      sig { params(value: T.untyped).returns(T::Array[Result]) }
      def results!(value)
        list = Array(value).map { |result| result.is_a?(Result) ? result : Result.from_h(result) }
        list.freeze
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
