# frozen_string_literal: true

require "json"
require "active_sanction/entity"
require "active_sanction/snapshot"
require "active_sanction/storage/base"
require "active_sanction/storage/active_record/row"

module ActiveSanction
  module Storage
    class ActiveRecord < Base
      # Turns the rows of one stored list back into a Snapshot.
      #
      # Four queries and no models. Every one of them is a `pluck` against an
      # indexed `snapshot_id`, because the alternative -- instantiating 19,015
      # Row::Entity objects and letting their associations load, or worse, not
      # letting them -- spends the whole cost of ActiveRecord's object graph on
      # data that is about to be turned into different objects anyway.
      #
      # The Snapshot is rebuilt with the checksum that was stored beside it,
      # which makes construction the verification: Snapshot recomputes the
      # digest over the records that actually came back and refuses to build if
      # it does not match. A row deleted by hand, a write that half landed, a
      # column edited in a console -- all of them raise rather than screen a
      # customer against a list that is quietly missing people.
      class Reader
        ENTITY_COLUMNS = %i[
          id external_id source source_ref entity_type dates_of_birth nationalities programs listed_on remarks
        ].freeze

        NAME_COLUMNS = %i[entity_id value kind quality script].freeze
        ADDRESS_COLUMNS = %i[entity_id street city state_province postal_code country note].freeze
        IDENTIFIER_COLUMNS = %i[entity_id kind value country issued_on expires_on note].freeze

        # Identifier members that are stored as JSON and rebuilt as dates.
        IDENTIFIER_DATES = %i[issued_on expires_on].freeze

        def initialize(row)
          @row = row
        end

        def call
          Snapshot.new(
            source: @row.source.to_sym, entities: entities, fetched_at: @row.fetched_at.to_time,
            checksum: @row.checksum, record_count: @row.record_count, schema_version: @row.schema_version,
            source_version: @row.source_version
          )
        end

        private

        def entities
          names = children(Row::Name, NAME_COLUMNS)
          addresses = children(Row::Address, ADDRESS_COLUMNS)
          identifiers = identifier_children
          rows(Row::Entity, ENTITY_COLUMNS).map do |cells|
            entity(cells, names, addresses, identifiers)
          end
        end

        def entity(cells, names, addresses, identifiers)
          key = cells[:id]
          Entity.from_h(
            id: cells[:external_id], source: cells[:source], source_ref: cells[:source_ref],
            type: cells[:entity_type], names: names[key], addresses: addresses[key], identifiers: identifiers[key],
            dates_of_birth: parse(cells[:dates_of_birth]), nationalities: parse(cells[:nationalities]),
            programs: parse(cells[:programs]), listed_on: parse(cells[:listed_on]), remarks: cells[:remarks]
          )
        end

        def identifier_children
          children(Row::Identifier, IDENTIFIER_COLUMNS).transform_values do |list|
            list.map { |member| member.merge(IDENTIFIER_DATES.to_h { |date| [date, parse(member[date])] }) }
          end
        end

        # Every child of every entity on this list, in one query, grouped by
        # the entity they hang off and left in the order they were written.
        def children(model, columns)
          model.where(snapshot_id: @row.id).order(:entity_id, :position).pluck(*columns)
               .group_by(&:first)
               .transform_values { |group| group.map { |cells| columns.drop(1).zip(cells.drop(1)).to_h } }
        end

        def rows(model, columns)
          model.where(snapshot_id: @row.id).order(:position).pluck(*columns).map { |cells| columns.zip(cells).to_h }
        end

        def parse(json) = json.nil? ? nil : JSON.parse(json)
      end
    end
  end
end
