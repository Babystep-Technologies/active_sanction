# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/parsers/xml_records/record"

module ActiveSanction
  module Parsers
    class XmlRecords
      # Turns a stream of parser events into one Record at a time.
      #
      # This is the part of XML parsing that is the same whichever library is
      # doing it: enter an element, collect its text, leave it into its parent,
      # and hand back a finished Record when the record element itself closes.
      # A backend translates its library's events into these four calls and
      # writes no tree-building code of its own, which is what keeps a second
      # backend small enough to be worth having.
      #
      # It is also what makes the toolkit streaming rather than DOM-based: the
      # stack only ever holds one record's depth, so a 126 MB file costs the
      # memory of its largest single record and not of itself.
      #
      # @api private
      class Builder
        extend T::Sig

        Frame = Struct.new(:name, :attributes, :text, :children, :line)
        private_constant :Frame

        sig { params(table: XmlRecords).void }
        def initialize(table:)
          @table = T.let(table, XmlRecords)
          @stack = T.let([], T::Array[T.untyped])
        end

        # Whether we are inside a record. A backend asks this to decide whether
        # an element is part of a record or is still the file's scaffolding.
        sig { returns(T::Boolean) }
        def open? = !@stack.empty?

        sig { params(name: T.untyped, attributes: T.untyped, line: T.nilable(Integer)).void }
        def enter(name, attributes = {}, line = nil)
          @stack << Frame.new(name, attributes, nil, [], line)
        end

        # Appended rather than replaced: a parser is free to split one run of
        # text across several events, and libxml2 does exactly that around
        # entity references.
        sig { params(string: String).void }
        def text(string)
          frame = @stack.last
          return if frame.nil?

          frame.text = frame.text ? frame.text + string : +string
        end

        # Closes the innermost element. Returns the finished Record when that
        # was the record element itself, and nil while still inside one.
        sig { returns(T.nilable(Record)) }
        def leave
          frame = @stack.pop
          return nil if frame.nil?

          record = build(frame)
          return record if @stack.empty?

          @stack.last.children << record
          nil
        end

        # A void element -- `<QUALITY/>` -- which libxml2 reports as a start
        # with no matching end.
        sig { params(name: T.untyped, attributes: T.untyped, line: T.nilable(Integer)).returns(T.nilable(Record)) }
        def void(name, attributes = {}, line = nil)
          enter(name, attributes, line)
          leave
        end

        private

        sig { params(frame: T.untyped).returns(Record) }
        def build(frame)
          Record.new(table: @table, name: frame.name, attributes: frame.attributes,
                     text: frame.text, children: frame.children, line: frame.line)
        end
      end
    end
  end
end
