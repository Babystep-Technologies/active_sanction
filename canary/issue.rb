# frozen_string_literal: true

module Canary
  # One source's findings, written as the GitHub issue that reports them.
  #
  #   issue = Canary::Issue.new(result, run_url: "https://github.com/.../actions/runs/1")
  #   issue.title   # => "Canary: ofac_sdn has drifted"
  #   issue.body    # => the markdown
  #
  # ### Why the output is an issue rather than a red badge
  #
  # A build status says something is wrong for as long as it is wrong and then
  # forgets it. What a maintainer needs from a publisher changing a label is the
  # opposite: a thing that survives, can be assigned, can be argued with, and
  # links to the commit that fixed it. So the canary opens one issue per source
  # and keeps it up to date, rather than turning anything red.
  #
  # ### The body is rewritten, not appended to
  #
  # One issue per source, whose body is replaced on every run that still finds
  # something. A drift that lasts three weeks is one issue that says what is
  # true today, not fifteen comments to scroll through -- and the marker comment
  # at the top is how the next run finds it again.
  class Issue
    # How the workflow finds the issue it opened for a source. Invisible when
    # rendered, and stable across every rewording of everything below it.
    def self.marker(source) = "<!-- canary:#{source} -->"

    attr_reader :result, :run_url, :baseline_path

    def initialize(result, run_url: nil, captured_at: nil, baseline_path: nil)
      @result = result
      @run_url = run_url
      @captured_at = captured_at
      @baseline_path = baseline_path || ".github/baselines/#{result.source}.json"
    end

    def title = result.title

    def body
      sections = result.unreachable? ? unreachable_sections : drift_sections
      ([self.class.marker(result.source)] + sections.compact + [footer]).join("\n\n")
    end

    private

    def drift_sections
      [opening, findings_table, measurements, remedy]
    end

    def opening
      "`#{result.source}` parsed into something [`#{baseline_path}`](#{baseline_path}) does not describe. " \
        "#{agreement}"
    end

    # Said only where it is true. An issue that claims two runs agreed when
    # one did not would make the claim worthless everywhere else it appears.
    def agreement
      return "It has been seen once so far." unless result.reportable?

      "Two consecutive canary runs agreed on this before it was opened, so it is not one bad afternoon " \
        "on a publisher's host."
    end

    def findings_table
      rows = result.findings.map do |finding|
        "| #{finding.severity} | `#{finding.check}` | #{escape(finding.message)} |"
      end
      return nil if rows.empty?

      (["| | check | what it says |", "| --- | --- | --- |"] + rows).join("\n")
    end

    # The numbers behind the findings, including the ones that did not move --
    # a coverage drop is read very differently depending on whether the record
    # count moved with it.
    def measurements
      rows = measurement_rows
      return nil if rows.empty?

      ["### Measurements", (["| | this run | baseline |", "| --- | --- | --- |"] + rows).join("\n")].join("\n\n")
    end

    def measurement_rows
      observed = result.profile
      return [] if observed.nil?

      baseline = result.baseline
      [row("records", number(observed.record_count), baseline && number(baseline.record_count))] +
        coverage_row(observed, baseline) + fill_rows(observed, baseline)
    end

    def coverage_row(observed, baseline)
      return [] if observed.remarks_coverage.nil?

      [row("remarks coverage", percentage(observed.remarks_coverage),
           baseline&.remarks_coverage && percentage(baseline.remarks_coverage))]
    end

    def fill_rows(observed, baseline)
      observed.fill.map do |field, share|
        was = baseline&.fill&.[](field)
        row("#{observed.cohort_name(field)} with #{phrase(field)}", percentage(share), was && percentage(was))
      end
    end

    def row(label, observed, baseline) = "| #{label} | #{observed} | #{baseline || "—"} |"

    def remedy
      <<~MARKDOWN.strip
        ### What to do with this

        1. **Look at the published file.** #{urls} The list is the record; this is one library's reading of it.
        2. **If the publisher changed something,** the fix belongs in the adapter — a new label in the remarks
           vocabulary, a renamed element, a column that moved. Close this issue with the change that adapts to it.
        3. **If this is normal churn,** run `bundle exec rake canary:refresh` and commit the diff to
           [`#{baseline_path}`](#{baseline_path}). Tune the per-key `tolerances` in that file if the same movement
           is going to keep arriving.

        This issue is rewritten by every run that still finds something, and closed automatically by the first
        run that comes back clean.
      MARKDOWN
    end

    def urls
      source = ActiveSanction::Sources[result.source]
      urls = source.respond_to?(:urls) ? source.urls.values : []
      return "" if urls.empty?

      urls.map { |url| "<#{url}>" }.join(" ")
    rescue ActiveSanction::Sources::UnknownSource
      ""
    end

    def unreachable_sections
      ["`#{result.source}` could not be fetched. #{agreement}", failure, transient]
    end

    def failure
      error = result.error || {}
      "```\n#{error["class"]}: #{error["message"]}\n```"
    end

    def transient
      <<~MARKDOWN.strip
        **This is a fetch failure, not drift.** Nothing here knows whether #{result.source} has changed — only
        that it could not be read. The library classes this error as #{retryable}.

        Government endpoints 403 a non-browser user agent and block cloud IP ranges, so the first thing to
        establish is whether the file is reachable from somewhere that is not a GitHub runner. If it is, the
        canary is being blocked rather than the list being down, and the fix is here rather than there.
      MARKDOWN
    end

    def retryable
      return "**retryable** — a publisher or an intermediary in a state it will not be in tomorrow" if
        (result.error || {})["retryable"]

      "**not retryable** — waiting is unlikely to fix this on its own"
    end

    def footer
      run = run_url ? " from [this run](#{run_url})" : ""
      captured = @captured_at ? " Baseline captured #{@captured_at}." : ""
      "<sub>Opened by the upstream canary (#69)#{run}.#{captured} " \
        "Run it by hand from **Actions → Canary → Run workflow**.</sub>"
    end

    def phrase(field)
      ActiveSanction::Doctor::Checkup::FIELD_PHRASES.fetch(field, field.to_s.tr("_", " "))
    end

    def percentage(ratio)
      value = (ratio.to_f * 100).round(1)
      value == value.to_i ? "#{value.to_i}%" : "#{value}%"
    end

    def number(value) = value.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

    def escape(text) = text.to_s.gsub("|", "\\|")
  end
end
