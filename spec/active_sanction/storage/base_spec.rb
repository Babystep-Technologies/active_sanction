# frozen_string_literal: true

RSpec.describe ActiveSanction::Storage::Base do
  def entity(source, ref)
    ActiveSanction::Entity.new(
      source: source, source_ref: ref, type: :individual,
      names: [ActiveSanction::Name.new(value: "AL ZAWAHIRI, Aiman", kind: :primary)]
    )
  end

  def snapshot(source, refs = %w[2674])
    ActiveSanction::Snapshot.new(source: source, entities: refs.map { |ref| entity(source, ref) },
                                 fetched_at: Time.utc(2026, 8, 28, 9, 30, 0))
  end

  let(:abstract) { Class.new(described_class).new }

  # Everything Base derives is derived from the four methods an adapter writes,
  # so the derived half is exercised through the simplest possible adapter that
  # writes them -- which is Memory, counting what it was asked to read.
  let(:counting) do
    Class.new(ActiveSanction::Storage::Memory) do
      def reads = @reads ||= []

      def read_snapshot(source)
        reads << source.to_sym
        super
      end
    end
  end
  let(:store) { counting.new([snapshot(:ofac_sdn), snapshot(:un_consolidated), snapshot(:canada_sema)]) }

  describe "what an adapter has to write" do
    it "says so when #write_snapshot is missing" do
      expect { abstract.write_snapshot(snapshot(:ofac_sdn)) }
        .to raise_error(ActiveSanction::UnsupportedError, /must implement #write_snapshot/)
    end

    it "says so when #read_snapshot is missing" do
      expect do
        abstract.read_snapshot(:ofac_sdn)
      end.to raise_error(ActiveSanction::UnsupportedError, /must implement #read_snapshot/)
    end

    it "says so when #delete_snapshot is missing" do
      expect { abstract.delete_snapshot(:ofac_sdn) }
        .to raise_error(ActiveSanction::UnsupportedError, /must implement #delete_snapshot/)
    end

    it "says so when #sources is missing" do
      expect { abstract.sources }.to raise_error(ActiveSanction::UnsupportedError, /must implement #sources/)
    end
  end

  describe "#each_entity" do
    # The promise the interface makes to the index build (#31), and the reason
    # it is an Enumerator: a caller that wants one entity must not pay for
    # deserializing every list in the store to get it.
    it "reads one list at a time rather than all of them up front" do
      store.each_entity.first

      expect(store.reads).to eq([:canada_sema])
    end

    it "reads the rest when it is asked for the rest" do
      store.each_entity.to_a

      expect(store.reads).to eq(%i[canada_sema ofac_sdn un_consolidated])
    end

    it "reads only the lists it was asked for" do
      store.each_entity(sources: %i[un_consolidated]).to_a

      expect(store.reads).to eq([:un_consolidated])
    end

    # A caller that named its lists gets them in the order it named them,
    # rather than in whatever order the store files them under.
    it "keeps the order the caller named its lists in" do
      entities = store.each_entity(sources: %i[un_consolidated ofac_sdn]).to_a

      expect(entities.map(&:source)).to eq(%i[un_consolidated ofac_sdn])
    end

    it "returns the store when it is given a block" do
      expect(store.each_entity { |_entity| nil }).to be(store)
    end

    # A list deleted between one call and the next is not an error when the
    # caller named no lists: it asked for whatever is stored.
    it "skips a list that disappeared while it was iterating" do
      store.each_entity { |_entity| store.delete_snapshot(:un_consolidated) }

      expect(store.reads).to eq(%i[canada_sema ofac_sdn un_consolidated])
    end
  end

  describe "#fetch_snapshot" do
    it "returns the stored snapshot" do
      expect(store.fetch_snapshot(:ofac_sdn)).to eq(snapshot(:ofac_sdn))
    end

    # The same courtesy the source registry pays a misspelled key: say what is
    # there, because the answer is usually either a typo or a list nobody has
    # synced yet.
    it "lists what is stored when there is nothing under the name asked for" do
      expect { store.fetch_snapshot(:eu_fsf) }
        .to raise_error(ActiveSanction::Storage::MissingSnapshot, /Stored: canada_sema, ofac_sdn, un_consolidated/)
    end

    it "says how to fix it" do
      expect { counting.new.fetch_snapshot(:eu_fsf) }
        .to raise_error(ActiveSanction::Storage::MissingSnapshot, /\(nothing\).*has to be synced/m)
    end
  end

  describe "#snapshot_meta" do
    # Derived from the snapshot for an adapter that keeps nothing cheaper.
    # #24 overrides it with a sidecar file and never opens the list.
    it "describes the stored snapshot" do
      expect(store.snapshot_meta(:ofac_sdn)).to eq(ActiveSanction::Storage::Meta.from_snapshot(snapshot(:ofac_sdn)))
    end

    it "is nil for a list that was never synced" do
      expect(store.snapshot_meta(:eu_fsf)).to be_nil
    end
  end

  describe "the bookkeeping it derives" do
    it "answers #stored? off the source list rather than by reading one" do
      store.stored?(:ofac_sdn)

      expect(store.reads).to be_empty
    end

    it "counts the lists it holds" do
      expect(store.size).to eq(3)
    end

    it "clears by deleting each list, so an adapter has one deletion path" do
      store.clear

      expect(store).to be_empty
    end

    it "returns itself from #clear" do
      expect(store.clear).to be(store)
    end
  end
end
