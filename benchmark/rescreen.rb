# frozen_string_literal: true

# What it costs to apply a snapshot diff to a book of business (#60).
#
#     bundle exec rake benchmark:rescreen
#     RUBYOPT=--yjit bundle exec rake benchmark:rescreen
#
# The claim rescreening rests on is that the cost is the book times *what
# moved* rather than the book times the whole corpus. This measures both sides
# of that: the same 10,000 subjects through `Rescreen#call` against a typical
# daily diff, and through `Matcher#screen_all` against the whole list, which is
# what a service doing it the naive way pays every night.
#
# ### Two books, and the difference between them is the point
#
# **A book of business** is ordinary customer names, which is what a bank
# actually holds. Almost none of them share a feature with a record that moved,
# so almost none of them reach the scorer at all, and the cost is dominated by
# describing each subject's name in the three feature spaces the index is keyed
# on.
#
# **A book drawn from the corpus** is every subject named like somebody on a
# sanctions list -- the same Zipf-shaped given names, the same surnames. It is
# not a realistic book and it is not meant to be: it is the ceiling, and the
# number worth sizing a worst case from.
#
# ### Nothing here is committed
#
# Like benchmark/latency.rb, this measures the machine it ran on -- its CPU,
# its Ruby, whether YJIT was enabled -- so a committed copy would change on
# every laptop and say nothing about the library.

require_relative "../lib/active_sanction"
require_relative "../spec/support/synthetic_corpus"

module RescreenBenchmark
  # The size every other benchmark here uses: roughly OFAC plus the UN plus
  # Canada once aliases are counted.
  ENTITIES = 27_000

  # A book of 10,000, which is #60's acceptance criterion.
  BOOK = 10_000

  # A typical day on the OFAC SDN list, which is what the README's diff
  # example prints: a dozen designations, a handful of delistings, a handful of
  # amendments.
  ADDED = 12
  REMOVED = 4
  AMENDED = 5

  # How many subjects the naive comparison actually screens before it is
  # extrapolated. A full screening call is ~20 ms, so 10,000 of them is not a
  # thing to sit through to learn that it is minutes.
  NAIVE_SAMPLE = 100

  # Ordinary customer names -- deliberately not drawn from the sanctions
  # vocabulary, because a book of business is not a sanctions list.
  GIVEN = %w[
    James Mary Robert Patricia John Jennifer Michael Linda David Elizabeth William Barbara Richard Susan
    Joseph Jessica Thomas Sarah Charles Karen Daniel Nancy Matthew Lisa Anthony Betty Mark Margaret
    Priya Rahul Ananya Hiroshi Yuki Sofia Mateo Lucas Emma Noah Olivia Liam Ava Ethan Chloe Isaac
  ].freeze

  FAMILY = %w[
    Smith Johnson Williams Brown Jones Miller Davis Wilson Anderson Taylor Moore Jackson Martin
    Thompson White Harris Clark Lewis Robinson Walker Young Allen King Wright Scott Green Baker Adams
    Nelson Hill Campbell Mitchell Roberts Carter Phillips Evans Turner Parker Collins Edwards Stewart
    Morris Rogers Reed Cook Morgan Bell Murphy Bailey Cooper Richardson Cox Howard Ward Peterson
  ].freeze

  module_function

  def run
    jit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "yjit" : "no jit"
    puts "ruby #{RUBY_VERSION} (#{RUBY_PLATFORM}, #{jit}) -- active_sanction #{ActiveSanction::VERSION}"
    corpus = SyntheticCorpus.build(ENTITIES)
    changes = daily(corpus)
    books = { "a book of business" => ordinary, "a book drawn from the corpus" => sampled(corpus) }
    apply(changes, books)
    naive(corpus, books.fetch("a book of business"))
    churn(corpus, books.fetch("a book of business"))
  end

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def time
    started = clock
    result = yield
    [clock - started, result]
  end

  def row(label, value) = printf("  %<label>-34s %<value>s\n", label: label, value: value)

  # A diff shaped like one day of a live list: a few designations, a few
  # delistings, and a few records amended the way governments amend them --
  # an alias added and a program added, which are the two commonest.
  def daily(corpus, added: ADDED, removed: REMOVED, amended: AMENDED)
    random = Random.new(11)
    kept = corpus.first(corpus.size - added)
    withdrawn = kept.sample(removed, random: random)
    moved = (kept - withdrawn).sample(amended, random: random)
    ActiveSanction::Diff.new(
      from: snapshot(kept),
      to: snapshot(kept - withdrawn - moved + moved.map { |entity| amend(entity) } + corpus.last(added))
    )
  end

  def snapshot(entities) = ActiveSanction::Snapshot.new(source: :ofac_sdn, entities: entities)

  def amend(entity)
    ActiveSanction::Entity.new(
      id: entity.id, source: entity.source, type: entity.type,
      names: entity.names + [ActiveSanction::Name.new(value: "#{entity.primary_name.value} JR", kind: :aka)],
      programs: entity.programs + %w[SDGT]
    )
  end

  def ordinary
    random = Random.new(3)
    Array.new(BOOK) do |ordinal|
      ActiveSanction::Subject.new(id: "cust_#{ordinal}", type: :individual,
                                  name: "#{GIVEN.sample(random: random)} #{FAMILY.sample(random: random)}")
    end
  end

  def sampled(corpus)
    corpus.sample(BOOK, random: Random.new(7)).each_with_index.map do |entity, ordinal|
      ActiveSanction::Subject.new(id: "listed_#{ordinal}", name: entity.primary_name.value, type: entity.type)
    end
  end

  # The measurement #60 is judged on: a whole book against one day's diff.
  def apply(changes, books)
    elapsed, rescreening = time { ActiveSanction::Rescreen.new(diff: changes, threshold: 75) }
    puts "\nApplying #{changes.summary}"
    row("Rescreen.new", format("%<value>8.1f ms", value: elapsed * 1000))
    books.each { |label, book| measure(rescreening, label, book) }
  end

  def measure(rescreening, label, book)
    rescreening.call(book.first(500))
    elapsed, alerts = time { rescreening.call(book) }
    puts "\n  #{label}, #{book.size} subjects"
    row("elapsed", format("%<value>8.2f s", value: elapsed))
    row("per subject", format("%<value>8.1f us", value: elapsed * 1_000_000 / book.size))
    row("alerts", format("%<value>8d", value: alerts.size))
    row("one million subjects", format("%<value>8.1f minutes", value: 1_000_000 * elapsed / book.size / 60))
  end

  # The alternative this exists to replace: every subject against every record.
  def naive(corpus, book)
    matcher = ActiveSanction::Matcher.new(index: ActiveSanction::Index.build(corpus),
                                          snapshots: { ofac_sdn: "sha256:benchmark" })
    sample = book.first(NAIVE_SAMPLE)
    matcher.screen_all(sample.first(10).map { |entry| entry.query(threshold: 75) })
    elapsed, = time { matcher.screen_all(sample.map { |entry| entry.query(threshold: 75) }) }
    puts "\nThe same book screened against the whole list instead, #{matcher.size} names"
    row("#{NAIVE_SAMPLE} subjects", format("%<value>8.2f s", value: elapsed))
    row("extrapolated to #{BOOK}", format("%<value>8.1f minutes", value: BOOK * elapsed / sample.size / 60))
  end

  # The other end of the range: what a rescreen costs on the day a publisher
  # reissues a large part of its list, which is the case the candidate cap is
  # there for.
  def churn(corpus, book)
    puts "\nHow the cost moves with how much the list did"
    printf("  %<size>-12s %<names>10s %<build>10s %<run>12s %<each>10s\n",
           size: "records", names: "names", build: "build", run: "10,000", each: "per subject")
    [1, 21, 200, 2_000].each { |size| sweep(corpus, book, size) }
  end

  def sweep(corpus, book, size)
    changes = daily(corpus, added: size, removed: 0, amended: 0)
    build, rescreening = time { ActiveSanction::Rescreen.new(diff: changes, threshold: 75) }
    rescreening.call(book.first(500))
    elapsed, = time { rescreening.call(book) }
    printf("  %<size>-12d %<names>10d %<build>7.0f ms %<run>9.2f s %<each>7.1f us\n",
           size: size, names: rescreening.instance_variable_get(:@index).size, build: build * 1000,
           run: elapsed, each: elapsed * 1_000_000 / book.size)
  end
end

RescreenBenchmark.run
