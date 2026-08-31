# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "rexml/parsers/pullparser"
require "rexml/text"
require "active_sanction/parsers/xml_records/backends"
require "active_sanction/parsers/xml_records/builder"

module ActiveSanction
  module Parsers
    class XmlRecords
      module Backends
        # The default backend: stdlib REXML, pulled one event at a time.
        #
        # Chosen as the default because it is everywhere Ruby is, needs no
        # build step, and gives every installation the same answer -- see
        # Backends for why that last property is the one that matters for a
        # list whose parsed content gets checksummed into an audit trail.
        #
        # It is the slower of the two. On the UN's 2.2 MB consolidated list
        # that is a fraction of a second on a job that already spent longer
        # downloading the file; a host parsing OFAC's 126 MB advanced XML on a
        # schedule is the case that should switch to libxml2, and can.
        class Rexml
          extend T::Sig

          # Nothing to check: `rexml` is a declared dependency of this gem.
          sig { returns(T::Boolean) }
          def self.available? = true

          sig { returns(T.nilable(String)) }
          def self.unavailable_reason = nil

          # The document element's attributes, which is where these publishers
          # put the version of the list.
          sig { returns(T.nilable(T::Hash[String, String])) }
          attr_reader :root

          sig { params(table: XmlRecords, xml: String).void }
          def initialize(table:, xml:)
            @table = T.let(table, XmlRecords)
            @xml = T.let(xml, String)
            @root = T.let(nil, T.nilable(T::Hash[String, String]))
            @depth = T.let(0, Integer)
            @builder = T.let(Builder.new(table: table), Builder)
            @newlines = T.let(nil, T.nilable(T::Array[Integer]))
          end

          sig { params(block: T.proc.params(record: Record).void).void }
          def each_record(&block)
            parser = ::REXML::Parsers::PullParser.new(@xml)
            pull(parser, &block)
            truncated! if @builder.open? || @depth.positive?
          rescue ::REXML::ParseException => e
            raise malformed(e, parser)
          end

          private

          sig { params(parser: T.untyped, block: T.proc.params(record: Record).void).void }
          def pull(parser, &block)
            handle(parser.pull, parser, &block) while parser.has_next?
          end

          sig { params(event: T.untyped, parser: T.untyped, block: T.proc.params(record: Record).void).void }
          def handle(event, parser, &block)
            case event.event_type
            when :start_element then start(event[0], event[1], parser)
            when :end_element then close(&block)
            when :text then text(::REXML::Text.unnormalize(event[0]))
            when :cdata then text(event[0])
            end
          end

          sig { params(string: String).void }
          def text(string)
            @builder.text(string) if @builder.open?
          end

          # The first element in the document is its root, whose attributes are
          # where these publishers put the version of the list -- the UN's
          # `dateGenerated`. Captured whether or not anything else parses.
          sig { params(name: T.untyped, attributes: T.untyped, parser: T.untyped).void }
          def start(name, attributes, parser)
            local = Backends.local_name(name)
            attrs = Backends.local_attributes(attributes)
            @root ||= attrs
            @depth += 1
            return unless @builder.open? || @table.record?(local)

            @builder.enter(local, attrs, line_at(parser))
          end

          sig { params(block: T.proc.params(record: Record).void).void }
          def close(&block)
            @depth -= 1
            return unless @builder.open?

            record = @builder.leave
            block.call(record) if record
          end

          # REXML stops at the end of the payload without complaint when a tag
          # was never closed, so a download cut in half looks like a short list
          # rather than like a problem. Elements still open at the end are the
          # evidence, and it is worth raising on: a truncated list that loads
          # quietly is how a screening run silently stops covering people.
          #
          # The depth counter is what catches the commoner half of it. A
          # download truncated between two records leaves the builder closed
          # and only the document element unfinished, so counting starts and
          # ends is the only thing that can tell that list from a complete one.
          sig { void }
          def truncated!
            raise MalformedDocument.new("the document ended inside an unclosed element", line: nil)
          end

          sig { params(error: T.untyped, parser: T.untyped).returns(MalformedDocument) }
          def malformed(error, parser)
            MalformedDocument.new(error.message.lines.first.to_s.strip, line: line_at(parser))
          end

          # REXML reports a byte offset rather than a line, so the offsets of
          # every newline are indexed once per pass and binary-searched. The
          # index is built over the bytes, not the characters, because that is
          # what the offset counts and the two part company on the first
          # accented name -- of which these lists have thousands.
          sig { params(parser: T.untyped).returns(T.nilable(Integer)) }
          def line_at(parser)
            offset = parser&.source&.position
            return nil unless offset.is_a?(Integer)

            (newlines.bsearch_index { |at| at >= offset } || newlines.size) + 1
          end

          sig { returns(T::Array[Integer]) }
          def newlines
            @newlines ||= begin
              bytes = @xml.b
              offsets = T.let([], T::Array[Integer])
              at = T.let(bytes.index("\n"), T.nilable(Integer))
              while at
                offsets << at
                at = bytes.index("\n", at + 1)
              end
              offsets
            end
          end
        end

        register(:rexml, Rexml)
      end
    end
  end
end
