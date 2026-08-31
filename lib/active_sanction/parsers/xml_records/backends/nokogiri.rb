# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/parsers/xml_records/backends"
require "active_sanction/parsers/xml_records/builder"

module ActiveSanction
  module Parsers
    class XmlRecords
      module Backends
        # libxml2 through Nokogiri::XML::Reader, which is a pull parser and so
        # streams on the same terms REXML does.
        #
        # Opt-in, never automatic:
        #
        #   ActiveSanction.configure { |c| c.xml_backend = :nokogiri }
        #
        # Nokogiri is not a dependency of this gem and is not required here.
        # It is used only if the host application has already loaded it, which
        # keeps a compliance library off the list of things that make a
        # deployment build native extensions it did not ask for.
        #
        # ### What it costs
        #
        # `Nokogiri::XML::Reader` exposes no position, so records parsed
        # through this backend carry `line: nil` and a warning about one says
        # only what went wrong, not where. A malformed *document* still reports
        # its line, because libxml2's SyntaxError carries one -- so the failure
        # that actually needs locating is located either way.
        #
        # The second difference is worth knowing before switching: given the
        # whole payload in memory, libxml2 checks the document's structure
        # before it yields anything, so a mismatched tag in the middle of a
        # file is refused whole. REXML finds the same error where it sits and
        # keeps every record parsed before it. A list that arrives mangled
        # mid-file needs investigating under either backend, but an operator
        # comparing two installations should know why one reported 400 records
        # and a warning where the other reported a failure. A download that
        # merely stops early -- the commoner accident -- streams and salvages
        # identically on both.
        class Nokogiri
          extend T::Sig

          # Deliberately `defined?` rather than a require: see above.
          sig { returns(T::Boolean) }
          def self.available? = defined?(::Nokogiri::XML::Reader) ? true : false

          sig { returns(T.nilable(String)) }
          def self.unavailable_reason
            "nokogiri is not loaded. Add `gem \"nokogiri\"` to your Gemfile and require it, or leave " \
              "`xml_backend` at :rexml"
          end

          # The document element's attributes, which is where these publishers
          # put the version of the list.
          sig { returns(T.nilable(T::Hash[String, String])) }
          attr_reader :root

          sig { params(table: XmlRecords, xml: String).void }
          def initialize(table:, xml:)
            @table = T.let(table, XmlRecords)
            @xml = T.let(xml, String)
            @root = T.let(nil, T.nilable(T::Hash[String, String]))
            @builder = T.let(Builder.new(table: table), Builder)
            @text_types = T.let(nil, T.nilable(T::Array[T.untyped]))
          end

          sig { params(block: T.proc.params(record: Record).void).void }
          def each_record(&block)
            reader = ::Nokogiri::XML::Reader(@xml)
            reader.each { |node| handle(node, &block) }
            truncated! if @builder.open?
          rescue ::Nokogiri::XML::SyntaxError => e
            raise MalformedDocument.new(e.message.to_s.strip, line: e.line)
          end

          private

          sig { params(node: T.untyped, block: T.proc.params(record: Record).void).void }
          def handle(node, &block)
            case node.node_type
            when ::Nokogiri::XML::Reader::TYPE_ELEMENT then start(node, &block)
            when ::Nokogiri::XML::Reader::TYPE_END_ELEMENT then finish(&block)
            when *text_types then @builder.text(node.value.to_s) if @builder.open?
            end
          end

          # Resolved on first use rather than into a constant: this file is
          # loaded whether or not the host has Nokogiri, and naming its
          # constants at load time would make merely requiring the gem fail.
          sig { returns(T::Array[T.untyped]) }
          def text_types
            @text_types ||= [::Nokogiri::XML::Reader::TYPE_TEXT,
                             ::Nokogiri::XML::Reader::TYPE_CDATA,
                             ::Nokogiri::XML::Reader::TYPE_WHITESPACE,
                             ::Nokogiri::XML::Reader::TYPE_SIGNIFICANT_WHITESPACE].freeze
          end

          # libxml2 reports `<QUALITY/>` as a start with no matching end, so a
          # self-closing element is opened and closed here rather than waiting
          # for an end event that never arrives. The UN's placeholder aliases
          # are made entirely of these.
          sig { params(node: T.untyped, block: T.proc.params(record: Record).void).void }
          def start(node, &block)
            local = Backends.local_name(node.name)
            attrs = Backends.local_attributes(node.attributes)
            @root ||= attrs
            return unless @builder.open? || @table.record?(local)

            @builder.enter(local, attrs)
            finish(&block) if node.self_closing?
          end

          sig { params(block: T.proc.params(record: Record).void).void }
          def finish(&block)
            return unless @builder.open?

            record = @builder.leave
            block.call(record) if record
          end

          sig { void }
          def truncated!
            raise MalformedDocument.new("the document ended inside an unclosed element", line: nil)
          end
        end

        register(:nokogiri, Nokogiri)
      end
    end
  end
end
