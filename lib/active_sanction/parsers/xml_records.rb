# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "set"
require "active_sanction/parsers/format"
require "active_sanction/parsers/xml_records/record"
require "active_sanction/parsers/xml_records/builder"
require "active_sanction/parsers/xml_records/backends"
require "active_sanction/parsers/xml_records/reader"

module ActiveSanction
  module Parsers
    # Reads a record-oriented XML list -- the UN, Canada, the EU and the UK all
    # publish one -- into records an adapter can map onto Entities.
    #
    # A table is a description of the document, built once and reused for every
    # sync; a Reader is one pass over one payload.
    #
    #   UN = ActiveSanction::Parsers::XmlRecords.new(records: %w[INDIVIDUAL ENTITY])
    #
    #   reader = UN.read(bytes)
    #   reader.each do |record|
    #     record.name                        # => "INDIVIDUAL"
    #     record["FIRST_NAME"]               # => "ERIC"
    #     record.values("NATIONALITY/VALUE") # => ["Chad"]
    #     record.nodes("INDIVIDUAL_ALIAS")   # => [Record, ...]
    #   end
    #   reader.root["dateGenerated"]         # the publisher's own version marker
    #
    # ### Streaming from day one, before anything needs it
    #
    # Every list this gem launches with is small: the UN is 2.2 MB, Canada is
    # 2.9 MB, and either would load into a DOM without anyone noticing. The one
    # that is coming does not. OFAC's `SDN_ADVANCED.XML` is 126 MB, and a DOM
    # design would meet it by being rewritten.
    #
    # So the interface is record-at-a-time now, while it is free to be: the
    # parser holds one record's depth on a stack and drops it as soon as the
    # adapter is done with it. What that buys is not speed, it is that the
    # adapter written against this today is the adapter that reads a 126 MB
    # file later, unchanged.
    #
    # ### Naming the records, and only the records
    #
    # A document's scaffolding -- `<CONSOLIDATED_LIST>`, `<INDIVIDUALS>` -- is
    # skipped entirely rather than being built into nodes nobody asked for.
    # Naming several record elements is normal: the UN files people under
    # `<INDIVIDUAL>` and organizations under `<ENTITY>`, in one document, and
    # an adapter wants a single pass over both.
    #
    # ### Namespaces
    #
    # Element and attribute names are matched with any prefix removed, so a
    # publisher adding an `xmlns` next quarter does not silently stop matching.
    # See Backends.local_name for why the prefix is dropped rather than
    # resolved.
    class XmlRecords
      extend T::Sig
      include Format

      # Raised by a backend when the payload stops being XML. Caught by Reader,
      # which decides between salvaging the records already read and refusing
      # the payload outright; it escapes as a ParseError either way, so a
      # caller rescuing the toolkit's errors does not have to know about it.
      class MalformedDocument < ParseError
        extend T::Sig

        # nil where the backend reports no position -- libxml2 does not always.
        sig { returns(T.nilable(Integer)) }
        attr_reader :line

        sig { params(message: String, line: T.nilable(Integer)).void }
        def initialize(message, line: nil)
          @line = T.let(line, T.nilable(Integer))
          super(message)
        end
      end

      # A Set: `record?` is asked once per element in the document, which for
      # the UN is roughly 30,000 times a pass.
      sig { returns(T::Set[String]) }
      attr_reader :records

      sig { override.returns(T::Array[String]) }
      attr_reader :nulls

      sig { override.returns(Encoding) }
      attr_reader :encoding

      # `null:` is here for the same reason DelimitedTable has it -- a
      # publisher that writes a sentinel where it means nothing -- though the
      # XML lists mostly use an empty element instead, which is already nil.
      #
      # `backend:` overrides the configured default for this table alone. Most
      # adapters should not pass it: which XML library parses a list is an
      # installation's decision, not a list's. See Backends.
      sig { params(records: T.untyped, null: T.untyped, encoding: T.untyped, backend: T.untyped).void }
      def initialize(records:, null: nil, encoding: DEFAULT_ENCODING, backend: nil)
        @records = T.let(records!(records), T::Set[String])
        @nulls = T.let(nulls!(null), T::Array[String])
        @encoding = T.let(encoding!(encoding), Encoding)
        @backend = T.let(backend&.to_sym, T.nilable(Symbol))
        freeze
      end

      # A pass over one payload. Takes the bytes as a String, which is what
      # Sources::Base hands #parse.
      sig { params(payload: T.untyped).returns(Reader) }
      def read(payload) = Reader.new(table: self, payload: payload)

      # Whether an element name starts a record. Asked by every backend for
      # every element outside a record, so it stays a Set lookup.
      sig { params(name: String).returns(T::Boolean) }
      def record?(name) = records.include?(name)

      # The record element names in declaration order, for a message or an
      # inspect -- Set is the right shape to ask `record?` of and the wrong
      # shape to print.
      sig { returns(T::Array[String]) }
      def record_names = records.to_a

      # Resolved per call rather than at construction, so a table built at
      # class-definition time -- which is where an adapter builds it -- still
      # honours an `xml_backend` set later in an initializer.
      sig { returns(T.untyped) }
      def backend = Backends.resolve(@backend || ActiveSanction.config.xml_backend)

      sig { returns(String) }
      def inspect
        "#<#{self.class} records=#{record_names.join(", ")}#{" null=#{nulls.first.inspect}" if nulls.any?}>"
      end

      private

      # Accepts one element name or several. Stored as a Set: a document with
      # 1,011 records asks `record?` once per element in the file, which for
      # the UN is roughly 30,000 times.
      sig { params(value: T.untyped).returns(T::Set[String]) }
      def records!(value)
        names = Array(value).map { |name| -name.to_s.strip }.reject(&:empty?).uniq
        raise ArgumentError, "records must name at least one element, e.g. records: \"INDIVIDUAL\"" if names.empty?

        Set.new(names).freeze
      end
    end
  end
end
