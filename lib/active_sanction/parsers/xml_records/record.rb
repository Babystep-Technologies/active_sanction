# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  module Parsers
    class XmlRecords
      # One record element and everything under it: the UN's `<INDIVIDUAL>`,
      # Canada's `<record>`. Fields are read by path relative to the record,
      # and a nested element is itself a Record, which is what lets an adapter
      # walk repeated children without knowing how the file was parsed.
      #
      #   record.name                       # => "INDIVIDUAL"
      #   record["DATAID"]                  # => "6907993"
      #   record["INDIVIDUAL_DATE_OF_BIRTH/YEAR"]
      #   record.values("NATIONALITY/VALUE")     # => ["Chad", "Sudan"]
      #   record.nodes("INDIVIDUAL_ALIAS")       # => [Record, Record]
      #   record["@dateGenerated"]               # an attribute, XPath-style
      #
      # ### Absent, empty, and blank are one answer
      #
      # An element that is missing, self-closing, or holds only whitespace all
      # read as nil. That is not laziness about the difference; it is the only
      # reading that survives the UN, which files placeholder aliases as
      # `<INDIVIDUAL_ALIAS><QUALITY/><ALIAS_NAME/></INDIVIDUAL_ALIAS>` and means
      # nothing at all by them. An adapter that had to distinguish the three
      # would produce blank-valued Names for every one of those placeholders.
      #
      # ### Why #[] does not raise the way a CSV Row does
      #
      # DelimitedTable::Row raises on a column its table never declared, since
      # a table's shape is fixed and an unknown name there is a typo. XML has
      # no such shape: one `<INDIVIDUAL>` carries elements the next one omits,
      # so an absent path is ordinary and #[] answers nil. #fetch is there for
      # the field an adapter considers mandatory, and it names the record and
      # what the record does carry when the field is missing.
      class Record
        extend T::Sig

        SEPARATOR = T.let("/", String)
        ATTRIBUTE = T.let("@", String)

        UNSET = T.let(Object.new.freeze, Object)
        private_constant :UNSET

        # The element's own name, with any namespace prefix already removed by
        # the backend -- see Backends.local_name.
        sig { returns(String) }
        attr_reader :name

        sig { returns(T::Hash[String, T.untyped]) }
        attr_reader :attributes

        sig { returns(T::Array[Record]) }
        attr_reader :children

        # nil where the backend reports no position.
        sig { returns(T.nilable(Integer)) }
        attr_reader :line

        sig do
          params(table: XmlRecords, name: T.untyped, attributes: T::Hash[String, T.untyped], text: T.untyped,
                 children: T::Array[Record], line: T.nilable(Integer)).void
        end
        def initialize(table:, name:, attributes: {}, text: nil, children: [], line: nil)
          @table = T.let(table, XmlRecords)
          @name = T.let(-name.to_s, String)
          @attributes = T.let(attributes.freeze, T::Hash[String, T.untyped])
          @raw_text = T.let(text, T.untyped)
          @children = T.let(children.freeze, T::Array[Record])
          @line = T.let(line, T.nilable(Integer))
          freeze
        end

        # This element's own text, with blanks and any declared null sentinel
        # resolved to nil. Text belonging to child elements is not included.
        sig { returns(T.nilable(String)) }
        def text = table.value(@raw_text)

        # The first value at `path`, or nil if nothing is there.
        sig { params(path: T.untyped).returns(T.nilable(String)) }
        def [](path) = values(path).first

        # Every value at `path`, in document order, with blanks dropped. The
        # answer to a repeated element: the UN files each nationality as its
        # own `<NATIONALITY><VALUE>`.
        sig { params(path: T.untyped).returns(T::Array[String]) }
        def values(path)
          steps, attribute = split(path)
          nodes = descend(steps)
          return nodes.filter_map { |node| node.attribute(attribute) } if attribute

          nodes.filter_map(&:text)
        end

        # The elements at `path`, as Records, whether or not they hold text --
        # an adapter reading `<INDIVIDUAL_ADDRESS>` wants the node, not a value.
        sig { params(path: T.untyped).returns(T::Array[Record]) }
        def nodes(path)
          steps, attribute = split(path)
          raise InvalidArgument, "#nodes reads elements, not the attribute #{path.inspect}" if attribute

          descend(steps)
        end

        sig { params(key: T.untyped).returns(T.nilable(String)) }
        def attribute(key) = table.value(attributes[key.to_s])

        # For a field the adapter treats as mandatory. Raises rather than
        # letting a renamed element arrive downstream as a nil nobody notices.
        sig { params(path: T.untyped, default: T.untyped).returns(T.untyped) }
        def fetch(path, default = UNSET)
          value = self[path]
          return value unless value.nil?
          return default unless default.equal?(UNSET)

          raise MissingKey, "no value at #{path.inspect} in <#{name}>#{" on line #{line}" if line}. " \
                            "It carries: #{present.join(", ")}"
        end

        sig { params(path: T.untyped).returns(T::Boolean) }
        def null?(path) = self[path].nil?

        # The child element names that actually carry something, which is what
        # a #fetch failure has to print and what makes an unfamiliar list
        # explorable from a console.
        sig { returns(T::Array[String]) }
        def present
          names = children.select { |child| !child.text.nil? || child.children.any? }.map(&:name)
          names.uniq
        end

        sig { returns(String) }
        def to_s = text.to_s

        sig { returns(String) }
        def inspect = "#<#{self.class} <#{name}>#{" line=#{line}" if line} #{present.join(" ")}>"

        protected

        sig { returns(XmlRecords) }
        attr_reader :table

        sig { params(wanted: String).returns(T::Array[Record]) }
        def children_named(wanted) = children.select { |child| child.name == wanted }

        private

        # Splits "INDIVIDUAL_ALIAS/ALIAS_NAME" into its steps, and peels off a
        # trailing "@attr" as the attribute to read instead of the text.
        sig { params(path: T.untyped).returns([T::Array[String], T.nilable(String)]) }
        def split(path)
          steps = path.to_s.split(SEPARATOR).map(&:strip).reject(&:empty?)
          return [steps, nil] unless steps.last&.start_with?(ATTRIBUTE)

          [steps[0..-2], steps.last.delete_prefix(ATTRIBUTE)]
        end

        # An empty path is the record itself, which is what makes `record["@id"]`
        # and `record[""]` mean the obvious things.
        sig { params(steps: T::Array[String]).returns(T::Array[Record]) }
        def descend(steps)
          steps.inject([self]) do |nodes, wanted|
            nodes.flat_map { |node| node.children_named(wanted) }
          end
        end
      end
    end
  end
end
