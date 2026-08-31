# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"

module ActiveSanction
  # The format toolkits adapters parse with. A source declares what its file
  # looks like -- delimiter, column names, null sentinel -- and gets rows back;
  # what those rows *mean* stays in the adapter, because that is the part no
  # two publishers agree on.
  #
  # Nothing here knows about Entity. These are file readers, and keeping them
  # ignorant of the canonical model is what lets an adapter for a list nobody
  # here has seen reuse them.
  module Parsers
    # A payload that could not be read at all: the wrong format, a truncated
    # download, an encoding that cannot be decoded. Distinct from a Warning,
    # which is a *row* that could not be read while the rest of the file could.
    class ParseError < Error; end

    # One row the parser could not use, kept rather than raised.
    #
    # A sanctions list is not a file we control. OFAC ships 19,321 rows and a
    # single unbalanced quote somewhere in the middle must not cost the other
    # 19,320 -- refusing to load a list because one record is malformed fails
    # exactly when the list is most needed. So a bad row is recorded here and
    # skipped, and the caller decides whether the count is tolerable.
    #
    # `line` is the line number within the file, which is what makes a warning
    # actionable: a 5.6 MB CSV is only debuggable if the complaint says where.
    # It is nil when the parser cannot say -- libxml2 reports no position for a
    # record -- and a warning that cannot point at a line still says what went
    # wrong rather than pointing at the wrong one.
    class Warning
      extend T::Sig

      # nil when the parser cannot say which line -- see above.
      sig { returns(T.nilable(Integer)) }
      attr_reader :line

      sig { returns(String) }
      attr_reader :message

      sig { returns(T.nilable(String)) }
      attr_reader :snippet

      sig { params(line: T.nilable(Integer), message: String, snippet: T.untyped).void }
      def initialize(line:, message:, snippet: nil)
        @line = T.let(line, T.nilable(Integer))
        @message = T.let(message, String)
        @snippet = T.let(snippet.nil? ? nil : truncate(snippet), T.nilable(String))
        freeze
      end

      sig { returns(String) }
      def to_s
        "#{"line #{line}: " if line}#{message}#{" -- #{snippet.inspect}" if snippet}"
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h = { line: line, message: message, snippet: snippet }

      sig { returns(String) }
      def inspect = "#<#{self.class} #{self}>"

      private

      # A malformed row is frequently malformed because it is enormous -- an
      # unclosed quote swallows everything after it -- so the evidence is
      # trimmed before it is kept.
      sig { params(text: T.untyped).returns(String) }
      def truncate(text)
        string = text.to_s
        -(string.length > 120 ? "#{string[0, 120]}..." : string)
      end
    end
  end
end

require "active_sanction/parsers/delimited_table"
require "active_sanction/parsers/xml_records"
require "active_sanction/parsers/xml_records/backends/rexml"
require "active_sanction/parsers/xml_records/backends/nokogiri"
require "active_sanction/parsers/join"
