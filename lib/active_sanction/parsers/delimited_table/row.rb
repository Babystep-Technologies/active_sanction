# frozen_string_literal: true

module ActiveSanction
  module Parsers
    class DelimitedTable
      # One parsed record: column name to value, with the publisher's null
      # sentinel already resolved to nil.
      #
      #   row[:sdn_name]   # => "AEROCARIBBEAN AIRLINES"
      #   row[:title]      # => nil, because OFAC wrote "-0- " there
      #   row.line         # => 2
      #
      # Deliberately not a Hash. A Hash would answer `row[:sdn_nme]` with nil
      # and let a typo in an adapter look like an empty column all the way into
      # a snapshot; #[] here raises on a name the table never declared, and
      # #fetch is available for the genuinely optional case.
      class Row
        attr_reader :values, :line

        def initialize(values:, line:)
          @values = values.freeze
          @line = line
          freeze
        end

        # Raises on an undeclared column, which is almost always a typo in an
        # adapter rather than a question about the data.
        def [](column)
          values.fetch(column) do
            raise KeyError, "no column #{column.inspect} in this table. Declared: #{columns.join(", ")}"
          end
        end

        def fetch(column, default = nil) = values.fetch(column, default)

        # True when the publisher left the column blank or wrote its null
        # sentinel there. Both arrive as nil, because "-0- " and "" mean the
        # same thing in a file that uses both.
        def null?(column) = self[column].nil?

        def columns = values.keys

        def to_h = values

        def ==(other)
          other.instance_of?(self.class) && other.values == values && other.line == line
        end
        alias eql? ==

        def hash = [self.class, values, line].hash

        def inspect
          filled = values.compact
          "#<#{self.class} line=#{line} #{filled.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")}>"
        end
      end
    end
  end
end
