# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/partial_date"

module ActiveSanction
  module Sources
    class UkSanctionsList < Base
      # The UK Sanctions List's own date convention, which no general date
      # parser reads and which is the single most valuable thing this adapter
      # gets right.
      #
      #   PublishedDate.call("04/08/2026")   # => 2026-08-04, day precision
      #   PublishedDate.call("dd/mm/1945")   # => 1945, year precision
      #   PublishedDate.call("dd/06/1945")   # => 1945-06, month precision
      #   PublishedDate.call("00/00/1975")   # => 1975, year precision
      #   PublishedDate.call("1945")         # => 1945, year precision
      #   PublishedDate.call("15/08/19yy")   # => nil
      #
      # ### The placeholders are the point
      #
      # The FCDO writes every date `DD/MM/YYYY`, and where it does not know a
      # component it writes the component's own letters in its place: 800 of
      # the 3,788 published birth dates read `dd/mm/1962`, and 23 read
      # `dd/07/1978`. One record uses `00` for the same purpose --
      # `00/00/1975`. That is a publisher stating precision, and it maps onto
      # PartialDate exactly.
      #
      # Read with an ordinary parser those become nil, and 824 of 3,788 birth
      # dates -- 22% of everything the list says about when a person was born
      # -- silently disappear. Read *credulously*, as a zeroth day of a zeroth
      # month, they become invalid dates or, worse, dates the scorer would
      # compare as though the FCDO had been precise.
      #
      # ### `19yy` gets no date, on purpose
      #
      # One record publishes `15/08/19yy`: a day and a month, and a century
      # where the year should be. PartialDate has no shape for a date with no
      # year, and inventing one -- a 1900-1999 span, which would throw the day
      # and month away, or a year of 1900, which would be a fact nobody
      # published -- is exactly the false precision PartialDate exists to
      # prevent. It reads as nil and the adapter keeps the published string in
      # `remarks` instead.
      module PublishedDate
        extend T::Sig

        SEPARATOR = T.let("/", String)

        # A component the FCDO filled in. Anything else -- `dd`, `mm`, `yy`,
        # `00`, an empty field -- is the publisher saying it does not know,
        # which is not the same as a zero and must never be read as one.
        KNOWN = T.let(/\A0*[1-9]\d*\z/, Regexp)

        YEAR_ONLY = T.let(/\A\d{4}\z/, Regexp)

        module_function

        # The PartialDate a UKSL date string states, at the precision it
        # states it, or nil for one that states no year at all.
        #
        # Returns nil rather than raising, for the reason PartialDate::Parser
        # does: a birth date is one field on a record, and a string this does
        # not read should not abort the import of the entity around it. The
        # adapter records what it could not read.
        sig { params(text: T.untyped).returns(T.nilable(PartialDate)) }
        def call(text)
          string = text.to_s.strip
          return nil if string.empty?
          return build(year: string) if string.match?(YEAR_ONLY)

          day, month, year = string.split(SEPARATOR, 3).map { |part| component(part) }
          return nil if year.nil?

          # A day the FCDO gave under a month it did not is a day of an unknown
          # month, which PartialDate rightly refuses. The month is the part
          # that is missing, so the day goes with it.
          build(year: year, month: month, day: (day if month))
        end

        # nil for a placeholder, so that "the FCDO did not say" and "the FCDO
        # said zero" cannot be confused downstream.
        sig { params(part: T.untyped).returns(T.nilable(Integer)) }
        def component(part)
          string = part.to_s.strip
          string.match?(KNOWN) ? string.to_i : nil
        end

        # A shape these regexes accept can still be an impossible date -- the
        # list publishes no 31 February today, but a screening tool should not
        # be the thing that breaks on the day it does.
        sig { params(attributes: T.untyped).returns(T.nilable(PartialDate)) }
        def build(**attributes)
          PartialDate.new(**attributes)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
