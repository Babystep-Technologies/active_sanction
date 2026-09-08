# frozen_string_literal: true

require "tmpdir"
require "zlib"

RSpec.describe ActiveSanction::Storage::FileSystem do
  around do |example|
    Dir.mktmpdir("active_sanction-storage") do |dir|
      @root = dir
      example.run
    end
  end

  attr_reader :root

  def entity(source, ref)
    ActiveSanction::Entity.new(
      source: source, source_ref: ref, type: :individual,
      names: [ActiveSanction::Name.new(value: "AL ZAWAHIRI, Aiman", kind: :primary)],
      identifiers: [ActiveSanction::Identifier.new(kind: :passport, value: ref, country: "EG")],
      dates_of_birth: [ActiveSanction::PartialDate.parse("1951-06-19")],
      remarks: "DOB 19 Jun 1951; POB Egypt"
    )
  end

  def snapshot(source, refs = %w[2674])
    ActiveSanction::Snapshot.new(source: source, entities: refs.map { |ref| entity(source, ref) },
                                 fetched_at: Time.utc(2026, 8, 28, 9, 30, 0), source_version: "2026-08-28")
  end

  let(:store) { described_class.new(root: root) }
  let(:ofac) { snapshot(:ofac_sdn) }
  let(:un) { snapshot(:un_consolidated) }

  def directory(source = :ofac_sdn) = File.join(root, source.to_s)
  def meta_path(source = :ofac_sdn) = File.join(directory(source), "meta.json")
  def list_path(source = :ofac_sdn) = Dir.glob(File.join(directory(source), "snapshot-*.json.gz")).first
  def meta_json(source = :ofac_sdn) = JSON.parse(File.read(meta_path(source)))

  # Each example that needs a second, independent store gets a directory of
  # its own under the one the `around` hook cleans up.
  it_behaves_like "a storage adapter" do
    def build_store = described_class.new(root: Dir.mktmpdir("store", root))
  end

  describe "where it puts things" do
    before { store.write_snapshot(ofac) }

    it "gives each source a directory of its own" do
      store.write_snapshot(un)

      expect(Dir.children(root).sort).to eq(%w[ofac_sdn un_consolidated])
    end

    it "writes the list as gzip" do
      expect(File.binread(list_path).byteslice(0, 2).unpack("C2")).to eq([0x1f, 0x8b])
    end

    it "names the list file after the content it holds" do
      expect(File.basename(list_path)).to eq("snapshot-#{ofac.checksum.tr(":", "-")}.json.gz")
    end

    it "leaves one list file per source" do
      expect(Dir.glob(File.join(directory, "snapshot-*"))).to contain_exactly(list_path)
    end

    it "leaves nothing half-written behind" do
      expect(Dir.glob(File.join(directory, "*.part"))).to be_empty
    end

    # The layout is private (#62); what it holds is the gzipped Snapshot#to_h,
    # which is what makes reading it back a plain from_h.
    it "stores the snapshot's own serialization" do
      expect(JSON.parse(Zlib.gunzip(File.binread(list_path)))).to eq(JSON.parse(JSON.generate(ofac.to_h)))
    end
  end

  # Documented as Meta#to_h's file, so an adapter or a tool that reads one can
  # read the other.
  describe "the meta.json sidecar" do
    before { store.write_snapshot(ofac) }

    it "holds exactly what Meta serializes" do
      expect(meta_json).to eq(JSON.parse(JSON.generate(ActiveSanction::Storage::Meta.from_snapshot(ofac).to_h)))
    end

    it "records the source, the checksum and the record count" do
      expect(meta_json).to include("source" => "ofac_sdn", "checksum" => ofac.checksum, "record_count" => 1)
    end

    it "records when the list was fetched and what the publisher called it" do
      expect(meta_json).to include("fetched_at" => "2026-08-28T09:30:00Z", "source_version" => "2026-08-28")
    end

    it "records the schema the list was written under" do
      expect(meta_json["schema_version"]).to eq(ActiveSanction::Snapshot::SCHEMA_VERSION)
    end

    # The point of the sidecar: an age is printed from a few hundred bytes
    # rather than by inflating and deserializing the whole list.
    it "answers #snapshot_meta without opening the list" do
      FileUtils.rm_f(list_path)

      expect(store.snapshot_meta(:ofac_sdn).record_count).to eq(1)
    end
  end

  describe "reading a corrupted list" do
    before { store.write_snapshot(ofac) }

    it "raises on a truncated file rather than returning the records it could read" do
      path = list_path
      File.binwrite(path, File.binread(path).byteslice(0, 40))

      expect { store.read_snapshot(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::CorruptSnapshot)
    end

    it "raises on bytes that are not gzip at all" do
      File.binwrite(list_path, "not a snapshot")

      expect { store.read_snapshot(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::CorruptSnapshot)
    end

    # A gzip member can be replaced wholesale and still inflate. What catches
    # this is Snapshot re-deriving the checksum from the records that came back.
    it "raises when a record has been edited under a valid gzip wrapper" do
      hash = JSON.parse(Zlib.gunzip(File.binread(list_path)))
      hash["entities"].first["names"].first["value"] = "SOMEBODY ELSE"
      File.binwrite(list_path, Zlib.gzip(JSON.generate(hash)))

      expect { store.read_snapshot(:ofac_sdn) }
        .to raise_error(ActiveSanction::Storage::CorruptSnapshot, /#{Regexp.escape(ofac.checksum)}/)
    end

    it "raises when records have been dropped" do
      store.write_snapshot(snapshot(:ofac_sdn, %w[2674 1234 9999]))
      hash = JSON.parse(Zlib.gunzip(File.binread(list_path)))
      hash["entities"] = hash["entities"].take(1)
      File.binwrite(list_path, Zlib.gzip(JSON.generate(hash)))

      expect { store.read_snapshot(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::CorruptSnapshot)
    end

    # The file inflates, and its own embedded checksum verifies against its own
    # records -- what has come apart is the pair. Only comparing the two
    # catches a generation swapped in under the name of another.
    it "raises when the sidecar names one generation and the file holds another" do
      File.binwrite(list_path, Zlib.gzip(JSON.generate(snapshot(:ofac_sdn, %w[9999]).to_h)))

      expect { store.read_snapshot(:ofac_sdn) }
        .to raise_error(ActiveSanction::Storage::CorruptSnapshot, /meta\.json/)
    end

    it "raises when a list is filed under a source it does not belong to" do
      FileUtils.cp_r(directory, directory(:un_consolidated))

      expect { store.read_snapshot(:un_consolidated) }.to raise_error(ActiveSanction::Storage::CorruptSnapshot,
                                                                      /ofac_sdn/)
    end

    it "names the directory to delete" do
      File.binwrite(list_path, "not a snapshot")

      expect { store.read_snapshot(:ofac_sdn) }.to raise_error(/#{Regexp.escape(directory)}/)
    end
  end

  describe "reading a corrupted sidecar" do
    before { store.write_snapshot(ofac) }

    it "raises when it is not JSON" do
      File.write(meta_path, "{")

      expect { store.snapshot_meta(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::CorruptSnapshot)
    end

    it "raises when it is JSON but not an object" do
      File.write(meta_path, "[]")

      expect { store.snapshot_meta(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::CorruptSnapshot)
    end

    it "raises when a field it needs is missing" do
      File.write(meta_path, JSON.generate(meta_json.tap { |hash| hash.delete("checksum") }))

      expect { store.snapshot_meta(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::CorruptSnapshot)
    end

    # The checksum is joined to a path. Nothing that is not a SHA-256 gets
    # there, whatever the file says.
    it "refuses a checksum that is really a path" do
      File.write(meta_path, JSON.generate(meta_json.merge("checksum" => "sha256:../../../etc/passwd")))

      expect { store.read_snapshot(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::CorruptSnapshot)
    end

    it "raises when the list the sidecar names is not there" do
      FileUtils.rm_f(list_path)

      expect { store.read_snapshot(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::CorruptSnapshot)
    end

    # A corrupt list must not make the store impossible to look at or to
    # repair: `sources`, and so `clear`, read no further than the filename.
    it "still lists the source" do
      File.write(meta_path, "{")

      expect(store.sources).to eq([:ofac_sdn])
    end

    it "still deletes the source" do
      File.write(meta_path, "{")
      store.delete_snapshot(:ofac_sdn)

      expect(store.sources).to be_empty
    end
  end

  describe "a snapshot from a version that does not exist yet" do
    before { store.write_snapshot(ofac) }

    def write_schema_version(version)
      File.write(meta_path, JSON.generate(meta_json.merge("schema_version" => version)))
    end

    # A newer schema will usually still deserialize -- into records missing
    # whatever it added, with a checksum that verifies, and with no symptom
    # other than names that quietly stop matching.
    it "refuses to read it" do
      write_schema_version(ActiveSanction::Snapshot::SCHEMA_VERSION + 1)

      expect { store.read_snapshot(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::UnsupportedSchema)
    end

    it "says what would fix it" do
      write_schema_version(99)

      expect { store.read_snapshot(:ofac_sdn) }.to raise_error(/Upgrade the gem/)
    end

    it "refuses before inflating the list" do
      write_schema_version(99)
      FileUtils.rm_f(list_path)

      expect { store.read_snapshot(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::UnsupportedSchema)
    end

    it "refuses a version that is not a number" do
      write_schema_version("today")

      expect { store.read_snapshot(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::UnsupportedSchema)
    end

    it "refuses one that is missing entirely" do
      File.write(meta_path, JSON.generate(meta_json.tap { |hash| hash.delete("schema_version") }))

      expect { store.read_snapshot(:ofac_sdn) }.to raise_error(ActiveSanction::Storage::UnsupportedSchema)
    end
  end

  # The acceptance criterion this adapter's layout exists to meet: a sync
  # killed at any point either has not happened or has happened completely.
  describe "a write that is interrupted" do
    let(:replacement) { snapshot(:ofac_sdn, %w[2674 1234 9999]) }

    before { store.write_snapshot(ofac) }

    # A second store over the same root, killed part-way through publishing a
    # replacement -- after the new list is on disk, before `meta.json` names it.
    def interrupted_write
      dying = described_class.new(root: root)
      allow(dying).to receive(:commit).and_raise(Interrupt)
      begin
        dying.write_snapshot(replacement)
      rescue Interrupt
        nil
      end
    end

    # The list file goes down under a name nothing else occupies, so the
    # generation already committed is untouched by it.
    it "leaves the previous list readable" do
      interrupted_write

      expect(store.read_snapshot(:ofac_sdn)).to eq(ofac)
    end

    it "leaves the previous list complete, not merely readable" do
      interrupted_write

      expect(store.read_snapshot(:ofac_sdn).entities.map(&:source_ref)).to eq(%w[2674])
    end

    it "keeps the previous sidecar" do
      interrupted_write

      expect(store.snapshot_meta(:ofac_sdn).checksum).to eq(ofac.checksum)
    end

    it "does not publish the list it never committed" do
      interrupted_write

      expect(store.snapshot_meta(:ofac_sdn).record_count).to eq(1)
    end

    it "leaves no truncated file where a reader would look" do
      File.binwrite(File.join(directory, "snapshot-#{replacement.checksum.tr(":", "-")}.json.gz"), "half a li")

      expect(store.read_snapshot(:ofac_sdn)).to eq(ofac)
    end

    # A write killed while the bytes were still going down leaves a `.part`
    # file, which is never a name a reader looks for and which the next write
    # sweeps once it is old enough to be from a dead process.
    it "sweeps a stale .part file on the next write" do
      stale = File.join(directory, "3.abcdef.part")
      File.write(stale, "x")
      File.utime(Time.now - 7200, Time.now - 7200, stale)
      store.write_snapshot(replacement)

      expect(File.exist?(stale)).to be(false)
    end

    it "leaves a .part file a live write may still be holding" do
      fresh = File.join(directory, "4.abcdef.part")
      File.write(fresh, "x")
      store.write_snapshot(replacement)

      expect(File.exist?(fresh)).to be(true)
    end
  end

  describe "replacing a list" do
    it "sweeps the generation it replaced" do
      store.write_snapshot(ofac)
      store.write_snapshot(snapshot(:ofac_sdn, %w[9999]))

      expect(Dir.glob(File.join(directory, "snapshot-*")).size).to eq(1)
    end

    it "keeps the list when the same content is written twice" do
      store.write_snapshot(ofac)
      store.write_snapshot(snapshot(:ofac_sdn))

      expect(store.read_snapshot(:ofac_sdn)).to eq(ofac)
    end

    # A reader that read the sidecar just before a write committed is sent to a
    # file the sweep has since removed. It re-reads rather than reporting the
    # list as gone.
    it "follows a commit that landed between reading the sidecar and opening the list" do
      store.write_snapshot(ofac)
      stale = ActiveSanction::Storage::Meta.from_snapshot(ofac)
      replacement = store.write_snapshot(snapshot(:ofac_sdn, %w[9999]))
      allow(store).to receive(:read_meta).and_return(stale, ActiveSanction::Storage::Meta.from_snapshot(replacement))

      expect(store.read_snapshot(:ofac_sdn)).to eq(replacement)
    end

    it "gives up on a sidecar that still names nothing on the second read" do
      store.write_snapshot(ofac)
      FileUtils.rm_f(list_path)

      expect { store.read_snapshot(:ofac_sdn) }
        .to raise_error(ActiveSanction::Storage::CorruptSnapshot, /is not there/)
    end
  end

  describe "the root directory" do
    it "defaults to the configured storage_dir" do
      ActiveSanction.configure { |c| c.storage_dir = File.join(root, "configured") }

      expect(described_class.new.root).to eq(File.join(root, "configured"))
    ensure
      ActiveSanction.reset!
    end

    it "expands what it is given" do
      expect(described_class.new(root: "~/lists").root).to eq(File.join(Dir.home, "lists"))
    end

    it "does not need to exist to be asked what it holds" do
      expect(described_class.new(root: File.join(root, "absent")).sources).to be_empty
    end

    it "is created on the first write" do
      described_class.new(root: File.join(root, "absent")).write_snapshot(ofac)

      expect(File.directory?(File.join(root, "absent", "ofac_sdn"))).to be(true)
    end

    # Whatever else a user keeps here, only directories named like source keys
    # and holding a committed sidecar are lists.
    it "ignores a directory that is not a stored source" do
      FileUtils.mkdir_p(File.join(root, "notes"))
      FileUtils.mkdir_p(File.join(root, "Not A Key"))
      store.write_snapshot(ofac)

      expect(store.sources).to eq([:ofac_sdn])
    end

    it "ignores a source directory whose write never committed" do
      FileUtils.mkdir_p(directory(:eu_fsf))

      expect(store.sources).to be_empty
    end

    it "says where it is when inspected" do
      expect(store.inspect).to eq("#<ActiveSanction::Storage::FileSystem #{root} (nothing)>")
    end
  end

  # The acceptance criterion, at a size the suite can afford to run on every
  # commit. OFAC's 19,015 records are the same code path with a bigger array.
  describe "a list the size of a real one" do
    let(:big) { snapshot(:ofac_sdn, Array.new(5_000) { |index| format("%05d", index) }) }

    before { store.write_snapshot(big) }

    it "reads back every record, field for field" do
      expect(store.read_snapshot(:ofac_sdn).entities.map(&:to_h)).to eq(big.entities.map(&:to_h))
    end

    it "reads back to the same checksum" do
      expect(store.read_snapshot(:ofac_sdn).checksum).to eq(big.checksum)
    end

    it "compresses it" do
      expect(File.size(list_path)).to be < (JSON.generate(big.to_h).bytesize / 4)
    end
  end
end
