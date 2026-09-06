# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  class Index
    # One indexed name: the entity it belongs to, the name as its publisher
    # wrote it, and the folded form the index and the scorers both work in.
    #
    #   entry.entity.id  # => "ofac_sdn:2674"
    #   entry.name.value # => "ABBAS, Abu"
    #   entry.form.value # => "abbas abu"
    #
    # An entity contributes one entry per name it carries, not one per entity.
    # That is the unit a screening call actually works in: OFAC ships more
    # aliases than primary names, a hit is produced by one specific spelling,
    # and a MatchResult (#33) has to be able to say which. Grouping several
    # entries back onto their entity is the scorer's job and is why `entity`
    # is here rather than an id.
    #
    # Frozen, like everything the index holds -- see Index on why that is the
    # whole point rather than a detail.
    class Entry
      extend T::Sig

      # This entry's position in the index's own array, which is what the
      # posting lists hold. Small integers rather than objects: a corpus of
      # 46,000 names produces upwards of a million postings across the three
      # feature spaces, and an array of Integers is the difference between an
      # index that fits in a web process and one that does not.
      sig { returns(Integer).checked(:tests) }
      attr_reader :id

      sig { returns(Entity).checked(:tests) }
      attr_reader :entity

      sig { returns(Name).checked(:tests) }
      attr_reader :name

      # The name folded under its entity's type, which is what makes the
      # stoplists apply -- `LTD` is dropped from an organization and `SHAYKH`
      # from an individual. Folded once, here, and handed to the scorers as it
      # stands: see Normalizer for why a second fold anywhere is a bug.
      sig { returns(Normalizer::Form).checked(:tests) }
      attr_reader :form

      sig { params(id: Integer, entity: Entity, name: Name, form: Normalizer::Form).void.checked(:tests) }
      def initialize(id:, entity:, name:, form:)
        @id = id
        @entity = entity
        @name = name
        @form = form
        freeze
      end

      # The source the entity came from, which a query may be filtered by and
      # which every hit has to name.
      sig { returns(Symbol).checked(:tests) }
      def source = entity.source

      sig { returns(String) }
      def inspect = "#<#{self.class} #{id} #{name.value.inspect} (#{entity.id})>"
    end
  end
end
