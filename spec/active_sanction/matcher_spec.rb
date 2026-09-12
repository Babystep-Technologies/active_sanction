# frozen_string_literal: true

RSpec.describe ActiveSanction::Matcher do
  after { ActiveSanction.reset! }

  def listed(id, *names, source: :ofac_sdn, type: :individual, **rest)
    ActiveSanction::Entity.new(
      id: id, source: source, type: type, **rest,
      names: names.map.with_index do |value, at|
        ActiveSanction::Name.new(value: value, kind: at.zero? ? :primary : :aka)
      end
    )
  end

  def dob(value) = [ActiveSanction::PartialDate.parse(value)]

  def ntaganda
    listed("ofac_sdn:1", "NTAGANDA, Bosco", dates_of_birth: dob("1973"), nationalities: %w[CD])
  end

  def store(*entities, source: :ofac_sdn)
    ActiveSanction::Storage::Memory.new.tap do |memory|
      entities.group_by(&:source).each do |key, group|
        memory.write_snapshot(ActiveSanction::Snapshot.new(source: key || source, entities: group))
      end
    end
  end

  def matcher(*entities, **options)
    described_class.build(store(*(entities.empty? ? [ntaganda] : entities)), **options)
  end

  describe ".build" do
    it "indexes every list the store holds" do
      expect(matcher(ntaganda, listed("ofac_sdn:2", "ABBAS, Abu")).size).to eq(2)
    end

    it "records the checksum of the list version it indexed" do
      built = store(ntaganda)

      expect(matcher(ntaganda).snapshot_id(:ofac_sdn)).to eq(built.read_snapshot(:ofac_sdn).checksum)
    end

    it "indexes only the sources it was asked for" do
      entities = [ntaganda, listed("un:1", "ABBAS, Abu", source: :un_consolidated)]

      expect(described_class.build(store(*entities), sources: %i[ofac_sdn]).sources).to eq(%i[ofac_sdn])
    end

    # Screening against a list that is not there returns a clean report, which
    # is the most expensive thing this library can get wrong.
    it "refuses to build over a store nobody has synced" do
      expect { described_class.build(ActiveSanction::Storage::Memory.new) }
        .to raise_error(described_class::NotSynced, /nothing to screen against/)
    end

    it "raises for a named source that has never been synced" do
      expect { described_class.build(store(ntaganda), sources: %i[un_consolidated]) }
        .to raise_error(ActiveSanction::Storage::MissingSnapshot)
    end

    it "refuses an empty list of sources rather than reading it as all of them" do
      expect { described_class.build(store(ntaganda), sources: []) }.to raise_error(ArgumentError, /omit it/)
    end

    it "refuses lists that hold no name anything could screen against" do
      expect { described_class.build(store(listed("ofac_sdn:1", "---"))) }
        .to raise_error(described_class::NotSynced, /no names/)
    end

    it "builds over the configured store when it is given none" do
      ActiveSanction.configure { |c| c.storage = store(ntaganda) }

      expect(described_class.build.size).to eq(1)
    end

    it "says what it is" do
      expect(matcher.inspect).to eq("#<ActiveSanction::Matcher 1 names from ofac_sdn>")
    end
  end

  describe "#screen" do
    it "finds a listed person from the name a caller would type" do
      expect(matcher.screen(name: "Bosco Ntaganda").first.matched_name.value)
        .to eq("NTAGANDA, Bosco")
    end

    it "returns an empty array for a name nothing on the list looks like" do
      expect(matcher.screen(name: "Jane Wilson of Dorset")).to eq([])
    end

    it "takes a bare name" do
      expect(matcher.screen("Bosco Ntaganda").size).to eq(1)
    end

    it "takes a query object" do
      expect(matcher.screen(ActiveSanction::Query.build("Bosco Ntaganda")).size).to eq(1)
    end

    it "scores the whole subject, not only the name" do
      screened = matcher.screen(name: "Bosco Ntaganda", date_of_birth: "1973", countries: %w[CD])

      expect(screened.first.score).to be > matcher.screen(name: "Bosco Ntaganda").first.score
    end

    it "stamps every result with the list version it came off" do
      expect(matcher.screen("Bosco Ntaganda").first.snapshot_id).to start_with("sha256:")
    end

    it "stamps every result with the backend that answered" do
      expect(matcher.screen("Bosco Ntaganda").first.backend).to eq(:local)
    end

    it "carries the query onto the result" do
      expect(matcher.screen(name: "Bosco Ntaganda", threshold: 40).first.query.threshold).to eq(40.0)
    end
  end

  describe "the ranking" do
    def crowd
      [ntaganda, listed("ofac_sdn:2", "TAGANDA, Bosco"), listed("ofac_sdn:3", "ABBAS, Abu")]
    end

    it "returns the hits highest score first" do
      scores = matcher(*crowd).screen(name: "Bosco Ntaganda", threshold: 0).map(&:score)

      expect(scores).to eq(scores.sort.reverse)
    end

    it "caps the results at the limit" do
      expect(matcher(*crowd).screen(name: "Bosco Ntaganda", threshold: 0, limit: 1).size).to eq(1)
    end

    it "drops everything under the threshold" do
      expect(matcher(*crowd).screen(name: "Bosco Ntaganda", threshold: 80).map { |hit| hit.entity.id })
        .to eq(["ofac_sdn:1"])
    end

    # A screening decision is re-derived during an audit, so which of two
    # equally scored records is listed first has to be the same answer later.
    it "orders equal scores by entity id, which is the same answer in a year" do
      twins = [listed("ofac_sdn:9", "NTAGENDA, Bosco"), listed("ofac_sdn:2", "NTAGENDA, Bosco")]

      expect(matcher(*twins).screen("Bosco Ntaganda").map { |hit| hit.entity.id })
        .to eq(%w[ofac_sdn:2 ofac_sdn:9])
    end

    # An entity is retrieved once for every one of its names the query looks
    # like, and the scorer already takes the maximum over them.
    it "reports an entity reached through two of its names once" do
      both = listed("ofac_sdn:1", "NTAGANDA, Bosco", "Bosco Ntaganda")

      expect(matcher(both).screen("Bosco Ntaganda").size).to eq(1)
    end

    it "never scores an entity against a type it is not" do
      ship = listed("ofac_sdn:5", "NTAGANDA, Bosco", type: :vessel)

      expect(matcher(ship).screen(name: "Bosco Ntaganda", type: :individual)).to eq([])
    end
  end

  describe "the source filter" do
    def mixed
      [ntaganda, listed("un:1", "NTAGANDA, Bosco", source: :un_consolidated)]
    end

    it "screens every list when the query names none" do
      expect(matcher(*mixed).screen("Bosco Ntaganda").map(&:source)).to contain_exactly(:ofac_sdn, :un_consolidated)
    end

    it "screens only the lists the query names" do
      expect(matcher(*mixed).screen(name: "Bosco Ntaganda", sources: %i[un_consolidated]).map(&:source))
        .to eq([:un_consolidated])
    end

    it "stamps each hit with its own list's checksum" do
      checksums = matcher(*mixed).screen("Bosco Ntaganda").map(&:snapshot_id)

      expect(checksums.uniq.size).to eq(2)
    end

    # The same person really is two records when two governments list them,
    # and both belong in a report -- even where the two publishers happened to
    # give them the same reference.
    it "reports one person listed by two governments once per list" do
      twice = [listed("1", "NTAGANDA, Bosco"),
               listed("1", "NTAGANDA, Bosco", source: :un_consolidated)]

      expect(matcher(*twice).screen("Bosco Ntaganda").map(&:source)).to eq(%i[ofac_sdn un_consolidated])
    end

    # A run that quietly covers one of the two lists it was asked for is
    # indistinguishable from one that covers both, and both report clear.
    it "refuses a query naming a list this matcher does not hold" do
      expect { matcher.screen(name: "Bosco Ntaganda", sources: %i[un_consolidated]) }
        .to raise_error(ActiveSanction::Storage::MissingSnapshot, /does not hold un_consolidated/)
    end
  end

  describe "#screen_all" do
    def book = ["Bosco Ntaganda", "Jane Wilson of Dorset", "Bosco Ntaganda"]

    it "returns one array of results per query, in the order they were given" do
      expect(matcher.screen_all(book).map(&:size)).to eq([1, 0, 1])
    end

    it "screens the same name twice rather than collapsing it, which a Hash would" do
      expect(matcher.screen_all(book).size).to eq(3)
    end

    it "applies an override to every query in the batch" do
      expect(matcher.screen_all(book, threshold: 99).map(&:size)).to eq([0, 0, 0])
    end

    it "takes hashes as readily as names" do
      expect(matcher.screen_all([{ name: "Bosco Ntaganda", type: :individual }]).first.size).to eq(1)
    end

    # A rescreening of a customer book against a new list version is one event
    # in an audit trail, not ten thousand a microsecond apart.
    it "stamps the whole batch with one screening time" do
      stamps = matcher.screen_all(book).flatten.map(&:screened_at)

      expect(stamps.uniq.size).to eq(1)
    end

    it "refuses something that is not a list of queries" do
      expect { matcher.screen_all("Bosco Ntaganda") }.to raise_error(ArgumentError, /Array of queries/)
    end
  end

  describe "the settings it pins at build" do
    # Nothing on the query path reads configuration: a weight changed halfway
    # through a batch cannot produce a run that is half one set of numbers.
    it "screens with the weights it was built under, not the ones set since" do
      built = matcher(ntaganda)
      ActiveSanction.configure { |c| c.scorer_weights = { nationality_match: 20.0 } }

      expect(built.screen(name: "Bosco Ntaganda", countries: %w[CD]).first.weights)
        .to eq(ActiveSanction::Scorer::Weights.default)
    end

    it "takes weights of its own" do
      built = matcher(ntaganda, weights: { nationality_match: 20.0 })

      expect(built.screen(name: "Bosco Ntaganda", countries: %w[CD]).first.weights.nationality_match).to eq(20.0)
    end

    it "records the weights it screened with on every result" do
      expect(matcher.screen("Bosco Ntaganda").first.weights).to eq(ActiveSanction::Scorer::Weights.default)
    end

    it "takes a candidate cap of its own" do
      expect(matcher(ntaganda, candidate_limit: 1).candidate_limit).to eq(1)
    end

    it "refuses a candidate cap of zero, which retrieves nothing and screens nobody" do
      expect { matcher(ntaganda, candidate_limit: 0) }.to raise_error(ArgumentError, /at least 1/)
    end
  end

  # The acceptance criterion: a screening call against a corpus with a
  # sanctions list's shape returns sensible ranked hits. The real lists cannot
  # be in this repository -- see spec/support/synthetic_corpus.rb for why
  # their *distribution* is the thing worth testing against, and why a corpus
  # of distinct random names would prove nothing.
  describe "screening a corpus with a sanctions list's shape" do
    def corpus = SyntheticCorpus.matcher(2_000)

    def sample = corpus.index.entries.each_slice(83).map(&:first).first(24)

    it "screens thousands of names, not a handful" do
      expect(corpus.size).to be > 3_000
    end

    # A published name screened as its publisher printed it has to come back.
    # Not necessarily first: this corpus repeats common given names by design,
    # exactly as the real ones do, so an identical name on another record is a
    # true tie rather than a failure.
    it "finds every record from the name its publisher printed" do
      found = sample.count { |entry| corpus.screen(entry.name.value).any? { |hit| hit.entity == entry.entity } }

      expect(found).to eq(sample.size)
    end

    it "finds a record from the inversion of its name, which is how a query arrives" do
      found = sample.count do |entry|
        corpus.screen(entry.form.tokens.reverse.join(" ")).any? { |hit| hit.entity == entry.entity }
      end

      expect(found).to eq(sample.size)
    end

    it "ranks the record it was handed the name of at the top" do
      entry = sample.first

      expect(corpus.screen(entry.name.value).first.score).to eq(100.0)
    end

    it "reports a name nothing on the list looks like as clear" do
      expect(corpus.screen("Fionnuala Ni Bhraonain")).to eq([])
    end

    it "stamps every hit with the checksum of the corpus it screened" do
      checksum = SyntheticCorpus.store(2_000).read_snapshot(:ofac_sdn).checksum

      expect(corpus.screen(sample.first.name.value).map(&:snapshot_id).uniq).to eq([checksum])
    end

    # Everything but the instant each run happened, which is the one field a
    # second run is entitled to differ on.
    def hits(name) = corpus.screen(name).map { |hit| hit.to_h.except(:screened_at) }

    it "returns the same results screened from eight threads as from one" do
      names = sample.first(8).map { |entry| entry.name.value }
      threaded = names.map { |name| Thread.new { hits(name) } }.map(&:value)

      expect(threaded).to eq(names.map { |name| hits(name) })
    end
  end

  describe "concurrency" do
    it "is frozen, so nothing on the query path can change it" do
      expect(matcher).to be_frozen
    end

    it "gives every thread the same answer" do
      built = matcher(ntaganda, listed("ofac_sdn:2", "ABBAS, Abu"))
      answers = Array.new(8) { Thread.new { built.screen("Bosco Ntaganda").map(&:score) } }.map(&:value)

      expect(answers.uniq.size).to eq(1)
    end

    it "screens correctly under concurrent queries for different names" do
      built = matcher(ntaganda, listed("ofac_sdn:2", "ABBAS, Abu"))
      names = %w[Ntaganda Abbas] * 8
      found = names.map { |name| Thread.new { built.screen(name: name, threshold: 40).size } }.map(&:value)

      expect(found).to all(eq(1))
    end
  end

  # Which list version answered is one question and who vouched for it is
  # another. A matcher records both, and stamps both onto every result.
  describe "the lists that arrived attested" do
    def verified_store(*entities)
      ActiveSanction::Storage::Memory.new.tap do |memory|
        memory.write_snapshot(ActiveSanction::Snapshot.new(source: :ofac_sdn, entities: entities, trusted: true))
      end
    end

    it "holds nothing attested for a list this installation synced itself" do
      expect(matcher(ntaganda).verified).to be_empty
    end

    it "records a list that came out of a verified bundle" do
      expect(described_class.build(verified_store(ntaganda)).verified).to eq(%i[ofac_sdn])
    end

    it "answers per source" do
      built = described_class.build(verified_store(ntaganda))

      expect([built.verified?(:ofac_sdn), built.verified?(:un_consolidated)]).to eq([true, false])
    end

    it "stamps every result off an attested list" do
      built = described_class.build(verified_store(ntaganda))

      expect(built.screen(name: "Bosco Ntaganda").map(&:verified?)).to eq([true])
    end

    it "stamps every result off a list nobody vouched for" do
      expect(matcher(ntaganda).screen(name: "Bosco Ntaganda").map(&:verified?)).to eq([false])
    end

    it "refuses to be told a list it does not hold was verified" do
      built = lambda do
        described_class.new(index: ActiveSanction::Index.build([ntaganda]), snapshots: { ofac_sdn: "sha256:1" },
                            verified: %i[eu_fsf])
      end

      expect(&built).to raise_error(ActiveSanction::InvalidArgument, /does not hold/)
    end
  end
end
