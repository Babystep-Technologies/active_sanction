# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Canary
  # What a source measured the last time somebody looked, committed to this
  # repository as `.github/baselines/<source>.json`.
  #
  #   baseline = Canary::Baseline.load(:ofac_sdn, directory: Canary::Baseline.directory)
  #
  #   baseline.present?                  # => true, there is a file to compare against
  #   baseline.profile.record_count      # => 19321
  #   baseline.tolerance(:record_count)  # => 0.05
  #
  # ### Why a file in the repository rather than a cache
  #
  # A runner is stateless, so the doctor's compare-against-the-last-snapshot has
  # nothing to compare to. A checked-in file gives it one, and makes drift
  # reviewable as a diff in a pull request rather than as a line in a log nobody
  # opens: the day OFAC's remarks coverage moves from 97.3% to 96.8% is a commit
  # with a date on it, an author, and a review.
  #
  # `actions/cache` is the wrong tool for the same two reasons: it is evicted
  # after seven days unused, and it keeps no audit trail of when a number moved.
  #
  # ### Tolerances are per key, because the numbers are not alike
  #
  # A record count moves every business day -- OFAC designates and delists
  # continuously -- and a canary that reported every one of those would be
  # muted in a week. Remarks coverage does not move on its own at all: it moves
  # when a label is spelled differently, which is exactly the thing this exists
  # to catch, so it is held ten times tighter. Everything else keeps the
  # doctor's own default, which is what `Doctor` would have applied anyway.
  #
  # A tolerance is a share of the baseline value, not an absolute: 0.05 on a
  # record count of 19,321 is roughly a thousand records.
  class Baseline
    # A baseline file that is not JSON, or is JSON of the wrong shape. Loud
    # rather than silently ignored: a canary that quietly treated an unreadable
    # baseline as "no baseline" would report every source as healthy forever.
    class Malformed < StandardError; end

    # What a check may move by before it is worth a finding, where the file
    # names nothing tighter. The same number `Doctor` defaults to.
    DEFAULT_TOLERANCE = 0.10

    # The two measurements that are not like the others. See the class comment.
    DEFAULT_TOLERANCES = { record_count: 0.05, remarks_coverage: 0.02 }.freeze

    # Checks judged as a share of the list rather than as a movement from a
    # baseline -- a warning class that was not there last time has no previous
    # value to have moved from, and neither does a child row that matched no
    # parent. `Doctor::Checkup` judges both as a share of the file, and this
    # holds them to the same rule at this source's tolerance for the key.
    SHARE_CHECKS = %i[warnings orphans].freeze

    # Findings no tolerance may swallow. A column assertion is a statement
    # about the file rather than a measurement of the list -- a positional
    # column that used to hold numbers and now holds company names is not 4%
    # different from what it was, it is a different file. `:empty`, `:parse`
    # and `:baseline` are the same: none of them is a number that drifted.
    ABSOLUTE_CHECKS = %i[empty parse baseline].freeze

    class << self
      # `.github/baselines`, where the committed files live.
      def directory(root = Canary.root) = File.join(root, ".github", "baselines")

      def path(source, directory: nil) = File.join(directory || self.directory, "#{source}.json")

      # The baseline for one source, or an empty one for a source that has
      # never had a run committed. An absent file is not an error: it is what
      # a newly added adapter looks like, and the run falls back to the floors
      # the adapter itself declared.
      def load(source, directory: nil)
        file = path(source, directory: directory)
        return new(source: source) unless File.exist?(file)

        from_h(JSON.parse(File.read(file)), source: source)
      rescue JSON::ParserError => e
        raise Malformed, "#{file} is not readable JSON: #{e.message}"
      end

      def from_h(hash, source: nil)
        attributes = hash.to_h.transform_keys(&:to_sym)
        profile = attributes[:profile]
        new(source: attributes[:source] || source, captured_at: attributes[:captured_at],
            tolerances: attributes[:tolerances], note: attributes[:note],
            profile: profile.nil? ? nil : ActiveSanction::Doctor::Profile.from_h(profile))
      rescue ActiveSanction::InvalidArgument => e
        raise Malformed, "the baseline for #{source} does not describe a profile: #{e.message}"
      end

      # Rewrites the committed baselines from what a run measured, and answers
      # with the sources whose file changed. Only sources that actually parsed
      # are touched: a publisher that was down has measured nothing, and
      # writing a baseline of nothing would make the next run report the list
      # coming back as drift.
      #
      # Tolerances already in a file are kept. They are the one part of a
      # baseline a human tuned, and a refresh that reset them to the defaults
      # would quietly undo that tuning every weekday.
      def refresh(report, directory: nil)
        into = directory || self.directory
        report.results.filter_map do |result|
          profile = result.profile
          next if profile.nil?

          load(result.source, directory: into).with(profile: profile).write(directory: into)
        end
      end
    end

    attr_reader :source

    # What the source measured when this was captured, as the doctor's own
    # profile -- record count, cohorts, fill rates, warning classes, orphan
    # counts, remarks coverage and column shapes. nil for a source with no
    # committed baseline yet.
    attr_reader :profile

    # When the run that produced this profile happened, UTC and ISO 8601.
    attr_reader :captured_at

    # Check name to the share it may move by. See the class comment.
    attr_reader :tolerances

    # Free text, for the baseline whose numbers need a sentence of explanation
    # -- a coverage figure that is low on purpose, a count that jumped for a
    # reason somebody has already established.
    attr_reader :note

    def initialize(source:, profile: nil, captured_at: nil, tolerances: nil, note: nil)
      @source = source.to_sym
      @profile = profile
      @captured_at = captured_at&.to_s
      @tolerances = DEFAULT_TOLERANCES.merge(symbolize(tolerances)).freeze
      @note = note&.to_s
      freeze
    end

    # Whether there is anything to compare against.
    def present? = !profile.nil?

    def tolerance(check) = tolerances.fetch(check.to_sym, DEFAULT_TOLERANCE)

    # The tightest tolerance this baseline names. It is what the doctor is run
    # at, so that every finding a per-key tolerance might keep is produced in
    # the first place; the per-key rule is then applied by #allows?, which can
    # only ever discard.
    def finest = ([DEFAULT_TOLERANCE] + tolerances.values).min

    # Whether a finding is inside what this source is allowed to move by, and
    # so not worth waking anybody for. `records` is how many records the run
    # parsed, which is what the share-judged checks are a share of.
    def allows?(finding, records: 0)
      check = finding.check
      return false if ABSOLUTE_CHECKS.include?(check) || check.start_with?("column_")
      return share_within?(finding, records) if SHARE_CHECKS.include?(check)

      movement_within?(finding)
    end

    # A copy carrying what a run measured. The capture time only moves when the
    # profile does: a refresh that restamped an unchanged baseline every
    # weekday would open a pull request a day whose whole diff was a timestamp,
    # and the one that mattered would be reviewed like the rest of them.
    def with(profile:, captured_at: nil)
      stamp = self.profile == profile ? self.captured_at : (captured_at || Time.now.utc.iso8601)
      self.class.new(source: source, profile: profile, captured_at: stamp,
                     tolerances: tolerances, note: note)
    end

    def to_h
      { source: source.to_s, captured_at: captured_at, note: note,
        tolerances: tolerances.transform_keys(&:to_s), profile: profile&.to_h }.compact
    end

    # Writes the file and answers the source when the bytes changed, nil when
    # they did not -- so a refresh can say what it moved, and a workflow can
    # decide whether there is anything to open a pull request about.
    def write(directory: nil)
      file = self.class.path(source, directory: directory)
      FileUtils.mkdir_p(File.dirname(file))
      bytes = "#{JSON.pretty_generate(to_h)}\n"
      return nil if File.exist?(file) && File.read(file) == bytes

      File.write(file, bytes)
      source
    end

    def to_s = "#{source} baseline#{present? ? " of #{captured_at}" : " (none)"}"

    private

    def symbolize(value) = (value || {}).to_h { |check, share| [check.to_sym, Float(share)] }

    def share_within?(finding, records)
      total = records.to_i
      return false unless total.positive?

      finding.observed.to_f.fdiv(total) <= tolerance(finding.check)
    end

    def movement_within?(finding)
      now = finding.observed
      was = finding.baseline
      return false unless now.is_a?(Numeric) && was.is_a?(Numeric)
      return now == was if was.zero?

      (now - was).abs.fdiv(was) <= tolerance(finding.check)
    end
  end
end
