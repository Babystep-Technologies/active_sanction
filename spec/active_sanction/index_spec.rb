# frozen_string_literal: true

RSpec.describe ActiveSanction::Index do
  def entity(id, *names, type: :individual, source: :ofac_sdn)
    ActiveSanction::Entity.new(
      id: id, source: source, type: type,
      names: names.map.with_index do |value, position|
        ActiveSanction::Name.new(value: value, kind: position.zero? ? :primary : :aka)
      end
    )
  end

  # The names in spec/fixtures, as their publishers write them.
  def corpus
    [
      entity("sdn:2674", "ABBAS, Abu", "ABBAS, Abu Al", "ZAYDAN, Muhammad"),
      entity("sdn:9640", "ABU TEIR, Mohammed", "ABU TAIR, Mohammed Mahmud"),
      entity("sdn:9647", "ZAHHAR, Mahmoud Khaled", "AL ZAHAR, Mahmoud Khaled"),
      entity("sdn:29242", "TANG, Chris", "TANG, Ping-keung"),
      entity("sdn:36", "AEROCARIBBEAN AIRLINES", "AERO-CARIBBEAN", type: :organization),
      entity("sdn:17250", "PUBLIC JOINT STOCK COMPANY GAZPROM", "PJSC GAZPROM", type: :organization),
      entity("sdn:gazneft", "GAZPROM NEFT TRADING GMBH", type: :organization),
      entity("sdn:18299", "ROSNEFT TRADING S.A.", type: :organization, source: :ofac_consolidated),
      entity("sdn:15268", "BANK OF KUNLUN CO LTD", type: :organization),
      entity("un:qusay", "QUSAY SADDAM HUSSEIN"),
      entity("un:qaddafi", "QADHAFI, Muammar", source: :un_consolidated)
    ]
  end

  def index = described_class.build(corpus)

  def values(candidates) = candidates.map { |candidate| candidate.name.value }

  describe ".build" do
    it "indexes every name an entity carries, not one per entity" do
      built = described_class.build([entity("x:1", "ABBAS, Abu", "ZAYDAN, Muhammad", "Abu Al Abbas")])
      expect(built.size).to eq(3)
    end

    it "takes a storage adapter and streams it" do
      store = ActiveSanction::Storage::Memory.new
      store.write_snapshot(ActiveSanction::Snapshot.new(source: :ofac_sdn, entities: corpus))
      expect(described_class.build(store).size).to eq(index.size)
    end

    it "refuses something that is neither a store nor a list of entities" do
      expect { described_class.build(42) }.to raise_error(ArgumentError, /storage adapter or an enumerable/)
    end

    # Form#empty? exists for these, and a name that cannot be scored is a name
    # no candidate set should ever carry.
    it "skips a name that folds away to nothing" do
      built = described_class.build([entity("x:1", "ABBAS, Abu", "---", "🙂")])
      expect(built.size).to eq(1)
    end

    # One OFAC record carries both spellings, and after the fold they are one
    # string. Indexing both would post the entity twice under every feature
    # and hand the scorer the same comparison twice.
    it "indexes one entry for two names of an entity that fold alike" do
      built = described_class.build([entity("x:1", "MUÑOZ HERMANOS S.A.", "MUNOZ HERMANOS", type: :organization)])
      expect(built.size).to eq(1)
    end

    it "keeps the publisher's own spelling of the one it kept" do
      built = described_class.build([entity("x:1", "MUÑOZ HERMANOS S.A.", "MUNOZ HERMANOS", type: :organization)])
      expect(built.entries.first.name.value).to eq("MUÑOZ HERMANOS S.A.")
    end

    it "folds each name under its entity's type, so the stoplists apply" do
      built = described_class.build([entity("x:1", "ROSNEFT TRADING S.A.", type: :organization)])
      expect(built.entries.first.form.value).to eq("rosneft trading")
    end
  end

  # The four shapes the three feature spaces exist for -- see Features. Each
  # of these is a query that one space finds and another cannot.
  describe "what it retrieves" do
    it "finds an inverted name, which is how every individual is published" do
      expect(values(index.candidates("Abu Abbas"))).to include("ABBAS, Abu")
    end

    it "finds a name through a typo, where no token matches" do
      expect(values(index.candidates("Gazprum"))).to include("PUBLIC JOINT STOCK COMPANY GAZPROM")
    end

    it "finds a transliteration variant through its phonetic key" do
      expect(values(index.candidates("Gaddafi"))).to include("QADHAFI, Muammar")
    end

    it "finds a name whose token boundary was drawn differently" do
      expect(values(index.candidates("Aero Caribbean"))).to include("AEROCARIBBEAN AIRLINES")
    end

    it "finds a name that dropped a middle token" do
      expect(values(index.candidates("Qusay Hussein"))).to include("QUSAY SADDAM HUSSEIN")
    end

    it "returns nothing for a query sharing no feature with the corpus" do
      expect(index.candidates("Путин")).to be_empty
    end

    it "returns nothing for a query that folds away entirely" do
      expect(index.candidates("---")).to be_empty
    end

    it "returns nothing from an index with nothing in it" do
      expect(described_class.build([]).candidates("Abu Abbas")).to be_empty
    end
  end

  describe "the cap" do
    it "returns no more than the limit asked for" do
      expect(index.candidates("Mohammed", limit: 2).size).to be <= 2
    end

    it "falls back to the configured limit" do
      allow(ActiveSanction.config).to receive(:candidate_limit).and_return(1)
      expect(index.candidates("Mohammed").size).to eq(1)
    end

    # Filtering after the cap would return fewer names than asked for, and
    # would do it exactly when the corpus is largest.
    it "filters by source before capping rather than after" do
      candidates = index.candidates("Rosneft Trading", sources: %i[ofac_consolidated])
      expect(candidates.map(&:source).uniq).to eq([:ofac_consolidated])
    end

    it "still finds the name it was filtered to" do
      expect(values(index.candidates("Rosneft", sources: %i[ofac_consolidated]))).to include("ROSNEFT TRADING S.A.")
    end
  end

  describe "the ranking" do
    # The cosine's length term. Both names carry `gazprom`; one of them folds
    # to almost nothing else, and that is the one a query for `Gazprom` means.
    # Ranking on the sum of what matched, without dividing by how much name
    # there is, puts these the other way round.
    it "ranks a short name matched wholly above a long one matched partly" do
      expect(values(index.candidates("Gazprom")).first).to eq("PUBLIC JOINT STOCK COMPANY GAZPROM")
    end

    it "scores a name against itself 1.0" do
      expect(index.candidates("ABBAS, Abu").first.weight).to be_within(1e-9).of(1.0)
    end

    it "scores every candidate inside 0..1" do
      expect(index.candidates("Mohammed Abu Teir").map(&:weight)).to all(be_between(0.0, 1.0))
    end

    it "hands them back heaviest first" do
      weights = index.candidates("Mohammed Abu Teir").map(&:weight)
      expect(weights).to eq(weights.sort.reverse)
    end

    # A screening decision is re-derived during an audit, so the cap has to
    # fall in the same place a year later. Ties break on the order the
    # publisher listed them in.
    it "breaks ties by publication order, not by hash order" do
      tied = described_class.build(Array.new(20) { |n| entity("x:#{n}", "ABBAS, Abu") })
      expect(tied.candidates("Abu Abbas", limit: 3).map { |c| c.entity.id }).to eq(%w[x:0 x:1 x:2])
    end

    it "gives the same answer every time it is asked" do
      expect(3.times.map { values(index.candidates("Mohammed Abu Teir")) }.uniq.size).to eq(1)
    end
  end

  describe "a built index" do
    it "is frozen" do
      expect(index).to be_frozen
    end

    it "has no way to add to it" do
      expect(index).not_to respond_to(:add)
    end

    it "freezes the posting lists inside it" do
      lists = index.instance_variable_get(:@tokens).values
      expect(lists).to all(be_frozen)
    end

    it "freezes the entries" do
      expect(index.entries).to all(be_frozen)
    end

    # The property a web process depends on: one index, every thread, no lock.
    it "answers the same from several threads at once" do
      built = index
      expected = values(built.candidates("Abu Abbas"))
      threads = 8.times.map { Thread.new { values(built.candidates("Abu Abbas")) } }
      expect(threads.map(&:value).uniq).to eq([expected])
    end
  end

  describe "#stats" do
    it "counts names, entities and the three feature spaces" do
      expect(index.stats.keys).to eq(%i[names entities tokens trigrams phonetics postings])
    end

    it "counts entities rather than names" do
      expect(index.stats[:entities]).to eq(corpus.size)
    end
  end

  # The acceptance criterion, and the one that matters: a name this stage does
  # not retrieve is never compared to anything, and nothing downstream can
  # tell that it happened. So recall is measured against queries that have
  # been deliberately damaged in the ways real ones are, over a corpus with a
  # sanctions list's shape -- see SyntheticCorpus for why that shape is the
  # thing being tested.
  describe "recall against damaged queries" do
    def built = SyntheticCorpus.index(4_000)

    def sample = built.entries.each_slice(19).map(&:first).first(300)

    # Every recall figure below is at the *configured* limit, not at some
    # generous one chosen to make the number look good: what is being measured
    # is what a caller gets by default.
    def recall(entries)
      found = entries.count do |entry|
        query = yield(entry)
        index = built
        index.candidates(query, type: entry.entity.type).any? { |candidate| candidate.entry.id == entry.id }
      end
      found.fdiv(entries.size)
    end

    def typo(value, offset = 2)
      positions = value.each_char.with_index.select { |character, _| character.match?(/[a-z]/) }.map(&:last)
      return value if positions.size < 4

      value.dup.tap { |damaged| damaged[positions.fetch(positions.size / offset)] = "x" }
    end

    # If the corpus were uniform this would all be easy and none of it would
    # mean anything. The skew is the thing being tested against.
    it "is measured against a corpus with a sanctions list's skew" do
      tokens = built.instance_variable_get(:@tokens)
      expect(tokens.values.max_by(&:size).size).to be > built.size / 20
    end

    it "finds a name from the string the publisher printed" do
      expect(recall(sample) { |entry| entry.name.value }).to eq(1.0)
    end

    it "finds a name from the inversion of it, which is how a query arrives" do
      expect(recall(sample) { |entry| entry.form.tokens.reverse.join(" ") }).to eq(1.0)
    end

    it "finds a name through a typo in the middle of it" do
      expect(recall(sample) { |entry| typo(entry.form.value) }).to eq(1.0)
    end

    it "finds nearly all of them through two typos" do
      expect(recall(sample) { |entry| typo(typo(entry.form.value), 3) }).to be > 0.97
    end

    it "finds a person whose middle name the query did not carry" do
      people = sample.select { |entry| entry.entity.type == :individual && entry.form.tokens.size >= 3 }
      expect(recall(people) { |entry| [entry.form.tokens.first, entry.form.tokens.last].join(" ") }).to eq(1.0)
    end
  end
end
