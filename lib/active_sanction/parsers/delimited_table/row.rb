# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

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
        extend T::Sig

        # Column name to value, with the publisher's null sentinel already
        # resolved to nil.
        sig { returns(T::Hash[Symbol, T.nilable(String)]) }
        attr_reader :values

        sig { returns(Integer) }
        attr_reader :line

        sig { params(values: T::Hash[Symbol, T.nilable(String)], line: Integer).void }
        def initialize(values:, line:)
          @values = T.let(values.freeze, T::Hash[Symbol, T.nilable(String)])
          @line = T.let(line, Integer)
          freeze
        end

        # Raises on an undeclared column, which is almost always a typo in an
        # adapter rather than a question about the data.
        sig { params(column: Symbol).returns(T.nilable(String)) }
        def [](column)
          values.fetch(column) do
            raise MissingKey, "no column #{column.inspect} in this table. Declared: #{columns.join(", ")}"
          end
        end

        sig { params(column: Symbol, default: T.untyped).returns(T.untyped) }
        def fetch(column, default = nil) = values.fetch(column, default)

        # True when the publisher left the column blank or wrote its null
        # sentinel there. Both arrive as nil, because "-0- " and "" mean the
        # same thing in a file that uses both.
        sig { params(column: Symbol).returns(T::Boolean) }
        def null?(column) = self[column].nil?

        sig { returns(T::Array[Symbol]) }
        def columns = values.keys

        sig { returns(T::Hash[Symbol, T.nilable(String)]) }
        def to_h = values

        sig { params(other: T.untyped).returns(T::Boolean) }
        def ==(other)
          return false unless other.instance_of?(self.class)

          values == other.values && line == other.line
        end
        alias eql? ==

        sig { returns(Integer) }
        def hash = [self.class, values, line].hash

        sig { returns(String) }
        def inspect
          filled = values.compact
          "#<#{self.class} line=#{line} #{filled.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")}>"
        end
      end
    end
  end
end
