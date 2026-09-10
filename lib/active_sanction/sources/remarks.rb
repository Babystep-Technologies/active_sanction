# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  module Sources
    # The publisher's own free text, plus the fields the canonical model has no
    # home for, kept together in one string.
    #
    #   Remarks.build(row[:remarks], [["Vessel flag", "Panama"], ["Tonnage", "8000"]])
    #   # => "Registered in Panama [source fields] Vessel flag: Panama; Tonnage: 8000"
    #
    #   Remarks.published(entity.remarks)   # => "Registered in Panama"
    #
    # ### Why an adapter appends rather than drops
    #
    # Every list publishes something the canonical Entity has nowhere to put --
    # OFAC a vessel's flag and owner, the UN a place of birth and a gender.
    # Dropping it keeps the schema tidy at the cost of real screening signal,
    # which is the wrong trade; putting it in remarks keeps it, at the cost of
    # mixing it with the publisher's own prose.
    #
    # The marker is what pays that cost back. Anything reading the remark for
    # what the publisher actually wrote -- OFAC's remarks parser (#19) is the
    # first, and it must never see a vessel flag and read it as a nationality
    # -- takes the text before the marker, which is what .published does.
    #
    # ### One marker, not one per source
    #
    # Both launch adapters invented this independently and gave it different
    # spellings, which would have meant every consumer of a remark learning
    # which source it came from before it could strip anything. There is one
    # marker now, and one format, and adding a third source does not add a
    # third convention.
    module Remarks
      extend T::Sig

      # @api private
      MARKER = T.let("[source fields]", String)

      # @api private
      SEPARATOR = T.let("; ", String)

      # `fields` is a list of label/value pairs. A value may be an Array -- the
      # UN files three designations under one element -- and a label whose
      # value is missing or blank is left out entirely rather than printed
      # against an empty string.
      sig { params(published: T.untyped, fields: T.untyped).returns(T.nilable(String)) }
      def self.build(published, fields = [])
        appended = Array(fields).filter_map { |label, value| entry(label, value) }
        text = string_or_nil(published)
        return text if appended.empty?

        [text, MARKER, appended.join(SEPARATOR)].compact.join(" ")
      end

      # The publisher's own text, with anything an adapter appended stripped
      # back off. nil when the publisher wrote nothing and every word in the
      # remark was put there by us, which is the honest answer: a consumer
      # asking what the publisher said should not be handed a vessel's tonnage.
      sig { params(remarks: T.untyped).returns(T.nilable(String)) }
      def self.published(remarks)
        string_or_nil(remarks.to_s.split(MARKER, 2).first)
      end

      sig { params(label: T.untyped, value: T.untyped).returns(T.nilable(String)) }
      def self.entry(label, value)
        values = Array(value).filter_map { |item| string_or_nil(item) }
        "#{label}: #{values.join(", ")}" if values.any?
      end
      private_class_method :entry

      sig { params(value: T.untyped).returns(T.nilable(String)) }
      def self.string_or_nil(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
      private_class_method :string_or_nil
    end
  end
end
