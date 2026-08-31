# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/parsers"
require "active_sanction/sources"
require "active_sanction/sources/base"

module ActiveSanction
  module Sources
    # The United Nations Security Council consolidated list: every individual
    # and entity subject to a UN sanctions regime, in one document.
    #
    #   snapshot = ActiveSanction::Sources[:un_consolidated].new.sync
    #
    # ### One file, two record shapes
    #
    #   https://scsanctions.un.org/resources/xml/en/consolidated.xml   2.2 MB
    #
    #     <INDIVIDUALS><INDIVIDUAL>   736 people
    #     <ENTITIES><ENTITY>          275 organizations
    #
    # Both are read in a single streaming pass. The file is small enough today
    # to have been loaded whole without anyone noticing, which is exactly why
    # it was not: the toolkit this adapter is written against (#15) is the one
    # that will read OFAC's 126 MB advanced XML, and an adapter that quietly
    # depended on holding the document would have to be rewritten then.
    #
    # ### The trap in this list
    #
    # `QUALITY` appears under both alias elements and means something different
    # under each. Under `<INDIVIDUAL_ALIAS>` it grades the alias -- Good or Low
    # -- which is a matching signal the scorer (#32) penalizes on. Under
    # `<ENTITY_ALIAS>` it is not a grade at all; it is `a.k.a.` or `f.k.a.`,
    # which is an alias *kind*. Reading one as the other silently either throws
    # away every entity's alias kind or grades 585 organization aliases on a
    # scale that was never applied to them. Record maps them separately, and
    # the counts above come from the published file rather than from a guess.
    #
    # ### What this adapter does not do
    #
    # `INDIVIDUAL_PLACE_OF_BIRTH`, `GENDER`, `TITLE` and `DESIGNATION` have no
    # home in the canonical model. They are appended to remarks after a marker
    # rather than dropped -- a place of birth is real screening signal, and
    # losing it to keep a schema tidy is the wrong trade -- and are left for a
    # later issue to structure if a matcher turns out to want them.
    class UnConsolidated < Base
      extend T::Sig

      key :un_consolidated
      jurisdiction :un
      authority "United Nations Security Council"
      format :xml

      url :main, "https://scsanctions.un.org/resources/xml/en/consolidated.xml"

      INDIVIDUAL = T.let("INDIVIDUAL", String)
      ENTITY = T.let("ENTITY", String)

      LIST = T.let(Parsers::XmlRecords.new(records: [INDIVIDUAL, ENTITY]), Parsers::XmlRecords)

      # The generation timestamp the UN stamps on the document element. More
      # precise than the Last-Modified header Base falls back to, and it is the
      # string that appears on the UN's own site, so it is the one an examiner
      # asking "which version was this screened against" will recognise.
      GENERATED_AT = T.let("dateGenerated", String)

      # Records that could not be used. Read after #parse; sync orchestration
      # (#34) reports them.
      sig { returns(T::Array[Parsers::Warning]) }
      attr_reader :warnings

      sig { params(args: T.untyped, options: T.untyped).void }
      def initialize(*args, **options)
        super
        @warnings = T.let([], T::Array[Parsers::Warning])
        @unmapped = T.let([], T::Array[Parsers::Warning])
        @generated_at = T.let(nil, T.nilable(String))
      end

      sig { override.params(raw: T.untyped).returns(T::Array[Entity]) }
      def parse(raw)
        reader = LIST.read(raw)
        entities = build(reader)
        @generated_at = reader.root[GENERATED_AT]
        @warnings = reader.warnings + @unmapped
        entities
      end

      sig { override.returns(T.nilable(String)) }
      def source_version = @generated_at || super

      private

      sig { params(reader: Parsers::XmlRecords::Reader).returns(T::Array[Entity]) }
      def build(reader)
        @unmapped = []
        reader.filter_map do |node|
          record = Record.new(node)
          entity = record.entity
          entity.nil? ? note_nameless(node) : entity
        end
      end

      # A record with no name cannot be screened against and is never what the
      # Committee meant to publish. None of the 1,011 published today is
      # nameless; the warning exists so that the day one is, it is visible
      # rather than absent.
      sig { params(node: Parsers::XmlRecords::Record).returns(NilClass) }
      def note_nameless(node)
        @unmapped << Parsers::Warning.new(
          line: node.line,
          message: "<#{node.name}> #{node["DATAID"].inspect} has no name and was skipped"
        )
        nil
      end
    end
  end
end

require "active_sanction/sources/un_consolidated/record"

ActiveSanction::Sources.register(ActiveSanction::Sources::UnConsolidated)
