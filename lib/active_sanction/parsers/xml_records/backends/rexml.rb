# frozen_string_literal: true

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
          # Nothing to check: `rexml` is a declared dependency of this gem.
          def self.available? = true
          def self.unavailable_reason = nil

          attr_reader :root

          def initialize(table:, xml:)
            @table = table
            @xml = xml
            @root = nil
            @depth = 0
            @builder = Builder.new(table: table)
          end

          def each_record(&)
            parser = ::REXML::Parsers::PullParser.new(@xml)
            pull(parser, &)
            truncated! if @builder.open? || @depth.positive?
          rescue ::REXML::ParseException => e
            raise malformed(e, parser)
          end

          private

          def pull(parser, &)
            handle(parser.pull, parser, &) while parser.has_next?
          end

          def handle(event, parser, &)
            case event.event_type
            when :start_element then start(event[0], event[1], parser, &)
            when :end_element then close(&)
            when :text then text(::REXML::Text.unnormalize(event[0]))
            when :cdata then text(event[0])
            end
          end

          def text(string)
            @builder.text(string) if @builder.open?
          end

          # The first element in the document is its root, whose attributes are
          # where these publishers put the version of the list -- the UN's
          # `dateGenerated`. Captured whether or not anything else parses.
          def start(name, attributes, parser)
            local = Backends.local_name(name)
            attrs = Backends.local_attributes(attributes)
            @root ||= attrs
            @depth += 1
            return unless @builder.open? || @table.record?(local)

            @builder.enter(local, attrs, line_at(parser))
          end

          def close
            @depth -= 1
            return unless @builder.open?

            record = @builder.leave
            yield record if record
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
          def truncated!
            raise MalformedDocument.new("the document ended inside an unclosed element", line: nil)
          end

          def malformed(error, parser)
            MalformedDocument.new(error.message.lines.first.to_s.strip, line: line_at(parser))
          end

          # REXML reports a byte offset rather than a line, so the offsets of
          # every newline are indexed once per pass and binary-searched. The
          # index is built over the bytes, not the characters, because that is
          # what the offset counts and the two part company on the first
          # accented name -- of which these lists have thousands.
          def line_at(parser)
            offset = parser&.source&.position
            return nil unless offset.is_a?(Integer)

            (newlines.bsearch_index { |at| at >= offset } || newlines.size) + 1
          end

          def newlines
            @newlines ||= begin
              bytes = @xml.b
              offsets = []
              at = bytes.index("\n")
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
