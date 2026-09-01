# frozen_string_literal: true

RSpec.describe ActiveSanction::Normalizer::Cache do
  let(:cache) { described_class.new(limit: 3) }

  def fold(store, string) = store.fetch(string) { ActiveSanction::Normalizer::Form.new(string) }

  describe "#fetch" do
    it "computes on a miss" do
      expect(fold(cache, "Al-Qaida").value).to eq("al qaida")
    end

    it "answers the memoized object on a hit rather than folding again" do
      first = fold(cache, "Al-Qaida")
      expect(fold(cache, "Al-Qaida")).to be(first)
    end

    it "does not call the block on a hit" do
      fold(cache, "Al-Qaida")
      expect { cache.fetch("Al-Qaida") { raise "folded twice" } }.not_to raise_error
    end

    it "keys on the exact string, since case and punctuation are what the fold removes" do
      expect(fold(cache, "Al-Qaida")).not_to be(fold(cache, "AL-QAIDA"))
    end
  end

  # An LRU would need a write on every read, which turns a cache hit -- the
  # case this exists for -- into lock contention on the query path.
  describe "the ceiling" do
    it "empties rather than evicting one entry at a time" do
      %w[one two three four].each { |name| fold(cache, name) }
      expect(cache.size).to eq(1)
    end

    it "keeps folding correctly across a clear" do
      %w[one two three four].each { |name| fold(cache, name) }
      expect(fold(cache, "Al-Qaida").value).to eq("al qaida")
    end

    it "refuses a limit that would make it useless" do
      expect { described_class.new(limit: 0) }.to raise_error(ArgumentError, /at least 1/)
    end
  end

  describe "#clear" do
    it "empties the cache, for a host reclaiming the memory after a batch" do
      fold(cache, "Al-Qaida")
      cache.clear
      expect(cache.size).to eq(0)
    end
  end

  # One web process screens on many threads against one index, and they all
  # reach the same normalizer.
  describe "concurrency" do
    it "answers every thread the same value for the same name" do
      shared = described_class.new
      values = Array.new(8) { Thread.new { 200.times.map { |i| fold(shared, "Name #{i % 50}").value } } }
                    .map(&:value)
      expect(values.uniq.size).to eq(1)
    end

    it "keeps the ceiling under concurrent writes" do
      shared = described_class.new(limit: 10)
      Array.new(8) { |t| Thread.new { 100.times { |i| fold(shared, "Name #{t}-#{i}") } } }.each(&:join)
      expect(shared.size).to be <= 10
    end
  end
end
