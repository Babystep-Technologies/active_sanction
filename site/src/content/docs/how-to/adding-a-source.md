---
title: Add a sanctions source
description: Register a working adapter for a list this gem does not yet read.
sidebar:
  order: 2
---

Register an adapter for a government sanctions list this gem does not yet
read, get it through the conformance suite, and commit a canary baseline so
drift in the real file is caught from the next weekday on.

**[`docs/adding_a_source.md`](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/adding_a_source.md)
is the canonical, section-by-section version of this walkthrough.** It ships
inside the gem, so a contributor working offline — or one already mid-adapter
in an editor — always has it, and it is where the full contract, every value
object's fields, and the complete worked example live. This page is the field
guide: the shape of the job and the ten places a contributor gets it wrong,
roughly in the order they bite. Where a step needs the exhaustive version, the
heading links straight to its section in the file.

## Before you write anything

**Read the closest existing adapter, not the nearest jurisdiction.** There is
no scaffold generator — an existing adapter copied for its *shape* does the
same job with no generator to keep in step with `Sources::Base`.

| Your publisher serves | Copy from |
|---|---|
| One delimited file, nothing unusual | [`spec/support/contract_example_source.rb`](https://github.com/Babystep-Technologies/active_sanction/blob/main/spec/support/contract_example_source.rb) — a whole adapter in twenty lines |
| Several delimited files that only mean something joined | [`lib/active_sanction/sources/ofac_sdn.rb`](https://github.com/Babystep-Technologies/active_sanction/blob/main/lib/active_sanction/sources/ofac_sdn.rb) |
| One XML document, one flat record shape | [`lib/active_sanction/sources/canada_sema.rb`](https://github.com/Babystep-Technologies/active_sanction/blob/main/lib/active_sanction/sources/canada_sema.rb) |
| One XML document, several record shapes | [`lib/active_sanction/sources/un_consolidated.rb`](https://github.com/Babystep-Technologies/active_sanction/blob/main/lib/active_sanction/sources/un_consolidated.rb) |
| One spreadsheet, records joined on a reference | [`lib/active_sanction/sources/australia_dfat.rb`](https://github.com/Babystep-Technologies/active_sanction/blob/main/lib/active_sanction/sources/australia_dfat.rb) |

Full table, with the XML variants split by nesting and file size:
[section 1](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/adding_a_source.md#1-read-the-closest-existing-adapter-first).

**Then get the real bytes and answer eight questions about them** before
writing a line — encoding, null sentinels, whether there is a stable id,
record counts, what separates repeated values, which fields have no home in
`Entity`, whether one element means two different things depending on the
record, and whether the document carries its own version marker. Every one of
these is cheaper to answer now than after a fixture is committed:
[section 2](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/adding_a_source.md#2-look-at-what-the-publisher-actually-serves).

## The shape of a finished adapter

<!-- sample: illustrative -- a sketch, not a complete adapter; #parse is elided -->

```ruby
class UnConsolidated < ActiveSanction::Sources::Base
  key          :un_consolidated
  jurisdiction :un
  authority    "United Nations Security Council"
  format       :xml
  url          :main, "https://scsanctions.un.org/resources/xml/en/consolidated.xml"

  def parse(raw)
    # => [Entity, ...]
  end
end

ActiveSanction::Sources.register(UnConsolidated)
```

`#parse` is the whole of what you write. Everything below is how to decide
what goes in it.

## Register it, and know what the key must be

`key` is lowercase `snake_case`, required, and never inherited — a subclass
silently taking its parent's key would try to register under a name already
taken. It is what `config.sources` names, what a stored snapshot is filed
under, what the payload cache uses as a directory name, and what a
`MatchResult` cites, so pick it once and expect it to outlive the pull
request.

Registration is one explicit line, not a hook on `inherited` — auto-registering
every subclass would also enrol the abstract intermediates a shared publisher
base needs (`Sources::Ofac` is one, and there is no such list as "OFAC"):

<!-- sample: illustrative -- MySource is a placeholder for your own adapter class -->

```ruby
# lib/active_sanction/sources/my_source.rb
ActiveSanction::Sources.register(ActiveSanction::Sources::MySource)
```

Add the matching `require` to `lib/active_sanction.rb`. Outside this gem the
registry is open and duck-typed — `.key` and `.new` are the whole contract, so
a source backed by a database table rather than a published file registers the
same way, with no `Sources::Base` subclass at all:
[section 9](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/adding_a_source.md#9-register-it).

## Fetching: conditional requests, and a user agent

A source declares one `url` per file it fetches; several files under one
source are each cached and conditionally re-fetched independently, so a sync
in which only one of three files moved downloads only that one. This is
handled by `Sources::Base` — you do not write the HTTP call.

**Some publishers reject a request that carries no `User-Agent`.** Set one
through `Configuration#user_agent` (or per-`Client`) rather than working
around it per adapter; the default this gem ships identifies itself honestly,
and a government endpoint is more likely to serve a client that does the same.

A source not fetched over HTTP at all — an internal watchlist backed by a
database — declares no `url` and overrides `#retrieve` to return a `Hash` of
name → bytes, or `nil` when nothing changed.

## Choosing a parser

There is no field-mapping DSL, deliberately — every launch source had at
least one quirk that needed an escape hatch, and when the escape hatches carry
most of the weight, the abstraction was not found. `#parse` is yours to write;
the reuse lives one layer down, in a toolkit that knows the *format* and
nothing about `Entity`.

| The publisher serves | Reach for |
|---|---|
| CSV, TSV, anything delimited | `Parsers::DelimitedTable` — declare `columns:` for a headerless file (which also pins the width, so an inserted column warns on every row), `null:` for the publisher's own empty-value sentinel |
| Record-oriented XML | `Parsers::XmlRecords` — streams, strips namespace prefixes, reads missing/self-closing/whitespace-only elements as `nil` |
| An `.xlsx` workbook | `Parsers::Spreadsheet` — reach for this only when the publisher offers nothing else; it needs `xl/styles.xml` to tell a year-as-serial-number from a year-as-plain-number apart |
| Several files, one logical record | `Parsers::Join` — the primary file streams, child files are indexed in memory, and `join.orphans` names how many child rows matched no primary row |
| Anything else | Parse it however it needs parsing. The toolkits are a convenience, not an obligation — the conformance spec does not know or care which you used |

Full options for each toolkit, and what each one refuses to do (formulas are
not evaluated, merged cells are ignored, a table's `Row` raises on a typo'd
column rather than answering `nil`):
[section 4](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/adding_a_source.md#4-choose-how-to-read-it).

## Mapping to `Entity`, including names with their kind and quality

`Entity` is the single source-agnostic record every adapter produces — nothing
downstream should ever need to know which government published a record.
Three rules are not negotiable, because the conformance spec holds every
adapter to them:

- **Every date is a `PartialDate`, never the string it was written as** — see
  [partial dates](#partial-dates-every-source-emits-them) below.
- **A record with no name is not a record.** Return `nil` for it and warn,
  naming the publisher's reference, so the day one appears it is visible
  rather than silently dropped.
- **Types are the matcher's coarsest filter.** Map the publisher's vocabulary
  onto `individual`, `organization`, `vessel` or `aircraft`; warn about
  anything unrecognized and default to `:organization` rather than dropping
  the record.

A `Name` carries `kind:` (`:primary`, `:aka`, `:fka`, `:nka` — defaults to
`:primary`) and `quality:` (`:good`, `:low`, or `nil` for unstated, which the
UN's graded aliases use). Getting `kind` right matters more than it looks: a
former name (`:fka`) is not penalized by the scorer, and a low-quality alias
is — so a publisher's own confidence grading has to survive the mapping, not
get flattened into one bucket of aliases.

The full value-object reference — `Address`, `Identifier`, every field on
each, and what raises when one is invalid — is in
[section 5](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/adding_a_source.md#5-map-the-publishers-fields-onto-the-canonical-model).

## Partial dates: every source emits them

No two lists agree on how precise a date of birth is, and `Date` cannot
represent "1948" or "circa 1962" without inventing a day that was never
published. `PartialDate.parse` reads ISO forms, worded forms, approximations
and spans, and returns `nil` on anything it cannot read:

<!-- sample: runnable -->

```ruby
ActiveSanction::PartialDate.parse("1948")           # year-only
ActiveSanction::PartialDate.parse("circa 1962")     # approximate
ActiveSanction::PartialDate.parse("1971-1973")      # a span
```

A publisher writing a locale-specific form (`14/03/2019`) is outside that
vocabulary — convert before parsing, and never store the raw string. Never
collapse a partial date to January 1st to make it fit somewhere else; that
manufactures a precision the publisher did not claim.

## Keep the publisher's own text verbatim in `remarks`

`Entity#remarks` is where every field the canonical model has no home for
still lives — OFAC's dates of birth and passport numbers are nowhere else
before a remarks parser extracts them. Never drop it to keep the schema tidy;
that loses screening signal permanently, and the conformance spec checks that
at least one record's remark still carries publisher text after your own
additions are read back off it.

Append your own fields behind one shared marker rather than inventing a
convention per source:

<!-- sample: illustrative -- row and entity come from a real parse -->

```ruby
Remarks.build(row[:remarks], [["Vessel flag", "Panama"], ["Tonnage", "8000"]])
# => "Registered in Panama [source fields] Vessel flag: Panama; Tonnage: 8000"

Sources::Base.published_remarks(entity.remarks)   # what the publisher actually wrote, marker stripped
```

## Fixtures: trimmed copies of the real file, and what "trimmed" may not do

**Use real published records, chosen by quirk rather than at random.** A
fixture written to pass the spec proves nothing about the list; aim for one
record per thing the adapter had to decide, plus one ordinary record.

**Keep the bytes verbatim.** The fixture is read with `File.binread` and
reaches `#parse` undecoded, which is the point — it holds the adapter to
doing its own decoding. An editor that helpfully re-saves a Windows-1252
fixture as UTF-8 turns that spec into a test of nothing.

**For a multi-file source, keep the join keys aligned.** Trim the primary
file to eight rows and leave a child file whole, and every unmatched alias
becomes an orphan — the fixture stops describing a coherent version of the
list.

Exact steps for cutting XML and delimited fixtures without touching bytes you
were not asked to, and why the document element's attributes matter for XML:
[section 8](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/adding_a_source.md#8-capture-a-fixture-and-wire-up-the-conformance-spec).

## The conformance group your adapter must pass

**It ships with the gem, so this works for an adapter in your own
application** — you do not need a checkout of this repository.

<!-- sample: illustrative -- belongs in a host application's spec_helper, where RSpec is loaded -->

```ruby
# spec/spec_helper.rb
require "active_sanction/testing"
```

<!-- sample: illustrative -- needs the shared example group loaded, above -->

```ruby
RSpec.describe MyCompany::InternalWatchlist do
  it_behaves_like "a sanction source", fixture: "internal_watchlist/list.csv"
end
```

Fixture paths resolve under `spec/fixtures`. If yours live somewhere else,
say so once:

<!-- sample: illustrative -- a host application's own layout -->

```ruby
ActiveSanction::Testing.fixture_root = "test/data/sanctions"
```

`require "active_sanction"` alone does not load any of this, so nothing
reaches a production process.

`"a sanction source"` is what every adapter is held to: a key, a jurisdiction, an authority and a URL declared and
registered; `#parse` returning `Entity` objects with unique, deterministic
ids, a canonical type, and at least one name; every date a `PartialDate`;
every record surviving a round trip through `#to_h`; the publisher's own text
surviving in `remarks`; an empty payload refused; a truncated one not
reported as the whole list. A multi-file source names one fixture per
declared `url`, keyed the way the adapter declared them; `remarks: false` is
the one opt-out, for a list that publishes no free text anywhere (Canada is
the only launch source that qualifies).

**It is the floor, not the ceiling.** Nothing in it knows that your publisher
writes `-0-` for null or which of your fixture's records is a vessel — write
your own examples on top of it that look records up by reference and assert
what they mean.

## Give every record a stable id

`Entity#id` derives as `"#{source}:#{source_ref}"` when the publisher supplies
a reference. It has to be unique within a sync and identical on a second read
of the same bytes — the snapshot diff compares records by id, and an id that
moves reports the whole list as removed and re-added.

When the publisher supplies none — Canada is the launch case — derive a
deterministic id from a stable citation, and hash the *name* into it as well
as the citation: item numbers are positions in a published list, so deleting
item 5 shifts every id after it, and hashing the citation alone would hand
item 6's old id to whoever used to be item 7. The recipe, and the four
decisions worth copying deliberately, are in
[section 6](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/adding_a_source.md#6-give-every-record-a-stable-id).

## Add the source to the canary baselines

The [upstream canary](/active_sanction/how-to/detecting-format-drift/) fetches
every registered source on weekdays and holds it against
`.github/baselines/<key>.json`. A newly registered adapter has no such file
yet and nothing breaks — it falls back to the coarse `floor` declarations you
made — but commit one anyway, in the same pull request as the adapter:

```console
$ CANARY_SOURCES=my_source bundle exec rake canary          # what it measures
$ CANARY_SOURCES=my_source bundle exec rake canary:refresh  # write the baseline
```

That reaches the real publisher, which is the point: the numbers a reviewer
sees are the numbers the file actually yields, and from the next weekday
onward a change in any of them opens an issue. It is also the cheapest review
your parser will get — a fill rate reading 4% where you expected 90% is far
easier to see in that diff than in a fixture of forty records.

## Attribution and licence terms

The source catalogue's licence column is generated, not typed — see
[`site/bin/generate_sources.rb`](https://github.com/Babystep-Technologies/active_sanction/blob/main/site/bin/generate_sources.rb).
Declare `licence_notice` and `licence_url` on the adapter with what the
publisher actually says about reuse; a source that skips this fails
`spec/site_sources_data_spec.rb` rather than rendering a blank cell that
reads as "no conditions."

## Then: typed, linted, and green

```console
$ bundle exec rake        # rspec, then rubocop, then srb tc; all three must pass
```

Every file in `lib/` is `# typed: strict`. That means `extend T::Sig`, a
`sig` on every method, `T.let` on every instance variable and constant, and
`override.` on `#parse`. An adapter living in your own application is under
no such obligation — nothing in the public API requires signatures.

## The checklist

- [ ] Read the closest existing adapter, and its spec.
- [ ] Downloaded the real file and answered the eight questions before writing.
- [ ] Declared `key`, `jurisdiction`, `authority`, `format`, and one `url` per file.
- [ ] `#parse` returns `Entity` objects and nothing else.
- [ ] Every id is unique and identical on a second read of the same bytes.
- [ ] Every date is a `PartialDate`.
- [ ] Every type is one of the four canonical types; an unrecognized one warns.
- [ ] The publisher's free text is kept verbatim; extra fields are appended with `Remarks.build`.
- [ ] Unreadable rows become warnings; a payload that is not the list raises.
- [ ] A trimmed fixture of real bytes, one record per quirk.
- [ ] `it_behaves_like "a sanction source"` passes — after `require "active_sanction/testing"` — plus a spec that knows what is in the fixture.
- [ ] `Sources.register` at the bottom of the file, and a `require` in `lib/active_sanction.rb`.
- [ ] A canary baseline committed under `.github/baselines/<key>.json`.
- [ ] A class comment naming the list, its record counts, and its quirks.
- [ ] `bundle exec rake` is green.

The full checklist, with the reasoning behind each line, is in
[the checklist section](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/adding_a_source.md#checklist)
of the canonical file — and its
[worked example](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/adding_a_source.md#a-worked-example-end-to-end)
is a complete adapter, fixture and spec for an invented list, built exactly
the way it would land in `lib/`.
