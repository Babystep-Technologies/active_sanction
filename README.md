# ActiveSanction

[![CI](https://github.com/Babystep-Technologies/active_sanction/actions/workflows/ci.yml/badge.svg)](https://github.com/Babystep-Technologies/active_sanction/actions/workflows/ci.yml)

Welcome to your new gem! In this directory, you'll find the files you need to be able to package up your Ruby library into a gem. Put your Ruby code in the file `lib/active_sanction`. To experiment with that code, run `bin/console` for an interactive prompt.

TODO: Delete this and the text above, and describe your gem

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'active_sanction'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install active_sanction

## Usage

TODO: Write usage instructions here

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

### Tests and linting

`bundle exec rake` runs the RSpec suite, then RuboCop, then `srb tc`; all three must pass.

The suite is hermetic. `spec_helper.rb` calls `WebMock.disable_net_connect!(allow_localhost: true)`, so an un-stubbed HTTP call raises `WebMock::NetConnectNotAllowedError` instead of quietly reaching the internet. Parser specs run against committed fixtures — a suite that can reach a government server stops proving anything about our parsing and starts proving that the server is up.

Specs that genuinely need a real endpoint are tagged `:live`. They are excluded from the default run, and `WebMock` is re-enabled around each one:

    $ bundle exec rspec --tag live

### Benchmarks

`benchmark/` holds the measurements that answer a design question rather than
pass or fail, so they are not part of `rake`:

    $ bundle exec rake benchmark:similarity          # the matching algorithms
    $ bundle exec rake benchmark:index               # index build, memory, query latency
    $ bundle exec rake benchmark:scorer              # scoring latency, and what a threshold buys
    $ bundle exec rake benchmark:accuracy            # precision, recall and F1 against the labeled set
    $ bundle exec rake benchmark:latency             # what a whole screening call costs
    $ RUBYOPT=--yjit bundle exec rake benchmark:similarity

Each timed one prints the Ruby and JIT it ran under, because that is most of
what the numbers mean.

**`benchmark:accuracy` is the exception, and it is committed.** It measures the
library rather than the machine — the same fixtures and the same seeded corpus
give the same numbers on any laptop — so it writes its report to
[`benchmark/results/accuracy.md`](benchmark/results/accuracy.md), which is in
the repository. A diff in that file is a change in what this library finds,
which is the one thing about match quality that is otherwise invisible in a
code review: a weight nudged by two points does not look like anything in a
patch, and it is exactly what moves a name from found to missed. Run it when
you change the normalizer, the index, the similarity algorithms, the scorer or
the weights, and commit what comes out.

The labeled set behind it is [`benchmark/fixtures/labeled_set.yml`](benchmark/fixtures/labeled_set.yml):
87 queries written against the real published records the source fixtures
hold, each one labeled with what it is supposed to find and what kind of damage
it is doing to the name — a transliteration, an inverted order, a missing
patronymic, a typo, a legal form spelled out — plus the names that must *not*
alert. The file's header says where each record comes from and why every
invented one is invented.

Both harnesses hide the labeled records inside a synthetic corpus the size and
shape of the real lists, because precision measured against thirty records is
a number about the fixture. To run either against a real synced corpus
instead:

    $ BACKGROUND=store bundle exec rake benchmark:accuracy

### Static typing

Every file in `lib/` is `# typed: strict`, and new files are born that way: a
signature written beside the code costs a line, and one retrofitted a milestone
later costs an afternoon of reading the code back.

    $ bundle exec srb tc      # or `bundle exec rake`, which runs it last

`sorbet-runtime` is a dependency of the gem, because the signatures are inline
`sig` blocks and inline `sig` blocks are ordinary method calls. It is pure Ruby
and compiles nothing, so it clears the same bar the gemspec sets for Nokogiri.
The static half -- `sorbet` and `tapioca` -- is in the Gemfile and never
reaches an application.

What that costs a host, and how to spend nothing at all:

* Signatures on a path that runs per query are declared `.checked(:tests)`:
  enforced by this suite and inert in production. The normalizer (#26) is the
  first path that qualifies and carries it throughout; the scorers (#32) join
  it as they land. `spec/spec_helper.rb` turns those checks on with
  `T::Private::RuntimeLevels.enable_checking_in_tests`, which is what makes
  them mean anything, and `spec/sorbet_runtime_spec.rb` holds them to being
  inert in a host that configured nothing.
* A host that wants none of it can turn every check off before requiring the
  gem, which is supported and tested:

  ```ruby
  T::Configuration.default_checked_level = :never
  require "active_sanction"
  ```

**What the types are for, and where they deliberately stop.** The canonical
model is declared: `Entity` states that `dates_of_birth` is an array of
`PartialDate`, so an adapter handing over the string a publisher wrote is a
type error rather than a bug found three layers downstream. The runtime half of
a signature is shallow -- it sees the Array and not what is in it -- so the
adapter conformance group goes on asserting the element types per fixture,
which is what covers an adapter written outside this repository.
Everything a publisher wrote is `T.untyped`
on the way in, because the value objects already coerce it and raise
`ArgumentError` with messages written for whoever has to fix the record, and a
type error would say less. Three places are `T.untyped` on purpose and say why
in a comment where they sit: the source registry (duck-typed on `.key` and
`.new`, which is what makes a bank's internal watchlist a first-class source),
`XmlRecords::Backends` (same, for a backend registered from outside), and
`Snapshot#entities` (the storage conformance group builds a snapshot of
half-deserialized hashes on purpose, to prove it catches a store that hands
them back).

**Consumers who typecheck their own code** need nothing from us but the gem:

    $ bundle exec tapioca gem active_sanction

reads the inline signatures through `sorbet-runtime` and writes an RBI that
says what this version actually declares. No `rbi/active_sanction.rbi` is
shipped, deliberately -- a hand-maintained copy of the signatures would be a
second source of truth, and a signature that lies is worse than none.

**The RBIs under `sorbet/`** are the checker's working files: generated
definitions for the gems `lib/` reaches, plus one hand-written shim for the
Rails generator surface (railties is not in this bundle and is not worth
pulling a web stack in to describe four methods). They are excluded from the
packaged gem. Regenerate one with `bin/tapioca gem <name>`; a gem that only
ever runs the suite or the linter is excluded in `sorbet/tapioca/config.yml`,
since `srb tc` reads `lib/` and not `spec/` -- RSpec defines its helpers with
`def` inside blocks, which Sorbet reads as methods on `Object`, and one spec's
`def initialize(root:)` is enough to make `Object.new` a type error in the
library.

### Adding a source

[`docs/adding_a_source.md`](docs/adding_a_source.md) is the end-to-end walkthrough: reading the publisher's file before writing anything, choosing the format toolkit, mapping its fields onto the canonical model, deriving a stable id for a list that publishes none, trimming a fixture, wiring up the conformance spec, and registering the adapter — from inside this gem or from an application that never forks it. It ends with a complete worked adapter, its fixture and its spec.

There is no scaffold generator, deliberately. Roughly eight adapters at maturity do not repay one that has to be kept in step with `Sources::Base`, the conformance spec and the parser toolkits, and that goes stale silently when it is not; the document plus the closest existing adapter to copy does the same job with none of the upkeep.

### The adapter contract

Every source adapter is held to one shared example group, `"a sanction source"`, which is what turns "can we add a new sanctions list?" into a checklist. A new adapter's spec names the contract and its fixture:

```ruby
RSpec.describe ActiveSanction::Sources::CanadaSema do
  it_behaves_like "a sanction source", fixture: "canada_sema/sema.xml"
end
```

It checks what everything downstream of an adapter assumes and cannot check for itself: that the list declares a key, a jurisdiction, an authority and a URL, and registers itself; that `#parse` returns `Entity` objects with unique, deterministic ids, a canonical type and at least one name; that dates arrive as `PartialDate` rather than as the string the publisher wrote them as; that every record survives the round-trip through `#to_h`; that the publisher's own text is kept in `remarks`; and that an empty payload is refused rather than reported as a list with nobody on it. It is the floor and not the ceiling — only a spec that knows what is in the fixture can check that the list was read *correctly*, so every adapter still writes its own.

The group is `spec/support/shared_examples/sanction_source.rb`, with its options documented at the top. `spec/active_sanction/sources/conformance_spec.rb` holds it to being able to fail: each example there takes one rule out of an otherwise conforming adapter and checks that the contract notices.

### Reading OFAC's free text

The US SDN list publishes no date of birth, place of birth, nationality or passport column. All of it — 88,827 semicolon-delimited segments across 19,015 records — is prose in one `Remarks` field, written for a person reading a page:

    DOB 10 Dec 1948; POB Egypt; nationality Egypt; Passport 123456 (Egypt) expires 12 Dec 2015

`Sources::Ofac::RemarksParser` reads it — both OFAC lists, since they publish the same prose in the same field — which is what gives the largest list in the world secondary identifiers to match on rather than names alone. Extraction is **additive**: `Entity#remarks` keeps the publisher's whole string whether the parser understood it or not, so a pattern that goes stale costs structure and never content. Silent data loss is the worst failure a compliance tool has, and a segment nobody could parse is still in front of the user in the government's own words.

Because these are heuristics against text that changes without notice, every sync reports how much of it was read:

```ruby
source = ActiveSanction::Sources[:ofac_sdn].new
source.sync
source.remarks_coverage.to_s
# => "recognized 86428 of 88827 segments (97.3%), 53429 extracted"
source.remarks_coverage.top(3)
# => [["Member of the", 615], ["ICTY indictee.", 45], ["all offices worldwide.", 43]]
```

`recognized` counts segments matched as prose carrying no fields — statutory citations, `Linked To:` notes — as well as those that produced a value, because "this carries nothing" and "we have never seen this" are different states and only the second is work. `top` ranks the shapes nobody has taught it yet, digits masked, by how many records they cost; that ranking is how the label table in `remarks_parser/vocabulary.rb` gets extended.

### The two OFAC lists

OFAC publishes the SDN list and the Consolidated (non-SDN) list in the same shape: three headerless Windows-1252 CSVs joined on `ent_num`, `-0- ` for null, everything the canonical model has no column for written into `Remarks`. `Sources::Ofac` reads that shape once, and `OfacSdn` and `OfacConsolidated` declare only which list they are and where their files live.

They are separate sources, so a caller can screen either or both:

```ruby
ActiveSanction.configure { |c| c.sources = %i[ofac_sdn ofac_consolidated] }
```

The consolidated file is six lists in one — SSI, CMIC, NS-PLC, NS-MBS, CAPTA, FSE — and a hit on CMIC is a different finding from a hit on NS-PLC, so which one a record is on has to survive the parse. There is no list column: the only thing in the CSV that names a list is the program code, so `OfacConsolidated` maps it.

```ruby
entity.programs                                     # => ["CMIC-EO13959"]
ActiveSanction::Sources::OfacConsolidated.lists(entity)  # => [:cmic]
ActiveSanction::Sources::OfacConsolidated.names(entity)  # => ["Non-SDN CMIC List"]
```

It reads off `Entity#programs`, which is a canonical member, so it keeps working on a record that has been stored and read back rather than needing a column of its own downstream. The names are also appended to `remarks` behind the `[source fields]` marker, which is where a report reads them from.

Checked against OFAC's own attribution in `CONS_ADVANCED.XML`, the mapping is exact for 478 of the 481 published records. The three it is not are all `RUSSIA-EO14024`, the one program OFAC uses for both SSI and NS-MBS: Gazprom, Transneft and Rosselkhozbank are on both lists and come out marked SSI only, and nothing in the CSVs separates them from the 89 rows carrying the identical program pair that are on SSI alone. A program the table has never seen puts a record on no list and raises a parse warning, which is how a new authority surfaces.

### Canada's consolidated list

`Sources::CanadaSema` reads the one file Global Affairs publishes for the Special Economic Measures Act and the Justice for Victims of Corrupt Foreign Officials Act together — 5,690 records, flat, every element optional.

Two things about it are worth knowing before a screening policy leans on it.

**A Canadian record carries much less than an OFAC one.** There is no nationality, no address, no place of birth and no document number anywhere in the file. An individual is a surname, given names, a date of birth about a third of the time, and a free-text alias field. Nothing here can make a name match decisive the way an OFAC passport number usually does, so a clean Canadian result is weaker evidence than a clean OFAC one.

**The ids are ours, not the publisher's.** Canada publishes no identifier at all. What it publishes is a citation — which regulation, which schedule, which item — and item numbers are positions in a list that get renumbered when a schedule is amended. `CanadaSema::SourceRef` hashes the citation *and the name*, so an amendment that shifts every item up one reports as removals and additions rather than quietly handing one person's id to the next person along. The cost is that correcting a typo in a name re-ids that record; churn in a diff is a nuisance, one id covering two different people is a screening failure.

Two smaller judgment calls, both visible in the parsed record:

```ruby
entity.programs   # => ["Belarus"]        the English half of "Belarus / Bélarus"
entity.remarks    # => "[source fields] Country: Belarus / Bélarus; Schedule: 1, Part 1; Item: 2"
```

`Country-Pays` is not a nationality and is not read as one — a Ukrainian official listed under the Special Economic Measures (Russia) Regulations is published under `Russia / Russie`, and 80 records name a statute rather than a country. It names the regulation, so it is a program. The French half, and the citation the id came from, stay in `remarks`.

Aliases are split on semicolons and never on commas. A comma is genuinely ambiguous in this field: `Завод "Дагдизель", АО` would yield a bare Russian legal form as an alias, and `Министерство образования, науки и молодежи Республики Крым` is one ministry rather than two. That costs recall on roughly 300 records whose primary name is published anyway, which is the cheaper of the two mistakes.

### Storing what a sync produced

A synced list is a `Snapshot` — one source's entities plus a checksum over their content — and storage keeps one per source, written whole and read back whole.

```ruby
store = ActiveSanction::Storage::Memory.new
store.write_snapshot(ActiveSanction::Sources[:ofac_sdn].new.sync)

store.sources                    # => [:ofac_sdn]
store.read_snapshot(:ofac_sdn)   # => Snapshot, or nil if it was never synced
store.snapshot_meta(:ofac_sdn)   # => fetched_at, checksum, record_count, without reading the list
store.each_entity { |entity| index.add(entity) }
```

Those five methods are the whole interface, and the rule they exist to enforce is that **nothing on the query path may name a concrete store**. The matcher is written against `Storage::Base` and against nothing else, which is what lets an installation put its lists in gzipped JSON, in Postgres, or in something it wrote itself without any of that reaching the code that decides whether two names are the same person. It is also why the interface lands before the matcher rather than after it: an interface extracted from a matcher that already reads files is an interface shaped like files.

`Storage::Memory` is a real adapter — a process that syncs and screens without wanting to own a directory should use it, and pays only a full download on each boot — and it is also the test double for storage throughout this suite. It is written as a `Storage::Base` subclass implementing the same four methods as everything else rather than as a Hash a spec passes around, because a double that is not held to the contract stops describing what the real adapters do a release or two before anyone notices.

Two of its rules are about the same failure, which is the one this library can least afford:

```ruby
store.read_snapshot(:eu_fsf)             # => nil
store.fetch_snapshot(:eu_fsf)            # => raises Storage::MissingSnapshot
store.each_entity(sources: %i[ofac_sdn eu_fsf])   # => raises Storage::MissingSnapshot
```

A source nobody has synced reads back as `nil` and never as an empty snapshot: "we have never fetched this" and "this list has nobody on it" are different states, and no sanctions list has ever said the second. And a caller that *named* its lists gets an exception for one that is missing rather than fewer entities, because a screening run that quietly covers two of the three lists an application configured is indistinguishable from one that covers all three — and both report the name clear.

`each_entity` is an `Enumerator` and reads one list at a time, so building an index over every source does not first materialize every entity of every source.

### The default store: gzipped JSON in a directory

`Storage::FileSystem` is what an installation gets without provisioning anything. `zlib` and `json` are stdlib, so persisting 19,015 OFAC records costs a directory — which is what makes the same library usable from a cron job, a CLI, a CI run, and an air-gapped host that only ever receives a copied directory.

```ruby
store = ActiveSanction::Storage::FileSystem.new                # ~/.active_sanction
store = ActiveSanction::Storage::FileSystem.new(root: "/srv/lists")

ActiveSanction.configure { |c| c.storage_dir = "/srv/lists" }  # or globally
```

`storage_dir` is deliberately not under `cache_dir`. Everything in the cache directory can be fetched again and a user is entitled to delete it; a stored snapshot cannot be fetched again, because publishers overwrite their files in place and the list version a past decision was screened against exists only here.

**The layout is private.** What is on disk is optimized for local reading and rewriting and is expected to change; the portable, cross-machine representation is the bundle format, which has its own stability contract. As it stands, each source gets a directory holding a `meta.json` sidecar and one gzipped list:

```
~/.active_sanction/ofac_sdn/meta.json
~/.active_sanction/ofac_sdn/snapshot-sha256-9f86d081884c7d65....json.gz
```

The sidecar is exactly `Storage::Meta#to_h`, which is what makes `snapshot_meta` cheap: printing how old six lists are reads six small JSON files instead of inflating and deserializing tens of megabytes.

**A sync killed part-way through either has not happened or has happened completely.** That is why the list file is named after the content it holds rather than sitting at a fixed `snapshot.json.gz`. Replacing a list means replacing both the list and the sidecar describing it, and whichever order two renames happen in, a process killed between them leaves a snapshot and a meta that do not describe each other — the new list under the old checksum, or a sidecar advertising records that are not there. Either way the previous list is gone and the source is unreadable until the next successful sync.

Naming the file after its checksum removes the conflict. A new list goes down under a name nothing else occupies, so it cannot destroy the list already there, and `meta.json` — one small file, one atomic rename — is the single point at which the new generation becomes live. Interrupt before that rename and the store is exactly as it was, plus a stray file the next write sweeps; interrupt after it and the new list is live and complete. There is no third state.

**Nothing partial is ever returned.** `Snapshot.from_h` re-derives the checksum from the records that came back and refuses to build if it does not match the one stored with them, so a truncated file, an edited record and a dropped record all raise rather than screening against a list that is quietly missing names:

```ruby
store.read_snapshot(:ofac_sdn)   # => raises Storage::CorruptSnapshot, naming the directory to delete
```

A snapshot written by a newer `active_sanction` raises `Storage::UnsupportedSchema` instead, and does so from the sidecar before the list is inflated — a newer schema will usually still deserialize, into records missing whatever it added, with a checksum that verifies and no symptom other than names that stop matching.

Many readers and one writer, across processes, is the arrangement it is built for: a scheduled sync replacing a list while web workers screen against it. Committing is a rename, so a reader sees the whole previous generation or the whole new one. Two processes syncing the *same* source at once is not supported and nothing here makes it safe.

### Storing lists in the host's database

`Storage::ActiveRecord` is optional in the strong sense: ActiveRecord is not a dependency of this gem and must not become one. The adapter is loaded only where ActiveRecord has already been loaded — by the host, or by Rails, whichever order that happens in — and everything above works with it absent.

```console
$ rails generate active_sanction:install
$ rails db:migrate
```

```ruby
store = ActiveSanction::Storage::ActiveRecord.new
store.write_snapshot(ActiveSanction::Sources[:ofac_sdn].new.sync)
```

**What the database buys is the prefilter.** Scoring 19,015 OFAC records against one name in Ruby is the cost the matcher wants to avoid paying, and an indexed equality probe narrows that to a handful of candidates before any of them are loaded:

```ruby
ActiveSanction::Storage::ActiveRecord::Row::Name.matching("Aiman al-Zawahiri").pluck(:entity_id)
ActiveSanction::Storage::ActiveRecord::Row::Identifier.matching("AB-123 456").pluck(:entity_id)
```

So unlike the filesystem layout, the schema here is public: five tables, `active_sanction_snapshots` and `active_sanction_entities` with `active_sanction_names`, `_addresses` and `_identifiers` hanging off them, with the models, columns and associations part of what the adapter promises. `normalized_value` is the indexed column both scopes probe, and `ActiveSanction::Storage::ActiveRecord.prefilter_key` is how a query builds the same key the write built — a key folded any other way will not find the rows. That fold is deliberately crude and deliberately not the matcher's normalizer: its only job is candidate generation, where a key that collides too eagerly costs a few extra records to score and a key that misses costs a sanctioned person who never reaches the scorer at all.

**A write is one transaction, and `insert_all` in batches inside it.** A full OFAC SDN sync is 19,015 entities and some 65,000 rows hanging off them; a sync that dies partway through rolls back to the list that was there before it, so there is no half-updated list to inspect and none to screen against. Row-at-a-time saves are the obvious alternative and are not what this does.

**Nothing partial is ever returned**, on the same terms as the filesystem adapter and by the same mechanism. The snapshot is rebuilt with the checksum stored beside it, so construction re-derives the digest over the records that actually came back — a row deleted by hand, a write that half landed, a column edited in a console all raise `Storage::CorruptSnapshot` rather than screening a customer against a list that is quietly missing people. That is also why `each_entity` is inherited rather than reimplemented as a cursor: a checksum covers a whole list, so a store that streamed rows straight to the matcher would be handing it records it cannot prove are all of them.

Concurrency is the database's problem, which is the point — readers on other processes and other machines see the list as it was before a write or as it is after it, rather than depending on a rename that only holds within one filesystem.

### The storage contract

Every storage adapter is held to one shared example group, `"a storage adapter"`, the same way every source adapter is held to `"a sanction source"`:

```ruby
RSpec.describe ActiveSanction::Storage::Memory do
  it_behaves_like "a storage adapter"
end
```

An adapter that needs something to be built says how, and is otherwise held to exactly the same checklist:

```ruby
RSpec.describe ActiveSanction::Storage::FileSystem do
  it_behaves_like "a storage adapter" do
    def build_store = described_class.new(root: Dir.mktmpdir)
  end
end
```

The ActiveRecord adapter is held to it against a database built by rendering and running the migration the generator actually copies, rather than one the suite wrote for itself — a schema no user gets is a schema the suite would keep passing against on the day it stopped matching the adapter.

Most of what it checks is a way of losing records quietly. A store that returns an empty snapshot for a source nobody synced, one that drops the third of four entities on the way back, one that reorders them, one that accumulates two writes of a list instead of replacing it — none of those raise, all of them return something that looks like a sanctions list, and the report they produce says the name you screened is clear. What it deliberately says nothing about is durability, concurrency and performance, which are the things the adapters genuinely differ on: that a file write is atomic, that a database write is one transaction, that the in-memory store is safe to screen from on many threads. Those are properties of one implementation, and each adapter's own spec has to make them.

The group is `spec/support/shared_examples/storage_adapter.rb`, and `spec/active_sanction/storage/conformance_spec.rb` holds it to being able to fail: each example there takes one rule out of an otherwise conforming adapter and checks that the contract notices.

### Syncing every list, and what happens when one is down

One source at a time is `Sources[:ofac_sdn].new.sync`, which fetches, parses and checksums, and deliberately rescues nothing. `ActiveSanction.sync!` is the layer above it — what a *run* does, which is a different set of decisions.

```ruby
report = ActiveSanction.sync!                   # every configured source
report = ActiveSanction.sync!(:ofac_sdn)        # one
report = ActiveSanction.sync!(force: true)      # bypass conditional GET
report = ActiveSanction.sync!(concurrency: 3)   # fetch from three publishers at once

report.failed?                  # => true
report[:ofac_sdn].status        # => :updated
report[:un_consolidated].error  # => "Net::ReadTimeout: execution expired"
exit report.exit_code           # 1 if any source failed, so cron and CI can alert
```

**One source failing must not abort the others.** Government endpoints go down, change format without notice, and occasionally serve half a file. If a UN outage stopped OFAC from syncing, the library would fail exactly when it is most needed — during an incident, which is when lists move. So every source runs inside its own rescue, and the run ends with a summary rather than an exception. `StandardError` and not `Exception`: an `Interrupt` is somebody stopping this run on purpose, and swallowing it to go on downloading three more lists is not isolation, it is a job that will not die.

**A failed source keeps its previous snapshot.** Nothing clears a stored list on failure — not a 500, not a parse error, not a publisher that started serving HTML where XML used to be. Screening against yesterday's OFAC list produces a report with a known, visible age on it; screening against an empty list produces a clean report for every customer, which is the most expensive thing this library can get wrong. That trade is only safe while the age is visible, so every result carries the record count and age of the list that source is *still* being screened against:

```
4 sources in 13.08s: 1 updated, 2 unchanged, 1 failed
  ofac_sdn           updated    19015 records  just fetched   12.41s
  ofac_consolidated  unchanged   1203 records  2h old          0.28s
  canada_sema        unchanged    684 records  2h old          0.19s
  un_consolidated    failed       612 records  3d old          1.11s  Net::ReadTimeout: execution expired
```

That table is `report.to_s`, but the report is an object rather than console output: it is what a host application alerts on, and `Sync::Report#to_h` round-trips through JSON so noticing a source that has been quietly failing since Tuesday does not mean scraping a log. `report.unscreenable` is the louder case underneath a failure — a source that kept its previous list is stale, one with nothing stored is not screened at all.

**Unchanged sources cost nothing.** A publisher that answers 304 is never parsed and never stored: the whole saving of conditional GET is that the parse — the expensive half for OFAC's three-file join — is skipped along with the download. A source whose bytes changed but whose parsed *content* hashes to what is already stored is also reported unchanged and not rewritten, since a publisher regenerating an identical file with a new timestamp is not a new list version, and rewriting tens of megabytes to say so would churn the checksum every audit record cites. The exception is a source with nothing readable stored: a conditional request asks the publisher whether the copy we hold is current, so a missing or corrupt snapshot is fetched in full rather than left to a 304 that would report it unchanged.

**Parallel fetching is polite by construction.** `concurrency:` bounds how many *publishers* are fetched from at once, never how hard any one of them is asked: sources are grouped by the host they download from and each group runs in order, because two of the built-in adapters are the same Treasury file server. It defaults to 1.

Sync is a capability of the local backend rather than of every backend — a hosted one does not sync, because data freshness is exactly what its user is paying somebody else to handle — which is why the report is a serializable object and why nothing in it writes to `$stdout`.

### Noticing what changed between two syncs

Screening is not a one-time event. A customer cleared last month may be listed today, and the obligation is to notice. Re-running an entire book of business against an entire list every night is how most services answer that, and it is why most services answer it weekly instead.

```ruby
diff = ActiveSanction.diff(:ofac_sdn, from: last_months_snapshot, to: todays_snapshot)
diff = ActiveSanction.diff(:ofac_sdn, from: last_months_snapshot)  # `to:` is what is stored now

diff.added      # => [Entity], newly listed
diff.removed    # => [Entity], delisted
diff.modified   # => [Diff::Change], amended, with the fields that moved
diff.changed    # => [Entity], what to re-screen the book against
diff.churn      # => 0.001104, the fraction of the previous list that moved
```

```
ofac_sdn: 19015 -> 19023 records, 12 added, 4 removed, 5 modified (0.1% of the previous list)
  + ofac_sdn:41234  IVANOV, Ivan Ivanovich  [SDGT]
  - ofac_sdn:2674   ABBAS, Abu  [SDGT]
  ~ ofac_sdn:36     names +1, programs +1
```

That table is `diff.to_s`; `Diff#to_h` is the same thing JSON-ready, carrying both snapshots' checksums so a diff says which pair of list versions produced it. There is no `.from_h` — a diff is derived rather than stored, and those two checksums are what makes it reproducible. Keep them and the diff can always be computed again; keep the diff and you have a copy of an answer nobody can check.

**Delistings matter as much as listings.** They are the half that a re-screen against new records only would miss: a delisting is what lets a customer back through the door, and a service that never notices one goes on blocking somebody the government stopped sanctioning in March. `diff.changed` is deliberately the additions and the amendments — the records to screen a book *against* — while `diff.removed` is a different job done with the same diff, which is clearing the alerts that are already open.

**An amendment is not a delisting plus a listing.** Governments amend far more records than they publish or withdraw: a passport number is corrected, an alias is added, a program is amended. The two snapshots are joined by entity id, so those report as one `Diff::Change` carrying the fields that moved, rather than as a removal and an addition — which would put a delisting in front of an analyst that never happened. That rests entirely on ids being stable between syncs, which is why the adapter conformance group asserts id stability and why the Canada adapter hashes a citation *and* a name into its synthetic one. Ids that move would make every sync look like a full replacement.

**A first sync is a baseline, not 19,015 new listings.** With no previous snapshot there is nothing to compare, and reporting the whole list as added would be false: those records were not listed today, they were listed over twenty years and we are only now looking. So a diff with no `from` reports `baseline?`, three empty lists, and nothing to re-screen — because the right response to a first sync is a deliberate full screening run rather than one driven by a diff that is really a list.

**Order is not a change, and neither is a reordered alias.** Two snapshots of the same file compare equal whatever order the publisher emitted it in, and the collection fields inside a record — names, addresses, identifiers, dates of birth, nationalities, programs — are compared by membership rather than by position. The one thing that is never decided for the host is which amendments are too small to bother re-screening: a corrected passport number and a reworded remark reach the scorer by different paths, and a library that filtered them would be choosing which sanctions hits it is willing to miss.

**Nothing here reads OFAC's `/changes/latest`.** OFAC serves a delta feed of its own, and a diff has to describe the two list versions *we hold* — a run that skipped a day, or held a stale list because a fetch failed, is not on either end of the publisher's delta. Cross-checking a computed diff against that feed is worth doing, since it is how a parser regression that quietly drops records gets caught, but it belongs in the OFAC adapter as one publisher's answer rather than in the general shape of a diff.

### Normalizing a name for matching

Screening compares folded strings, never published ones. `ActiveSanction::Normalizer` is where that fold happens — stage one of the matching pipeline, and the only place in the library a name is folded at all.

```ruby
form = ActiveSanction::Normalizer.call("O'Brien, Seán")
form.original   # => "O'Brien, Seán"
form.value      # => "o brien sean"
form.tokens     # => ["o", "brien", "sean"]
```

Five stages, in order: Unicode NFKD, strip the combining marks it separated, casefold (`String#downcase(:fold)`, so `Straße` reaches `strasse`), punctuation to spaces, collapse whitespace. Plus one table for the Latin letters decomposition cannot reach — nothing decomposes `ø` into an `o`, so `Bjørn` would otherwise never meet `Bjorn`, and the same goes for `ł`, `đ`, `þ`, `æ`, `ı` and `ə`.

Punctuation becomes a space rather than nothing, which is the conservative direction: `Al-Qaida` and `Al Qaida` are both `al qaida`, where closing the gap would have made each unreachable from the other. Both halves of the result travel together because both are needed — the scorers compare `value` and the index keys on `tokens`, while a hit is reported in `original`, in the government's own capitalization. A report that quotes the folded string is quoting this library rather than the list.

**There is one code path, and that is the point.** A matcher whose index and query fold differently does not fail; it silently stops matching, on exactly the records the difference touches. If the indexer strips `'` and the query path does not, `O'Brien` becomes unreachable from `O'Brien`, the suite still passes, and the symptom is a sanctioned person reported clean. So both sides call `Normalizer.call`, folding is idempotent (`n(n(x)) == n(x)`), and the suite holds every name in every committed fixture to coming out of it unmarked, lowercase, punctuation-free and single-spaced.

**Non-Latin script is not transliterated, and that is a known recall limitation.** Cyrillic, Arabic, Han, Kana and Hangul come out casefolded and stripped of marks, in their own script: `Путин` does not become `putin`, so a Cyrillic name matches a Cyrillic query and nothing else. What makes that survivable is that these lists publish a non-Latin name as an additional variant rather than instead of a Latin one — the UN's `ORIGINAL_SCRIPT` aliases and Canada's Cyrillic ones sit on records that carry a romanized name too, which is the one an English-language query finds. Romanization is a per-script problem with several competing standards for Cyrillic alone, and guessing at it costs precision everywhere; Double Metaphone (#30) covers the case this actually leaves open, which is one name romanized two ways.

Two things it does handle that are easy to miss. Arabic vocalization marks are stripped, so one publisher's `مُحَمَّد` and another's `محمد` fold together, and a hamza-carrying alef folds onto a bare one. And the modifier letters a transliterator uses as apostrophes — the `ʻ` in `Sanʻa`, the `ʼ` in `Qurʼan` — are read as punctuation rather than as the letters Unicode calls them, since a mark that survives the fold is a token no query is ever typed with.

Folding is memoized, because the same string is folded over and over: an index build folds every name once per index it feeds, aliases repeat across records, and a rescreening run folds the same book of subjects against every new snapshot. The cache is bounded and internally synchronized, so one web process can screen on many threads through the shared `Normalizer.call`. A caller that wants its own — a smaller one, or one it can discard after a batch — builds `ActiveSanction::Normalizer.new(cache_limit: 1_000)` and gets an identical fold.

### Dropping the tokens that identify nothing

Telling `Normalizer.call` what kind of entity a name belongs to turns on a sixth stage: the token dictionaries, which drop the parts of a name that every entity of its kind shares.

```ruby
ActiveSanction::Normalizer.call("Public Joint Stock Company Gazprom", type: :organization).value  # => "gazprom"
ActiveSanction::Normalizer.call("PJSC Gazprom", type: :organization).value                        # => "gazprom"
ActiveSanction::Normalizer.call("Hajji Abdallah", type: :individual).value                        # => "abdallah"
ActiveSanction::Normalizer.call("PJSC Gazprom").value                                             # => "pjsc gazprom"
```

"Rosneft Oil Company" and "Rosneft" are the same company, and a scorer comparing one token in three will not say so. `LTD`, `GMBH` and `OOO` say how an entity is incorporated rather than which entity it is — and OFAC publishes the same firm as "PUBLIC JOINT STOCK COMPANY GAZPROM", "PJSC GAZPROM" and "GAZPROM PAO" on the same record, which fold to one string here and to three without this stage.

**The lists apply per entity type, and that is not tidiness.** `CO` is a legal form on a company and a syllable in a great many personal names; `AS` is a Norwegian company and an English word. Legal forms and function words are stripped from organizations, honorifics from individuals, and nothing at all from a vessel, an aircraft, or a caller who did not say. Passing no type is a different question rather than a worse answer — and both sides of a comparison have to ask the same one, since a query folded as an organization against an index folded as a bare string is the same silent mismatch one stage further down.

**The preserve list wins, always.** `bin`, `ibn`, `bint`, `abu`, `abd`, `al`, `el`, `van`, `von`, `de`, `da`, `del`, `della`, `di` and `dos` look like noise to a stopword filter and are structural parts of the names they appear in: stripping `bin` from "Osama bin Laden", or `abd` from "Shaykh Umar Abd Al Rahman" — a real SDN entry — does not shorten the name, it changes it, and costs both a false negative and a false positive. No entry containing one of these is applied, whatever list it is on and whoever put it there. The collision is real and shipped: `AL` sits on the organization stopword list, strips nothing, and reaches the scorers in every name it belongs to.

**The lists are data files, not constants.** They live in [`lib/active_sanction/normalizer/dictionaries/`](lib/active_sanction/normalizer/dictionaries) — one entry per line, `#` comments, four files — because what belongs on them is settled by reading government lists rather than by reading Ruby, and a contributor adding `OYJ` should be sending a one-line diff. Entries are written the way a publisher writes them and folded by the same `Form` the names are folded by, so `LTD` covers `Ltd` and `ltd.`, and an entry that folds to several tokens is matched as a contiguous phrase, wherever in the name it falls. Folding does not join tokens, though, so `LLC` and `L.L.C.` are separate entries and the file carries both.

A host adds its own with a Hash, or replaces the shipped lists outright with a dictionary it builds — which has to spell out all four lists, including the particles, because a replacement that quietly dropped the preserve list would strip `al` out of several hundred SDN names without saying anything:

```ruby
ActiveSanction.configure do |c|
  c.normalizer_dictionary = { legal_forms: %w[OYJ TBK], particles: %w[ben] }
end
```

One deliberate refusal: a name whose every token is on a strip list keeps them all. An organization called "The Company" is a poor name to screen on and a worse one to index as the empty string, which matches everything or nothing depending on which scorer sees it first.

### Scoring a candidate, with reasons

`ActiveSanction::Scorer` is stage four: it turns a candidate into a number between 0 and 100 and the account of how it got there.

```ruby
subject = ActiveSanction::Scorer::Subject.new(
  name:           "Vladimir Putin",
  type:           :individual,
  dates_of_birth: "1952-10-07",
  nationalities:  %w[RU]
)

result = ActiveSanction::Scorer.call(subject, entity, threshold: 75)

result.score        # => 97.3
result.name.value   # => "PUTIN, Vladimir Vladimirovich"
result.explanation.map(&:to_s)
# => ["+76.3 name: matched primary name \"PUTIN, Vladimir Vladimirovich\"",
#     "+15.0 dob: date of birth 1952-10-07 matches",
#     "+6.0 nationality: RU matches"]
```

**The score is the explanation.** It is not stored beside the reasons, it is the sum of them, rounded once — there is no arithmetic anywhere in the library that can move one without the other. A compliance officer has to answer "why did this score 87?" to an examiner, and a number that merely travels alongside a list of reasons is one that can come apart from them in a later release and be quietly wrong for a year. So the explanation is never empty, it always adds up, and where the 0..100 clamp moves the total off the sum that correction is itself a reason.

**An entity's score is the best of its names.** OFAC ships 20,147 aliases against 19,321 primary names and the UN publishes as many as a dozen spellings of one person, so averaging over an entity's names would punish the records that describe themselves most thoroughly, and reading only the primary name would miss most of what these lists are for. Every name is scored, the best wins, and the winner is on the result — a report has to be able to say which spelling produced the hit. The UN's `QUALITY=Low` aliases are penalized before the maximum rather than after it, so a good name scoring 85 beats a low-quality one scoring 90.

**Four algorithms and a phonetic pass, blended by documented weights.** `token_set` carries the largest share at 0.45, because a 1.0 from it means every word of the shorter name appears in the longer one — the shape of nearly every honest partial query. The character algorithms are the brake: they are what keep `kim jong un` and `kim yong chol` apart, where sorting loses the information that two names were already written in the same order. Every number lives in `ActiveSanction::Scorer::Weights` with the reason it is what it is, and a host can change any of them.

```ruby
ActiveSanction.configure { |c| c.scorer_weights = { dob_conflict: -20.0 } }
```

The blend is a weighted mean rather than the weighted maximum the well-known Python ratio uses, and that is a choice with a cost. A maximum would score the query `Mohammed` against `MOHAMMED AL-ZAWAHIRI` in the nineties, and on a corpus where a quarter of the individuals share a handful of given names that is not tolerance, it is an alert queue nobody can work through. A mean puts the same pair in the high seventies — still high, because the caller's whole query really is on the record — and what pulls it apart from a real match is not the name at all.

#### Secondary identifiers are what make it a screening tool

Name similarity alone puts thousands of people on a list of a few hundred. The passport number, the date of birth and the nationality are the corrective, and they are the fields a compliance officer already has in a customer record.

| Signal | Default |
|---|---|
| Passport / national ID exact match | **+40** — near-decisive; two people share a name, not a passport number |
| Date of birth, exact full date | +15 |
| Date of birth, year-only overlap | +6 |
| Date of birth, genuine conflict | **−35** |
| Nationality agreement | +6 |
| Nationality conflict | −12 |
| UN `QUALITY=Low` alias | −10 |
| Entity type mismatch | filtered out entirely, at any name similarity |

**Absent is not conflict, and it is the rule everything obeys.** Most records lack most identifiers: Canada publishes no aliases and frequently no date of birth, OFAC's dates are prose in a remarks field, and the UN grades what it has and says nothing about what it does not. Every adjustment fires only when *both* sides carry the field — a missing field produces no reason at all, not a small penalty. Treating absence as disagreement would systematically under-score the jurisdictions that publish least and hide real hits behind a threshold, which is the quietest way to build a screening tool that does not screen.

The same rule governs a country nobody can resolve. Nationality is the one identifier published as prose, so a query of `RU` meets a record of `Russian Federation` and a query of `Iran` meets `Iran, Islamic Republic of`; compared as strings those are disagreements, and a penalty on them would land on exactly the records where the caller supplied the most information. `ActiveSanction::Country` resolves both sides against a shipped ISO 3166-1 table — codes, ISO names and the aliases a list actually writes, in [`lib/active_sanction/countries.txt`](lib/active_sanction/countries.txt) — and a value it does not recognize is treated as absent rather than as a contradiction. A conflict needs both sides resolved.

An entity type mismatch is a filter rather than a penalty. `NORTHERN STAR` is a ship and a person, vessels and aircraft are about 10% of the SDN list, and there is no score at which a compliance officer wants a ship in a list of people.

#### One name transliterated two ways is the case this does not solve

`QADHAFI, Muammar` against `Muammar Gaddafi` scores 58.8, and raising the phonetic share does not fix it — pushing that share from 0.05 to 0.15 moves the pair to 66.8, still under any threshold worth setting, while lifting every common-name near-miss by the same few points. It buys nothing and costs precision, so it is not done.

What covers the case is upstream. These lists publish the variants themselves — OFAC's Qadhafi record carries `QADHAFI`, `QADAFI`, `GADAFI` and `KADAFI` among others — the index keys on Double Metaphone so a query for one spelling retrieves a record filed under another, and the scorer takes the maximum over an entity's names, so the query is scored against the alias it is actually a spelling of. The residue is a record carrying one spelling and one only, queried with a different one. That is a real limitation, and the honest mitigation is the identifier fields rather than a bigger number in the weights.

#### `threshold:` is how a screening call fits in its budget

Scoring is nearly all of what a screening call costs, and a threshold is what makes it affordable — without changing a single score:

```
threshold       no jit      yjit    results per query
        0     105.6 ms   46.3 ms                184.0
       75      37.5 ms   16.3 ms                 31.4
       85      24.0 ms   10.5 ms                 10.6
```

The five shares are measured one at a time, cheapest-to-tighten first, and everything still unmeasured is worth at most its own weight — so the moment `total + remaining` falls under the cutoff, the rest is not computed. What *is* computed is computed with a threshold of its own, derived from the weights left to come, which is what lets Levenshtein turn it into an edit budget and stop its rows early. Every exit is a bound on what a pair can reach and never an approximation of what it did reach, so a result at or above the threshold is exactly the result the same call without one returns. `bundle exec rake benchmark:scorer` prints the sweep and fails loudly if a threshold ever changes a score.

It is applied to the whole score rather than to the name, which matters: a subject carrying the right passport number needs forty points less of a name than one carrying nothing.

#### What 75 is set from

The default was a guess until `rake benchmark:accuracy` measured it. Against 87 labeled queries — real published records queried the way a customer record spells them, plus the common names and near misses that must not alert — F1 peaks at exactly the number this library ships:

```
threshold  precision  recall      F1   found  missed  false alerts  noise/query
       60      0.831   0.970   0.895      64       2            13          6.7
       75      0.899   0.939   0.919      62       4             7          1.7   <- best F1
       85      0.963   0.788   0.867      52      14             2          1.2
```

Raising it to 85 removes five false alerts and stops returning ten listed records. Lowering it to 60 finds two more and costs six false alerts and five times the noise. F1 weighs those two errors equally and a sanctions screen does not — a false positive costs an analyst minutes, a false negative is a sanctioned counterparty onboarded — so the default sits at the peak rather than above it, and `threshold:` is per query for the host that has to be more careful still. What lowering it costs is the noise column rather than something to be discovered in production.

The same report breaks recall down by list, which is the number an averaged one would hide:

```
source                 queries  recall   found
canada_sema                 25   0.880   22 of 25
un_consolidated             20   1.000   20 of 20
ofac_sdn                    15   0.933   14 of 15
```

Canada is measurably worse and it is not the matching's fault: the list publishes no alias kinds, packs several aliases into one comma-joined string and gives a date of birth for a minority of its records, so there is less to match against. That is a fact about coverage a compliance team has to know, and [the committed report](benchmark/results/accuracy.md) names every record this version misses and every one it wrongly alerts on.

`rake benchmark:latency` is the other half — a whole screening call against 47,000 indexed names, at the median and in the tail:

```
threshold       mean       p50       p95       p99   slowest
        0     54.7 ms   51.4 ms  100.6 ms  128.6 ms  140.3 ms
       75     18.2 ms   14.8 ms   47.9 ms   85.7 ms   91.5 ms
       85     11.7 ms   10.2 ms   22.7 ms   39.1 ms   40.2 ms
```


### Screening a name

`ActiveSanction.screen` is the whole pipeline behind one call: fold the query once, retrieve the names worth comparing, score each with reasons, then filter, rank, cap and stamp.

```ruby
results = ActiveSanction.screen(
  name:          "Vladimir Putin",
  type:          :individual,
  date_of_birth: "1952-10-07",
  countries:     %w[RU],
  sources:       %i[ofac_sdn un_consolidated],   # default: every synced list
  threshold:     75,
  limit:         10
)

hit = results.first
hit.score            # => 97.3
hit.entity           # => Entity
hit.matched_name     # => the specific Name that produced the score
hit.source           # => :ofac_sdn
hit.explanation      # => [Reason, ...], summing to the score
hit.snapshot_id      # => "sha256:9f86d081884c7d65..."
hit.matcher_version  # => "1"
hit.screened_at      # => 2026-09-06 11:04:02 UTC
```

An empty array is the ordinary answer — most customers are not on a sanctions list — and everything that could make it a lie rather than a fact raises instead. A store nobody has synced raises `Matcher::NotSynced`; a query naming a list the matcher does not hold raises `Storage::MissingSnapshot` rather than quietly covering two of the three lists it was asked for. Screening against a list that is not there returns a clean report, and a clean report is the most expensive thing this library can get wrong.

`date_of_birth:` and `dates_of_birth:`, `country:`, `countries:` and `nationalities:`, `identifier:` and `identifiers:` all mean the same thing. A caller with one date writes the singular and a caller with three writes the plural, and neither should have to remember which this library prefers.

**One result per entity, in the alias that won.** An entity is retrieved once for every one of its names the query looks like, and its score is the best of those names, so each is scored once and reported once. Results are ordered by score descending and ties by entity id — ties are not a corner case on these lists, and which of two identically scored records is listed first has to be the same answer in a year's time.

#### Every result is a reproducibility stamp

`MatchResult` is the most permanent object in the gem: it is what ends up in a customer's audit record, read by people who have neither this process nor this version of the gem. So it serializes to a documented shape, `MatchResult.from_h` rebuilds it losslessly from that shape, and every field that could have changed the answer travels with it.

```ruby
JSON.generate(hit.to_h)                                  # into an audit record
ActiveSanction::MatchResult.from_h(JSON.parse(json))     # == hit, years later
```

Four fields make a past decision re-derivable, and each of them is a way the same query could score differently today:

| Field | What it pins down |
|---|---|
| `snapshot_id` | the checksum of the exact list version that answered. Publishers overwrite their files in place, so "the OFAC list" is not a thing that can be cited; a checksum is |
| `matcher_version` | which matching pipeline scored it — deliberately not the gem version, which moves for a new source adapter or a documentation release |
| `weights` | what each signal was worth. A host that retunes `dob_conflict` changes what every past decision would score today |
| `query` | what was screened, and under what threshold. A hit at 78 means one thing under a threshold of 75 and cannot have existed under 85 |

`backend` is the fifth, and it is what makes the seam real: a hosted backend answers the same call against data somebody else keeps fresh, and an audit record has to say which one answered. The score itself is never stored beside its reasons — it is the sum of them, re-derived on construction, and a `score:` that disagrees with the explanation it arrives with is refused rather than laundered into a record.

#### Holding a matcher, and screening from many threads

`ActiveSanction.screen` is sugar over one shared `Matcher`, built from the configured store on first use. A server can hold its own instead, which is what a process needing two configurations at once — a pinned list version for an audit re-run beside the current one for live traffic — has to do:

```ruby
MATCHER = ActiveSanction::Matcher.build(store, sources: %i[ofac_sdn])

MATCHER.screen(name: "Vladimir Putin")
MATCHER.screen_all(customers.map { |c| { name: c.name, dob: c.born_on } })   # one array of results per query
```

A matcher holds an index, the checksum of every list in it, the weights it scores with and the candidate cap it retrieves with. All of it is fixed at construction and the object is frozen, so `screen` allocates locals and touches nothing shared — many threads screen through one matcher without a lock.

**Nothing on the query path reads configuration**, which is a stronger statement than thread safety and the one that matters for an audit: a threshold, a weight or a candidate cap changed halfway through a batch cannot produce a run that is half one set of numbers and half another, because the numbers were read once — into the `Query`, and into the matcher.

A sync does not update a matcher. It builds a new one and the application swaps its reference, so requests in flight finish against one consistent list version:

```ruby
ActiveSanction.reload!                              # after a sync, for the shared one
MATCHER = ActiveSanction::Matcher.build(store)      # for one held by the application
```

Batch screening stamps the whole call with one `screened_at`, because a rescreening of a customer book against a new list version is one event in an audit trail rather than ten thousand a microsecond apart. Results come back index-aligned rather than keyed by name — a book of customers contains the same name twice often enough, and a Hash would silently screen one of them and report both.


## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/active_sanction. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/[USERNAME]/active_sanction/blob/master/CODE_OF_CONDUCT.md).


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the ActiveSanction project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/[USERNAME]/active_sanction/blob/master/CODE_OF_CONDUCT.md).
