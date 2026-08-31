# frozen_string_literal: true

require "json"
require "active_sanction/storage/base"
require "active_sanction/storage/active_record/row"

module ActiveSanction
  module Storage
    class ActiveRecord < Base
      # Turns one Snapshot into rows, in batches, with `insert_all`.
      #
      # Called with the `active_sanction_snapshots` row already created and
      # inside the transaction that created it, which is the arrangement the
      # acceptance criterion asks for: a sync that dies partway through 19,015
      # entities rolls back to the list that was there before it, rather than
      # leaving a snapshot row advertising records that are not underneath it.
      #
      # ### Why the entity ids are read back rather than returned
      #
      # A child row needs its parent's primary key, and `insert_all` can return
      # the keys it assigned -- on PostgreSQL and on recent SQLite. MySQL has
      # no `RETURNING`, and an adapter that worked on two of the three
      # databases Rails ships support for would not be worth the word
      # "optional" in the issue. So the entities go in first, and one ordered
      # `pluck` of their ids follows: one extra query per sync, against a
      # method that works everywhere.
      class Writer
        def initialize(row, snapshot, batch_size:)
          @row = row
          @snapshot = snapshot
          @batch_size = batch_size
        end

        def call
          write_entities
          write_children
          @row
        end

        private

        def write_entities
          each_batch { |pairs| insert(Row::Entity, pairs.map { |entity, position| entity_row(entity, position) }) }
        end

        def write_children
          ids = entity_ids
          each_batch { |pairs| write_batch(pairs, ids) }
        end

        def write_batch(pairs, ids)
          insert(Row::Name, pairs.flat_map { |entity, index| name_rows(entity, ids.fetch(index)) })
          insert(Row::Address, pairs.flat_map { |entity, index| address_rows(entity, ids.fetch(index)) })
          insert(Row::Identifier, pairs.flat_map { |entity, index| identifier_rows(entity, ids.fetch(index)) })
        end

        # The list in slices, each entity paired with the position it was
        # written at -- which is the index its primary key sits at in `ids`.
        def each_batch(&) = @snapshot.entities.each_with_index.each_slice(@batch_size, &)

        # Ordered by the column the writer just filled in, so the id at index
        # `n` belongs to the entity written at position `n`.
        def entity_ids = Row::Entity.where(snapshot_id: @row.id).order(:position).pluck(:id)

        def insert(model, rows)
          rows.each_slice(@batch_size) { |slice| model.insert_all(slice) }
        end

        def entity_row(entity, position)
          {
            snapshot_id: @row.id, position: position, external_id: entity.id, source: entity.source.to_s,
            entity_type: entity.type.to_s, source_ref: entity.source_ref,
            dates_of_birth: json(entity.dates_of_birth.map(&:to_h)), nationalities: json(entity.nationalities),
            programs: json(entity.programs), listed_on: json(entity.listed_on&.to_h), remarks: entity.remarks
          }
        end

        def name_rows(entity, entity_id)
          entity.names.each_with_index.map do |name, position|
            {
              entity_id: entity_id, snapshot_id: @row.id, position: position, value: name.value,
              normalized_value: ActiveSanction::Storage::ActiveRecord.prefilter_key(name.value),
              kind: name.kind.to_s, quality: name.quality&.to_s, script: name.script&.to_s
            }
          end
        end

        def address_rows(entity, entity_id)
          entity.addresses.each_with_index.map do |address, position|
            {
              entity_id: entity_id, snapshot_id: @row.id, position: position, street: address.street,
              city: address.city, state_province: address.state_province, postal_code: address.postal_code,
              country: address.country, note: address.note
            }
          end
        end

        def identifier_rows(entity, entity_id)
          entity.identifiers.each_with_index.map do |identifier, position|
            {
              entity_id: entity_id, snapshot_id: @row.id, position: position, kind: identifier.kind.to_s,
              value: identifier.value, normalized_value: identifier.normalized_value, country: identifier.country,
              issued_on: json(identifier.issued_on&.to_h), expires_on: json(identifier.expires_on&.to_h),
              note: identifier.note
            }
          end
        end

        # Nil rather than "[]" or "null" for anything the publisher did not
        # give, which keeps the column readable in a database console and
        # matches what the canonical record means by an absent member: Entity
        # reads a nil collection back as an empty one.
        def json(value)
          return nil if value.nil? || (value.respond_to?(:empty?) && value.empty?)

          JSON.generate(value)
        end
      end
    end
  end
end
