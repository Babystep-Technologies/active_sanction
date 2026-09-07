# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  module Parsers
    class Spreadsheet
      # One row of a sheet: column name to value, with every cell already
      # resolved to the string it displays as -- a shared string looked up, a
      # date serial rendered, a blank cell nil.
      #
      #   row[:name_of_individual_or_entity]   # => "MOHAMMAD HASSAN AKHUND"
      #   row[:date_of_birth]                  # => "1963-01-30"
      #   row[:alias_strength]                 # => nil, the cell being empty
      #   row.number                           # => 2, the sheet's own row number
      #
      # Deliberately not a Hash, for the reason DelimitedTable::Row is not one:
      # a Hash would answer `row[:date_of_brith]` with nil and let a typo in an
      # adapter look like an empty column all the way into a snapshot. #[]
      # raises on a name the sheet never had, and #fetch is there for the
      # genuinely optional case.
      #
      # It is a separate class from the delimited table's row rather than a
      # shared one because the two disagree about what locates a record. A CSV
      # row is at a line of a file; a sheet row is at a row number the
      # spreadsheet itself assigns, which is what is showing in the corner of
      # the window when somebody opens the published file to check a record --
      # and which survives the workbook being re-saved with different XML.
      class Row
        extend T::Sig

        sig { returns(T::Hash[Symbol, T.nilable(String)]) }
        attr_reader :values

        # The sheet's own row number, 1-based and counting the header row --
        # the number a reader of the published file will see beside the record.
        sig { returns(Integer) }
        attr_reader :number

        sig { params(values: T::Hash[Symbol, T.nilable(String)], number: Integer).void }
        def initialize(values:, number:)
          @values = T.let(values.freeze, T::Hash[Symbol, T.nilable(String)])
          @number = T.let(number, Integer)
          freeze
        end

        # Raises on a column the sheet never had, which is almost always a typo
        # in an adapter rather than a question about the data.
        sig { params(column: Symbol).returns(T.nilable(String)) }
        def [](column)
          values.fetch(column) do
            raise KeyError, "no column #{column.inspect} in this sheet. Read: #{columns.join(", ")}"
          end
        end

        sig { params(column: Symbol, default: T.untyped).returns(T.untyped) }
        def fetch(column, default = nil) = values.fetch(column, default)

        sig { params(column: Symbol).returns(T::Boolean) }
        def null?(column) = self[column].nil?

        sig { returns(T::Array[Symbol]) }
        def columns = values.keys

        sig { returns(T::Hash[Symbol, T.nilable(String)]) }
        def to_h = values

        sig { params(other: T.untyped).returns(T::Boolean) }
        def ==(other)
          return false unless other.instance_of?(self.class)

          values == other.values && number == other.number
        end
        alias eql? ==

        sig { returns(Integer) }
        def hash = [self.class, values, number].hash

        sig { returns(String) }
        def inspect
          filled = values.compact
          "#<#{self.class} row=#{number} #{filled.map { |name, value| "#{name}=#{value.inspect}" }.join(" ")}>"
        end
      end
    end
  end
end
