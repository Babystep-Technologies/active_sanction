# frozen_string_literal: true

module Canary
  # What the canary found out about one source: the doctor's diagnosis of it,
  # held against the committed baseline and classified into the three things a
  # maintainer can actually do something about.
  #
  #   result.source       # => :ofac_sdn
  #   result.status       # => :drift
  #   result.reportable?  # => true, and a second run agreed
  #   Canary::Issue.new(result).body
  #
  # ### Three statuses, and the line between the first two
  #
  #   :ok            the file parsed into what the baseline says it should
  #   :drift         it parsed into something else
  #   :unreachable   it could not be fetched at all
  #
  # Separating `unreachable` from `drift` is the whole of what keeps this
  # readable. Government endpoints 403 a non-browser user agent, block cloud IP
  # ranges, and go down for an afternoon at a time; if that arrived as "OFAC has
  # drifted" the issues this opens would be wrong more often than right, and
  # nobody would read the one that was not.
  #
  # The classification is the exception's own answer rather than a guess here:
  # a `FetchError` -- an HTTP status, a timeout, a redirect that went nowhere,
  # a payload the publisher confirmed and then did not serve -- is a publisher
  # having a bad afternoon. A `ParseError` is not: the bytes arrived and this
  # library could not read them, which is drift of the loudest kind.
  #
  # ### Findings are the doctor's, minus what this source is allowed to move by
  #
  # Nothing is measured here. `Doctor::Checkup` produced the findings, and this
  # discards the ones the baseline's per-key tolerance permits -- and only
  # those. A finding that survives at `warn` or above is drift; `info` findings
  # are kept for the issue body, because "unknown SDN_Type" on 41 rows is
  # context for the coverage drop above it rather than a thing to be woken for.
  #
  # Instances are frozen on construction.
  class Result
    STATUSES = %i[ok drift unreachable].freeze

    LABELS = { ok: "OK", drift: "DRIFT", unreachable: "UNREACHABLE" }.freeze

    def self.from(diagnosis, baseline:)
      observed = diagnosis.profile
      kept = diagnosis.findings.reject do |finding|
        finding.at_least?(:warn) && baseline.allows?(finding, records: observed&.record_count.to_i)
      end
      new(source: diagnosis.source, status: status_for(diagnosis, kept), findings: kept, profile: observed,
          baseline: baseline.profile, error: diagnosis.exception, duration: diagnosis.duration,
          compared: baseline.present?)
    end

    # A source that could not be fetched is `unreachable` whatever else was
    # said about it; everything else is drift or health, decided by whether any
    # finding survived the tolerances.
    def self.status_for(diagnosis, findings)
      return :unreachable if diagnosis.failed? && diagnosis.exception.is_a?(ActiveSanction::FetchError)

      findings.any? { |finding| finding.at_least?(:warn) } ? :drift : :ok
    end

    def self.from_h(hash)
      attributes = hash.to_h.transform_keys(&:to_sym)
      profile = attributes[:profile]
      baseline = attributes[:baseline]
      new(source: attributes[:source], status: attributes[:status],
          findings: attributes[:findings] || [], error: attributes[:error],
          profile: profile && ActiveSanction::Doctor::Profile.from_h(profile),
          baseline: baseline && ActiveSanction::Doctor::Profile.from_h(baseline),
          duration: attributes[:duration].to_f, compared: attributes[:compared],
          confirmed: attributes[:confirmed])
    end

    attr_reader :source, :status, :findings, :profile, :baseline, :duration, :error, :confirmed

    def initialize(source:, status:, findings: [], profile: nil, baseline: nil, error: nil,
                   duration: 0.0, compared: false, confirmed: nil)
      @source = source.to_sym
      @status = status!(status)
      @findings = findings!(findings)
      @profile = profile
      @baseline = baseline
      @error = failure!(error)
      @duration = duration.to_f
      @compared = compared ? true : false
      @confirmed = confirmed.nil? ? nil : Array(confirmed).map(&:to_s).freeze
      freeze
    end

    def ok? = status == :ok

    def drift? = status == :drift

    def unreachable? = status == :unreachable

    # Whether there was a committed baseline to hold this run against. False
    # says the source was held to the floors its adapter declared, which is a
    # far coarser thing, and the report says so rather than reading as a clean
    # comparison.
    def compared? = @compared

    # What this run would report, as stable identities that survive the numbers
    # moving between two runs: a coverage figure of 71.4% one morning and 71.1%
    # the next is the same finding, and it has to be, or nothing ever agrees
    # with anything. A warning class is identified by the class rather than by
    # the check it arrived under, because a parse produces several at once.
    def fingerprints
      findings.select { |finding| finding.at_least?(:warn) }.map { |finding| fingerprint(finding) }.uniq
    end

    # The same result, told what the previous run said about this source.
    # Agreement is deliberately narrow: the same status, and at least one
    # finding in common. A fetch failure yesterday and a parse failure today
    # are two different afternoons, not a confirmation.
    def confirmed_against(previous)
      return with(confirmed: []) if previous.nil? || previous.source != source || previous.status != status

      with(confirmed: fingerprints & previous.fingerprints)
    end

    # Whether this is worth opening an issue about: something is wrong, and a
    # previous run agreed that the same thing was wrong. Until then it is
    # pending, which is what one bad afternoon on a government host looks like.
    def reportable? = !ok? && !confirmed.nil? && !confirmed.empty?

    # Something is wrong and no previous run has agreed with it yet -- either
    # this is the first time, or there was no previous report to compare with.
    def pending? = !ok? && !reportable?

    def record_count = profile&.record_count || 0

    def title
      unreachable? ? "Canary: #{source} could not be fetched" : "Canary: #{source} has drifted"
    end

    # `OK`, `DRIFT (pending)`, `UNREACHABLE` -- what an eye runs down the
    # left-hand column looking for.
    def label = "#{LABELS.fetch(status)}#{" (pending)" if pending?}"

    def with(**changes)
      attributes = { source: source, status: status, findings: findings, profile: profile,
                     baseline: baseline, error: error, duration: duration, compared: compared?,
                     confirmed: confirmed }
      self.class.new(**attributes, **changes)
    end

    def to_h
      { source: source.to_s, status: status.to_s, reportable: reportable?, pending: pending?,
        title: title, compared: compared?, confirmed: confirmed, duration: duration,
        error: error, findings: findings.map(&:to_h), profile: profile&.to_h, baseline: baseline&.to_h }
    end

    private

    def fingerprint(finding)
      return finding.check.to_s unless finding.check == :warnings

      "warnings:#{finding.message.sub(/\s*\([^()]*\)\z/, "")}"
    end

    def status!(value)
      status = value.to_sym
      return status if STATUSES.include?(status)

      raise ArgumentError, "status must be one of #{STATUSES.join(", ")}, got #{value.inspect}"
    end

    def findings!(value)
      Array(value).map { |one| one.is_a?(ActiveSanction::Doctor::Finding) ? one : finding!(one) }.freeze
    end

    def finding!(hash) = ActiveSanction::Doctor::Finding.from_h(hash)

    # An exception is kept as its class and message, because a report is
    # written to JSON and read back by the next run, and a backtrace does not
    # survive that. `retryable` is the publisher's own answer to whether this
    # is worth trying again, and is what the issue body quotes.
    def failure!(value)
      case value
      when nil then nil
      when Exception
        { "class" => value.class.name, "message" => value.message.to_s,
          "retryable" => value.respond_to?(:retryable?) && value.retryable? }
      else value.to_h.transform_keys(&:to_s)
      end
    end
  end
end
