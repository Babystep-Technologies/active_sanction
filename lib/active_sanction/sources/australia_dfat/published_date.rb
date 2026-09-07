# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/partial_date"

module ActiveSanction
  module Sources
    class AustraliaDfat < Base
      # The dates DFAT writes, which are not one format and were never meant to
      # be read by a machine.
      #
      #   PublishedDate.dates("13/06/1961, Approximately 1963")
      #   # => [[#<PartialDate 1961-06-13>, #<PartialDate ~1963>], []]
      #
      #   PublishedDate.listing("Listed on 25 Jan. 2001 (amended on 3 Sep. 2003)")
      #   # => #<PartialDate 2001-01-25>
      #
      # ### One cell, any number of birth dates, in any number of spellings
      #
      # The Date of Birth column holds every date the listing carries, and a
      # committee that received four reports of when somebody was born publishes
      # four. `1945, 1946, 1947, 1948, 1949, 1950, 1955, 1956, 1957, 1958` is one
      # cell of this list, and so are `a) 5/12/1970 b) 1969`, `Approximately:
      # Between 1972 and 1975`, `12 April 1965` and `03/1955`. The separators
      # are commas, the letters of an enumeration DFAT inherits from the UN's
      # own text on 17 rows, and -- on 28 more -- nothing but a space between
      # two dates.
      #
      # Four records out of the 3,906 carry a fragment this cannot read, and all
      # four are typed wrong at the source: `1980.1981`, `/02/1961`,
      # `7/02/1950/11/1950`, `10/061962`. Each is kept verbatim in the record's
      # remarks rather than dropped, so a date this version cannot parse is
      # still in front of whoever reads the hit.
      #
      # ### Day first, because Australia writes day first
      #
      # `05/12/1970` is the fifth of December. Nothing in the file says so, and
      # reading it the American way would move some of the 2,013 dates written
      # this way by up to eleven months -- silently, and only for the days below
      # the thirteenth. What settles it is the publisher: DFAT writes Australian
      # dates, and not one of the 2,013 has a middle component above twelve,
      # which a file in the other order would produce on any date after the
      # twelfth of a month.
      #
      # Excel serial dates do not come through here at all: they arrive as
      # ISO 8601 from the spreadsheet reader, which knows the cell's format,
      # and PartialDate::Parser reads those directly.
      module PublishedDate
        extend T::Sig

        # `a)`, `b)`: the enumerators, which separate values rather than being
        # part of one. Also removed from the addresses, for the same reason.
        ENUMERATOR = T.let(/(?:\A|[[:space:]])[a-z]\)[[:space:]]*/, Regexp)

        # Two dates with nothing between them but space. A digit on each side is
        # what distinguishes `14/04/1970 14/04/1971`, which is two dates, from
        # `12 April 1965`, which is one.
        ADJACENT = T.let(/(?<=\d)[[:space:]]+(?=\d)/, Regexp)

        # DFAT writes `Approximately:` before a span and `Approximately` before
        # a year, and PartialDate::Parser knows the second spelling only.
        APPROXIMATELY = T.let(/\Aapproximately:/i, Regexp)

        # Every kind of space, because the cells carry more than one: 203 of the
        # 6,823 birth dates end in a non-breaking space, which `String#strip`
        # does not remove and which leaves an otherwise perfectly good
        # `24/08/1962` matching no pattern at all.
        SPACE = T.let(/[[:space:]]+/, Regexp)

        DAY_MONTH_YEAR = T.let(%r{\A(\d{1,2})/(\d{1,2})/(\d{4})\z}, Regexp)
        MONTH_YEAR = T.let(%r{\A(\d{1,2})/(\d{4})\z}, Regexp)

        # A listing date is the one that follows the word "on", which is how
        # every row that states one states it: `Listed on 25 January 2001`,
        # `Designated under the Autonomous Sanctions Regulations 2011 on 2 March
        # 2012`. Matching the bare year in a legislative title -- which is what
        # the other 63% of the column consists of -- would report the year an
        # instrument was made as the day a person was sanctioned.
        LISTED_ON = T.let(/(\w[\w-]*)[[:space:]]+on:?[[:space:]]+(\d{1,2}[[:space:]]+[A-Za-z]+\.?,?[[:space:]]+\d{4})/,
                          Regexp)

        # A row that opens with a date and explains it afterwards: `28 Jan. 2003
        # (amended on 2 Jul. 2007, ...)`.
        LISTED_FIRST = T.let(/\A(\d{1,2}[[:space:]]+[A-Za-z]+\.?,?[[:space:]]+\d{4})/, Regexp)

        # The words that make the date after them the wrong one. 17 rows read
        # `... List 2001 (updated on 5 Aug. 2004)`, where the first date in the
        # cell is when the listing was last touched rather than when it was
        # made, and a designation dated by its own last amendment is worse than
        # one left undated.
        AMENDMENT = T.let(/\A(?:amend|relist|re-list|updat|expir)/i, Regexp)

        module_function

        # Every date in one cell, and the fragments that could not be read --
        # which the adapter keeps in remarks rather than losing.
        sig { params(text: T.untyped).returns([T::Array[PartialDate], T::Array[String]]) }
        def dates(text)
          dates = []
          unread = []
          fragments(text).each do |fragment|
            date = one(fragment)
            date.nil? ? unread << fragment : dates << date
          end
          [dates.uniq, unread]
        end

        # The date the designation was made, from the Listing Information prose,
        # or nil where DFAT names only the instrument -- which is 63% of the
        # list, and is the publisher saying nothing rather than this failing to
        # read it.
        sig { params(text: T.untyped).returns(T.nilable(PartialDate)) }
        def listing(text)
          string = text.to_s
          opening = LISTED_FIRST.match(string)
          return PartialDate::Parser.call(opening[1]) if opening

          match = LISTED_ON.match(string)
          return nil if match.nil? || AMENDMENT.match?(match[1].to_s)

          PartialDate::Parser.call(match[2])
        end

        # One cell split into the values it holds. Commas first, because they
        # are the separator DFAT means; then the enumerators and the bare space,
        # which are what the UN's own prose left behind.
        sig { params(text: T.untyped).returns(T::Array[String]) }
        def fragments(text)
          text.to_s.gsub(ENUMERATOR, ",").split(",").flat_map { |part| part.split(ADJACENT) }
              .map { |part| part.gsub(SPACE, " ").strip }.reject(&:empty?)
        end

        sig { params(fragment: String).returns(T.nilable(PartialDate)) }
        def one(fragment)
          slashed(fragment) || PartialDate::Parser.call(fragment.sub(APPROXIMATELY, "approximately"))
        end

        # The two shapes with slashes in them, which PartialDate::Parser does
        # not read and must not guess at: `05/12/1970` is a date in one order
        # and a different date in the other, and only the publisher settles it.
        sig { params(fragment: String).returns(T.nilable(PartialDate)) }
        def slashed(fragment)
          if (match = DAY_MONTH_YEAR.match(fragment))
            build(year: match[3].to_i, month: match[2].to_i, day: match[1].to_i)
          elsif (match = MONTH_YEAR.match(fragment))
            build(year: match[2].to_i, month: match[1].to_i)
          end
        end

        # A shape the regexes accept can still be an impossible date -- 31
        # February -- and that is PartialDate's judgment, not ours. An
        # unreadable fragment is reported as unread rather than dropped.
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
