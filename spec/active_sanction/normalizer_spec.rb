# frozen_string_literal: true

RSpec.describe ActiveSanction::Normalizer do
  # Every name in every committed fixture, read through the adapters that
  # produce them. This is what the acceptance criteria are really about: a
  # fold that holds on invented examples and not on the government's own files
  # is not a fold anyone can screen against.
  #
  # Parsed once for the whole file -- four fixtures through four adapters is
  # not work worth repeating per example.
  fixtures = {
    ActiveSanction::Sources::CanadaSema => "canada_sema/sema.xml",
    ActiveSanction::Sources::UnConsolidated => "un_consolidated/consolidated.xml",
    ActiveSanction::Sources::OfacSdn => { sdn: "ofac_sdn/SDN.CSV", alt: "ofac_sdn/ALT.CSV",
                                          add: "ofac_sdn/ADD.CSV" },
    ActiveSanction::Sources::OfacConsolidated => { prim: "ofac_consolidated/PRIM.CSV",
                                                   alt: "ofac_consolidated/ALT.CSV",
                                                   add: "ofac_consolidated/ADD.CSV" }
  }.freeze
  parsed = []

  define_method(:fixture_entities) do
    parsed[0] ||= fixtures.flat_map do |adapter, paths|
      payload = if paths.is_a?(Hash)
                  paths.transform_values { |path| File.binread(fixture_path(path)) }
                else
                  File.binread(fixture_path(paths))
                end
      adapter.new.parse(payload)
    end
  end

  define_method(:fixture_names) do
    parsed[1] ||= fixture_entities.flat_map { |entity| entity.names.map(&:value) }
  end

  def fixture_path(path) = File.expand_path("../fixtures/#{path}", __dir__)

  # Every name one entity publishes, folded the way that entity's type says to
  # fold it. This is what an index build does, and what the dictionaries (#27)
  # are for: an alias set that collapses to one string is a set of names a
  # scorer no longer has to be clever about.
  define_method(:fixture_folds) do |id|
    entity = fixture_entities.find { |candidate| candidate.id == id }
    entity.names.map { |name| described_class.call(name, type: entity.type).value }
  end

  # Whether the record a non-Latin name belongs to also carries a romanized
  # one. Found by name rather than by entity, since that is what the fold
  # sees.
  define_method(:latin_sibling?) do |name|
    entity = fixture_entities.find { |candidate| candidate.names.any? { |other| other.value == name } }
    entity.names.any? { |other| other.value.match?(/\A[\p{Latin}\p{P}\s\d]+\z/) }
  end

  describe ".call" do
    it "returns both forms of the name" do
      form = described_class.call("Bélarus")
      expect([form.original, form.value]).to eq(%w[Bélarus belarus])
    end

    it "takes a Name as readily as a String, so an indexer passes what it holds" do
      name = ActiveSanction::Name.new(value: "AERO-CARIBBEAN", kind: :aka)
      expect(described_class.call(name).value).to eq("aero caribbean")
    end

    it "answers an empty form rather than raising on nil" do
      expect(described_class.call(nil).empty?).to be(true)
    end

    it "memoizes, since the same name is folded over and over during an index build" do
      first = described_class.call("Al-Qaida")
      expect(described_class.call("Al-Qaida")).to be(first)
    end
  end

  # The acceptance criterion this class exists for. A matcher whose index and
  # query fold differently does not fail -- it silently stops matching, on
  # exactly the records the difference touches.
  describe "one code path" do
    it "folds the same string the same way through the class, an instance and a Form" do
      folded = [described_class.call("O'Brien"), described_class.new.call("O'Brien"),
                ActiveSanction::Normalizer::Form.new("O'Brien")].map(&:value)
      expect(folded.uniq).to eq(["o brien"])
    end

    it "runs the class method against the process-wide instance" do
      expect(described_class.call("Al-Qaida")).to be(described_class::DEFAULT.call("Al-Qaida"))
    end

    # The same rule one stage down. A query folded as an organization against
    # an index folded as a bare string is the same silent mismatch, and it is
    # why the type travels with the call rather than with the normalizer.
    it "folds a typed name the same way through the class, an instance and a Form" do
      stoplist = ActiveSanction::Normalizer::Dictionary.default.stoplist(:organization)
      folded = [described_class.call("PJSC Gazprom", type: :organization),
                described_class.new.call("PJSC Gazprom", type: :organization),
                ActiveSanction::Normalizer::Form.new("PJSC Gazprom", stoplist: stoplist)].map(&:value)
      expect(folded.uniq).to eq(["gazprom"])
    end

    it "gives an instance with its own cache the identical fold" do
      own = described_class.new(cache_limit: 1)
      expect(fixture_names.map { |name| own.call(name).value })
        .to eq(fixture_names.map { |name| described_class.call(name).value })
    end
  end

  describe "idempotence" do
    it "folds an already-folded string to itself" do
      once = ["CO., LTD.", "Bélarus", "  ABBAS, Abu ", "Straße", "Bjørn", "أبو بكر"]
             .map { |name| described_class.call(name).value }
      expect(once.map { |value| described_class.call(value).value }).to eq(once)
    end

    it "holds for every name in every fixture" do
      once = fixture_names.map { |name| described_class.call(name).value }
      expect(once.map { |value| described_class.call(value).value }).to eq(once)
    end

    # A stripped token cannot come back to be stripped again, so the second
    # pass has nothing left to do here either.
    it "holds with the dictionaries applied" do
      names = { "PUBLIC JOINT STOCK COMPANY GAZPROM" => :organization, "Hajji Abdallah" => :individual }
      once = names.map { |name, type| [described_class.call(name, type: type).value, type] }
      expect(once.map { |value, type| described_class.call(value, type: type).value }).to eq(once.map(&:first))
    end
  end

  describe "every fixture name, folded" do
    let(:folded) { fixture_names.map { |name| described_class.call(name).value } }

    it "reads enough names for that to be worth asserting" do
      expect(fixture_names.size).to be > 50
    end

    it "leaves no combining mark anywhere" do
      expect(folded.grep(/[\p{Mn}\p{Me}]/)).to eq([])
    end

    it "leaves no uppercase anywhere" do
      expect(folded.grep(/\p{Upper}/)).to eq([])
    end

    it "leaves no punctuation or symbol anywhere" do
      expect(folded.grep(/[^[:alnum:][:space:]]/)).to eq([])
    end

    it "leaves single spaces and no padding" do
      expect(folded.grep(/\A\s|\s\z|\s\s/)).to eq([])
    end

    # The diacritics criterion, on the names that actually carry them: Canada
    # publishes `Bélarus` in the same file as `Belarus`.
    it "leaves nothing accented in a name published with accents" do
      accented = fixture_names.grep(/[éèàáñíóúüô]/i)
      expect(accented.map { |name| described_class.call(name).value }.grep(/[^[:ascii:]]/)).to eq([])
    end
  end

  # The documented recall limitation, and the reason it is survivable: a
  # non-Latin name is reachable only from its own script, and these lists
  # publish one as an extra variant rather than instead of a romanized name.
  describe "non-Latin script, which v1 does not transliterate" do
    it "leaves a Cyrillic name reachable only from Cyrillic" do
      expect(described_class.call("ПУТИН, Владимир").value).to eq("путин владимир")
    end

    it "finds a Latin name beside every non-Latin one the fixtures publish" do
      expect(fixture_names.grep_v(/\A[\p{Latin}\p{P}\s\d]+\z/).map { |name| latin_sibling?(name) })
        .to all(be(true))
    end
  end

  # Stage 1b of the pipeline, reached by telling `call` what kind of entity the
  # name belongs to. Dictionary holds what is on the lists and why; this is
  # what the entry point does with them.
  describe "the dictionaries" do
    it "strips a legal form from an organization, and nothing at all from a name of no stated type" do
      expect([described_class.call("Rosneft Oil Company", type: :organization).value,
              described_class.call("Rosneft Oil Company").value])
        .to eq(["rosneft oil", "rosneft oil company"])
    end

    # The acceptance criterion, on the government's own file: three ways of
    # writing one company, one string for a scorer to compare.
    it "folds an organization's published name and both its aliases onto one string" do
      expect(fixture_folds("ofac_consolidated:30882").uniq).to eq(["china telecom"])
    end

    it "does the same for the initialism and the phrase OFAC spells it out as" do
      expect(fixture_folds("ofac_consolidated:17250").uniq).to eq(["gazprom"])
    end

    # The other half of the criterion, on the same file: what the strip lists
    # must not touch.
    it "leaves the particles at the front of a real individual's aliases" do
      expect(fixture_folds("ofac_consolidated:9640").map { |value| value.split.first }).to eq(%w[abu abu abou])
    end

    it "strips an honorific from an individual and leaves the same word alone on an organization" do
      expect([described_class.call("General Taganda", type: :individual).value,
              described_class.call("General Trading Co", type: :organization).value])
        .to eq(["taganda", "general trading"])
    end

    it "caches per type, since one string folded two ways is two answers" do
      normalizer = described_class.new
      %i[organization individual].each { |type| normalizer.call("Company Ltd", type: type) }
      expect(normalizer.cache.size).to eq(2)
    end

    it "shares one entry between a vessel and a bare string, since no list applies to either" do
      normalizer = described_class.new
      [{ type: :vessel }, {}].each { |options| normalizer.call("Ever Given", **options) }
      expect(normalizer.cache.size).to eq(1)
    end

    it "raises on a type it does not know rather than quietly stripping nothing" do
      expect { described_class.call("Rosneft", type: :corporation) }.to raise_error(ArgumentError, /unknown entity/)
    end
  end

  describe "a host's own dictionary" do
    after { ActiveSanction.reset! }

    it "reaches the process-wide normalizer through the configuration" do
      ActiveSanction.configure { |c| c.normalizer_dictionary = { legal_forms: %w[OYJ] } }
      expect(described_class.call("Nokia Oyj", type: :organization).value).to eq("nokia")
    end

    it "leaves an instance that pinned its own dictionary alone" do
      pinned = described_class.new(dictionary: ActiveSanction::Normalizer::Dictionary.default)
      ActiveSanction.configure { |c| c.normalizer_dictionary = { legal_forms: %w[OYJ] } }
      expect(pinned.call("Nokia Oyj", type: :organization).value).to eq("nokia oyj")
    end
  end

  describe "an instance" do
    it "caches into its own cache rather than a shared one" do
      normalizer = described_class.new
      normalizer.call("Al-Qaida")
      expect(normalizer.cache.size).to eq(1)
    end

    it "takes a cache limit, for a host that would rather spend the memory elsewhere" do
      expect(described_class.new(cache_limit: 10).cache.limit).to eq(10)
    end
  end
end
