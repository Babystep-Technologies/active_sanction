# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

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
    extend T::Sig

    # :range is a precision in the sense the scorer (#32) cares about -- how
    # much of the calendar a date could be -- not a grammatical one.
    PRECISIONS = T.let(%i[year month day range].freeze, T::Array[Symbol])

    # Canonical member order. Snapshot (#8) checksums the serialized form, so
    # #to_h must lay its keys out the same way every time. `precision` is
    # derived rather than stored: a stored copy can disagree with the fields it
    # describes, and then two records that mean the same thing checksum apart.
    #
    # @api private
    MEMBERS = T.let(%i[year month day from to approximate].freeze, T::Array[Symbol])

    # "Circa 1962" and "1963" are the same claim about a person, made by two
    # governments with different sources. Comparing an approximate date on its
    # literal bounds would call that a conflict and penalize a true match, so
    # comparison -- and only comparison, never #to_h or #to_s -- widens an
    # approximate date by a year on each side.
    #
    # @api private
    APPROXIMATE_SLACK_YEARS = 1

    # A point date carries year/month/day and no endpoints; a range carries its
    # endpoints and no year of its own. Which is which is #range?.
    sig { returns(T.nilable(Integer)) }
    attr_reader :year

    sig { returns(T.nilable(Integer)) }
    attr_reader :month

    sig { returns(T.nilable(Integer)) }
    attr_reader :day

    sig { returns(T.nilable(PartialDate)) }
    attr_reader :from

    sig { returns(T.nilable(PartialDate)) }
    attr_reader :to

    sig { returns(T::Boolean) }
    attr_reader :approximate

    # The two dates that bound this one, whatever shape it is -- which is what
    # makes #overlaps? exact regardless of how precise either side is. Never
    # nil: #initialize derives both for every instance it will build.
    sig { returns(Date) }
    attr_reader :first_date

    sig { returns(Date) }
    attr_reader :last_date

    # Reads a date expression from free text, returning nil on anything it
    # cannot read. The vocabulary lives in Parser, which is where new source
    # spellings get added.
    sig { params(text: T.untyped).returns(T.nilable(PartialDate)) }
    def self.parse(text)
      Parser.call(text)
    end

    # Rebuilds a date from #to_h output. Accepts string keys, so a record that
    # has been through JSON round-trips without a separate coercion step.
    sig { params(hash: T.untyped).returns(T.attached_class) }
    def self.from_h(hash)
      attributes = hash.to_h.transform_keys(&:to_sym)
      unknown = attributes.keys - MEMBERS
      raise InvalidArgument, "unknown PartialDate attribute(s): #{unknown.join(", ")}" if unknown.any?

      new(**attributes)
    end

    # A span, from the UN's `TYPE_OF_DATE = BETWEEN`. Endpoints may be
    # PartialDates, #to_h hashes, or strings this class can parse.
    sig { params(from: T.untyped, to: T.untyped, approximate: T::Boolean).returns(T.attached_class) }
    def self.range(from, to, approximate: false)
      new(from: from, to: to, approximate: approximate)
    end

    # Untyped on purpose, and the same choice Entity makes: these arrive as
    # whatever a publisher wrote and a parser made of it. What comes back out
    # is typed -- see the readers above.
    sig do
      params(year: T.untyped, month: T.untyped, day: T.untyped, from: T.untyped, to: T.untyped,
             approximate: T.untyped).void
    end
    def initialize(year: nil, month: nil, day: nil, from: nil, to: nil, approximate: false)
      @approximate = T.let(approximate ? true : false, T::Boolean)
      @year = T.let(nil, T.nilable(Integer))
      @month = T.let(nil, T.nilable(Integer))
      @day = T.let(nil, T.nilable(Integer))
      @from = T.let(nil, T.nilable(PartialDate))
      @to = T.let(nil, T.nilable(PartialDate))
      # Both branches assign the members they own and hand back the pair of
      # dates that bound them, which is what makes those two non-nil for every
      # instance rather than for most of them.
      first, last =
        if from.nil? && to.nil?
          assign_point(year, month, day)
        else
          reject_mixed_shape(year, month, day)
          assign_range(from, to)
        end
      @first_date = T.let(first, Date)
      @last_date = T.let(last, Date)
      freeze
    end

    sig { returns(T::Boolean) }
    def range? = !from.nil?

    sig { returns(T::Boolean) }
    def approximate? = approximate

    sig { returns(Symbol) }
    def precision
      return :range if range?
      return :day if day
      return :month if month

      :year
    end

    # Every date this could be, which is the whole point of the type.
    sig { returns(T::Range[Date]) }
    def to_range = first_date..last_date

    # True when the two dates could describe the same day. Precision does not
    # have to match: a year-only date overlaps every full date inside it, which
    # is what lets #32 treat 1972 against 1972-04-29 as a moderate boost rather
    # than a miss.
    sig { params(other: T.untyped).returns(T::Boolean) }
    def overlaps?(other)
      return false if other.nil?

      mine = comparison_range
      theirs = comparable!(other).comparison_range
      mine.first <= theirs.last && theirs.first <= mine.last
    end

    # The strict complement of #overlaps? for two known dates. A missing date
    # is not a conflict -- nobody claimed anything to contradict -- so nil
    # answers false to both questions.
    sig { params(other: T.untyped).returns(T::Boolean) }
    def conflicts_with?(other)
      return false if other.nil?

      !overlaps?(other)
    end

    # Widened by APPROXIMATE_SLACK_YEARS when the publisher said circa.
    sig { returns(T::Range[Date]) }
    def comparison_range
      return to_range unless approximate?

      first_date.prev_year(APPROXIMATE_SLACK_YEARS)..last_date.next_year(APPROXIMATE_SLACK_YEARS)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h
      { year: year, month: month, day: day, from: from&.to_h, to: to&.to_h, approximate: approximate }
    end

    # Renders in a form .parse reads back, so a date survives a trip through
    # free text -- which is how OFAC publishes them in the first place.
    sig { returns(String) }
    def to_s
      text = range? ? "#{from} to #{to}" : point_to_s
      approximate? ? "circa #{text}" : text
    end

    sig { params(other: T.untyped).returns(T::Boolean) }
    def ==(other)
      return false unless other.instance_of?(self.class)

      to_h == other.to_h
    end
    alias eql? ==

    sig { returns(Integer) }
    def hash
      [self.class, to_h].hash
    end

    sig { returns(String) }
    def inspect
      "#<#{self.class} #{self} precision=#{precision.inspect}>"
    end

    private

    sig { params(year: T.untyped, month: T.untyped, day: T.untyped).returns([Date, Date]) }
    def assign_point(year, month, day)
      raise InvalidArgument, "year is required" if year.nil?

      number = integer!(:year, year)
      @year = number
      @month = optional_integer(:month, month)
      @day = optional_integer(:day, day)
      validate_point!(number)
      first = Date.new(number, @month || 1, @day || 1).freeze
      # A year-only date runs to 31 December, a month to its own real last day.
      [first, @day ? first : Date.new(number, @month || 12, -1).freeze]
    end

    sig { params(year: Integer).void }
    def validate_point!(year)
      raise InvalidArgument, "day given without a month" if @day && @month.nil?
      raise InvalidArgument, "not a real date: #{to_s.inspect}" unless Date.valid_date?(year, @month || 1, @day || 1)
    end

    sig { params(from: T.untyped, to: T.untyped).returns([Date, Date]) }
    def assign_range(from, to)
      raise InvalidArgument, "a range needs both from and to" if from.nil? || to.nil?

      first = endpoint!(:from, from)
      last = endpoint!(:to, to)
      @from = first
      @to = last
      raise InvalidArgument, "range runs backwards: #{first} to #{last}" if first.first_date > last.last_date

      [first.first_date, last.last_date]
    end

    sig { params(year: T.untyped, month: T.untyped, day: T.untyped).void }
    def reject_mixed_shape(year, month, day)
      return if [year, month, day].all?(&:nil?)

      raise InvalidArgument, "a range carries its year in its endpoints, not alongside them"
    end

    # Endpoints are themselves PartialDates so a span between two year-only
    # dates keeps both years, and they may not nest: "between (1971 to 1972)
    # and 1973" is not something any list publishes.
    sig { params(member: Symbol, value: T.untyped).returns(PartialDate) }
    def endpoint!(member, value)
      date = coerce_endpoint(value)
      raise InvalidArgument, "#{member} is not a date: #{value.inspect}" if date.nil?
      raise InvalidArgument, "#{member} cannot itself be a range" if date.range?

      date
    end

    sig { params(value: T.untyped).returns(T.nilable(PartialDate)) }
    def coerce_endpoint(value)
      case value
      when PartialDate then value
      when Hash then PartialDate.from_h(value)
      else PartialDate.parse(value)
      end
    end

    sig { params(other: T.untyped).returns(PartialDate) }
    def comparable!(other)
      return other if other.is_a?(PartialDate)

      raise InvalidArgument, "expected a #{self.class}, got #{other.class}"
    end

    sig { params(member: Symbol, value: T.untyped).returns(T.nilable(Integer)) }
    def optional_integer(member, value)
      value.nil? ? nil : integer!(member, value)
    end

    sig { params(member: Symbol, value: T.untyped).returns(Integer) }
    def integer!(member, value)
      Integer(value.to_s, 10)
    rescue TypeError, ArgumentError
      raise InvalidArgument, "#{member} is not a number: #{value.inspect}"
    end

    sig { returns(String) }
    def point_to_s
      case precision
      when :day then format("%<year>04d-%<month>02d-%<day>02d", year: year, month: month, day: day)
      when :month then format("%<year>04d-%<month>02d", year: year, month: month)
      else format("%<year>04d", year: year)
      end
    end
  end
end
