# frozen_string_literal: true

require "tmpdir"

RSpec.describe ActiveSanction::Normalizer::Dictionary do
  subject(:dictionary) { described_class.default }

  def fold(string, type) = ActiveSanction::Normalizer::Form.new(string, stoplist: dictionary.stoplist(type)).value

  describe ".default" do
    it "reads the shipped lists rather than carrying them in the code" do
      expect(dictionary.to_h.keys).to eq(described_class::LISTS)
    end

    it "reads every list non-empty, since a file that failed to parse looks like a list nobody uses" do
      expect(dictionary.to_h.values.map(&:size)).to all(be_positive)
    end

    it "is frozen, since it is shared by every fold in the process" do
      expect(dictionary).to be_frozen
    end

    it "answers the same instance every time" do
      expect(described_class.default).to be(dictionary)
    end

    # Data files are only in the gem if the gemspec ships them, and a missing
    # one is not a degraded fold -- it is a library that does not load.
    it "ships the data files inside the packaged gem" do
      root = File.expand_path("../../..", __dir__)
      packaged = Gem::Specification.load(File.join(root, "active_sanction.gemspec")).files
      files = Dir[File.join(described_class::DIRECTORY, "*.txt")].map { |path| path.delete_prefix("#{root}/") }

      expect([files.size, files - packaged]).to eq([described_class::LISTS.size, []])
    end
  end

  describe ".from_files" do
    it "reads one entry per line, ignoring comments and blank lines" do
      Dir.mktmpdir do |directory|
        described_class::LISTS.each do |list|
          File.write(File.join(directory, "#{list}.txt"), "# a comment\n\n  #{list.to_s.upcase}  \n")
        end

        expect(described_class.from_files(directory).legal_forms).to eq(["LEGAL_FORMS"])
      end
    end
  end

  # The dictionaries are applied per entity type because the same token means
  # different things in different ones -- `CO` is a legal form on a company and
  # a syllable in a great many personal names.
  describe "contextual application" do
    it "strips a legal form from an organization" do
      expect(fold("Rosneft Oil Company", :organization)).to eq("rosneft oil")
    end

    it "leaves the same token alone on an individual" do
      expect(fold("Elena Company", :individual)).to eq("elena company")
    end

    it "strips an honorific from an individual" do
      expect(fold("Hajji Abdallah", :individual)).to eq("abdallah")
    end

    it "leaves the same token alone on an organization" do
      expect(fold("General Trading Establishment", :organization)).to eq("general trading establishment")
    end

    it "strips a function word from an organization, which is how two ways of writing one bank meet" do
      expect([fold("CENTRAL BANK OF THE RUSSIAN FEDERATION", :organization),
              fold("BANK OF RUSSIA", :organization)]).to eq(["central bank russian federation", "bank russia"])
    end

    it "leaves a vessel and an aircraft entirely alone, since neither list was written for them" do
      expect(%i[vessel aircraft].map { |type| dictionary.stoplist(type) }).to eq([nil, nil])
    end

    it "leaves a caller who did not say the type entirely alone" do
      expect(dictionary.stoplist(nil)).to be_nil
    end

    # A typo in a type name would silently turn stripping off, which is the
    # class of failure this library is built to make impossible.
    it "raises on a type it does not know rather than quietly stripping nothing" do
      expect { dictionary.stoplist(:individuals) }
        .to raise_error(ArgumentError, /unknown entity type :individuals/)
    end
  end

  # The whole reason the preserve list exists: these look like noise to a
  # stopword filter and are structural parts of the names they appear in.
  describe "the preserve list" do
    it "carries the particles the issue names" do
      expect(dictionary.particles)
        .to include("bin", "ibn", "bint", "abu", "abd", "al", "el", "van", "von", "de", "da", "del", "della",
                    "di", "dos")
    end

    it "keeps every particle out of every strip list, whatever the strip lists say" do
      stripped = ActiveSanction::Entity::TYPES.filter_map { |type| dictionary.stoplist(type) }
                                              .flat_map { |stoplist| stoplist.entries.flatten }
      expect(stripped & dictionary.particles).to eq([])
    end

    it "keeps every particle in the fold, for an individual and for an organization" do
      survivors = dictionary.particles.flat_map do |particle|
        %i[individual organization].map { |type| fold("#{particle} rahman", type).split.first }
      end
      expect(survivors.uniq).to eq(dictionary.particles.flat_map { |particle| [particle] })
    end

    # Real SDN and UN entries, which is what the acceptance criterion asks for.
    it "keeps bin, abu, al and abd in the names they belong to" do
      names = ["Osama bin Laden", "Shaykh Umar Abd Al Rahman", "ABBAS, Abu Al",
               "Amir Muhammad Sa'id Abdal-Rahman al-Mawla"]
      expect(names.map { |name| fold(name, :individual) })
        .to eq(["osama bin laden", "umar abd al rahman", "abbas abu al",
                "amir muhammad sa id abdal rahman al mawla"])
    end

    # The collision the issue asks for by name: `AL` is on the organization
    # stopword list and on the preserve list, and the preserve list wins.
    it "wins over a strip list that names the same token" do
      expect([dictionary.organization_stopwords, fold("Al Rajhi Bank", :organization)])
        .to eq([%w[THE AND OF FOR AL], "al rajhi bank"])
    end
  end

  # An entry is folded by the same Form the names are, so `L.L.C.` in the file
  # matches `LLC` in a name -- at the cost of an entry being several tokens.
  describe "entries that fold to more than one token" do
    it "matches a punctuated abbreviation however it was written" do
      expect(["ABC Widgets, L.L.C.", "ABC Widgets LLC", "ABC Widgets L L C"]
               .map { |name| fold(name, :organization) }).to all(eq("abc widgets"))
    end

    it "matches the phrase an initialism stands for, which is how Gazprom's two names meet" do
      expect(["PUBLIC JOINT STOCK COMPANY GAZPROM", "PJSC GAZPROM", "GAZPROM PAO"]
               .map { |name| fold(name, :organization) }).to all(eq("gazprom"))
    end

    it "prefers the longest phrase at a position, rather than the first entry that starts there" do
      expect(fold("Open Joint Stock Company Rosneft Oil Company", :organization)).to eq("rosneft oil")
    end

    it "strips wherever the entry appears, since OFAC writes the form at either end" do
      expect(fold("JSC Bank Ltd", :organization)).to eq("bank")
    end
  end

  describe "#merge" do
    it "adds entries a host's market needs without disturbing the shipped ones" do
      merged = dictionary.merge(legal_forms: %w[OYJ])
      expect([merged.legal_forms.last, merged.legal_forms & dictionary.legal_forms])
        .to eq(["OYJ", dictionary.legal_forms])
    end

    it "takes a bare string, which is what a host adding one entry will write" do
      expect(dictionary.merge(legal_forms: "OYJ").legal_forms.last).to eq("OYJ")
    end

    it "drops a duplicate rather than treating it as an error" do
      expect(dictionary.merge(legal_forms: ["LTD"]).legal_forms).to eq(dictionary.legal_forms)
    end

    it "strips a host's whitespace, since these lists are hand-edited" do
      expect(dictionary.merge(honorifics: ["  BRIG  "]).honorifics.last).to eq("BRIG")
    end

    it "leaves the receiver alone" do
      expect { dictionary.merge(legal_forms: %w[OYJ]) }.not_to change(dictionary, :legal_forms)
    end

    it "folds the added entries the same way the shipped ones are folded" do
      merged = dictionary.merge(legal_forms: ["Öyj."])
      expect(ActiveSanction::Normalizer::Form.new("Nokia OYJ", stoplist: merged.stoplist(:organization)).value)
        .to eq("nokia")
    end

    # A host's preserve list has the same precedence the shipped one does,
    # which is what makes the preserve list a rule rather than a coincidence.
    it "lets a host protect a token the shipped lists strip" do
      merged = dictionary.merge(particles: %w[co])
      expect([fold("Kunlun Co", :organization),
              ActiveSanction::Normalizer::Form.new("Kunlun Co", stoplist: merged.stoplist(:organization)).value])
        .to eq(["kunlun", "kunlun co"])
    end
  end

  describe "a dictionary built by hand" do
    it "replaces the shipped lists outright" do
      replacement = described_class.new(legal_forms: %w[LTD], honorifics: [], organization_stopwords: [],
                                        particles: [])
      expect(ActiveSanction::Normalizer::Form.new("Rosneft Oil Company Ltd",
                                                  stoplist: replacement.stoplist(:organization)).value)
        .to eq("rosneft oil company")
    end

    it "requires every list, so that one built without the particles cannot happen by omission" do
      expect { described_class.new(legal_forms: %w[LTD]) }.to raise_error(ArgumentError, /organization_stopwords/)
    end

    it "compares by value, so a rebuilt dictionary is the dictionary it rebuilt" do
      expect(described_class.from_files).to eq(dictionary)
    end
  end

  # Dictionary::Stoplist: one type's lists, resolved down to the sequences the
  # fold drops.
  describe "the stoplist a type resolves to" do
    let(:stoplist) { dictionary.stoplist(:organization) }

    it "keys on its contents, so a rebuilt dictionary shares a warm fold cache" do
      expect(described_class.from_files.stoplist(:organization).key).to eq(stoplist.key)
    end

    it "keys differently per type, since the same name folded two ways is two answers" do
      expect(stoplist.key).not_to eq(dictionary.stoplist(:individual).key)
    end

    it "keys differently when the lists change" do
      expect(dictionary.merge(legal_forms: %w[OYJ]).stoplist(:organization).key).not_to eq(stoplist.key)
    end

    it "answers the tokens it did not strip" do
      expect(stoplist.reject(%w[rosneft oil company])).to eq(%w[rosneft oil])
    end

    it "answers nothing at all when a name is legal forms and nothing else" do
      expect(stoplist.reject(%w[the company])).to eq([])
    end
  end
end
