# frozen_string_literal: true

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
      # `warnings` gathers every complaint from every file in the join, primary
      # first, and `orphans` counts the child rows that matched nothing. Both
      # are populated by #each, since that is when the files are actually read.
      attr_reader :on, :children, :orphans, :warnings

      def initialize(on:, **children)
        raise ArgumentError, "a join needs at least one child reader" if children.empty?

        @on = on.to_sym
        @children = children
        @orphans = {}
        @warnings = []
      end

      # Yields each primary row with its related child rows. Returns an
      # Enumerator without a block, so `join.each(rows).lazy` works.
      #
      # Re-running rebuilds the indexes rather than reusing them, because the
      # readers reset their own warnings on re-enumeration and a join that kept
      # a stale index would report a first pass's problems against a second
      # pass's rows.
      def each(primary)
        return enum_for(:each, primary) unless block_given?

        indexes = build_indexes
        matched = Hash.new { |hash, name| hash[name] = Set.new }
        primary.each { |row| yield row, related(indexes, matched, row.fetch(on)) }
        @warnings = collect_warnings(primary)
        count_orphans(indexes, matched)
        self
      end

      def inspect = "#<#{self.class} on=#{on.inspect} children=#{children.keys.join(", ")}>"

      private

      def build_indexes
        children.transform_values { |reader| index(reader) }
      end

      # Rows filed under their key, in the order the publisher wrote them --
      # OFAC's `alt_num` ordering is the closest thing its aliases have to a
      # priority, so it must survive the join.
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
      def related(indexes, matched, key)
        indexes.to_h do |name, table|
          matched[name] << key unless key.nil?
          [name, key.nil? ? [] : table.fetch(key, [])]
        end
      end

      def count_orphans(indexes, matched)
        @orphans = indexes.to_h do |name, table|
          [name, table.except(*matched[name]).values.sum(&:size)]
        end
      end

      def collect_warnings(primary)
        (primary.warnings + children.values.flat_map(&:warnings)).freeze
      end
    end
  end
end
