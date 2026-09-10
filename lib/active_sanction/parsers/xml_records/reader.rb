# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  module Parsers
    class XmlRecords
      # One pass over one payload. Enumerable, and lazy: records are yielded as
      # they are parsed rather than collected, so the memory cost of a pass is
      # one record plus whatever the caller keeps -- which is the whole point
      # of the toolkit, and the reason OFAC's 126 MB advanced XML can drop in
      # later without a redesign.
      #
      #   reader = table.read(bytes)
      #   reader.each { |record| record["DATAID"] }
      #   reader.root       # => {"dateGenerated" => "2026-08-28T00:00:00"}
      #   reader.warnings   # => what could not be read
      #
      # Re-enumerating re-parses from the start, which also resets #warnings --
      # so `reader.count` followed by `reader.warnings` reports the warnings
      # from the counting pass, not from two passes appended together.
      #
      # @api private
      class Reader
        extend T::Sig
        extend T::Generic
        include Enumerable

        Elem = type_member { { fixed: Record } }

        sig { returns(XmlRecords) }
        attr_reader :table

        # The records this pass could not read. Reset by each pass -- see the
        # class comment.
        sig { returns(T::Array[Warning]) }
        attr_reader :warnings

        sig { params(table: XmlRecords, payload: T.untyped).void }
        def initialize(table:, payload:)
          @table = T.let(table, XmlRecords)
          @payload = T.let(payload, T.untyped)
          @warnings = T.let([], T::Array[Warning])
          @backend = T.let(nil, T.untyped)
          @count = T.let(0, Integer)
        end

        sig { override.params(block: T.nilable(T.proc.params(record: Record).void)).returns(T.untyped) }
        def each(&block)
          return enum_for(:each) unless block

          @warnings = []
          @backend = table.backend.new(table: table, xml: decoded)
          read(&block)
          self
        end

        # The document element's attributes. The UN puts the list's generation
        # date there and nowhere else, and it is the version string an examiner
        # recognises, so it has to be reachable without the adapter reaching
        # around the toolkit for it.
        #
        # Parsing far enough to answer costs only the bytes up to the first
        # record, so asking before a pass is cheap; asking after one is free.
        sig { returns(T::Hash[String, T.untyped]) }
        def root
          each.first if @backend.nil?
          @backend&.root || {}
        end

        # Every record, in memory. The convenience the small lists get to use;
        # anything list-sized should stay with #each.
        sig { returns(T::Array[Record]) }
        def to_a = each.to_a

        sig { returns(String) }
        def inspect = "#<#{self.class} #{table.record_names.join(", ")} via #{table.backend}>"

        private

        # A document that stops being XML part-way is not treated the way a
        # malformed CSV row is, because it cannot be: XML has no row boundary
        # to resynchronise on, so everything after the break is unreadable no
        # matter how it is handled. What can be saved is everything before it,
        # and that is what happens -- the records already yielded stand, and
        # the break is recorded as a warning naming the line.
        #
        # Failing before the first record is the different case, and raises:
        # nothing was salvaged, and the overwhelmingly likely cause is that the
        # payload was never XML. An HTML error page saved under a .xml URL is
        # the classic, and reporting that as "0 records, one warning" would let
        # a sync succeed at screening against nothing.
        sig { params(block: T.proc.params(record: Record).void).void }
        def read(&block)
          @count = 0
          @backend.each_record do |record|
            @count += 1
            block.call(record)
          end
        rescue MalformedDocument => e
          give_up!(e) if @count.zero?
          record(e.line, "the document ended after #{@count} record(s): #{e.message}")
        end

        sig { returns(String) }
        def decoded
          string, replaced = table.decode(@payload)
          record(nil, table.invalid_bytes_message) if replaced
          raise ParseError, "expected an XML document, got an empty payload" if string.strip.empty?

          string
        end

        sig { params(line: T.nilable(Integer), message: String).void }
        def record(line, message)
          @warnings << Warning.new(line: line, message: message)
        end

        # The line the backend stopped on is carried through, because that is
        # the whole difference between "this 25 MB file is not XML" and a
        # complaint somebody can open an editor to.
        sig { params(error: MalformedDocument).void }
        def give_up!(error)
          raise ParseError.new(
            "no <#{table.record_names.join("> or <")}> element could be read before the document stopped " \
            "being XML. This payload is almost certainly not the XML it was read as -- check the URL, " \
            "and whether the publisher served an error page. #{error.message}", line: error.line
          )
        end
      end
    end
  end
end
