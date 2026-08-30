# frozen_string_literal: true

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
      class Reader
        include Enumerable

        attr_reader :table, :warnings

        def initialize(table:, payload:)
          @table = table
          @payload = payload
          @warnings = []
          @backend = nil
        end

        def each(&)
          return enum_for(:each) unless block_given?

          @warnings = []
          @backend = table.backend.new(table: table, xml: decoded)
          read(&)
          self
        end

        # The document element's attributes. The UN puts the list's generation
        # date there and nowhere else, and it is the version string an examiner
        # recognises, so it has to be reachable without the adapter reaching
        # around the toolkit for it.
        #
        # Parsing far enough to answer costs only the bytes up to the first
        # record, so asking before a pass is cheap; asking after one is free.
        def root
          each.first if @backend.nil?
          @backend&.root || {}
        end

        # Every record, in memory. The convenience the small lists get to use;
        # anything list-sized should stay with #each.
        def to_a = each.to_a

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
        def read
          @count = 0
          @backend.each_record do |record|
            @count += 1
            yield record
          end
        rescue MalformedDocument => e
          give_up!(e) if @count.zero?
          record(e.line, "the document ended after #{@count} record(s): #{e.message}")
        end

        def decoded
          string, replaced = table.decode(@payload)
          record(nil, table.invalid_bytes_message) if replaced
          raise ParseError, "expected an XML document, got an empty payload" if string.strip.empty?

          string
        end

        def record(line, message)
          @warnings << Warning.new(line: line, message: message)
        end

        def give_up!(error)
          raise ParseError,
                "no <#{table.record_names.join("> or <")}> element could be read before the document stopped " \
                "being XML. This payload is almost certainly not the XML it was read as -- check the URL, " \
                "and whether the publisher served an error page. #{error.message}"
        end
      end
    end
  end
end
