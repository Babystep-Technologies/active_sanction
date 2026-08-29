# frozen_string_literal: true

RSpec.describe ActiveSanction::ValidatorStore::Memory do
  let(:url) { "https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV" }
  let(:validators) { ActiveSanction::Validators.new(url: url, etag: '"0953154d"') }
  let(:store) { described_class.new }

  it "returns nil for a key never fetched, which is what a first sync sees" do
    expect(store[:ofac_sdn]).to be_nil
  end

  it "reads back what was stored" do
    store[:ofac_sdn] = validators

    expect(store[:ofac_sdn]).to eq(validators)
  end

  # A source adapter (#12) files by name; an ad-hoc caller files by URL. Both
  # have to survive the round-trip through JSON, which has only strings.
  it "treats a symbol and its string spelling as the same key" do
    store[:ofac_sdn] = validators

    expect(store["ofac_sdn"]).to eq(validators)
  end

  it "keys a URL by the URL" do
    store[url] = validators

    expect(store[url]).to eq(validators)
  end

  it "rejects a blank key" do
    expect { store[""] = validators }.to raise_error(ArgumentError, /validator key is required/)
  end

  describe "records that cannot save a download" do
    # Otherwise #stale? reports a usable copy for a key that has nothing to be
    # conditional with.
    it "does not store validators the publisher gave neither header for" do
      store[:ofac_sdn] = ActiveSanction::Validators.new(url: url)

      expect(store[:ofac_sdn]).to be_nil
    end

    it "treats storing nil as a delete" do
      store[:ofac_sdn] = validators
      store[:ofac_sdn] = nil

      expect(store).to be_empty
    end

    it "replaces a usable record with an empty one by removing it" do
      store[:ofac_sdn] = validators
      store[:ofac_sdn] = ActiveSanction::Validators.new(url: url)

      expect(store).not_to be_key(:ofac_sdn)
    end
  end

  describe "#delete" do
    it "forgets one source, so its next fetch downloads in full" do
      store[:ofac_sdn] = validators
      store[:un_consolidated] = validators

      store.delete(:ofac_sdn)

      expect(store.keys).to eq(["un_consolidated"])
    end

    it "is quiet about a key that was never there" do
      expect { store.delete(:nothing) }.not_to raise_error
    end
  end

  it "clears every key" do
    store[:ofac_sdn] = validators
    store.clear

    expect(store).to be_empty
  end

  it "reports its size" do
    store[:ofac_sdn] = validators
    store[:un_consolidated] = validators

    expect(store.size).to eq(2)
  end

  it "seeds from a hash, which is what a spec or a one-off script wants" do
    seeded = described_class.new(ofac_sdn: validators)

    expect(seeded[:ofac_sdn]).to eq(validators)
  end

  it "keeps nothing between processes, by design" do
    store[:ofac_sdn] = validators

    expect(described_class.new).to be_empty
  end
end
