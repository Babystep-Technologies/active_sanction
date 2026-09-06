# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  class Index
    # A name the index thinks is worth comparing, and how strongly it thought
    # so.
    #
    #   candidate.name.value  # => "ABBAS, Abu"
    #   candidate.form.value  # => "abbas abu"
    #   candidate.weight      # => 14.82
    #
    # ### `weight` is not a score
    #
    # It is the sum of what the query and this name have in common, each
    # shared feature counted by how rare it is -- see Index for the arithmetic.
    # It says how confident the retrieval was, in a unit with no upper bound
    # and no meaning outside the corpus it was computed against: a long name
    # with rare tokens outranks a short one with common tokens before either
    # has been compared to anything.
    #
    # So it is not comparable with the 0..100 a MatchResult (#33) carries, it
    # is not a threshold anybody should set, and it must never reach a
    # compliance user. Its one job is ordering the cap -- when more names
    # match than the caller asked for, this decides which are dropped -- and
    # it is exposed rather than hidden because that decision is the one thing
    # about this stage that can silently cost a true match, and a caller
    # investigating why a name was missed needs to see where it fell.
    class Candidate
      extend T::Sig

      sig { returns(Entry).checked(:tests) }
      attr_reader :entry

      sig { returns(Float).checked(:tests) }
      attr_reader :weight

      sig { params(entry: Entry, weight: Float).void.checked(:tests) }
      def initialize(entry:, weight:)
        @entry = entry
        @weight = weight
        freeze
      end

      sig { returns(Entity).checked(:tests) }
      def entity = entry.entity

      sig { returns(Name).checked(:tests) }
      def name = entry.name

      sig { returns(Normalizer::Form).checked(:tests) }
      def form = entry.form

      sig { returns(Symbol).checked(:tests) }
      def source = entry.source

      sig { returns(String) }
      def inspect = "#<#{self.class} #{name.value.inspect} weight=#{weight.round(2)}>"
    end
  end
end
