# frozen_string_literal: true

# A corpus shaped like a sanctions list, at whatever size a spec needs.
#
#   entities = SyntheticCorpus.build(2_000)
#   index = ActiveSanction::Index.build(entities)
#
# The real lists cannot be in this repository -- they are megabytes, they
# change weekly, and fetching one is a network call the suite refuses to make.
# But the property the index has to be measured against is not the names
# themselves, it is their *distribution*: a handful of given names carried by
# a quarter of the individuals, a long tail of surnames carried by one entity
# each, organizations that repeat the same half-dozen words, and more aliases
# than primary names. An index that looks fast against 46,000 distinct names
# and collapses against 46,000 realistically skewed ones has been measured
# against the wrong thing.
#
# So: names are drawn from weighted vocabularies with a Zipf-shaped tail, the
# type mix is roughly OFAC's, and about half the entities carry aliases that
# are real variants of their primary -- an inversion, a dropped middle name, a
# transliteration variant -- because those are the shapes a query has to find.
#
# Deterministic: the same size always produces the same corpus, so a recall
# number is a fact about the index rather than about today's seed.
module SyntheticCorpus
  SEED = 20_260_906

  GIVEN_NAMES = %w[
    mohammed muhammad ali ahmed hassan hussein abdul ibrahim mahmoud omar
    vladimir sergei ivan dmitri alexei viktor mikhail
    jose maria juan carlos luis
    wei jun ming yong chol jong
    kim park lee
    ahmad rashid tariq yusuf khalid nasser samir farid jamal karim
    boris pavel nikolai andrei roman igor
    ana sofia elena carmen rosa
  ].freeze

  SURNAMES = %w[
    abbas zawahiri qaddafi nasrallah zaydan teir zahhar hakim mansour saleh
    putin lavrov shoigu ivanov petrov sidorov volkov orlov sokolov popov
    garcia rodriguez martinez lopez gonzalez perez sanchez ramirez torres flores
    zhang wang chen liu yang huang zhao wu zhou xu
    al-masri al-suri al-libi al-jazairi al-yemeni
    bakr faruq ghani haddad idris jaber kassab labib madani
  ].freeze

  ORG_HEADS = %w[
    gazprom rosneft lukoil sberbank vtb novatek sovcomflot transneft
    kunlun huawei zte cosco norinco
    melli saderat parsian tejarat sepah
    hermanos comercial industrial internacional
  ].freeze

  ORG_TAILS = [
    "trading company", "oil company", "shipping lines", "holding ag", "bank",
    "co ltd", "sa", "gmbh", "llc", "public joint stock company", "group",
    "import export", "logistics", "petrochemical company", "investment fund"
  ].freeze

  VESSEL_NAMES = %w[
    artavia ever given sea horizon northern star blue ocean pacific dawn
    grand phoenix silver wave atlantic pearl golden eagle
  ].freeze

  # The curated lists above are the *head* of each vocabulary -- the names a
  # large share of these lists actually repeat. On their own they are not a
  # corpus: 20,000 entities drawn from sixty surnames produce the same name
  # hundreds of times over, which is not what a sanctions list looks like and
  # would measure the index against collisions no real query meets.
  #
  # So each head is followed by a generated tail, and the draw is steep enough
  # that the head still dominates. What comes out has the property that
  # matters: a handful of names carried by thousands of records, and thousands
  # carried by one.
  SYLLABLES = %w[
    ab ad af al am an ar as at av az ba bar be bo bu da dar de di do du fa fi
    ga gar gi go gu ha har he hi ho hu ib id il im in ir is ka kar ke kha khi
    la lar le li lo lu ma mar me mi mo mu na nar ne ni no nu qa qi ra rah re
    ri ro ru sa sar se sha shi so su ta tar te ti to tu ub ul um un ur us va
    vi vo za zar ze zi zo zu
  ].freeze

  def self.generated(count, lengths, seed)
    random = Random.new(seed)
    Array.new(count) do
      Array.new(lengths.to_a.sample(random: random)) { SYLLABLES.fetch(random.rand(SYLLABLES.size)) }.join
    end.uniq
  end

  GIVEN_TAIL = generated(600, 2..3, SEED + 1).freeze
  SURNAME_TAIL = generated(8_000, 2..4, SEED + 2).freeze
  ORG_TAIL_HEADS = generated(3_000, 2..3, SEED + 3).freeze

  ALL_GIVEN = (GIVEN_NAMES + GIVEN_TAIL).freeze
  ALL_SURNAMES = (SURNAMES + SURNAME_TAIL).freeze
  ALL_ORG_HEADS = (ORG_HEADS + ORG_TAIL_HEADS).freeze

  # Roughly OFAC's mix: mostly people, a solid share of companies, a tail of
  # vessels and aircraft.
  TYPES = [
    *Array.new(60, :individual), *Array.new(30, :organization),
    *Array.new(7, :vessel), *Array.new(3, :aircraft)
  ].freeze

  module_function

  # `count` entities, with names in the proportions above.
  def build(count)
    random = Random.new(SEED)
    (0...count).map { |ordinal| entity(ordinal, random) }
  end

  # The same corpus, indexed once and kept. Building one is a second or two,
  # and a spec file's worth of examples all want the same one.
  def index(count)
    @indexes ||= {}
    @indexes[count] ||= ActiveSanction::Index.build(build(count))
  end

  def entity(ordinal, random)
    type = TYPES.fetch(random.rand(TYPES.size))
    primary = primary_name(type, ordinal, random)
    ActiveSanction::Entity.new(
      id: "synthetic:#{ordinal}",
      source: :ofac_sdn,
      type: type,
      names: [ActiveSanction::Name.new(value: primary, kind: :primary)] + aliases(primary, type, random)
    )
  end

  def primary_name(type, ordinal, random)
    case type
    when :individual then individual_name(random)
    when :organization then "#{zipf(ALL_ORG_HEADS, random, 2)} #{zipf(ORG_TAILS, random, 1)}".upcase
    else "#{zipf(VESSEL_NAMES, random, 1)} #{ordinal % 97}".upcase
    end
  end

  # `LAST, First`, which is how every list publishes a person, and about a
  # third of them with a middle name as well -- a patronymic, a father's name,
  # a second given name. That third is not decoration: a query almost never
  # carries the middle name, so it is the shape the index's recall has to be
  # measured against.
  def individual_name(random)
    middle = random.rand < 0.35 ? " #{given(random).capitalize}" : ""
    "#{surname(random).upcase}, #{given(random).capitalize}#{middle}"
  end

  # About half of them carry aliases, and an alias is a variant of the primary
  # rather than an unrelated string -- an inversion, a dropped token, a letter
  # changed. Those are the shapes a query arrives in.
  def aliases(primary, type, random)
    return [] if random.rand > 0.55

    variants(primary, type, random).map { |value| ActiveSanction::Name.new(value: value, kind: :aka) }
  end

  def variants(primary, _type, random)
    tokens = primary.delete(",").split
    candidates = [tokens.reverse.join(" ")]
    candidates << tokens.first(tokens.size - 1).join(" ") if tokens.size > 2
    candidates << misspell(primary, random)
    candidates.uniq.first(random.rand(1..2)).reject { |value| value == primary || value.strip.empty? }
  end

  # One letter changed, which is what a transliterator's vowel or a clerk's
  # typo looks like to every stage of the pipeline.
  def misspell(value, random)
    letters = value.chars
    position = letters.index { |character| character.match?(/[a-z]/i) }
    return value if position.nil?

    letters[position] = %w[a e i o u y].fetch(random.rand(6))
    letters.join
  end

  # Given names are drawn far more steeply than surnames, which is the shape
  # these lists have: a quarter of the individuals share a handful of given
  # names, while most surnames belong to one record.
  def given(random) = zipf(ALL_GIVEN, random, 4)
  def surname(random) = zipf(ALL_SURNAMES, random, 3)

  # Zipf-shaped: the front of the vocabulary is drawn far more often than the
  # tail, and `steepness` says how much more. This is the property the index's
  # rarity weighting exists for, so a corpus that did not have it would not be
  # measuring anything.
  def zipf(vocabulary, random, steepness)
    draw = random.rand**steepness
    vocabulary.fetch((draw * vocabulary.size).floor.clamp(0, vocabulary.size - 1))
  end
end
