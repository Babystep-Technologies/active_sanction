# frozen_string_literal: true

require "fileutils"

require_relative "issue"

module Canary
  # What `rake canary` and `rake canary:refresh` actually do: read the
  # environment, run the canary, print it, write what the workflow needs, and
  # answer with an exit code.
  #
  #     bundle exec rake canary
  #     CANARY_SOURCES=ofac_sdn bundle exec rake canary
  #     CANARY_PREVIOUS=previous/report.json bundle exec rake canary
  #
  # Options arrive through the environment rather than through arguments,
  # because rake's argument syntax is worse than an environment variable at
  # every length, and because a workflow sets environment variables anyway.
  #
  #   CANARY_SOURCES     comma-separated source keys; every registered source
  #                      by default
  #   CANARY_BASELINES   where the committed baselines live
  #                      (.github/baselines)
  #   CANARY_OUT         where the report and the issue bodies are written
  #                      (tmp/canary)
  #   CANARY_PREVIOUS    the report the last run wrote, which is what lets a
  #                      finding be confirmed; without it nothing is reported
  #   CANARY_REPORT      for `refresh`, a report to rewrite the baselines from
  #                      rather than fetching every list again
  #   CANARY_RUN_URL     the workflow run to link the issue bodies back to
  #   CANARY_USER_AGENT  what the publishers see; see Run::USER_AGENT
  #
  # ### What it writes, and what reads it
  #
  # `<out>/report.json` is the run, and is kept as a workflow artifact so that
  # tomorrow's run has something to agree with. `<out>/<source>.md` is one
  # issue body per source with something wrong, which the workflow hands to
  # `gh issue create`. `<out>/summary.md` is the job summary.
  #
  # Nothing here talks to GitHub. Opening, updating and closing the issues is
  # the workflow's job, done with `gh` and the token it already has -- a canary
  # that authenticated to an API of its own would be a second thing to hold
  # credentials for, and a laptop running `rake canary` must not be able to
  # open an issue by accident.
  module CLI
    module_function

    # Runs the canary and answers with the exit code. See Report#exit_code.
    def canary(env: ENV, io: $stdout)
      configure(env)
      out = env.fetch("CANARY_OUT", File.join(Canary.root, "tmp", "canary"))
      run = Run.new(sources: split(env["CANARY_SOURCES"]), baselines: baselines(env),
                    previous: Report.read(env["CANARY_PREVIOUS"]))
      report = run.call
      io.puts report
      publish(report, run, out: out, env: env, io: io)
      report.exit_code
    end

    # Rewrites the committed baselines from a run, and answers 0 whether or not
    # anything moved -- this is a maintainer accepting what the lists say now,
    # not a check.
    #
    # `CANARY_REPORT` reuses a report a run already wrote, so that the
    # workflow's baseline-update pull request costs no second download of seven
    # government files.
    def refresh(env: ENV, io: $stdout)
      report = Report.read(env["CANARY_REPORT"]) || begin
        configure(env)
        Run.new(sources: split(env["CANARY_SOURCES"]), baselines: baselines(env)).call
      end
      written = Baseline.refresh(report, directory: baselines(env))
      io.puts written.empty? ? "baselines unchanged" : "rewrote #{written.join(", ")}"
      0
    end

    # The gem's default user agent already names this repository; this names
    # the job as well, so a publisher reading its logs can tell a nightly
    # format check from an application syncing its lists.
    def configure(env)
      ActiveSanction.configure do |config|
        config.user_agent = env.fetch("CANARY_USER_AGENT", Run::USER_AGENT)
      end
    end

    def baselines(env) = env.fetch("CANARY_BASELINES", Baseline.directory)

    def split(value) = value.to_s.split(",").map(&:strip).reject(&:empty?)

    # The report, one issue body per source with something wrong, and the job
    # summary.
    def publish(report, run, out:, env:, io:)
      FileUtils.mkdir_p(out)
      report.write(File.join(out, "report.json"))
      report.results.reject(&:ok?).each { |result| write_issue(result, run, out: out, env: env) }
      File.write(File.join(out, "summary.md"), summary(report))
      io.puts "\nwritten to #{out}"
    end

    def write_issue(result, run, out:, env:)
      issue = Issue.new(result, run_url: env["CANARY_RUN_URL"],
                                captured_at: run.baseline(result.source).captured_at)
      File.write(File.join(out, "#{result.source}.md"), "#{issue.body}\n")
    end

    # A run that found something but has nothing to confirm it against is the
    # one state worth spelling out here: silence about a source and health of a
    # source must not look the same to somebody reading the job summary.
    def summary(report)
      pending = report.pending
      notes = if pending.empty?
                ""
              else
                "\n\nSeen once, not yet reported: #{pending.map(&:source).join(", ")}. " \
                  "Nothing is opened until a second run agrees.\n"
              end
      "## Canary\n\n```\n#{report}\n```#{notes}\n"
    end
  end
end
