# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/parsers"
require "active_sanction/sources"
require "active_sanction/sources/base"

module ActiveSanction
  module Sources
    # Canada's consolidated sanctions list: everyone named in a schedule to a
    # regulation made under the Special Economic Measures Act, plus the people
    # listed under the Justice for Victims of Corrupt Foreign Officials Act.
    #
    #   snapshot = ActiveSanction::Sources[:canada_sema].new.sync
    #
    # ### One file, one flat record shape
    #
    #   https://www.international.gc.ca/.../sanctions/sema-lmes.xml   2.9 MB
    #
    #     <data-set><record>   5,690 records
    #
    # Every record is the same eleven optional elements with no nesting, which
    # makes this the simplest list the gem reads and the hardest one to give a
    # stable identity to.
    #
    # ### The three things that make this source awkward
    #
    # **No stable identifier.** Global Affairs publishes no id of any kind.
    # What it publishes is where in the law a person appears -- the schedule
    # and the item number within it -- which is scoped per regulation and is
    # renumbered whenever a schedule is amended. Record derives a deterministic
    # synthetic id from it; see Record::SOURCE_REF_PARTS for what goes in and
    # why the name is part of it.
    #
    # **Bilingual tags and values.** Element names pair English and French
    # (`Country-Pays`), and so do the values in three of them. The separator is
    # not one string: countries use ` / ` (`Belarus / Bélarus`) and vessel
    # types and titles use `|` (`Oil Tanker | Navire-citerne`), sometimes with
    # no space and sometimes wrapped across a line. Only those three elements
    # are split; a name is never split, because `Islamic Revolutionary Guard
    # Corps/Corps des Gardiens de la Révolution islamique` and `Victory/Pobeda
    # Political Bloc` are the same punctuation meaning two different things and
    # nothing in the file separates them.
    #
    # **The date element doubles as a ship's build date.** It is named
    # `DateOfBirthOrShipBuildDate-...` and means whichever the record is. A
    # build year is not a date of birth, so a vessel's goes to remarks and its
    # `dates_of_birth` stays empty.
    #
    # ### What a clean Canadian result is worth
    #
    # Less than a clean OFAC one, and a screening policy should know it. Canada
    # publishes no nationality, no address, no place of birth and no document
    # number for any of the 5,690 records: an individual is a surname, given
    # names, a date of birth roughly half the time, and a free-text alias
    # field. There is nothing here to make a name match decisive with, which is
    # the opposite of OFAC, where a passport number usually settles it.
    #
    # ### Aliases, and the comma this adapter refuses to split on
    #
    # 3,195 records carry an `Aliases-Alias` element, which is free text with
    # no declared separator. Semicolons are unambiguous and are split on. Commas
    # are not, and splitting on them manufactures names that match far too much:
    # `Завод "Дагдизель", АО` and `М Инвест, ООО` would each yield a bare
    # Russian legal form as an alias, and `Министерство образования, науки и
    # молодежи Республики Крым` is one ministry, not two. So a comma-joined
    # alias field stays one alias. That costs recall on roughly 300 records
    # whose primary name is published anyway, and it is the cheaper of the two
    # mistakes.
    class CanadaSema < Base
      extend T::Sig

      key :canada_sema
      jurisdiction :ca
      authority "Global Affairs Canada"
      format :xml

      url :main,
          "https://www.international.gc.ca/world-monde/assets/office_docs/" \
          "international_relations-relations_internationales/sanctions/sema-lmes.xml"

      # @api private
      RECORD = T.let("record", String)

      # @api private
      LIST = T.let(Parsers::XmlRecords.new(records: RECORD), Parsers::XmlRecords)

      # Records that could not be used, and fields that could not be read.
      # Read after #parse; sync orchestration (#34) reports them.
      sig { returns(T::Array[Parsers::Warning]) }
      attr_reader :warnings

      sig { params(args: T.untyped, options: T.untyped).void }
      def initialize(*args, **options)
        super
        @warnings = T.let([], T::Array[Parsers::Warning])
        @unmapped = T.let([], T::Array[Parsers::Warning])
      end

      sig { override.params(raw: T.untyped).returns(T::Array[Entity]) }
      def parse(raw)
        reader = LIST.read(raw)
        entities = build(reader)
        @warnings = reader.warnings + @unmapped
        entities
      end

      private

      sig { params(reader: Parsers::XmlRecords::Reader).returns(T::Array[Entity]) }
      def build(reader)
        @unmapped = []
        reader.filter_map do |node|
          record = Record.new(node)
          entity = record.entity
          @unmapped.concat(record.warnings)
          entity.nil? ? note_nameless(node) : entity
        end
      end

      # A record with no name in any of its three name elements cannot be
      # screened against. None of the 5,690 published today is nameless; the
      # warning exists so that the day one is, it is visible rather than absent.
      sig { params(node: Parsers::XmlRecords::Record).returns(NilClass) }
      def note_nameless(node)
        @unmapped << Parsers::Warning.new(
          line: node.line,
          message: "<#{node.name}> at item #{node[Record::ITEM].inspect} has no name and was skipped"
        )
        nil
      end
    end
  end
end

require "active_sanction/sources/canada_sema/record"

ActiveSanction::Sources.register(ActiveSanction::Sources::CanadaSema)
