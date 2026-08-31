# frozen_string_literal: true

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
        SEPARATOR = "/"
        ATTRIBUTE = "@"

        UNSET = Object.new.freeze
        private_constant :UNSET

        attr_reader :name, :attributes, :children, :line

        def initialize(table:, name:, attributes: {}, text: nil, children: [], line: nil)
          @table = table
          @name = -name.to_s
          @attributes = attributes.freeze
          @raw_text = text
          @children = children.freeze
          @line = line
          freeze
        end

        # This element's own text, with blanks and any declared null sentinel
        # resolved to nil. Text belonging to child elements is not included.
        def text = table.value(@raw_text)

        # The first value at `path`, or nil if nothing is there.
        def [](path) = values(path).first

        # Every value at `path`, in document order, with blanks dropped. The
        # answer to a repeated element: the UN files each nationality as its
        # own `<NATIONALITY><VALUE>`.
        def values(path)
          steps, attribute = split(path)
          nodes = descend(steps)
          return nodes.filter_map { |node| node.attribute(attribute) } if attribute

          nodes.filter_map(&:text)
        end

        # The elements at `path`, as Records, whether or not they hold text --
        # an adapter reading `<INDIVIDUAL_ADDRESS>` wants the node, not a value.
        def nodes(path)
          steps, attribute = split(path)
          raise ArgumentError, "#nodes reads elements, not the attribute #{path.inspect}" if attribute

          descend(steps)
        end

        def attribute(key) = table.value(attributes[key.to_s])

        # For a field the adapter treats as mandatory. Raises rather than
        # letting a renamed element arrive downstream as a nil nobody notices.
        def fetch(path, default = UNSET)
          value = self[path]
          return value unless value.nil?
          return default unless default.equal?(UNSET)

          raise KeyError, "no value at #{path.inspect} in <#{name}>#{" on line #{line}" if line}. " \
                          "It carries: #{present.join(", ")}"
        end

        def null?(path) = self[path].nil?

        # The child element names that actually carry something, which is what
        # a #fetch failure has to print and what makes an unfamiliar list
        # explorable from a console.
        def present
          names = children.select { |child| !child.text.nil? || child.children.any? }.map(&:name)
          names.uniq
        end

        def to_s = text.to_s

        def inspect = "#<#{self.class} <#{name}>#{" line=#{line}" if line} #{present.join(" ")}>"

        protected

        attr_reader :table

        def children_named(wanted) = children.select { |child| child.name == wanted }

        private

        # Splits "INDIVIDUAL_ALIAS/ALIAS_NAME" into its steps, and peels off a
        # trailing "@attr" as the attribute to read instead of the text.
        def split(path)
          steps = path.to_s.split(SEPARATOR).map(&:strip).reject(&:empty?)
          return [steps, nil] unless steps.last&.start_with?(ATTRIBUTE)

          [steps[0..-2], steps.last.delete_prefix(ATTRIBUTE)]
        end

        # An empty path is the record itself, which is what makes `record["@id"]`
        # and `record[""]` mean the obvious things.
        def descend(steps)
          steps.inject([self]) do |nodes, wanted|
            nodes.flat_map { |node| node.children_named(wanted) }
          end
        end
      end
    end
  end
end
