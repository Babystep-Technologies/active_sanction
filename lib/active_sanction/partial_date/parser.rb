# frozen_string_literal: true

require "date"

module ActiveSanction
  class PartialDate
    # Reads the date expressions the lists publish in free text. OFAC ships
    # dates inside a remarks blob ("DOB circa 1962"), so the vocabulary here is
    # whatever a government typist actually wrote, not a format we chose.
    #
    # Returns nil on anything it cannot read, per the issue: a birth date is one
    # field on a record, and an unanticipated string should not abort the import
    # of the entity around it. Callers decide whether that is worth reporting.
    module Parser
      # "Sept" is not in Date::ABBR_MONTHNAMES but appears in OFAC free text.
      MONTHS = [Date::MONTHNAMES, Date::ABBR_MONTHNAMES].each_with_object({ "sept" => 9 }) do |names, months|
        names.each_with_index { |name, number| months[name.downcase] = number if name }
      end.freeze

      ISO = /\A(\d{4})(?:-(\d{1,2})(?:-(\d{1,2}))?)?\z/
      DAY_MONTH_YEAR = /\A(\d{1,2})\s+([a-z]+)\.?,?\s+(\d{4})\z/i
      MONTH_DAY_YEAR = /\A([a-z]+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\z/i
      MONTH_YEAR = /\A([a-z]+)\.?,?\s+(\d{4})\z/i
      APPROXIMATE = /\A(?:circa|approximately|approx|about|ca|c)\.?\s+|\A~\s*/i
      BETWEEN = /\Abetween\s+/i
      WORD_RANGE = /\A(.+?)\s+(?:to|and|through|until)\s+(.+)\z/i
      # A bare dash separates a span only between two four-digit years. Anything
      # looser would read the "-" in 1972-04 as a span from 1972 to April.
      YEAR_RANGE = /\A(\d{4})\s*[-–—]\s*(\d{4})\z/

      module_function

      def call(text)
        string = text.to_s.strip.squeeze(" ")
        return nil if string.empty?

        approximate = APPROXIMATE.match?(string)
        string = string.sub(APPROXIMATE, "").sub(BETWEEN, "")
        span(string, approximate) || point(string, approximate)
      end

      # Endpoints go back through .call, so "1971 to circa 1973" reads. A nested
      # span raises in the constructor and comes back as nil.
      def span(string, approximate)
        match = WORD_RANGE.match(string) || YEAR_RANGE.match(string)
        return nil unless match

        from = call(match[1])
        to = call(match[2])
        return nil if from.nil? || to.nil?

        build(from: from, to: to, approximate: approximate)
      end

      def point(string, approximate)
        attributes = point_attributes(string)
        return nil if attributes.nil?

        build(**attributes, approximate: approximate)
      end

      # A shape the regexes accept can still be an impossible date -- 31
      # February 1972 -- and that is the constructor's judgment, not ours.
      def build(**attributes)
        PartialDate.new(**attributes)
      rescue ArgumentError
        nil
      end

      def point_attributes(string)
        match = ISO.match(string)
        return { year: match[1].to_i, month: match[2]&.to_i, day: match[3]&.to_i } if match

        worded_attributes(string)
      end

      def worded_attributes(string)
        if (match = DAY_MONTH_YEAR.match(string))
          named_month(year: match[3], month: match[2], day: match[1])
        elsif (match = MONTH_DAY_YEAR.match(string))
          named_month(year: match[3], month: match[1], day: match[2])
        elsif (match = MONTH_YEAR.match(string))
          named_month(year: match[2], month: match[1])
        end
      end

      def named_month(year:, month:, day: nil)
        number = MONTHS[month.downcase]
        return nil if number.nil?

        { year: year.to_i, month: number, day: day&.to_i }
      end
    end
  end
end
