# frozen_string_literal: true

require "English"

ActiveRecordDatabase.load!

RSpec.describe ActiveSanction::Storage::ActiveRecord do
  # A fresh in-memory database per store, which is what makes two stores in one
  # example independent -- the same thing Dir.mktmpdir does for the filesystem
  # adapter. The schema comes from the generator's own migration template.
  def fresh_store
    ActiveRecordDatabase.reset!
    described_class.new
  end

  it_behaves_like "a storage adapter" do
    def build_store = fresh_store
  end

  let(:store) { fresh_store }
  let(:row) { described_class::Row }

  def entity(ref, names: nil)
    ActiveSanction::Entity.new(
      source: :ofac_sdn, source_ref: ref, type: :individual,
      names: names || [ActiveSanction::Name.new(value: "AL ZAWAHIRI #{ref}, Aiman", kind: :primary)],
      addresses: [ActiveSanction::Address.new(country: "EG", city: "Cairo")],
      identifiers: [ActiveSanction::Identifier.new(kind: :passport, value: "AB-#{ref} 456", country: "EG",
                                                   issued_on: ActiveSanction::PartialDate.parse("2004-06-01"))],
      dates_of_birth: [ActiveSanction::PartialDate.parse("1951-06-19")],
      nationalities: %w[EG], programs: %w[SDGT],
      listed_on: ActiveSanction::PartialDate.parse("2001-09-23"), remarks: "DOB 19 Jun 1951"
    )
  end

  def snapshot(refs, source: :ofac_sdn)
    ActiveSanction::Snapshot.new(source: source, entities: refs.map { |ref| entity(ref) },
                                 fetched_at: Time.utc(2026, 8, 28, 9, 30, 0), source_version: "2026-08-28")
  end

  # Every statement the block sent to the database, which is how the two
  # acceptance criteria about *how* a list is written get checked rather than
  # asserted in a comment.
  def statements(&)
    captured = []
    subscriber = ->(*, payload) { captured << payload[:sql] }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record", &)
    captured
  end

  # A replacement write that cannot finish, swallowed: what the example after
  # it cares about is the state the database was left in, not the exception.
  def failed_write
    store.write_snapshot(snapshot(%w[9999]))
  rescue ActiveRecord::StatementInvalid
    nil
  end

  def inserts(&) = statements(&).grep(/\AINSERT/i)

  describe "the prefilter key" do
    it "folds case, diacritics and punctuation and nothing else" do
      expect(described_class.prefilter_key("Ayman  al-ẒAWĀHIRĪ, Dr.")).to eq("ayman al zawahiri dr")
    end

    it "leaves a key a database can index" do
      expect(described_class.prefilter_key("a" * 900).length).to eq(described_class::PREFILTER_KEY_LIMIT)
    end
  end

  describe "prefiltering" do
    before { store }

    # The whole point of the database adapter: narrowing 19,015 records to a
    # few hundred with an indexed equality probe, before any of them are
    # loaded. A key a query cannot rebuild is an index nothing can use.
    it "files a name under a key a caller can rebuild from a differently written query" do
      store.write_snapshot(ActiveSanction::Snapshot.new(
                             source: :ofac_sdn,
                             entities: [entity("1", names: [ActiveSanction::Name.new(value: "Ayman al-Ẓawāhirī")])]
                           ))

      expect(row::Name.matching("  AYMAN  AL ZAWAHIRI!  ").pluck(:value)).to eq(["Ayman al-Ẓawāhirī"])
    end

    it "finds a document written with different punctuation than it was published with" do
      store.write_snapshot(snapshot(%w[2674]))

      expect(row::Identifier.matching("ab2674456").pluck(:value)).to eq(["AB-2674 456"])
    end

    it "scopes to one list, so a host can prefilter the list it means to screen against" do
      store.write_snapshot(snapshot(%w[2674]))
      store.write_snapshot(snapshot(%w[2674], source: :un_consolidated))

      expect(row::Name.where(snapshot_id: row::Snapshot.find_by(source: "ofac_sdn").id).count).to eq(1)
    end

    it "is indexed, which is the only reason to store it" do
      indexed = ActiveRecordDatabase.connection.indexes("active_sanction_names").map(&:columns)

      expect(indexed).to include(%w[normalized_value])
    end
  end

  describe "writing in bulk" do
    # 19,015 entities and some 65,000 rows hanging off them is not work to do
    # one INSERT at a time, and "we used insert_all" is only true until someone
    # adds a callback that quietly makes it false.
    it "writes a whole list in one statement per table" do
      expect(inserts { store.write_snapshot(snapshot((1..300).map(&:to_s))) }.size).to eq(5)
    end

    it "splits a list larger than the batch size" do
      ActiveRecordDatabase.reset!
      small = described_class.new(batch_size: 100)

      expect(inserts { small.write_snapshot(snapshot((1..300).map(&:to_s))) }.size).to eq(13)
    end

    it "stores every row of every child table" do
      store.write_snapshot(snapshot((1..300).map(&:to_s)))
      counted = [row::Entity, row::Name, row::Address, row::Identifier].map(&:count)

      expect(counted).to eq([300, 300, 300, 300])
    end

    it "refuses a batch size that is not a number of rows" do
      expect { described_class.new(batch_size: 0) }.to raise_error(ActiveSanction::ConfigurationError, /at least 1/)
    end
  end

  # Row::Name is the third of the four bulk inserts a write performs, so a
  # failure there lands with the snapshot row and all of its entities already
  # written -- the half-updated list the transaction exists to prevent.
  describe "a write that dies partway through" do
    before do
      store.write_snapshot(snapshot(%w[2674 1234]))
      allow(row::Name).to receive(:insert_all).and_raise(ActiveRecord::StatementInvalid, "disk full")
    end

    it "gives up rather than reporting a list it did not store" do
      expect { store.write_snapshot(snapshot(%w[9999])) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    # The acceptance criterion the transaction exists for: there is no
    # half-updated state to inspect, and none to screen against.
    it "leaves the list that was there before it" do
      previous = store.read_snapshot(:ofac_sdn)
      failed_write

      expect(store.read_snapshot(:ofac_sdn)).to eq(previous)
    end

    it "leaves behind no rows of the list it could not finish" do
      failed_write

      expect(row::Entity.distinct.count(:snapshot_id)).to eq(1)
    end
  end

  # Four tables that may have nothing in them for a given record, on a write
  # path whose whole job is bulk inserts. An `insert_all` of an empty list is
  # the sort of thing that raises in one database adapter and not another.
  describe "a record with nothing hanging off it" do
    let(:bare) do
      ActiveSanction::Snapshot.new(source: :un_consolidated,
                                   entities: [ActiveSanction::Entity.new(source: :un_consolidated, source_ref: "X",
                                                                         type: :vessel)])
    end

    it "stores a record carrying no names, addresses or identifiers" do
      store.write_snapshot(bare)

      expect(store.read_snapshot(:un_consolidated).entities.map(&:to_h)).to eq(bare.entities.map(&:to_h))
    end

    # Not the same state as a source that was never synced, and the difference
    # is the one thing this library cannot afford to get wrong.
    it "stores a list with nobody on it as a list rather than as an absence" do
      empty = ActiveSanction::Snapshot.new(source: :ofac_sdn, entities: [])
      store.write_snapshot(empty)

      expect(store.read_snapshot(:ofac_sdn)).to eq(empty)
    end
  end

  describe "replacing a list" do
    before { store.write_snapshot(snapshot(%w[2674 1234])) }

    it "leaves no orphaned children behind" do
      store.write_snapshot(snapshot(%w[9999]))

      expect(row::Name.count).to eq(1)
    end

    it "keeps one snapshot row per source" do
      store.write_snapshot(snapshot(%w[9999]))

      expect(row::Snapshot.count).to eq(1)
    end
  end

  describe "a stored list that is not what it says it is" do
    before { store.write_snapshot(snapshot(%w[2674 1234])) }

    # Every one of these is a way of losing records that raises nothing and
    # leaves something list-shaped behind. The checksum is what turns them into
    # an exception instead of a clean screening report.
    it "refuses to return a list a row was deleted from" do
      row::Name.where(entity_id: row::Entity.first.id).delete_all

      expect { store.read_snapshot(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::CorruptSnapshot)
    end

    it "refuses to return a list an entity was deleted from" do
      row::Entity.where(id: row::Entity.first.id).delete_all

      expect { store.read_snapshot(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::CorruptSnapshot)
    end

    it "refuses to return a list a column was edited in" do
      row::Name.where(id: row::Name.first.id).update_all(value: "SOMEBODY ELSE")

      expect { store.read_snapshot(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::CorruptSnapshot, /re-sync/)
    end

    it "refuses to return a list written under a schema this gem cannot read" do
      row::Snapshot.update_all(schema_version: ActiveSanction::Snapshot::SCHEMA_VERSION + 1)

      expect { store.read_snapshot(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::UnsupportedSchema, /Upgrade/)
    end

    # Before a record is read, because a newer schema will usually deserialize
    # into records missing whatever it added and no other symptom.
    it "checks the schema version without reading the list" do
      row::Snapshot.update_all(schema_version: 99)

      expect { store.read_snapshot(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::UnsupportedSchema)
    end
  end

  describe "a database the migration has not been run against" do
    before do
      store
      ActiveRecordDatabase::TABLES.each { |table| ActiveRecordDatabase.connection.drop_table(table) }
    end

    # A bare `no such table` sends an operator looking for a bug in the gem.
    # This is a misconfigured installation and has a different fix.
    it "says which fix it needs" do
      expect { store.sources }.to raise_error(ActiveSanction::ConfigurationError, /db:migrate/)
    end

    it "is not reported as installed" do
      expect(described_class).not_to be_installed
    end
  end

  # Rails' generator machinery needs railties, which this gem does not carry
  # even in development -- it would put a native-extension build in the way of
  # a suite that deliberately has none. So the generator's body is not executed
  # here; what is checked is the seam between it and the template, which is
  # where a rename or a stray interpolation would break it in a host
  # application rather than in CI. The template's *contents* are covered by
  # every other example in this file, which runs against the schema it builds.
  describe "the generator" do
    let(:source) { File.read("lib/generators/active_sanction/install/install_generator.rb") }

    it "copies a template that is there to copy" do
      expect(source).to include(File.basename(ActiveRecordDatabase::TEMPLATE))
    end

    it "asks the template for nothing Rails' migration_template does not supply" do
      interpolated = File.read(ActiveRecordDatabase::TEMPLATE).scan(/<%=\s*([a-z_]+)/).flatten.uniq

      expect(interpolated).to contain_exactly("migration_class_name", "migration_version")
    end
  end

  describe "the migration the generator copies" do
    before { store }

    it "creates every table the adapter reads" do
      expect(ActiveRecordDatabase.connection.tables).to include(*ActiveRecordDatabase::TABLES)
    end

    # One stored list per source, enforced by the database and not by the
    # adapter alone: two rows for one source would mean screening against
    # whichever the planner happened to return.
    it "allows one snapshot per source" do
      expect(ActiveRecordDatabase.connection.indexes("active_sanction_snapshots"))
        .to include(an_object_having_attributes(columns: %w[source], unique: true))
    end

    it "indexes the children by the list they belong to" do
      indexed = ActiveRecordDatabase.connection.indexes("active_sanction_addresses").map(&:columns)

      expect(indexed).to include(%w[snapshot_id])
    end
  end

  # The acceptance criterion that cannot be checked from inside a suite that
  # has already loaded ActiveRecord, so it is checked in a child process that
  # has not.
  describe "loading without ActiveRecord" do
    def ruby(script)
      command = [RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__), "-e", script]
      output = IO.popen(command, err: %i[child out], &:read)
      raise "child process failed:\n#{output}" unless $CHILD_STATUS.success?

      output.strip
    end

    it "loads, and screens, with ActiveRecord absent" do
      script = <<~RUBY
        require "active_sanction"
        store = ActiveSanction::Storage::Memory.new
        store.write_snapshot(ActiveSanction::Snapshot.new(source: :ofac_sdn, entities: []))
        puts [defined?(::ActiveRecord), ActiveSanction::Storage.const_defined?(:ActiveRecord, false),
              store.sources].inspect
      RUBY

      expect(ruby(script)).to eq("[nil, false, [:ofac_sdn]]")
    end

    it "loads the adapter when the host required ActiveRecord first" do
      script = <<~RUBY
        require "active_record"
        require "active_sanction"
        puts ActiveSanction::Storage.const_defined?(:ActiveRecord, false)
      RUBY

      expect(ruby(script)).to eq("true")
    end

    # The Rails order: ActiveSupport is loaded long before ActiveRecord::Base,
    # so the guard has to book itself onto the hook rather than test a constant
    # once and give up.
    it "loads the adapter when ActiveRecord arrives after the library" do
      script = <<~RUBY
        require "active_support"
        require "active_sanction"
        before = ActiveSanction::Storage.const_defined?(:ActiveRecord, false)
        require "active_record"
        ActiveRecord::Base
        puts [before, ActiveSanction::Storage.const_defined?(:ActiveRecord, false)].inspect
      RUBY

      expect(ruby(script)).to eq("[false, true]")
    end
  end
end
