# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/entity"

module ActiveSanction
  class Diff
    # One entity that is on both snapshots and is not the same on each, with
    # the fields that moved.
    #
    #   change.entity    # => Entity, as the new list has it
    #   change.previous  # => Entity, as the old list had it
    #   change.fields    # => [:names, :programs]
    #   change.changes
    #   # => { names:    { added: [#<Name "ZAYDAN, Muhammad">], removed: [] },
    #   #      programs: { added: ["SDGT"], removed: [] } }
    #
    #   puts change      # => ofac_sdn:2674  names +1, programs +1
    #
    # ### Why an amendment is not a delisting plus a listing
    #
    # Governments amend far more records than they publish or withdraw: a
    # passport number is corrected, an alias is added, a program is amended.
    # Reporting one of those as a removal followed by an addition puts a
    # delisting in front of an analyst that never happened -- and a delisting
    # is the entry a compliance team acts on, since it is the one that lets a
    # customer back through the door. So the two snapshots are joined by entity
    # id and only what actually moved is reported, which is what makes id
    # stability a conformance requirement for every adapter (#16) rather than a
    # nicety.
    #
    # ### Collections are compared as sets
    #
    # `names`, `addresses`, `identifiers`, `dates_of_birth`, `nationalities`
    # and `programs` are compared by membership rather than position: a
    # publisher that re-emits the same four aliases in a different order has
    # not amended the record, and a diff that says it has costs somebody a
    # review. Everything else is a scalar and is reported as `from` and `to`.
    #
    # `FIELDS` is derived from Entity::MEMBERS rather than written out, so a
    # field added to the canonical record is compared here without anyone
    # having to remember to add it. A new *collection* still has to be named in
    # COLLECTIONS -- until it is, it is compared whole, which is a coarse
    # answer rather than a silently missing one.
    #
    # Instances are frozen on construction and compare by value.
    class Change
      extend T::Sig

      # Compared by membership. See the class comment.
      COLLECTIONS = T.let(
        %i[names addresses identifiers dates_of_birth nationalities programs].freeze,
        T::Array[Symbol]
      )

      # Every member of the canonical record except `id`, in the order Entity
      # lays them out. `id` is the key the snapshots were joined on, so it
      # cannot differ here; nothing else is excluded, including `source` --
      # a record whose source moved under a stable id is a bug worth seeing
      # rather than one worth hiding.
      FIELDS = T.let((Entity::MEMBERS - %i[id]).freeze, T::Array[Symbol])

      # How much of a scalar's value a summary line prints before it truncates.
      # Remarks are prose and run to paragraphs.
      DISPLAY_WIDTH = T.let(40, Integer)

      # The entity as the new snapshot has it.
      sig { returns(T.untyped) }
      attr_reader :entity

      # The entity as the old snapshot had it.
      sig { returns(T.untyped) }
      attr_reader :previous

      # Field to detail, in Entity's member order. A collection field carries
      # `{ added:, removed: }` and a scalar `{ from:, to: }`.
      sig { returns(T::Hash[Symbol, T::Hash[Symbol, T.untyped]]) }
      attr_reader :changes

      # The change between two versions of one entity, or nil when they say the
      # same thing. Nil rather than an empty change: "this record was amended"
      # and "this record was re-published unchanged" are different answers, and
      # only one of them is worth an analyst's time.
      sig { params(previous: T.untyped, current: T.untyped).returns(T.nilable(T.attached_class)) }
      def self.between(previous, current)
        changes = FIELDS.each_with_object({}) do |field, found|
          detail = compare(field, previous.public_send(field), current.public_send(field))
          found[field] = detail if detail
        end
        changes.empty? ? nil : new(previous: previous, entity: current, changes: changes)
      end

      # What moved in one field, or nil if nothing did.
      sig { params(field: Symbol, before: T.untyped, after: T.untyped).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
      def self.compare(field, before, after)
        return nil if before == after
        return { from: before, to: after }.freeze unless COLLECTIONS.include?(field)

        added = after - before
        removed = before - after
        # Equal as sets, unequal as arrays: the publisher reordered them.
        return nil if added.empty? && removed.empty?

        { added: added.freeze, removed: removed.freeze }.freeze
      end
      private_class_method :compare

      sig { params(previous: T.untyped, entity: T.untyped, changes: T.untyped).void }
      def initialize(previous:, entity:, changes:)
        @previous = T.let(previous, T.untyped)
        @entity = T.let(entity, T.untyped)
        @changes = T.let(changes.freeze, T::Hash[Symbol, T::Hash[Symbol, T.untyped]])
        freeze
      end

      # The id both versions share, which is the whole reason this is one
      # record rather than two.
      sig { returns(String) }
      def id = entity.id

      sig { returns(T::Array[Symbol]) }
      def fields = changes.keys

      sig { params(field: T.untyped).returns(T::Boolean) }
      def changed?(field) = changes.key?(field.to_sym)

      # What moved in one field, or nil if that field did not.
      sig { params(field: T.untyped).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
      def [](field) = changes[field.to_sym]

      # JSON-ready: every value object is serialized the way the snapshot
      # serializes it, so a consumer that already reads entities can read a
      # change without a second vocabulary.
      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h
        {
          id: id,
          entity: entity.to_h,
          previous: previous.to_h,
          changes: changes.transform_values { |detail| detail.transform_values { |value| serialize(value) } }
        }
      end

      # One line, for the summary a human reads:
      #
      #   ofac_sdn:2674  names +1 -1, programs +1, remarks "..." -> "..."
      sig { returns(String) }
      def summary = fields.map { |field| describe(field) }.join(", ")

      sig { returns(String) }
      def to_s = "#{id}  #{summary}"

      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.instance_of?(self.class)

        to_h == other.to_h
      end
      alias eql? ==

      sig { returns(Integer) }
      def hash = [self.class, to_h].hash

      sig { returns(String) }
      def inspect = "#<#{self.class} #{self}>"

      private

      sig { params(field: Symbol).returns(String) }
      def describe(field)
        detail = T.must(changes[field])
        return "#{field} #{display(detail[:from])} -> #{display(detail[:to])}" unless COLLECTIONS.include?(field)

        counts = [("+#{detail[:added].size}" unless detail[:added].empty?),
                  ("-#{detail[:removed].size}" unless detail[:removed].empty?)]
        "#{field} #{counts.compact.join(" ")}"
      end

      # A scalar as a summary line prints it. Long prose is truncated, since
      # the question the line answers is which field moved and not what the
      # whole of the new remarks say.
      sig { params(value: T.untyped).returns(String) }
      def display(value)
        return "(none)" if value.nil?

        text = value.to_s
        text.length > DISPLAY_WIDTH ? "#{text[0, DISPLAY_WIDTH]}..." : text
      end

      sig { params(value: T.untyped).returns(T.untyped) }
      def serialize(value)
        case value
        when Array then value.map { |item| serialize(item) }
        when String, Symbol, Numeric, nil, true, false then value
        else value.respond_to?(:to_h) ? value.to_h : value.to_s
        end
      end
    end
  end
end
