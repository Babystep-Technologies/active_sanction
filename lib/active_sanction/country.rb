# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/normalizer/form"

module ActiveSanction
  # Which country a publisher meant, as an ISO 3166-1 alpha-2 code.
  #
  #   ActiveSanction::Country.code("Russia")               # => "RU"
  #   ActiveSanction::Country.code("RUS")                  # => "RU"
  #   ActiveSanction::Country.code("Russian Federation")   # => "RU"
  #   ActiveSanction::Country.code("Ruritania")            # => nil
  #
  #   ActiveSanction::Country.name("RU")                   # => "Russian Federation"
  #
  # ### Why the scorer cannot compare these as strings
  #
  # Nationality is the one identifier on these records that is published as
  # prose. A caller screening a customer has an ISO code in a database column;
  # the UN files `NATIONALITY/VALUE` as whatever its Committee wrote, and OFAC
  # writes nationality into the middle of a remarks sentence. So a query of
  # `RU` meets a record of `Russian Federation`, and a query of `Iran` meets
  # `Iran, Islamic Republic of`.
  #
  # Compared as strings those are three disagreements, and a scorer that reads
  # a disagreement as a conflict does not merely fail to boost the match -- it
  # *penalizes* it, on exactly the records where the caller supplied the most
  # information. That is the worst shape a false negative can take, so the
  # comparison happens on a resolved code or it does not happen at all: see
  # Scorer::Adjustments, which treats an unresolvable country as absent rather
  # than as a conflict.
  #
  # ### What resolution is, and what it is not
  #
  # A lookup, not a guess. Every spelling in `countries.txt` -- the alpha-2,
  # the alpha-3, the ISO name and the aliases a list actually writes -- is
  # folded once at load and mapped to its alpha-2 code, and a string that is
  # not in that table returns nil. There is no fuzzy matching here on purpose:
  # `Niger` and `Nigeria` are two countries, `Guinea` is three, and a scorer
  # that resolved a country approximately would be applying a decisive
  # adjustment on a guess.
  #
  # Input is folded by the same `Normalizer::Form` names are folded by, which
  # is what makes `côte d'ivoire`, `Cote D Ivoire` and `CÔTE-D'IVOIRE` one
  # lookup. It is folded with no stoplist: a country is not an entity, and the
  # organization lists would take `Republic` out of half this table.
  #
  # ### The table is a data file
  #
  # `lib/active_sanction/countries.txt`, one country per line, for the reason
  # the normalizer's dictionaries are files: what belongs on it is settled by
  # reading government lists rather than by reading Ruby, and a contributor
  # adding the spelling their market uses should be sending a one-line diff.
  module Country
    extend T::Sig

    TABLE = T.let(File.expand_path("countries.txt", __dir__), String)

    # `<alpha-2>|<alpha-3>|<ISO name>|<alias>...`
    SEPARATOR = T.let("|", String)

    class << self
      extend T::Sig

      # The alpha-2 code for a name, a code or an alias, or nil for anything
      # not in the table. nil and blank are nil rather than an error: an
      # absent nationality is the common case on these lists, and the scorer
      # asks about it record by record.
      sig { params(value: T.untyped).returns(T.nilable(String)).checked(:tests) }
      def code(value)
        return nil if value.nil?

        key = fold(value.to_s)
        key.empty? ? nil : CODES[key]
      end

      # The ISO name for an alpha-2 code, for a hit a person has to read. The
      # ISO name rather than the alias a publisher wrote, deliberately: the
      # published string is still on the record, and an explanation that names
      # one country two ways is one a reviewer has to reconcile.
      sig { params(value: T.untyped).returns(T.nilable(String)).checked(:tests) }
      def name(value)
        found = code(value)
        found && NAMES[found]
      end

      # Every alpha-2 code in the table, in file order.
      sig { returns(T::Array[String]).checked(:tests) }
      def codes = NAMES.keys

      # The fold a lookup key goes through. Public because a collision in the
      # table is a fact about folded strings rather than about the file, and
      # the suite checks for one.
      sig { params(value: String).returns(String).checked(:tests) }
      def fold(value) = Normalizer::Form.new(value).value

      # Reads the shipped table, or another one shaped like it. Returns the
      # pair the constants below hold: spelling => alpha-2, and alpha-2 =>
      # ISO name.
      #
      # A spelling claimed twice raises rather than resolving to whichever
      # line came first. Two countries quietly sharing a name would move a
      # nationality adjustment onto the wrong record, and it would do it
      # silently -- the table would still load and every lookup would still
      # answer.
      sig { params(path: String).returns([T::Hash[String, String], T::Hash[String, String]]).checked(:tests) }
      def read(path = TABLE)
        codes = {}
        names = {}
        each_row(path) do |fields|
          alpha2 = T.must(fields.first)
          names[alpha2] = fields[2]
          fields.each { |field| claim(codes, field, alpha2) }
        end
        [codes.freeze, names.freeze]
      end

      private

      # One country per line; blank lines and `#` comments ignored, as in the
      # normalizer's dictionaries.
      sig { params(path: String, block: T.proc.params(fields: T::Array[String]).void).void }
      def each_row(path, &block)
        File.readlines(path, chomp: true).each do |line|
          row = line.strip
          next if row.empty? || row.start_with?("#")

          fields = row.split(SEPARATOR).map(&:strip).reject(&:empty?)
          raise ArgumentError, "#{path}: a country needs a code, a code and a name: #{row.inspect}" if fields.size < 3

          block.call(fields)
        end
      end

      sig { params(codes: T::Hash[String, String], field: String, alpha2: String).void }
      def claim(codes, field, alpha2)
        key = fold(field)
        return if key.empty?

        claimed = codes[key]
        if claimed && claimed != alpha2
          raise ArgumentError, "#{field.inspect} is claimed by both #{claimed} and #{alpha2}"
        end

        codes[key] = alpha2
      end
    end

    # Built at load rather than memoized on first use, so nothing has to
    # synchronize reading a file. Private because the two readers above are
    # the way to reach them.
    codes, names = read
    CODES = T.let(codes, T::Hash[String, String])
    NAMES = T.let(names, T::Hash[String, String])
    private_constant :CODES, :NAMES
  end
end
