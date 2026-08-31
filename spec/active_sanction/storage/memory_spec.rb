# frozen_string_literal: true

RSpec.describe ActiveSanction::Storage::Memory do
  def entity(source, ref)
    ActiveSanction::Entity.new(
      source: source, source_ref: ref, type: :individual,
      names: [ActiveSanction::Name.new(value: "AL ZAWAHIRI, Aiman", kind: :primary)]
    )
  end

  def snapshot(source, refs = %w[2674])
    ActiveSanction::Snapshot.new(source: source, entities: refs.map { |ref| entity(source, ref) })
  end

  let(:store) { described_class.new }
  let(:ofac) { snapshot(:ofac_sdn) }
  let(:un) { snapshot(:un_consolidated) }

  it_behaves_like "a storage adapter"

  describe "seeding" do
    it "takes the snapshots a caller already has" do
      expect(described_class.new([ofac, un]).sources).to eq(%i[ofac_sdn un_consolidated])
    end

    it "takes a single snapshot without an array around it" do
      expect(described_class.new(ofac).read_snapshot(:ofac_sdn)).to eq(ofac)
    end

    it "does not go on sharing the caller's array" do
      given = [ofac]
      seeded = described_class.new(given)
      given << un

      expect(seeded.sources).to eq([:ofac_sdn])
    end

    it "refuses a seed that is not a snapshot" do
      expect { described_class.new([ofac.to_h]) }.to raise_error(ArgumentError, /Snapshot/)
    end
  end

  describe "what it holds" do
    # Snapshots freeze themselves, so there is nothing to copy: the object
    # handed back is the object that was stored, and a caller cannot edit the
    # list under the store.
    it "hands back the snapshot object it was given" do
      store.write_snapshot(ofac)

      expect(store.read_snapshot(:ofac_sdn)).to be(ofac)
    end

    it "reports how many lists it holds" do
      store.write_snapshot(ofac)
      store.write_snapshot(un)

      expect(store.size).to eq(2)
    end

    it "starts empty" do
      expect(store).to be_empty
    end

    it "says what it holds when inspected" do
      store.write_snapshot(ofac)

      expect(store.inspect).to eq("#<ActiveSanction::Storage::Memory ofac_sdn>")
    end

    it "says so when it holds nothing" do
      expect(store.inspect).to eq("#<ActiveSanction::Storage::Memory (nothing)>")
    end
  end

  # A web process screens on many threads while a scheduled sync replaces a
  # list under them. What must not happen is a reader seeing the hash mid-write
  # or a write being lost; a reader holding the previous snapshot and finishing
  # against it is correct, and is why snapshots are immutable.
  describe "being written and read at once" do
    it "loses no write" do
      writers = (1..20).map do |index|
        Thread.new { store.write_snapshot(snapshot(:"source_#{index}")) }
      end
      writers.each(&:join)

      expect(store.size).to eq(20)
    end

    it "never hands a reader a half-replaced list" do
      store.write_snapshot(snapshot(:ofac_sdn, %w[2674 1234]))
      reader = Thread.new { 200.times.map { store.read_snapshot(:ofac_sdn).entities.size } }
      100.times { store.write_snapshot(snapshot(:ofac_sdn, %w[2674 1234])) }

      expect(reader.value.uniq).to eq([2])
    end
  end
end
