# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "set"

module ActiveSanction
  module Parsers
    # Joins one primary file to any number of child files on a shared column.
    #
    # Sanctions publishers routinely split one logical record across several
    # files. OFAC is the extreme case: an entity's name is in SDN.CSV, its
    # aliases are in ALT.CSV and its addresses are in ADD.CSV, and all three
    # are keyed on `ent_num`. None of the three means anything alone.
    #
    #   join = ActiveSanction::Parsers::Join.new(
    #     on: :ent_num, aliases: ALT.read(raw[:alt]), addresses: ADD.read(raw[:add])
    #   )
    #
    #   join.each(SDN.read(raw[:sdn])) do |row, related|
    #     related[:aliases]     # => [Row, ...] -- always an Array, never nil
    #     related[:addresses]   # => [Row, ...]
    #   end
    #
    # ### What streams and what does not
    #
    # The primary file streams: one row at a time, and the caller decides what
    # to keep. The child files are indexed, which means they are held in memory
    # for the length of the join.
    #
    # That asymmetry is not a shortcut, it is the only honest option. A join
    # can stream both sides only if both are sorted on the key, and a
    # publisher's sort order is not something to bet a parse on -- OFAC's files
    # happen to arrive sorted today, and nothing says they will next quarter. So
    # the smaller side is indexed and the larger side streams: for OFAC that is
    # ~45k child rows resident while 19,321 primary rows pass through, which is
    # a few tens of megabytes and entirely affordable. A source whose child
    # files are genuinely too large for that wants a different strategy, and
    # should say so rather than discovering it here.
    #
    # ### Orphans
    #
    # A child row whose key matches no primary row is dropped and counted. It
    # is worth counting: a nonzero orphan count after a sync usually means the
    # three files were downloaded at different moments and do not describe the
    # same version of the list, which is a data problem no amount of careful
    # parsing fixes.
    class Join
      extend T::Sig

      # `warnings` gathers every complaint from every file in the join, primary
      # first, and `orphans` counts the child rows that matched nothing. Both
      # are populated by #each, since that is when the files are actually read.
      sig { returns(Symbol) }
      attr_reader :on

      # The child readers, by the name the caller gave each one; that name is
      # what #each yields them back under.
      sig { returns(T::Hash[Symbol, T.untyped]) }
      attr_reader :children

      sig { returns(T::Hash[Symbol, Integer]) }
      attr_reader :orphans

      sig { returns(T::Array[Warning]) }
      attr_reader :warnings

      sig { params(on: T.untyped, children: T.untyped).void }
      def initialize(on:, **children)
        raise InvalidArgument, "a join needs at least one child reader" if children.empty?

        @on = T.let(on.to_sym, Symbol)
        @children = T.let(children, T::Hash[Symbol, T.untyped])
        @orphans = T.let({}, T::Hash[Symbol, Integer])
        @warnings = T.let([], T::Array[Warning])
      end

      # Yields each primary row with its related child rows. Returns an
      # Enumerator without a block, so `join.each(rows).lazy` works.
      #
      # Re-running rebuilds the indexes rather than reusing them, because the
      # readers reset their own warnings on re-enumeration and a join that kept
      # a stale index would report a first pass's problems against a second
      # pass's rows.
      sig { params(primary: T.untyped, block: T.untyped).returns(T.untyped) }
      def each(primary, &block)
        return enum_for(:each, primary) unless block

        indexes = build_indexes
        matched = Hash.new { |hash, name| hash[name] = Set.new }
        primary.each { |row| block.call(row, related(indexes, matched, row.fetch(on))) }
        @warnings = collect_warnings(primary)
        count_orphans(indexes, matched)
        self
      end

      sig { returns(String) }
      def inspect = "#<#{self.class} on=#{on.inspect} children=#{children.keys.join(", ")}>"

      private

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def build_indexes
        children.transform_values { |reader| index(reader) }
      end

      # Rows filed under their key, in the order the publisher wrote them --
      # OFAC's `alt_num` ordering is the closest thing its aliases have to a
      # priority, so it must survive the join.
      sig { params(reader: T.untyped).returns(T::Hash[T.untyped, T::Array[T.untyped]]) }
      def index(reader)
        table = Hash.new { |hash, key| hash[key] = [] }
        reader.each do |row|
          key = row.fetch(on)
          next if key.nil?

          table[key] << row
        end
        table
      end

      # Also records that the key was seen, which is what makes a child row
      # left over at the end of the pass an orphan rather than just unvisited.
      sig do
        params(indexes: T::Hash[Symbol, T.untyped], matched: T.untyped, key: T.untyped)
          .returns(T::Hash[Symbol, T::Array[T.untyped]])
      end
      def related(indexes, matched, key)
        indexes.to_h do |name, table|
          matched[name] << key unless key.nil?
          [name, key.nil? ? [] : table.fetch(key, [])]
        end
      end

      sig { params(indexes: T::Hash[Symbol, T.untyped], matched: T.untyped).void }
      def count_orphans(indexes, matched)
        @orphans = indexes.to_h do |name, table|
          [name, table.except(*matched[name]).values.sum(&:size)]
        end
      end

      sig { params(primary: T.untyped).returns(T::Array[Warning]) }
      def collect_warnings(primary)
        (primary.warnings + children.values.flat_map(&:warnings)).freeze
      end
    end
  end
end
