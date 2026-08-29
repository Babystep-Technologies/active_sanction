# frozen_string_literal: true

require "date"
require "active_sanction/partial_date/parser"

module ActiveSanction
  # A date a sanctions list published imprecisely. `Date` cannot hold one:
  # collapsing "1972" to 1972-01-01 invents a precision the publisher never
  # claimed, and a scorer that believes it will call 1972 and 1972-04-29 a
  # conflict when they are in fact a match.
  #
  #   PartialDate.parse("1972")                     # year only
  #   PartialDate.parse("circa 1962")               # approximate
  #   PartialDate.parse("between 1971 and 1973")    # a span
  #   PartialDate.new(year: 1965, month: 4, day: 29)
  #
  # Every instance carries a first and last possible date, which is what makes
  # #overlaps? and #conflicts_with? exact regardless of how precise either side
  # is. Instances are frozen on construction and compare by value.
  class PartialDate
    # :range is a precision in the sense the scorer (#32) cares about -- how
    # much of the calendar a date could be -- not a grammatical one.
    PRECISIONS = %i[year month day range].freeze

    # Canonical member order. Snapshot (#8) checksums the serialized form, so
    # #to_h must lay its keys out the same way every time. `precision` is
    # derived rather than stored: a stored copy can disagree with the fields it
    # describes, and then two records that mean the same thing checksum apart.
    MEMBERS = %i[year month day from to approximate].freeze

    # "Circa 1962" and "1963" are the same claim about a person, made by two
    # governments with different sources. Comparing an approximate date on its
    # literal bounds would call that a conflict and penalize a true match, so
    # comparison -- and only comparison, never #to_h or #to_s -- widens an
    # approximate date by a year on each side.
    APPROXIMATE_SLACK_YEARS = 1

    attr_reader(*MEMBERS, :first_date, :last_date)

    # Reads a date expression from free text, returning nil on anything it
    # cannot read. The vocabulary lives in Parser, which is where new source
    # spellings get added.
    def self.parse(text)
      Parser.call(text)
    end

    # Rebuilds a date from #to_h output. Accepts string keys, so a record that
    # has been through JSON round-trips without a separate coercion step.
    def self.from_h(hash)
      attributes = hash.to_h.transform_keys(&:to_sym)
      unknown = attributes.keys - MEMBERS
      raise ArgumentError, "unknown PartialDate attribute(s): #{unknown.join(", ")}" if unknown.any?

      new(**attributes)
    end

    # A span, from the UN's `TYPE_OF_DATE = BETWEEN`. Endpoints may be
    # PartialDates, #to_h hashes, or strings this class can parse.
    def self.range(from, to, approximate: false)
      new(from: from, to: to, approximate: approximate)
    end

    def initialize(year: nil, month: nil, day: nil, from: nil, to: nil, approximate: false)
      @approximate = approximate ? true : false
      if from.nil? && to.nil?
        assign_point(year, month, day)
      else
        reject_mixed_shape(year, month, day)
        assign_range(from, to)
      end
      freeze
    end

    def range? = !from.nil?

    def approximate? = approximate

    def precision
      return :range if range?
      return :day if day
      return :month if month

      :year
    end

    # Every date this could be, which is the whole point of the type.
    def to_range = first_date..last_date

    # True when the two dates could describe the same day. Precision does not
    # have to match: a year-only date overlaps every full date inside it, which
    # is what lets #32 treat 1972 against 1972-04-29 as a moderate boost rather
    # than a miss.
    def overlaps?(other)
      return false if other.nil?

      mine = comparison_range
      theirs = comparable!(other).comparison_range
      mine.begin <= theirs.end && theirs.begin <= mine.end
    end

    # The strict complement of #overlaps? for two known dates. A missing date
    # is not a conflict -- nobody claimed anything to contradict -- so nil
    # answers false to both questions.
    def conflicts_with?(other)
      return false if other.nil?

      !overlaps?(other)
    end

    # Widened by APPROXIMATE_SLACK_YEARS when the publisher said circa.
    def comparison_range
      return to_range unless approximate?

      first_date.prev_year(APPROXIMATE_SLACK_YEARS)..last_date.next_year(APPROXIMATE_SLACK_YEARS)
    end

    def to_h
      { year: year, month: month, day: day, from: from&.to_h, to: to&.to_h, approximate: approximate }
    end

    # Renders in a form .parse reads back, so a date survives a trip through
    # free text -- which is how OFAC publishes them in the first place.
    def to_s
      text = range? ? "#{from} to #{to}" : point_to_s
      approximate? ? "circa #{text}" : text
    end

    def ==(other)
      other.instance_of?(self.class) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      [self.class, to_h].hash
    end

    def inspect
      "#<#{self.class} #{self} precision=#{precision.inspect}>"
    end

    private

    def assign_point(year, month, day)
      raise ArgumentError, "year is required" if year.nil?

      @year = integer!(:year, year)
      @month = optional_integer(:month, month)
      @day = optional_integer(:day, day)
      validate_point!
      @first_date = Date.new(@year, @month || 1, @day || 1).freeze
      # A year-only date runs to 31 December, a month to its own real last day.
      @last_date = (@day ? @first_date : Date.new(@year, @month || 12, -1)).freeze
    end

    def validate_point!
      raise ArgumentError, "day given without a month" if @day && @month.nil?
      raise ArgumentError, "not a real date: #{to_s.inspect}" unless Date.valid_date?(@year, @month || 1, @day || 1)
    end

    def assign_range(from, to)
      raise ArgumentError, "a range needs both from and to" if from.nil? || to.nil?

      @from = endpoint!(:from, from)
      @to = endpoint!(:to, to)
      raise ArgumentError, "range runs backwards: #{@from} to #{@to}" if @from.first_date > @to.last_date

      @first_date = @from.first_date
      @last_date = @to.last_date
    end

    def reject_mixed_shape(year, month, day)
      return if [year, month, day].all?(&:nil?)

      raise ArgumentError, "a range carries its year in its endpoints, not alongside them"
    end

    # Endpoints are themselves PartialDates so a span between two year-only
    # dates keeps both years, and they may not nest: "between (1971 to 1972)
    # and 1973" is not something any list publishes.
    def endpoint!(member, value)
      date = coerce_endpoint(value)
      raise ArgumentError, "#{member} is not a date: #{value.inspect}" if date.nil?
      raise ArgumentError, "#{member} cannot itself be a range" if date.range?

      date
    end

    def coerce_endpoint(value)
      case value
      when PartialDate then value
      when Hash then PartialDate.from_h(value)
      else PartialDate.parse(value)
      end
    end

    def comparable!(other)
      return other if other.is_a?(PartialDate)

      raise ArgumentError, "expected a #{self.class}, got #{other.class}"
    end

    def optional_integer(member, value)
      value.nil? ? nil : integer!(member, value)
    end

    def integer!(member, value)
      Integer(value.to_s, 10)
    rescue TypeError, ArgumentError
      raise ArgumentError, "#{member} is not a number: #{value.inspect}"
    end

    def point_to_s
      case precision
      when :day then format("%<year>04d-%<month>02d-%<day>02d", year: year, month: month, day: day)
      when :month then format("%<year>04d-%<month>02d", year: year, month: month)
      else format("%<year>04d", year: year)
      end
    end
  end
end
