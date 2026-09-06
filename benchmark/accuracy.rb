# frozen_string_literal: true

# What the matching pipeline actually finds, and what it wrongly alerts on
# (#37).
#
#     bundle exec rake benchmark:accuracy
#     BACKGROUND=store bundle exec rake benchmark:accuracy
#
# Every threshold in this library was a guess until this ran. The question a
# compliance team asks is not whether 75 is a sensible-looking number, it is
# what raising it to 85 costs -- and in this domain the two errors are not
# symmetric: a false positive costs an analyst ten minutes, and a false
# negative is a sanctioned counterparty onboarded. That trade cannot be argued
# from intuition, so this measures it.
#
# It screens the labeled set (benchmark/fixtures/labeled_set.yml) once at a
# threshold of zero and derives every number from those scores, which is what
# makes the whole sweep exact rather than sampled: what a query scored against
# a record does not depend on the threshold, only whether it is reported does.
#
# The report is written to benchmark/results/accuracy.md as well as printed,
# and that file is committed. It is deterministic -- the same fixtures and the
# same seeded corpus give the same numbers on any machine and any Ruby -- so a
# diff in it is a change in what this library finds, which is the one thing
# about match quality that is otherwise invisible in a code review. Nothing
# timed goes into it, for the same reason: a report that changed on every
# laptop would be scrolled past. Timings are benchmark/latency.rb.
#
# ### The four numbers, and what each one is a number about
#
# **Recall** is over the labeled positives: of the queries somebody wrote a
# right answer down for, how many returned it. This is the number a regulator
# is asking about.
#
# **Precision** is over alerts on labeled records only -- a hit on a record
# somebody wrote the right answer for, that was the wrong answer. Alerts on
# the surrounding haystack are deliberately kept out of it: the haystack is
# synthetic, and folding it in would report a precision that is really a
# statement about a name generator.
#
# **Noise** is those haystack alerts, per query, counted separately. It is the
# honest measure of what a threshold costs an analyst's queue, and it is why a
# threshold of 50 is not free even though its precision looks respectable.
#
# **F1** is the two at once, and it is what the default threshold is argued
# from at the end of the report -- with the argument written out rather than
# left implicit, because F1 weighs the two errors equally and this domain does
# not.
#
# ### A class rather than a module
#
# Unlike the other three benchmarks, this one builds a document: every section
# reads the same screening results and appends to the same report. The state
# is the point, so it is an object rather than a module with instance
# variables hidden on itself.

require_relative "labeled_set"

class AccuracyBenchmark
  # The size of the haystack, matching the other benchmarks: roughly OFAC plus
  # the UN plus Canada once aliases are counted.
  ENTITIES = 27_000

  THRESHOLDS = (0..95).step(5).to_a.freeze

  RESULTS = File.expand_path("results/accuracy.md", __dir__)

  # The plot, in characters.
  WIDTH = 54
  ROWS = 11

  # Metrics at one threshold, over some set of labeled cases. `found` and
  # `missed` count queries; `false_alerts` and `noise` count alerts, since one
  # query can produce several of either.
  Measurement = Struct.new(:threshold, :found, :missed, :false_alerts, :noise, :queries, keyword_init: true) do
    def precision = found.zero? ? 0.0 : found.fdiv(found + false_alerts)
    def recall = (found + missed).zero? ? 0.0 : found.fdiv(found + missed)
    def f1 = (precision + recall).zero? ? 0.0 : 2 * precision * recall / (precision + recall)
    def noise_per_query = queries.zero? ? 0.0 : noise.fdiv(queries)
  end

  def self.run = new.run

  # Screened once, at a threshold of nothing and a limit high enough that the
  # candidate cap is what bounds the answer rather than the query's own limit.
  # Every section below reads these same results.
  def initialize
    @matcher = LabeledSet.matcher(ENTITIES)
    @alerts = LabeledSet.cases.map do |kase|
      [kase, @matcher.screen(kase.query.merge(threshold: 0, limit: ActiveSanction.config.candidate_limit))]
    end
    @lines = []
  end

  def run
    header
    sweep
    curve
    breakdown("source", "the list the record is on") { |kase| listing(kase) }
    breakdown("variation", "what the query did to the name", &:variation)
    identifiers
    mistakes
    rationale
    File.write(RESULTS, "#{@lines.join("\n")}\n")
  end

  private

  # Printed and collected, so what is committed is exactly what the terminal
  # showed. Right-stripped: a column left blank is a fact about the run, and
  # trailing spaces in a committed file are noise in every diff after it.
  def say(line = "")
    puts line.rstrip
    @lines << line.rstrip
  end

  def default = ActiveSanction.config.screening_threshold

  # Every metric at one threshold, over the cases given.
  def measure(alerts, threshold)
    counts = Hash.new(0)
    alerts.each do |kase, results|
      labeled, background = results.select { |result| result.score >= threshold }
                                   .partition { |result| !LabeledSet.background?(result) }
      counts[:noise] += background.size
      tally(counts, kase, labeled)
    end
    Measurement.new(threshold: threshold, found: counts[:found], missed: counts[:missed],
                    false_alerts: counts[:false_alerts], noise: counts[:noise], queries: alerts.size)
  end

  # A positive query is found or missed once, whatever else it alerted on, and
  # every alert that is not its answer is a false one -- which for a query
  # with no answer is all of them.
  def tally(counts, kase, labeled)
    unless kase.positive?
      counts[:false_alerts] += labeled.size
      return
    end

    found = labeled.any? { |result| result.entity.id == kase.target.id }
    counts[found ? :found : :missed] += 1
    counts[:false_alerts] += labeled.count { |result| result.entity.id != kase.target.id }
  end

  def header
    positives = LabeledSet.cases.count(&:positive?)
    say("# Match quality")
    say
    say("Generated by `bundle exec rake benchmark:accuracy`, and committed: a diff here is a change in")
    say("what this library finds. benchmark/accuracy.rb says what each number is a number about.")
    say
    say("- #{LabeledSet.cases.size} labeled queries: #{positives} with a right answer, " \
        "#{LabeledSet.cases.size - positives} that must not alert")
    say("- #{LabeledSet.listed.size} labeled records, inside #{@matcher.size} indexed names " \
        "(#{LabeledSet.haystack_description(ENTITIES)})")
    say("- matcher version #{ActiveSanction::MATCHER_VERSION}, candidate limit " \
        "#{@matcher.candidate_limit}, default weights")
  end

  def sweep
    best = THRESHOLDS.max_by { |threshold| measure(@alerts, threshold).f1 }
    say
    say("## Precision, recall and F1 by threshold")
    say
    say("```")
    say("threshold  precision  recall      F1   found  missed  false alerts  noise/query")
    THRESHOLDS.each { |threshold| row(measure(@alerts, threshold), best) }
    say("```")
  end

  def row(measurement, best)
    say(format("%<threshold>9d  %<precision>9.3f  %<recall>6.3f  %<f1>6.3f  %<found>6d  %<missed>6d  " \
               "%<false_alerts>12d  %<noise>11.1f%<mark>s",
               threshold: measurement.threshold, precision: measurement.precision, recall: measurement.recall,
               f1: measurement.f1, found: measurement.found, missed: measurement.missed,
               false_alerts: measurement.false_alerts, noise: measurement.noise_per_query,
               mark: measurement.threshold == best ? "   <- best F1" : ""))
  end

  # The tradeoff drawn rather than asserted. Each point carries the threshold
  # that produced it, so the stretch where raising the number buys nothing
  # reads as a cluster.
  def curve
    grid = Array.new(ROWS) { " " * WIDTH }
    THRESHOLDS.each { |threshold| plot(grid, measure(@alerts, threshold)) }
    say
    say("## The precision/recall curve")
    say
    say("_precision up the side, recall across, each point labeled with the threshold behind it._")
    say
    say("```")
    grid.each_with_index { |line, row| say(format("%<axis>5s |%<line>s", axis: axis(row), line: line.rstrip)) }
    say("#{" " * 6}+#{"-" * WIDTH}")
    say("#{" " * 7}0.0#{" " * (WIDTH - 12)}recall  1.0")
    say("```")
  end

  # Precision down the left, 1.0 to 0.0 in tenths.
  def axis(row) = format("%<value>.1f", value: (ROWS - 1 - row).fdiv(ROWS - 1))

  def plot(grid, measurement)
    column = (measurement.recall * (WIDTH - 3)).round
    row = ((1.0 - measurement.precision) * (ROWS - 1)).round
    line = grid.fetch(row)
    return unless line[column, 2] == "  "

    line[column, 2] = format("%<threshold>02d", threshold: measurement.threshold)
  end

  # Recall at the default threshold, cut by something about the query. The
  # per-source cut is the one #37 asks for by name: Canada publishes no alias
  # kinds and few dates, and a report that averaged it in with OFAC would hide
  # the jurisdiction a compliance team is least covered on.
  def breakdown(name, subtitle, &grouping)
    groups = @alerts.select { |kase, _| kase.positive? }.group_by { |kase, _| grouping.call(kase) }
    say
    say("## Recall at #{default.round}, by #{name}")
    say
    say("_#{subtitle}_")
    say
    say("```")
    say(format("%<name>-28s %<queries>7s  %<recall>6s   %<found>s",
               name: name, queries: "queries", recall: "recall", found: "found"))
    groups.sort_by { |key, group| [-group.size, key.to_s] }.each { |key, group| cut(key, group) }
    say("```")
  end

  # The constructed pairs are filed under a source nothing real is filed
  # under, and the table says so rather than letting six invented records read
  # as a fourth jurisdiction's numbers.
  def listing(kase) = LabeledSet.constructed?(kase.target) ? :"#{kase.source} (made up)" : kase.source

  def cut(key, group)
    measurement = measure(group, default)
    say(format("%<name>-28s %<queries>7d  %<recall>6.3f   %<found>d of %<total>d",
               name: key, queries: group.size, recall: measurement.recall,
               found: measurement.found, total: group.size))
  end

  # The case a name alone cannot decide. Each of these queries names a record
  # with a twin -- the same name, a different date of birth or nationality or
  # registration number -- so the gap between the two scores is the whole of
  # what the secondary identifier was worth.
  def identifiers
    say
    say("## What a secondary identifier separates")
    say
    say("_name-identical records, told apart by one field. The gap is what that field bought._")
    say
    say("```")
    say("query                              distinguished by            right   twin     gap")
    @alerts.select { |kase, _| kase.variation == :identifier }.each { |kase, results| pair(kase, results) }
    say("```")
  end

  def pair(kase, results)
    right = kase.positive? ? results.find { |result| result.entity.id == kase.target.id }&.score : nil
    twin = results.select { |result| twin?(kase, result) }.map(&:score).max
    say(format("%<query>-34s %<field>-26s %<right>6s %<twin>6s %<gap>7s",
               query: kase.name[0, 33], field: distinguisher(kase), right: number(right),
               twin: number(twin), gap: gap(right, twin)))
  end

  def number(score) = score.nil? ? "none" : format("%<score>.1f", score: score)

  def gap(right, twin) = right && twin ? format("%<gap>+.1f", gap: right - twin) : ""

  # A twin is a labeled record carrying the answer's name and not being it.
  # For a query whose answer is "none", every labeled record it reached is one.
  def twin?(kase, result)
    return false if LabeledSet.background?(result)

    kase.positive? ? result.entity.id != kase.target.id : true
  end

  def distinguisher(kase)
    subject = kase.query.subject
    return "dob #{subject.dates_of_birth.first}" if subject.dates_of_birth?
    return "document #{subject.identifiers.first}" if subject.identifiers?
    return "nationality #{subject.nationalities.first}" if subject.nationalities.any?

    "nothing -- name only"
  end

  # The section a reviewer actually reads: what this version does not find,
  # and what it wrongly alerts on. A regression shows up here as a name
  # appearing rather than as a decimal moving.
  def mistakes
    say
    say("## Every miss and every false alert at #{default.round}")
    say
    say("```")
    misses
    say
    false_alerts
    say("```")
  end

  def misses
    missed = @alerts.reject { |kase, results| !kase.positive? || found?(kase, results) }
    say("MISSED (#{missed.size}) -- a listed record the query did not return")
    missed.each do |kase, results|
      best = results.find { |result| result.entity.id == kase.target.id }
      mistake(kase, kase.target.primary_name.value, best&.score)
    end
  end

  def false_alerts
    wrong = @alerts.flat_map do |kase, results|
      results.select { |result| false_alert?(kase, result) }.map { |result| [kase, result] }
    end
    say("FALSE ALERTS (#{wrong.size}) -- a labeled record returned that was not the answer")
    wrong.each { |kase, result| mistake(kase, result.matched_name.value, result.score) }
  end

  def mistake(kase, name, score)
    say(format("  %<query>-38s %<name>-38s %<score>5s  %<variation>s",
               query: kase.name[0, 37], name: name[0, 37], score: number(score), variation: kase.variation))
  end

  def found?(kase, results)
    results.any? { |result| result.entity.id == kase.target.id && result.score >= default }
  end

  def false_alert?(kase, result)
    return false if result.score < default || LabeledSet.background?(result)

    !kase.positive? || result.entity.id != kase.target.id
  end

  # The section #37 exists for: the default threshold argued from the table
  # above rather than from taste.
  def rationale
    at = THRESHOLDS.to_h { |threshold| [threshold, measure(@alerts, threshold)] }
    best = at.values.max_by(&:f1)
    say
    say("## What the default threshold is set from")
    say
    say("F1 peaks at #{best.threshold} (#{format("%<f1>.3f", f1: best.f1)}), and the default is " \
        "#{default.round}. #{agreement(best)}")
    say
    trade(at)
    say
    caveat
  end

  def agreement(best)
    return "They agree, and that is what the default rests on." if best.threshold == default.round

    "They differ, and the paragraph below says why #{default.round} is still what ships."
  end

  def trade(at)
    here = at.fetch(default.round)
    raising(here, at.fetch(85))
    lowering(here, at.fetch(60))
  end

  def raising(here, high)
    say("Raising it from #{default.round} to #{high.threshold} takes recall from #{fmt(here.recall)} to " \
        "#{fmt(high.recall)} -- #{high.missed - here.missed} more listed records not returned -- to remove " \
        "#{here.false_alerts - high.false_alerts} false alerts.")
  end

  def lowering(here, low)
    say("Lowering it to #{low.threshold} finds #{low.found - here.found} more, and costs " \
        "#{low.false_alerts - here.false_alerts} false alerts and " \
        "#{format("%<noise>.1f", noise: low.noise_per_query - here.noise_per_query)} more noise per query.")
  end

  def caveat
    say("F1 weighs a miss and a false alert equally and a sanctions screen does not: a false positive")
    say("costs an analyst minutes, and a false negative is a sanctioned counterparty onboarded. So the")
    say("default sits at the F1 peak rather than above it, and a host that has to be more careful still")
    say("lowers it -- `threshold:` is per query, and what lowering it costs is the noise column above")
    say("rather than something to be discovered in production.")
  end

  def fmt(value) = format("%<value>.3f", value: value)
end

AccuracyBenchmark.run
