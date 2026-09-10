# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"

module ActiveSanction
  module Parsers
    # An assertion about what one column of a positional file contains,
    # measured over the whole file.
    #
    #   ENT_NUM = ColumnShape.new(name: :ent_num, matches: /\A\d+\z/, at_least: 0.99)
    #
    #   tally = ENT_NUM.tally(rows.map { |row| row[:ent_num] })
    #   tally.ok?       # => false
    #   tally.ratio     # => 0.0
    #   tally.sample    # => ["AEROCARIBBEAN AIRLINES", "AEROTAXI EJECUTIVO"]
    #   tally.to_s      # => "ent_num numeric on 0.0% of 19321 rows (expected 99%)"
    #
    # ### Why a declared width is not enough
    #
    # A file that names its own columns cannot have them quietly swapped: the
    # header moves with the data and an adapter reading `sdn_type` still gets
    # the type. A headerless file has no such protection, and OFAC ships three
    # of them. Declaring the column names pins the *width*, so a column
    # inserted upstream arrives as a wrong-width row and every row says so --
    # but a column *reordered* upstream keeps the width, parses cleanly, and
    # produces 19,321 entities built from shifted fields. Nothing raises,
    # nothing warns, and the list means something different.
    #
    # So the shape of the values is asserted separately from the shape of the
    # row. `ent_num` is a number on essentially every row of OFAC's file, and
    # a version of that file where it is a company name is not a version this
    # library should screen against.
    #
    # ### `at_least`, rather than "every row"
    #
    # These are published files, not validated ones. A single row where a
    # publisher typed a letter into a numeric column is a curiosity; a file
    # where a third of them are is a format change. The threshold is what
    # separates the two, and it defaults to 99% -- high enough that a real
    # swap cannot hide under it, loose enough that one bad row does not stop a
    # sync being diagnosed as healthy.
    #
    # Blank values are not counted at all. A column the publisher leaves empty
    # is saying nothing about its shape, and OFAC leaves most of its columns
    # empty most of the time -- `-0- ` roughly a quarter of a million times
    # across the six files. Counting those as failures would make every
    # assertion about an optional column fail on the day it was written.
    #
    # Instances are frozen on construction.
    class ColumnShape
      extend T::Sig

      # @api private
      DEFAULT_AT_LEAST = T.let(0.99, Float)

      # Unmatched values kept as evidence. Enough to recognize what is in the
      # column instead, and few enough that a whole shifted file does not
      # arrive in a report someone has to read.
      #
      # @api private
      SAMPLE_SIZE = T.let(3, Integer)

      sig { returns(Symbol) }
      attr_reader :name

      # The share of non-blank values that must satisfy the rule.
      sig { returns(Float) }
      attr_reader :at_least

      # What the column is supposed to hold, in words, for the message a
      # failure prints: "numeric", "a known SDN_Type".
      sig { returns(String) }
      attr_reader :description

      # One of `matches:` (a Regexp), `allowing:` (the values the column may
      # hold, compared case-insensitively after stripping), or `satisfying:`
      # (a callable taking the value and returning truthy). `description:`
      # names the expectation in the failure message; the first two derive a
      # readable one when it is not given.
      sig do
        params(name: T.untyped, matches: T.untyped, allowing: T.untyped, satisfying: T.untyped,
               at_least: T.untyped, description: T.untyped).void
      end
      def initialize(name:, matches: nil, allowing: nil, satisfying: nil, at_least: DEFAULT_AT_LEAST,
                     description: nil)
        @name = T.let(name!(name), Symbol)
        @allowed = T.let(allowing.nil? ? nil : allowed!(allowing), T.nilable(T::Array[String]))
        @rule = T.let(rule!(matches, satisfying), T.nilable(T.proc.params(value: String).returns(T.untyped)))
        @at_least = T.let(at_least!(at_least), Float)
        @description = T.let(description!(description, matches), String)
        freeze
      end

      # Whether one value satisfies the assertion. Blanks never reach here --
      # see #tally.
      sig { params(value: String).returns(T::Boolean) }
      def satisfied_by?(value)
        allowed = @allowed
        return allowed.include?(value.strip.downcase) unless allowed.nil?

        !!T.must(@rule).call(value)
      end

      # Measures the assertion over one file's worth of values, in one pass.
      # Takes anything enumerable, so a caller can hand it a lazy reader
      # rather than materializing 19,321 rows.
      sig { params(values: T.untyped).returns(Tally) }
      def tally(values)
        checked = 0
        matched = 0
        blank = 0
        sample = T.let([], T::Array[String])
        values.each do |value|
          string = value.nil? ? "" : value.to_s.strip
          next blank += 1 if string.empty?

          checked += 1
          next matched += 1 if satisfied_by?(string)

          sample << string if sample.size < SAMPLE_SIZE
        end
        Tally.new(shape: self, checked: checked, matched: matched, blank: blank, sample: sample)
      end

      sig { returns(String) }
      def to_s = "#{name} #{description} on at least #{percentage(at_least)} of rows"

      sig { returns(String) }
      def inspect = "#<#{self.class} #{self}>"

      # A percentage as a report prints one: no decimal where there is nothing
      # after the point, since "99%" is what was declared and "99.0%" is not.
      sig { params(ratio: Float).returns(String) }
      def self.percentage(ratio)
        value = (ratio * 100).round(1)
        value == value.to_i ? "#{value.to_i}%" : "#{value}%"
      end

      sig { params(ratio: Float).returns(String) }
      def percentage(ratio) = ColumnShape.percentage(ratio)

      private

      sig { params(value: T.untyped).returns(Symbol) }
      def name!(value)
        string = value.to_s.strip
        raise InvalidArgument, "a column shape needs a column name" if string.empty?

        string.to_sym
      end

      sig { params(value: T.untyped).returns(T::Array[String]) }
      def allowed!(value)
        list = Array(value).map { |entry| entry.to_s.strip.downcase }.reject(&:empty?)
        raise InvalidArgument, "allowing: needs at least one value" if list.empty?

        list.uniq.freeze
      end

      sig do
        params(matches: T.untyped, satisfying: T.untyped)
          .returns(T.nilable(T.proc.params(value: String).returns(T.untyped)))
      end
      def rule!(matches, satisfying)
        return nil unless @allowed.nil?
        return ->(value) { matches.match?(value) } if matches.is_a?(Regexp)
        return ->(value) { satisfying.call(value) } if satisfying.respond_to?(:call)

        raise InvalidArgument,
              "a column shape needs one of matches: (a Regexp), allowing: (the values it may hold) " \
              "or satisfying: (a callable)"
      end

      sig { params(value: T.untyped).returns(Float) }
      def at_least!(value)
        ratio = Float(value)
        return ratio if ratio.between?(0.0, 1.0)

        raise InvalidArgument, "at_least must be a share between 0 and 1, got #{value.inspect}"
      end

      sig { params(value: T.untyped, matches: T.untyped).returns(String) }
      def description!(value, matches)
        string = value.to_s.strip
        return -string unless string.empty?
        return -"one of #{@allowed.join(", ")}" unless @allowed.nil?

        matches.is_a?(Regexp) ? -"matching #{matches.inspect}" : "as declared"
      end

      # What a ColumnShape measured over one file. Frozen, serializable, and
      # deliberately keeping the values it rejected: "ent_num is numeric on 0%
      # of rows" says a column moved, and the sample says which one moved into
      # it.
      #
      # @api private
      class Tally
        extend T::Sig

        sig { returns(ColumnShape) }
        attr_reader :shape

        # Non-blank values measured.
        sig { returns(Integer) }
        attr_reader :checked

        sig { returns(Integer) }
        attr_reader :matched

        # Values the publisher left empty, which are not measured -- see the
        # ColumnShape comment.
        sig { returns(Integer) }
        attr_reader :blank

        # Up to ColumnShape::SAMPLE_SIZE of the values that did not satisfy the
        # assertion, as evidence.
        sig { returns(T::Array[String]) }
        attr_reader :sample

        sig do
          params(shape: ColumnShape, checked: Integer, matched: Integer, blank: Integer,
                 sample: T::Array[String]).void
        end
        def initialize(shape:, checked:, matched:, blank: 0, sample: [])
          @shape = T.let(shape, ColumnShape)
          @checked = T.let(checked, Integer)
          @matched = T.let(matched, Integer)
          @blank = T.let(blank, Integer)
          @sample = T.let(sample.dup.freeze, T::Array[String])
          freeze
        end

        sig { returns(Symbol) }
        def name = shape.name

        # 1.0 for a column with nothing in it to measure. A file where the
        # column is blank on every row is a different complaint -- a fill rate
        # that fell to zero -- and reporting it here as a shape violation would
        # say the wrong thing about it twice.
        sig { returns(Float) }
        def ratio = checked.zero? ? 1.0 : matched.fdiv(checked)

        sig { returns(T::Boolean) }
        def ok? = ratio >= shape.at_least

        sig { returns(T::Boolean) }
        def failed? = !ok?

        sig { returns(T::Hash[Symbol, T.untyped]) }
        def to_h
          { column: name, description: shape.description, checked: checked, matched: matched,
            blank: blank, ratio: ratio.round(4), at_least: shape.at_least, sample: sample }
        end

        sig { returns(String) }
        def to_s
          "#{name} #{shape.description} on #{shape.percentage(ratio)} of #{checked} rows " \
            "(expected #{shape.percentage(shape.at_least)})#{evidence}"
        end

        sig { returns(String) }
        def inspect = "#<#{self.class} #{self}>"

        private

        sig { returns(String) }
        def evidence = sample.empty? ? "" : ": #{sample.map(&:inspect).join(", ")}"
      end
    end
  end
end
