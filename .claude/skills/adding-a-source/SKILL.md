---
name: adding-a-source
description: Add a sanctions list the active_sanction gem does not read yet: write the source adapter, trim a fixture from the real published file, wire up the conformance group, register it and commit a canary baseline. Use when asked to add, support or read a new sanctions, watchlist or designation list, or to write a Sources::Base subclass for one.
user-invocable: true
---

# Adding a sanctions source

One adapter is the only part of this library that knows what a particular
government publishes. Everything either side of it — conditional GET, the
payload cache, checksumming into a `Snapshot`, storage, the matcher — is written
against the canonical model, so adding a jurisdiction is a parsing problem and
not a plumbing one.

**Read [`.claude/rules/adapter-rules.md`](../../rules/adapter-rules.md) first.**
It is the rules; this file is the order they are applied in. Both point at
[`docs/adding_a_source.md`](../../../docs/adding_a_source.md), which is the
reasoning and is not restated in either.

Do the steps in this order. Steps 1 and 2 are the ones an agent skips and the
ones that cost a rewrite.

## 1. Read the closest existing adapter

There is no scaffold generator, deliberately. Pick by the **shape** of what the
publisher serves, not by the jurisdiction:

| The publisher serves | Copy from |
| --- | --- |
| One delimited file, nothing unusual | `spec/support/contract_example_source.rb` |
| Several delimited files that mean something only joined | `lib/active_sanction/sources/ofac.rb`, `ofac_sdn.rb` |
| One XML document, one flat record shape | `lib/active_sanction/sources/canada_sema.rb` |
| One XML document, several record shapes | `lib/active_sanction/sources/un_consolidated.rb` |
| One XML document, tens of megabytes, data in attributes | `lib/active_sanction/sources/eu_fsf.rb` |
| One XML document, deeply nested, data in elements | `lib/active_sanction/sources/uk_sanctions_list.rb` |
| One spreadsheet, records joined on a reference | `lib/active_sanction/sources/australia_dfat.rb` |
| Two lists from one publisher in one format | `lib/active_sanction/sources/ofac.rb` holds the reading |

Read its spec too. Each adapter opens with a class comment describing the list,
its record counts, its quirks and what the adapter refuses to do about them.
That comment is part of the deliverable.

Note the two-file convention in the XML adapters: `canada_sema.rb` says what the
list is and drives the read, `canada_sema/record.rb` says what the publisher's
elements *mean*. Split them when the judgment is more than a glance.

## 2. Look at what the publisher actually serves

**Do not fetch it yourself.** Rule 15: publishers 403 non-browser agents and
block cloud ranges. Write the command down and ask the person to run it, then
work from the bytes they hand back.

```bash
curl -sSL -o /tmp/list.xml "https://example.gov/sanctions/list.xml"
file /tmp/list.xml && wc -c /tmp/list.xml
```

Answer all eight questions in
[§2](../../../docs/adding_a_source.md#2-look-at-what-the-publisher-actually-serves)
before writing a line, and write the answers into the class comment:

1. What encoding is it, really? The adapter states it; it does not guess.
2. What does the publisher write where it means nothing? (`-0- `, `N/A`)
3. Is there an identifier, and is it stable? — the question most likely to cost
   a rewrite.
4. How many records, and of what kinds? Count them; a checkable comment beats
   "some people and some organizations".
5. What separates repeated values? Semicolons are usually unambiguous; commas
   usually are not.
6. Which fields have no home in `Entity`? They go in `remarks`, never on the
   floor.
7. Does one element or column mean two different things?
8. Does the document carry its own version marker? If so, override
   `#source_version`.

If you cannot get the real bytes, **stop and say so**. Everything after this
step is guesswork without them.

## 3. Declare the list

```ruby
key          :ruritania_fsl   # required, never inherited, lowercase snake_case
jurisdiction :rt             # required
authority    "Ruritanian Ministry of Finance"   # spelled the way the body spells itself
format       :csv            # a label a CLI prints; not dispatched on
url          :main, "https://finance.gov.rt/sanctions/consolidated.csv"
```

One `url` per file the publisher serves, because they change independently. One
declared URL means `#parse` receives a `String`; several mean it receives a
`Hash` keyed by the names you declared. Everything except `key` resolves up the
superclass chain.

A source not fetched over HTTP declares no URL and overrides `#retrieve`. It
does not have to subclass `Base` at all — the registry is duck-typed on `.key`
and `.new`.

## 4. Choose a parser toolkit

There is no field-mapping DSL and one was deliberately not built (#13).
`#parse` is yours to write; the reuse is in `ActiveSanction::Parsers`, which
knows nothing about `Entity`.

- **`Parsers::DelimitedTable`** — CSV, TSV, anything delimited. `columns:` names
  a headerless file's columns *and pins its width*; `columns: nil` reads the
  header. `null:` declares the sentinel. `row[:typo]` raises rather than
  answering `nil`.
- **`Parsers::XmlRecords`** — record-oriented XML, streaming. Name only the
  record elements. Namespace prefixes are stripped. Missing, self-closing and
  whitespace-only elements all read as `nil`. **Do not pass `backend:`** — which
  XML library parses a list is an installation's decision.
- **`Parsers::Spreadsheet`** — an `.xlsx`, only when the publisher offers
  nothing else. Name the sheet rather than taking the first.
- **`Parsers::Join`** — several files, one logical record. Watch `#orphans`: a
  nonzero count usually means the files were downloaded at different moments.
- **Neither** — JSON, fixed-width, anything else: parse it however it needs
  parsing. The toolkits are a convenience. Rules 1 to 14 are not.

## 5. Map onto `Entity`, and derive a stable id

Rules 1 to 11. Build `ActiveSanction::Entity` objects and nothing else:

```ruby
Entity.new(source: key, source_ref: row[:reference], type: type(row), names: published,
           identifiers: identifiers(row), dates_of_birth: dates_of_birth(row),
           programs: [row[:regime]].compact, listed_on: PartialDate.parse(row[:date_of_listing]),
           remarks: Remarks.build(row[:notes], [["Position", row[:position]]]))
```

Value objects: `Name` (`value:`, `kind:`, `quality:`, `script:` — a blank value
raises), `Address` (raises if it located nothing; rescue and drop rather than
keeping an empty one), `Identifier` (`:other` is a real answer; a document with a
type and no number has nothing to match on — drop it), `PartialDate`.

Where the publisher supplies no id, copy `CanadaSema::SourceRef` and its four
decisions verbatim.

## 6. Report what you could not read

Rules 12 to 14, and the convention every adapter here follows:

```ruby
attr_reader :warnings

def parse(raw)
  reader = LIST.read(raw)
  @unmapped = []
  entities = reader.filter_map { |record| entity(record) }
  @warnings = reader.warnings + @unmapped
  entities
end
```

Then two optional declarations, both worth a moment:

- **`floor :record_count, 400`** — a coarse backstop for the run with nothing to
  compare against. Declare few and declare them wide. A number tightened to make
  a build pass is a number nobody reads again.
- **`#column_shapes`** — if and only if the publisher ships a *positional* file.
  Declared column names already pin the width, so an inserted column warns; a
  column *reordered* upstream parses cleanly and builds every record out of
  shifted fields. Assert what the values are, not only how many there are.

## 7. Trim a fixture from the real file

Rule 16. Real published bytes, cut down — never hand-written.

- **Choose records by quirk, not at random.** One record per thing the adapter
  had to decide, plus one ordinary record. The Canadian fixture is sixteen
  records and every one of them is a line in the spec.
- **Keep the bytes verbatim.** The fixture is read with `File.binread` and
  reaches `#parse` undecoded, which is what holds the adapter to doing its own
  decoding. Cut with a tool that does not touch what it was not asked to.
- **For XML**, keep the document element *and its attributes* — that is where a
  version marker lives — plus any intermediate scaffolding, then delete whole
  record elements. Verify it parses before committing.
- **For a multi-file source, keep the join keys aligned**, or every unmatched
  child row becomes an orphan and the fixture stops describing a coherent
  version of the list.
- **Keep it small.** The existing fixtures run from 250 bytes to 18 KB.

Commit it under `spec/fixtures/<key>/`.

```bash
head -1 /tmp/SDN.CSV > spec/fixtures/my_source/SDN.CSV
grep -a '^36,' /tmp/SDN.CSV >> spec/fixtures/my_source/SDN.CSV
```

## 8. Write the spec

Rule 22. The conformance group, plus a spec that knows what is in the fixture:

```ruby
RSpec.describe ActiveSanction::Sources::RuritaniaFsl do
  it_behaves_like "a sanction source", fixture: "ruritania_fsl/list.csv"

  def entity(ref) = entities.find { |candidate| candidate.source_ref == ref }

  it "types a record carrying an IMO number as a vessel" do
    expect(entity("RT/2023/0330").type).to eq(:vessel)
  end
end
```

Paths are relative to `spec/fixtures`. A multi-file source names one fixture per
declared URL: `fixture: { sdn: "...", alt: "...", add: "..." }`. There is one
option, `remarks: false`, for a list that publishes no free text of its own
anywhere — it has to be asked for, so that dropping a remark by accident stays a
failure.

## 9. Register it, and declare it

An adapter that never registers is invisible, and nothing says so out loud.
Four edits, all of them easy to forget:

1. `ActiveSanction::Sources.register(ActiveSanction::Sources::MySource)` at the
   bottom of the adapter's own file.
2. `require "active_sanction/sources/my_source"` in `lib/active_sanction.rb`.
3. The adapter class added to `docs/api_stability.md` under *Sources, and the
   toolkits an adapter is written with* — rule 17. Its `Record` class and column
   constants are marked `@api private` and are **not** added.
4. A `CHANGELOG.md` entry under `Unreleased`.

## 10. The canary baseline

Rule 15 again: this reaches the real publisher, so **name the commands and let a
person run them.**

```console
$ CANARY_SOURCES=my_source bundle exec rake canary          # what it measures
$ CANARY_SOURCES=my_source bundle exec rake canary:refresh  # write the baseline
```

Commit `.github/baselines/<key>.json` in the same pull request as the adapter.
Nothing breaks without it — the source is held to the coarse `floor`
declarations instead and the run reports `compared: false` — but it is the
cheapest review the parser will ever get. A fill rate reading 4% where you
expected 90% is a field mapped to the wrong element, and that is far easier to
see in the baseline diff than in a fixture of forty records.

## 11. Green, and signed off

```bash
bundle exec rake     # rspec, then rubocop, then srb tc -- all three must pass
git commit -s        # rules 19 to 27
```

## Done when

- [ ] Real published bytes were read, and the eight questions answered in the
      class comment.
- [ ] `key`, `jurisdiction`, `authority`, `format` and one `url` per file
      declared; `#source_version` overridden if the document carries a marker.
- [ ] `#parse` returns `Entity` objects, ids stable, dates `PartialDate`, types
      canonical, free text kept verbatim.
- [ ] Unreadable rows warn; a payload that is not the list raises.
- [ ] A fixture trimmed from the real file under `spec/fixtures/<key>/`, one
      record per quirk.
- [ ] `it_behaves_like "a sanction source"` plus a spec that knows the fixture.
- [ ] Registered, required, declared in `docs/api_stability.md`, noted in
      `CHANGELOG.md`.
- [ ] The canary commands handed over, and the baseline committed once run.
- [ ] `bundle exec rake` green, commits signed off.
