# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  class Index
    # The mutable half of an immutable index.
    #
    # Index.build is the entry point; this exists so that the thing a web
    # process shares between threads has no `add` on it at all. An index that
    # could be appended to would be an index that has to be locked, and the
    # whole design is that it is not -- see Index on the swap.
    #
    #   builder = ActiveSanction::Index::Builder.new
    #   store.each_entity { |entity| builder.add(entity) }
    #   index = builder.build
    #
    # A builder is single-threaded and single-use. Calling `build` twice
    # returns two indexes over the same entries, which is harmless and not
    # something anything needs.
    class Builder
      extend T::Sig

      sig { void.checked(:tests) }
      def initialize
        @entries = T.let([], T::Array[Entry])
        @tokens = T.let({}, T::Hash[String, T::Array[Integer]])
        @trigrams = T.let({}, T::Hash[String, T::Array[Integer]])
        @phonetics = T.let({}, T::Hash[String, T::Array[Integer]])
      end

      # Every name the entity carries, folded under its type and posted to the
      # three feature spaces.
      #
      # Two names are skipped, and both are skips rather than errors because a
      # government file is not something a build gets to reject:
      #
      # **A name that folds to nothing.** Punctuation, an emoji, a row of
      # dashes -- Form#empty? exists for these. Such a name cannot be scored,
      # so indexing it would only produce candidates no comparison can rank.
      #
      # **A name that folds onto one this entity already has.** OFAC publishes
      # `MUÑOZ HERMANOS S.A.` and `MUNOZ HERMANOS` on one record, and after
      # the fold they are the same string. Keeping both would post the same
      # entity twice under every one of its features, which costs memory on
      # the way in and hands the scorer the same comparison twice on the way
      # out. The publisher's own spelling is not lost: the first one to arrive
      # keeps its Name, and that is what a hit is reported in.
      sig { params(entity: Entity).returns(T.self_type).checked(:tests) }
      def add(entity)
        folded = T.let({}, T::Hash[String, TrueClass])
        entity.names.each do |name|
          form = Normalizer.call(name.value, type: entity.type)
          next if form.empty? || folded.key?(form.value)

          folded[form.value] = true
          index(Entry.new(id: @entries.size, entity: entity, name: name, form: form))
        end
        self
      end

      # The finished index. Everything it holds is frozen on the way in.
      sig { returns(Index).checked(:tests) }
      def build
        Index.new(entries: @entries, tokens: @tokens, trigrams: @trigrams, phonetics: @phonetics)
      end

      private

      sig { params(entry: Entry).void }
      def index(entry)
        @entries << entry
        post(@tokens, Features.tokens(entry.form), entry.id)
        post(@trigrams, Features.trigrams(entry.form), entry.id)
        post(@phonetics, Features.phonetics(entry.form), entry.id)
      end

      # Ids arrive in ascending order because they are assigned in the order
      # entries are made, so a posting list is sorted without ever being
      # sorted. Query relies on that only for determinism; nothing binary
      # searches these.
      sig { params(postings: T::Hash[String, T::Array[Integer]], features: T::Array[String], id: Integer).void }
      def post(postings, features, id)
        features.each { |feature| (postings[feature] ||= []) << id }
      end
    end
  end
end
