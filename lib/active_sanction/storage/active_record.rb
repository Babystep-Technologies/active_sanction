# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_record"
require "json"
require "active_sanction/configuration"
require "active_sanction/snapshot"
require "active_sanction/storage"
require "active_sanction/storage/base"
require "active_sanction/storage/meta"
require "active_sanction/storage/active_record/row"
require "active_sanction/storage/active_record/reader"
require "active_sanction/storage/active_record/writer"

module ActiveSanction
  module Storage
    # Snapshots in the host application's database.
    #
    #   $ rails generate active_sanction:install && rails db:migrate
    #
    #   store = ActiveSanction::Storage::ActiveRecord.new
    #   store.write_snapshot(ActiveSanction::Sources[:ofac_sdn].new.sync)
    #   store.snapshot_meta(:ofac_sdn).age   # one row read
    #
    # ### Optional means optional
    #
    # ActiveRecord is not a dependency of this gem and must not become one.
    # Nothing requires this file unless a host has already loaded ActiveRecord
    # itself -- see the guard at the bottom of storage.rb -- and the gem is
    # fully usable, including Storage::FileSystem, with ActiveRecord absent.
    # The default adapter costs a directory; this one costs a migration, and it
    # is for an installation that already has a database and wants to *query*
    # its lists, not a prerequisite for using this library.
    #
    # ### What the database buys, and what it does not
    #
    # It buys the prefilter. Scoring 19,015 OFAC records against one name in
    # Ruby is the cost the matcher (#33) wants to avoid paying, and an equality
    # probe on an indexed column narrows that to a few hundred candidates
    # before any of them are loaded:
    #
    #   Row::Name.matching("Aiman al-Zawahiri").pluck(:entity_id)
    #   Row::Identifier.matching("AB-123 456").pluck(:entity_id)
    #
    # It does not buy a different reading model. `each_entity` is inherited
    # from Storage::Base rather than reimplemented as a cursor, and that is a
    # decision rather than an omission: a snapshot's checksum is computed over
    # the whole list, so a store that streamed rows straight to the matcher
    # would be handing it records it cannot prove are all of them. Reading a
    # list here materializes it and verifies it, exactly as the other adapters
    # do. Tens of megabytes is a fine price for that; screening against a list
    # that is quietly missing people is not.
    #
    # ### Writing
    #
    # One transaction per list, and `insert_all` in batches inside it. A sync
    # that dies partway through 19,015 entities rolls back to the list that was
    # there before it -- there is no half-updated state to inspect, and none to
    # screen against. Row-at-a-time saves would be the obvious alternative and
    # are not: 19,015 entities plus some 65,000 rows hanging off them is not
    # work to do one `INSERT` at a time.
    #
    # ### Reading
    #
    # Nothing partial is ever returned. The Snapshot is rebuilt with the
    # checksum stored beside it, so construction re-derives the digest over the
    # records that actually came back and raises CorruptSnapshot when they do
    # not agree -- a row deleted by hand, a write that half landed, a column
    # edited in a console. A schema_version this gem does not know raises
    # UnsupportedSchema before a record is read.
    #
    # ### Concurrency
    #
    # The database's problem, which is the point. A write is one transaction,
    # so a reader sees the list as it was before it or as it is after it, and
    # readers on other processes and other machines get that for free rather
    # than from a rename that only holds within one filesystem.
    class ActiveRecord < Base
      extend T::Sig

      # Snapshot versions this code can read. Anything above the version it
      # writes was produced by a newer gem.
      READABLE_SCHEMA_VERSIONS = T.let(1..Snapshot::SCHEMA_VERSION, T::Range[Integer])

      # Rows per `insert_all`. Big enough that a full OFAC sync is a few dozen
      # statements rather than 19,015, small enough that no single statement is
      # megabytes of SQL a database has to parse in one piece.
      DEFAULT_BATCH_SIZE = T.let(1_000, Integer)

      # What `normalized_value` is declared as, because it is indexed and MySQL
      # will not index an unbounded column. Comfortably past the longest name
      # any of the launch lists publishes.
      PREFILTER_KEY_LIMIT = T.let(512, Integer)

      COMBINING_MARKS = T.let(/\p{Mn}+/, Regexp)
      NON_ALPHANUMERIC = T.let(/[^[:alnum:]]+/, Regexp)

      # The key a name is filed under in `active_sanction_names.normalized_value`
      # and the key a query has to build to find it:
      #
      #   prefilter_key("Aiman  al-ZAWAHIRI!")   # => "aiman al zawahiri"
      #   prefilter_key("Ayman al-Ẓawāhirī")     # => "ayman al zawahiri"
      #
      # Deliberately crude, and deliberately not the matcher's normalizer
      # (#26). Its only job is candidate generation, where the cost of the two
      # kinds of error is wildly asymmetric: a key that collides too eagerly
      # costs a few extra records to score in Ruby, and a key that misses costs
      # a sanctioned person who never reaches the scorer at all. So it folds
      # width and diacritics, cases down, and reduces everything that is not
      # alphanumeric to a single space -- and it stops there. It does not
      # transliterate, drop legal forms (#27), or reorder tokens; those change
      # what a name *means* and belong where a human can see the decision.
      #
      # Because it is stored, changing this fold makes the stored keys stale.
      # A release that changes it will say so, and the fix is a re-sync.
      sig { params(value: T.untyped).returns(String) }
      def self.prefilter_key(value)
        folded = value.to_s.unicode_normalize(:nfkd).gsub(COMBINING_MARKS, "").downcase
        folded.gsub(NON_ALPHANUMERIC, " ").strip.squeeze(" ").slice(0, PREFILTER_KEY_LIMIT).to_s
      end

      # Whether the migration has been run. Not checked on construction: an
      # adapter built in a Rails initializer must not open a connection to say
      # hello, and a host running `rails db:migrate` would then be unable to
      # boot the application that migrates it.
      sig { returns(T::Boolean) }
      def self.installed?
        Row::ALL.all?(&:table_exists?)
      rescue ::ActiveRecord::ActiveRecordError
        false
      end

      # Rows per `insert_all` -- see DEFAULT_BATCH_SIZE.
      sig { returns(Integer) }
      attr_reader :batch_size

      sig { params(batch_size: T.untyped).void }
      def initialize(batch_size: DEFAULT_BATCH_SIZE)
        @batch_size = T.let(batch_size!(batch_size), Integer)
        super()
      end

      # Replaces the source's list inside one transaction: the previous
      # generation is dropped and the new one written, or neither happens.
      sig { override.params(snapshot: T.untyped).returns(Snapshot) }
      def write_snapshot(snapshot)
        stored = snapshot!(snapshot)
        key = source_key!(stored.source)
        connected do
          Row::Base.transaction do
            Row::Snapshot.find_by(source: key.to_s)&.discard!
            Writer.new(create_row(key, stored), stored, batch_size: batch_size).call
          end
        end
        stored
      end

      sig { override.params(source: T.untyped).returns(T.nilable(Snapshot)) }
      def read_snapshot(source)
        row = snapshot_row(source_key!(source))
        return nil if row.nil?

        schema_version!(row)
        build(row)
      end

      # One row read, and no entities. What makes printing how old six lists
      # are six primary-key lookups rather than six full deserializations.
      sig { override.params(source: T.untyped).returns(T.nilable(Meta)) }
      def snapshot_meta(source)
        row = snapshot_row(source_key!(source))
        return nil if row.nil?

        Meta.new(source: row.source, fetched_at: row.fetched_at.to_time, checksum: row.checksum,
                 record_count: row.record_count, schema_version: row.schema_version,
                 source_version: row.source_version)
      end

      sig { override.params(source: T.untyped).returns(T::Boolean) }
      def delete_snapshot(source)
        key = source_key!(source)
        connected do
          Row::Base.transaction do
            row = Row::Snapshot.find_by(source: key.to_s)
            row&.discard!
            !row.nil?
          end
        end
      end

      # Sorted in Ruby rather than by the database, so a summary does not
      # reshuffle itself when the same lists are read through a connection with
      # a different collation.
      sig { override.returns(T::Array[Symbol]) }
      def sources = connected { Row::Snapshot.pluck(:source) }.map(&:to_sym).sort

      private

      sig { params(key: Symbol).returns(T.untyped) }
      def snapshot_row(key) = connected { Row::Snapshot.find_by(source: key.to_s) }

      sig { params(key: Symbol, snapshot: Snapshot).returns(T.untyped) }
      def create_row(key, snapshot)
        Row::Snapshot.create!(source: key.to_s, fetched_at: snapshot.fetched_at, checksum: snapshot.checksum,
                              record_count: snapshot.record_count, schema_version: snapshot.schema_version,
                              source_version: snapshot.source_version)
      end

      # Snapshot recomputes the checksum over the records that came back and
      # refuses to build if it does not match the one stored beside them, which
      # is what turns every way of losing a row into an exception rather than
      # into a clean report.
      sig { params(row: T.untyped).returns(Snapshot) }
      def build(row)
        Reader.new(row).call
      rescue Snapshot::ChecksumMismatch, ArgumentError, TypeError, JSON::ParserError => e
        raise CorruptSnapshot, corrupt(row, e.message)
      end

      # Checked before a record is read, because a snapshot written by a newer
      # gem will usually still deserialize -- into records missing whatever the
      # new version added, with no symptom other than names that stop matching.
      sig { params(row: T.untyped).void }
      def schema_version!(row)
        return if READABLE_SCHEMA_VERSIONS.cover?(row.schema_version)

        raise UnsupportedSchema,
              "the stored #{row.source} list was written under snapshot schema_version " \
              "#{row.schema_version.inspect}; active_sanction #{VERSION} reads " \
              "#{READABLE_SCHEMA_VERSIONS.first}-#{READABLE_SCHEMA_VERSIONS.last}. Upgrade the gem, or delete the " \
              "snapshot and re-sync the source."
      end

      # An un-migrated database is a misconfigured installation, not a corrupt
      # list, and it has a different fix -- so it is worth saying which one it
      # is rather than letting a bare `no such table` reach the caller.
      sig { params(block: T.proc.returns(T.untyped)).returns(T.untyped) }
      def connected(&block)
        block.call
      rescue ::ActiveRecord::StatementInvalid
        raise if self.class.installed?

        raise ConfigurationError,
              "the ActiveSanction storage tables are not in this database. Run " \
              "`rails generate active_sanction:install && rails db:migrate`, or use " \
              "ActiveSanction::Storage::FileSystem, which needs no schema."
      end

      sig { params(value: T.untyped).returns(Integer) }
      def batch_size!(value)
        # `exception: false` answers nil for anything unparseable, which the
        # stdlib RBI does not say -- hence the nilable annotation.
        integer = T.let(Integer(value, exception: false), T.nilable(Integer))
        raise ConfigurationError, "batch_size must be a whole number of rows, got #{value.inspect}" if integer.nil?
        raise ConfigurationError, "batch_size must be at least 1, got #{integer}" unless integer.positive?

        integer
      end

      sig { params(row: T.untyped, detail: String).returns(String) }
      def corrupt(row, detail)
        "the stored #{row.source} list cannot be trusted to be the list it says it is (#{detail}). Nothing partial " \
          "is returned from storage -- delete the snapshot and re-sync the source to replace it."
      end
    end
  end
end
