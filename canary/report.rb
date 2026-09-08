# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Canary
  # What one canary run found, one Result per source.
  #
  #   report = Canary::Run.new.call
  #
  #   report.ok?           # => false
  #   report[:ofac_sdn]    # => Result
  #   report.reportable    # => the sources a second run has agreed about
  #   exit report.exit_code
  #   puts report
  #
  #   3 sources in 41.02s: 1 drifting, 1 unreachable
  #   ofac_sdn         DRIFT        19,402 records (baseline 19,321)
  #                                 warn  remarks coverage 71.4% (was 97.3%): "Passport No." x 1,880 unrecognized
  #   un_consolidated  OK           1,014 records (baseline 1,011)
  #   eu_fsf           UNREACHABLE  ActiveSanction::HttpClient::ResponseError: 403
  #
  # ### Two runs have to agree before anything is opened
  #
  # A run is written to JSON and kept as a workflow artifact; the next run
  # downloads it and calls #confirmed_against with it. A finding reported by
  # both runs is confirmed and can be opened as an issue; a finding seen once is
  # pending and is printed, kept in the report and otherwise left alone.
  #
  # This is the rule that makes the canary worth leaving switched on. Government
  # endpoints have bad afternoons -- a 403 for a non-browser user agent, a
  # blocked cloud IP range, a file truncated mid-publish -- and every one of
  # those clears on its own by the next morning. Reporting them would fill the
  # tracker with issues that were wrong by the time anybody read them, and the
  # one that was not wrong would be scrolled past with the rest.
  #
  # With no previous report at all, nothing is confirmed and nothing is opened.
  # That is deliberate, and it is why the run says `pending` rather than
  # `clean` -- silence about a source and health of a source must not look the
  # same.
  class Report
    def self.from_h(hash)
      attributes = hash.to_h.transform_keys(&:to_sym)
      new(results: Array(attributes[:results]).map { |one| Result.from_h(one) },
          started_at: attributes[:started_at], duration: attributes[:duration].to_f)
    end

    # Reads a report a previous run wrote, or nil where there is none. A
    # missing or unreadable artifact is not an error: it means the previous run
    # never got as far as writing one, which is itself a reason not to confirm
    # anything against it.
    def self.read(path)
      return nil if path.nil? || path.to_s.empty? || !File.exist?(path)

      from_h(JSON.parse(File.read(path)))
    rescue JSON::ParserError, ActiveSanction::InvalidArgument, ArgumentError
      nil
    end

    attr_reader :results, :started_at, :duration

    def initialize(results:, started_at: nil, duration: 0.0)
      @results = Array(results).freeze
      @started_at = time!(started_at)
      @duration = duration.to_f
      freeze
    end

    def [](source)
      key = source.to_sym
      results.find { |result| result.source == key }
    end

    def sources = results.map(&:source)

    def size = results.size

    def ok? = results.all?(&:ok?)

    def drifted = results.select(&:drift?)

    def unreachable = results.select(&:unreachable?)

    # The sources something is wrong with and a previous run agreed about.
    def reportable = results.select(&:reportable?)

    # The sources something is wrong with that no previous run has agreed with
    # yet -- one bad afternoon, or the first morning of a real change.
    def pending = results.select(&:pending?)

    # Every finding, in the order the sources were examined.
    def findings = results.flat_map(&:findings)

    # The same report, told what the run before it said. See the class comment.
    def confirmed_against(previous)
      self.class.new(results: results.map { |result| result.confirmed_against(previous&.[](result.source)) },
                     started_at: started_at, duration: duration)
    end

    # What `rake canary` exits with. Drift outranks a fetch failure, because
    # only one of the two is ever certain, and both outrank a clean run:
    #
    #   0  every source parsed into what its baseline says it should
    #   1  at least one parsed into something else
    #   2  at least one could not be fetched, and none drifted
    #
    # Note that this is the state of the *lists*, not of the report: a run
    # whose findings are still pending confirmation exits non-zero all the
    # same, because something is wrong with a government file whether or not
    # this is the morning to open an issue about it.
    def exit_code
      return 1 if drifted.any?

      unreachable.any? ? 2 : 0
    end

    def to_h
      { generated_at: started_at.iso8601, duration: duration, summary: summary,
        results: results.map(&:to_h) }
    end

    def write(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{JSON.pretty_generate(to_h)}\n")
      path
    end

    def summary
      counts = { "drifting" => drifted.size, "unreachable" => unreachable.size,
                 "pending confirmation" => pending.size }
               .reject { |_label, count| count.zero? }
               .map { |label, count| "#{count} #{label}" }
      "#{size} #{size == 1 ? "source" : "sources"} in #{format("%.2f", duration)}s: " \
        "#{counts.empty? ? "all as committed" : counts.join(", ")}"
    end

    def to_s = ([summary] + results.flat_map { |result| lines(result) }).join("\n")

    def inspect = "#<#{self.class} #{summary}>"

    private

    # One source's block: its heading and the count that anchors it, then one
    # line per finding, indented under the columns so an eye can run down them.
    def lines(result)
      heading = "#{result.source.to_s.ljust(width)}  #{result.label.ljust(label_width)}  #{counts(result)}"
      [heading] + result.findings.map { |finding| "#{" " * (width + label_width + 4)}#{severity(finding)}#{finding}" }
    end

    def counts(result)
      return failure(result.error) if result.profile.nil?

      baseline = result.baseline
      "#{number(result.record_count)} records#{" (baseline #{number(baseline.record_count)})" if baseline}"
    end

    # The exception on one line, and without a dangling colon for the error
    # class that carried no message of its own.
    def failure(error)
      return "not read" if error.nil?

      message = error["message"].to_s
      message.empty? ? error["class"].to_s : "#{error["class"]}: #{message}"
    end

    def severity(finding) = "#{finding.severity.to_s.ljust(5)}  "

    def width = results.map { |result| result.source.to_s.length }.max.to_i

    def label_width = results.map { |result| result.label.length }.max.to_i

    def number(value) = value.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

    def time!(value)
      case value
      when nil then Time.now.utc
      when Time then value.utc
      else Time.parse(value.to_s).utc
      end
    end
  end
end
