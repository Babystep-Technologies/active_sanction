# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  module Parsers
    # The two questions every format toolkit has to answer about a publisher's
    # bytes, regardless of whether they arrive as rows or as elements: what
    # encoding they are in, and what the publisher writes where it means
    # nothing.
    #
    # Included into the description objects -- DelimitedTable, XmlRecords --
    # rather than into the readers, because both are properties of the *file*
    # that an adapter declares once and reuses for every sync.
    #
    # (Not to be confused with `Sources::Definition#format`, which is the
    # publisher-facing label -- :csv, :xml -- that a CLI prints. This is the
    # machinery behind reading either one.)
    module Format
      extend T::Sig
      extend T::Helpers

      abstract!

      # Included into DelimitedTable and XmlRecords, both of which are ordinary
      # objects; this is what lets `raise` and `Array()` resolve here.
      requires_ancestor { Kernel }

      DEFAULT_ENCODING = T.let(Encoding::UTF_8, Encoding)

      # A UTF-8 BOM left in place becomes part of the first thing parsed: the
      # first column name of a headered CSV, or the `<?xml` of a document that
      # then does not start with `<?xml`. Neither publisher meant to send it.
      BOM = T.let("﻿", String)

      # Both are the including class's to hold, because both are assigned by
      # its constructor from what an adapter declared about the file. Declaring
      # them abstract here rather than reading the instance variables directly
      # is what lets this module say what it needs of an includer instead of
      # reaching into one.
      sig { abstract.returns(T::Array[String]) }
      def nulls; end

      sig { abstract.returns(Encoding) }
      def encoding; end

      # What a caller declared as null, resolved. Public because an adapter
      # joining files by hand needs the same rule the reader applies.
      #
      #   table.value("-0- ")   # => nil
      #   table.value("  ")     # => nil
      #   table.value(" CUBA")  # => "CUBA"
      sig { params(raw: T.untyped).returns(T.nilable(String)) }
      def value(raw)
        string = raw.to_s.strip
        return nil if string.empty? || nulls.include?(string)

        -string
      end

      # The payload as a String in UTF-8, and whether anything had to be
      # replaced to get there.
      #
      # Decoding never raises: a byte that is not valid in the declared
      # encoding becomes U+FFFD and the caller reports it, because losing one
      # character of one address is a far better outcome than refusing to load
      # the list. OFAC serves Windows-1252 and the UN serves UTF-8, and neither
      # declares it in a header we can trust, which is why the encoding is
      # something the adapter states.
      sig { params(payload: T.untyped).returns([String, T::Boolean]) }
      def decode(payload)
        string = payload.to_s.dup.force_encoding(encoding)
        return [string.delete_prefix(BOM), false] if string.valid_encoding? && encoding == DEFAULT_ENCODING

        replaced = !string.valid_encoding?
        utf8 = string.encode(DEFAULT_ENCODING, invalid: :replace, undef: :replace, replace: "�")
        [utf8.delete_prefix(BOM), replaced]
      end

      sig { returns(String) }
      def invalid_bytes_message
        "payload contains bytes that are not valid #{encoding}; they were replaced with U+FFFD"
      end

      private

      # Accepts one sentinel or several: a publisher that writes both "-0-" and
      # "N/A" is not unusual, and an adapter should be able to say so once.
      sig { params(value: T.untyped).returns(T::Array[String]) }
      def nulls!(value)
        Array(value).map { |sentinel| -sentinel.to_s.strip }.reject(&:empty?).uniq.freeze
      end

      sig { params(value: T.untyped).returns(Encoding) }
      def encoding!(value)
        return value if value.is_a?(Encoding)

        Encoding.find(value.to_s)
      rescue ArgumentError
        raise InvalidArgument, "unknown encoding #{value.inspect}"
      end
    end
  end
end
