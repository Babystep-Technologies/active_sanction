# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_record"
require "active_sanction/identifier"
require "active_sanction/storage/base"

module ActiveSanction
  module Storage
    class ActiveRecord < Base
      # The five tables, as ActiveRecord models.
      #
      #   Row::Snapshot     active_sanction_snapshots     one row per synced list
      #   Row::Entity       active_sanction_entities      one row per record on it
      #   Row::Name         active_sanction_names         one row per name variant
      #   Row::Address      active_sanction_addresses
      #   Row::Identifier   active_sanction_identifiers
      #
      # They are namespaced under `Row` rather than named `Snapshot`, `Entity`
      # and so on directly, for a reason that is not stylistic: this file sits
      # inside ActiveSanction, where `Snapshot` and `Entity` already mean the
      # canonical value objects. A model shadowing either would make every
      # unqualified reference in this adapter mean whichever one Ruby's lexical
      # lookup reached first. `Row::Snapshot` is the table; `Snapshot` is the
      # record.
      #
      # ### These are public
      #
      # Unlike Storage::FileSystem's directory layout, which is `@api private`
      # under #62, the schema here is the point of the adapter. An installation
      # that already has a database wants to *query* its lists -- to narrow
      # 19,015 OFAC records to the few hundred worth scoring in Ruby, before
      # any of them are loaded:
      #
      #   Row::Name.matching("Aiman al-Zawahiri").pluck(:entity_id)
      #
      # So the table names, the columns and the associations are part of what
      # this adapter promises, and change under SemVer like anything else
      # public.
      #
      # ### What they deliberately do not do
      #
      # No validations, no callbacks, no `dependent: :destroy`. Every write
      # goes through `insert_all` in batches inside one transaction, which
      # bypasses all three by design: a sync writes 19,015 entities and some
      # 65,000 rows hanging off them, and row-at-a-time saves with callbacks
      # turn seconds into minutes. Deletion is Row::Snapshot#discard!, which
      # drops the children in bulk and then the parent.
      module Row
        # Abstract, so a host can point the sanctions tables at a database
        # other than its application's without touching ActiveRecord::Base:
        #
        #   ActiveSanction::Storage::ActiveRecord::Row::Base.connects_to(database: { writing: :sanctions })
        #
        # Left unconnected here, so it inherits whatever ActiveRecord::Base is
        # connected to -- the right default, because the common case is a Rails
        # application with one database.
        class Base < ::ActiveRecord::Base
          self.abstract_class = true
        end

        # `active_sanction_snapshots` -- one row per synced list, carrying the
        # checksum the whole list is rebuilt against.
        class Snapshot < Base
          extend T::Sig

          self.table_name = "active_sanction_snapshots"

          has_many :entities, class_name: "ActiveSanction::Storage::ActiveRecord::Row::Entity",
                              foreign_key: :snapshot_id, inverse_of: :snapshot, dependent: nil

          # Everything stored for this list, including the row itself, dropped
          # in bulk. `delete_all` rather than `destroy_all`: these rows have no
          # callbacks to run, and instantiating 19,015 of them to throw them
          # away is exactly the cost this adapter exists to avoid.
          #
          # Children first, parent last, so the sequence is one a host that has
          # added foreign keys of its own can also execute.
          sig { void }
          def discard!
            [Name, Address, Identifier, Entity].each { |model| model.where(snapshot_id: id).delete_all }
            self.class.where(id: id).delete_all
          end
        end

        # `active_sanction_entities` -- one row per record on a list, with its
        # names, addresses and identifiers hanging off it.
        class Entity < Base
          self.table_name = "active_sanction_entities"

          belongs_to :snapshot, class_name: "ActiveSanction::Storage::ActiveRecord::Row::Snapshot",
                                inverse_of: :entities

          has_many :names, class_name: "ActiveSanction::Storage::ActiveRecord::Row::Name",
                           foreign_key: :entity_id, inverse_of: :entity, dependent: nil
          has_many :addresses, class_name: "ActiveSanction::Storage::ActiveRecord::Row::Address",
                               foreign_key: :entity_id, inverse_of: :entity, dependent: nil
          has_many :identifiers, class_name: "ActiveSanction::Storage::ActiveRecord::Row::Identifier",
                                 foreign_key: :entity_id, inverse_of: :entity, dependent: nil
        end

        # `active_sanction_names` -- one row per name variant, primary or alias.
        # `normalized_value` is the indexed column the prefilter probes.
        class Name < Base
          self.table_name = "active_sanction_names"

          belongs_to :entity, class_name: "ActiveSanction::Storage::ActiveRecord::Row::Entity",
                              inverse_of: :names

          # The names whose prefilter key is the one this string folds to --
          # the candidate-generation path, and the reason the index exists:
          #
          #   Row::Name.matching("Aiman AL-ZAWAHIRI").pluck(:entity_id)
          #
          # An equality lookup on an indexed column, so it stays a b-tree probe
          # rather than the table scan a `LIKE '%...%'` would be. It prefilters
          # and does not match: it answers "which records are worth scoring in
          # Ruby", never "is this the same person".
          scope :matching, lambda { |value|
            where(normalized_value: ActiveSanction::Storage::ActiveRecord.prefilter_key(value))
          }
        end

        # `active_sanction_addresses` -- one row per published address. Not a
        # prefilter path: addresses on these lists are too partial to probe on.
        class Address < Base
          self.table_name = "active_sanction_addresses"

          belongs_to :entity, class_name: "ActiveSanction::Storage::ActiveRecord::Row::Entity",
                              inverse_of: :addresses
        end

        # `active_sanction_identifiers` -- one row per document number, keyed on
        # ActiveSanction::Identifier#normalized_value so that two publishers'
        # punctuation of the same passport finds each other.
        class Identifier < Base
          self.table_name = "active_sanction_identifiers"

          belongs_to :entity, class_name: "ActiveSanction::Storage::ActiveRecord::Row::Entity",
                              inverse_of: :identifiers

          # The other prefilter path, and the stronger one: an exact document
          # match is near-decisive where a name match never is. Keyed on
          # ActiveSanction::Identifier#normalized_value, which is why OFAC's
          # `AB-123 456` and the UN's `AB123456` find each other.
          scope :matching, lambda { |value|
            where(normalized_value: ActiveSanction::Identifier.new(value: value).normalized_value)
          }
        end

        # Parents before children: the order a write inserts in, and the
        # reverse of the order a delete removes in.
        ALL = T.let([Snapshot, Entity, Name, Address, Identifier].freeze, T::Array[T.untyped])
      end
    end
  end
end
