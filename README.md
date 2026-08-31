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

`bundle exec rake` runs the RSpec suite and then RuboCop; both must pass.

The suite is hermetic. `spec_helper.rb` calls `WebMock.disable_net_connect!(allow_localhost: true)`, so an un-stubbed HTTP call raises `WebMock::NetConnectNotAllowedError` instead of quietly reaching the internet. Parser specs run against committed fixtures — a suite that can reach a government server stops proving anything about our parsing and starts proving that the server is up.

Specs that genuinely need a real endpoint are tagged `:live`. They are excluded from the default run, and `WebMock` is re-enabled around each one:

    $ bundle exec rspec --tag live

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

Most of what it checks is a way of losing records quietly. A store that returns an empty snapshot for a source nobody synced, one that drops the third of four entities on the way back, one that reorders them, one that accumulates two writes of a list instead of replacing it — none of those raise, all of them return something that looks like a sanctions list, and the report they produce says the name you screened is clear. What it deliberately says nothing about is durability, concurrency and performance, which are the things the adapters genuinely differ on: that a file write is atomic, that a database write is one transaction, that the in-memory store is safe to screen from on many threads. Those are properties of one implementation, and each adapter's own spec has to make them.

The group is `spec/support/shared_examples/storage_adapter.rb`, and `spec/active_sanction/storage/conformance_spec.rb` holds it to being able to fail: each example there takes one rule out of an otherwise conforming adapter and checks that the contract notices.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/active_sanction. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/[USERNAME]/active_sanction/blob/master/CODE_OF_CONDUCT.md).


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the ActiveSanction project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/[USERNAME]/active_sanction/blob/master/CODE_OF_CONDUCT.md).
