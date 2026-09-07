# Adding a source

A source adapter is the only part of this library that knows what a particular
government publishes. It declares what the list is and where it lives, and it
turns that publisher's bytes into `ActiveSanction::Entity` objects. Everything
either side of that — conditional GET, the payload cache, checksumming the
result into a `Snapshot`, storage, and eventually the matcher — is written
against the canonical model and never against a list, so adding a jurisdiction
is a parsing problem and not a plumbing one.

```ruby
class UnConsolidated < ActiveSanction::Sources::Base
  key          :un_consolidated
  jurisdiction :un
  authority    "United Nations Security Council"
  format       :xml
  url          :main, "https://scsanctions.un.org/resources/xml/en/consolidated.xml"

  def parse(raw)
    ...   # => [Entity, ...]
  end
end

ActiveSanction::Sources.register(UnConsolidated)
```

`#parse` is the whole of what you must write. This document is the rest: how to
decide what goes in it, and what the surrounding checklist is.

It applies whether the adapter lands in this gem or in your own application —
the registry is open and duck-typed, and [section 9](#9-register-it) covers
both.

## Contents

1. [Read the closest existing adapter first](#1-read-the-closest-existing-adapter-first)
2. [Look at what the publisher actually serves](#2-look-at-what-the-publisher-actually-serves)
3. [Declare the list](#3-declare-the-list)
4. [Choose how to read it](#4-choose-how-to-read-it)
5. [Map the publisher's fields onto the canonical model](#5-map-the-publishers-fields-onto-the-canonical-model)
6. [Give every record a stable id](#6-give-every-record-a-stable-id)
7. [Report what you could not read](#7-report-what-you-could-not-read)
8. [Capture a fixture and wire up the conformance spec](#8-capture-a-fixture-and-wire-up-the-conformance-spec)
9. [Register it](#9-register-it)
10. [Typed, linted, and green](#10-typed-linted-and-green)
11. [A worked example, end to end](#a-worked-example-end-to-end)
12. [Checklist](#checklist)

## 1. Read the closest existing adapter first

There is no scaffold generator, deliberately. This project will have roughly
eight adapters at maturity, and a generator maintained for that many uses has
to be kept in step with every change to `Sources::Base`, the conformance spec
and the parser toolkits — and goes stale silently when it is not. An existing
adapter to copy does the same job with none of the upkeep.

Pick the one whose *shape* matches your publisher's, not the one whose
jurisdiction is nearest:

| The publisher serves | Copy from | Its spec |
| --- | --- | --- |
| One delimited file, nothing unusual | `spec/support/contract_example_source.rb` — a whole adapter in twenty lines | `spec/active_sanction/sources/conformance_spec.rb` |
| Several delimited files that only mean something joined | `lib/active_sanction/sources/ofac.rb`, `ofac_sdn.rb` | `spec/active_sanction/sources/ofac_sdn_spec.rb` |
| One XML document, one flat record shape | `lib/active_sanction/sources/canada_sema.rb` | `spec/active_sanction/sources/canada_sema_spec.rb` |
| One XML document, several record shapes | `lib/active_sanction/sources/un_consolidated.rb` | `spec/active_sanction/sources/un_consolidated_spec.rb` |
| One XML document, tens of megabytes, data in attributes | `lib/active_sanction/sources/eu_fsf.rb` | `spec/active_sanction/sources/eu_fsf_spec.rb` |
| Two lists from one publisher in one format | `lib/active_sanction/sources/ofac.rb` holds the reading; `ofac_sdn.rb` and `ofac_consolidated.rb` declare only which list they are | |

Each of those files opens with a class comment describing the list, its quirks,
and what the adapter refuses to do about them. That comment is part of the
deliverable, not decoration: it is where the next person finds out why Canadian
aliases are not split on commas without having to reconstruct the argument from
the code.

Note the two-file convention in the XML adapters. `canada_sema.rb` says what the
list is and drives the read; `canada_sema/record.rb` says what the publisher's
elements *mean*. They are separated because they are two jobs, and all the
judgment sits in the second one. A mapping small enough to read at a glance —
the contract example, a five-column CSV — does not need the split.

## 2. Look at what the publisher actually serves

Before writing a line, get the bytes and answer eight questions about them.
Every one of them changes the adapter, and every one of them is cheaper to
answer now than after a fixture has been committed.

```bash
curl -sSL -o /tmp/list.xml "https://example.gov/sanctions/list.xml"
file /tmp/list.xml && wc -c /tmp/list.xml
```

1. **What encoding is it, really?** OFAC serves Windows-1252 and says nothing
   about it in a header; the UN serves UTF-8 and says nothing either. Read as
   the wrong one, thousands of accented names arrive as replacement characters.
   The adapter states the encoding; it does not guess.
2. **What does the publisher write where it means nothing?** OFAC writes `-0- `
   — with a trailing space — roughly a quarter of a million times. Blank and
   all-whitespace are already nil; a sentinel has to be declared.
3. **Is there an identifier, and is it stable?** See
   [section 6](#6-give-every-record-a-stable-id). This is the question most
   likely to cost you a rewrite.
4. **How many records, and of what kinds?** Count them. The counts belong in the
   class comment, because a comment saying "736 individuals, 275 organizations"
   is checkable against the file and a comment saying "some people and some
   organizations" is not.
5. **What separates repeated values?** Semicolons are usually unambiguous.
   Commas usually are not — see the alias discussion in `canada_sema.rb` for
   what splitting on an ambiguous separator manufactures.
6. **Which fields have no home in `Entity`?** They go into `remarks` behind the
   `[source fields]` marker, never on the floor.
7. **Does one element or column mean two different things?** The UN's `QUALITY`
   grades an alias under `<INDIVIDUAL_ALIAS>` and names the alias *kind* under
   `<ENTITY_ALIAS>`. Canada's date element is a date of birth or a ship's build
   date depending on the record. These are the bugs that produce a list which
   parses cleanly and is wrong.
8. **Does the document carry its own version marker?** The UN stamps
   `dateGenerated` on the root element. If yours does, override
   `#source_version` to return it — it is the string an examiner asking "which
   version was this screened against" will recognise, and it is more precise
   than the `Last-Modified` header `Base` falls back to.

## 3. Declare the list

Declarations come from `Sources::Definition`, extended into `Sources::Base`, so
an adapter's class body reads as a description of the list:

```ruby
key          :ofac_sdn      # required, never inherited
jurisdiction :us            # required
authority    "U.S. Department of the Treasury, Office of Foreign Assets Control"
format       :csv           # optional, informational

url :sdn, "https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV"
url :alt, "https://sanctionslistservice.ofac.treas.gov/api/download/ALT.CSV"
url :add, "https://sanctionslistservice.ofac.treas.gov/api/download/ADD.CSV"
```

- **`key`** is the public name of the list: what `config.sources` names, what a
  stored snapshot is filed under, what the payload cache uses as a directory
  name, and what a match result cites. Lowercase `snake_case`, and it is never
  inherited — a subclass silently taking its parent's key would try to register
  under a name already taken.
- **`authority`** is what a compliance report prints beside a hit, so spell it
  the way the body spells itself: `"United Nations Security Council"`, not
  `"UN"`.
- **`format`** is a label a CLI prints. It is not dispatched on and is not
  checked against a list of known formats, so a source arriving as
  `:fixed_width` can say so.
- **`url`** is declared once per file. Each is fetched, validated and cached
  independently, because they change independently: a sync in which only
  `ALT.CSV` moved should download only `ALT.CSV`. A source declaring several
  files has each filed under `"#{key}-#{name}"` in the cache; one declaring a
  single file is filed under the key itself.

Everything except `key` resolves up the superclass chain, so two lists from one
publisher share a base that holds the jurisdiction, the authority and the format
— that is exactly what `Sources::Ofac` is.

A source that is not fetched over HTTP at all — a bank's internal watchlist
backed by a database table — declares no URL and overrides `#retrieve` instead.
It does not have to subclass `Base` at all; see [section 9](#9-register-it).

### What `#parse` is handed

Whatever the declaration implies, and never what a caller happened to pass:

- one declared URL → `#parse` receives the bytes as a `String`;
- several → it receives a `Hash` keyed by the names you declared, as in
  `raw[:sdn]`.

That rule is applied by `Base` before `#parse` is called and again by the
conformance spec, so an adapter's signature does not change when a fixture is
handed to `#snapshot` directly:

```ruby
source = ActiveSanction::Sources[:un_consolidated].new
source.snapshot(File.binread("spec/fixtures/un_consolidated/consolidated.xml"))
source.sync                       # the same path, with the network in front of it
```

The bytes arrive **undecoded**. An adapter reading the Windows-1252 OFAC serves
is held to doing its own decoding rather than to being handed a `String` that
somebody already fixed up — which is what the format toolkits do for you when
you tell them the encoding.

## 4. Choose how to read it

### There is no field-mapping DSL

A declarative `field_map` DSL was planned (#13) and deliberately not built. The
intent was to make a new list a *mapping* rather than a hand-written parser, but
every launch source has at least one quirk that needed a transform hook to
absorb — `-0-` sentinels, bilingual values, one name spread across four
elements, an id that has to be synthesized — and when the escape hatches carry
most of the weight, the abstraction has not been found. Two real adapters later
the shared part turned out to be the *format* layer, not the mapping layer.

So: `#parse` is yours to write, and the reuse lives in
`ActiveSanction::Parsers`. Nothing in `Parsers` knows about `Entity` — they are
file readers, and keeping them ignorant of the canonical model is what lets an
adapter for a list nobody here has seen reuse them.

### `Parsers::DelimitedTable` — CSV, TSV, anything delimited

```ruby
LIST = ActiveSanction::Parsers::DelimitedTable.new(
  columns:  %i[ent_num sdn_name sdn_type program title remarks],
  null:     "-0-",
  encoding: Encoding::WINDOWS_1252
)

LIST.read(raw).each { |row| row[:sdn_name] }
```

A table is a description of the file, built once at class-definition time and
reused for every sync; `#read` is one pass over one payload.

- **`columns:`** names a headerless file's columns *and* pins its width. If the
  publisher inserts a column, every row arrives the wrong width and says so in
  `#warnings` — a far better failure than 19,321 entities quietly built from
  shifted fields. Pass `columns: nil` (the default) for a file that carries its
  own header; the names are read from the first row, lowercased and
  snake_cased, so `City/State/Province/ZIP/Postal Code` and
  `city_state_province_zip_postal_code` are the same column no matter how the
  publisher capitalized it this quarter.
- **`null:`** takes one sentinel or several. It is matched after stripping
  surrounding whitespace, and blank fields are nil regardless.
- **`col_sep:` / `quote_char:`** for TSV and the rest.
- **`liberal_parsing:`** defaults to `true`, because an unescaped quote inside a
  company name is common in published data and failing the row is the wrong
  default. Turn it off where a stray quote should be loud.

A `Row` is deliberately not a `Hash`: `row[:sdn_nme]` raises rather than
answering `nil` and letting a typo look like an empty column all the way into a
snapshot. `row.fetch(:col)` is there for the genuinely optional case,
`row.null?(:col)` asks whether the publisher left it empty, and `row.line` is
the line number a warning has to cite.

### `Parsers::XmlRecords` — record-oriented XML

```ruby
LIST = ActiveSanction::Parsers::XmlRecords.new(records: %w[INDIVIDUAL ENTITY])

reader = LIST.read(raw)
reader.each do |record|
  record.name                          # => "INDIVIDUAL"
  record["FIRST_NAME"]                 # => "ERIC"
  record.values("NATIONALITY/VALUE")   # => ["Chad", "Sudan"]
  record.nodes("INDIVIDUAL_ALIAS")     # => [Record, ...]
  record["@dateGenerated"]             # an attribute, XPath-style
end
reader.root["dateGenerated"]           # the publisher's own version marker
```

- **It streams.** One record's depth is held on a stack and dropped as soon as
  you are done with it. Every list here today is small enough to have loaded
  whole, which is exactly why it does not: the adapter written against this
  interface is the one that reads OFAC's 126 MB `SDN_ADVANCED.XML` later,
  unchanged.
- **Name only the record elements.** Scaffolding — `<CONSOLIDATED_LIST>`,
  `<INDIVIDUALS>` — is skipped rather than built into nodes nobody asked for.
  Naming several is normal and gives you one pass over both shapes.
- **Namespace prefixes are stripped** before matching, so a publisher adding an
  `xmlns` next quarter does not silently stop matching anything.
- **Missing, self-closing and whitespace-only elements all read as `nil`.** That
  is the only reading that survives real documents: the UN files 294 placeholder
  aliases as `<INDIVIDUAL_ALIAS><QUALITY/><ALIAS_NAME/></INDIVIDUAL_ALIAS>` and
  means nothing at all by them. Use `record.fetch(path)` for a field you
  consider mandatory — it names the record and what it does carry when the path
  is missing — and `record.present` to explore an unfamiliar document from
  `bin/console`.

Do not pass `backend:`. Which XML library parses a list is an installation's
decision (`config.xml_backend`), not a list's.

### `Parsers::Join` — several files, one logical record

```ruby
join = ActiveSanction::Parsers::Join.new(
  on: :ent_num, aliases: ALT.read(raw[:alt]), addresses: ADD.read(raw[:add])
)

join.each(PRIMARY.read(raw[:sdn])) do |row, related|
  related[:aliases]     # => [Row, ...] -- always an Array, never nil
  related[:addresses]   # => [Row, ...]
end

join.orphans            # => { aliases: 0, addresses: 0 }
```

The primary file streams; the child files are indexed and held in memory for the
length of the join. A child row matching no primary row is dropped and counted,
and a nonzero orphan count after a sync usually means the files were downloaded
at different moments and do not describe the same version of the list — a data
problem no amount of careful parsing fixes.

### Neither

If the publisher serves JSON, a fixed-width file, or something with no shape
worth abstracting, parse it however it needs parsing and build Entities. The
toolkits are a convenience, not an obligation, and the conformance spec does not
know or care which you used. What it does care about is the rules in sections 5
to 7, which are not optional.

## 5. Map the publisher's fields onto the canonical model

`Entity` is the single source-agnostic record every adapter produces. Nothing
downstream — storage, the diff between two syncs, the index, the matcher, the
report an examiner reads — should ever need to know which government published a
record.

```ruby
ActiveSanction::Entity.new(
  source:         :ofac_sdn,          # required -- your own key
  source_ref:     "2674",             # the publisher's own reference, if it has one
  id:             nil,                # derived from source + source_ref when omitted
  type:           :individual,        # individual | organization | vessel | aircraft
  names:          [Name, ...],
  addresses:      [Address, ...],
  identifiers:    [Identifier, ...],
  dates_of_birth: [PartialDate, ...],
  nationalities:  ["EG"],
  programs:       ["SDGT"],
  listed_on:      PartialDate,
  remarks:        "..."
)
```

Instances are frozen and compare by value. The four collection members are
declared types, so `srb tc` refuses an adapter that hands over the string a
publisher wrote where a `PartialDate` belongs.

### The rules that are not negotiable

**Every date is a `PartialDate`, never the string it was written as.** A date
left as the publisher's string cannot be compared with one from another list,
and `PartialDate` exists because no two lists agree on how precise a date of
birth is. `PartialDate.parse` reads ISO (`1972`, `1972-04`, `1972-04-29`),
worded forms (`29 Apr 1972`, `April 29, 1972`, `Apr 1972`), approximations
(`circa 1962`, `~1962`) and spans (`between 1971 and 1973`, `1971-1973`), and
returns `nil` on anything it cannot read. A publisher writing `14/03/2019` is
outside that vocabulary and the adapter converts before parsing; it never stores
the string.

**Types are the matcher's coarsest filter.** `vessel` and `aircraft` are
first-class because they are about 10% of the OFAC SDN list and carry name-like
strings; without a distinct type, a search for a person can rank a ship. Map the
publisher's vocabulary onto the four, warn about anything you did not recognise,
and default to `:organization` rather than dropping the record.

**A record with no name is not a record.** It cannot be screened against. Return
`nil` for it and record a warning naming the publisher's reference, so the day
one appears it is visible rather than absent.

**Never drop the publisher's free text.** `Entity#remarks` keeps it verbatim.
This is where the fields the canonical model has no home for still live —
OFAC's dates of birth and passport numbers are nowhere else — and an adapter
that drops it loses data no later issue can get back.

### Fields with no home: `Sources::Remarks`

Append them behind one shared marker rather than inventing a convention per
source:

```ruby
Remarks.build(row[:remarks], [["Vessel flag", "Panama"], ["Tonnage", "8000"]])
# => "Registered in Panama [source fields] Vessel flag: Panama; Tonnage: 8000"

Sources::Base.published_remarks(entity.remarks)   # => "Registered in Panama"
```

`Remarks.build` drops a label whose value is blank or missing, and a value may
be an `Array` — the UN files three designations under one element.
`Remarks.published` strips everything an adapter appended back off, which is
what anything reading the remark for what the publisher *actually wrote* must
use: OFAC's remarks parser must never see a vessel flag and read it as a
nationality. The conformance spec checks that at least one record still has
publisher text after stripping, so appending is safe and swallowing is not.

### The value objects

| Class | Notes |
| --- | --- |
| `Name` | `value:` plus `kind:` (`:primary`, `:aka`, `:fka`, `:nka` — defaults to `:primary`), `quality:` (`:good`, `:low`, or `nil` for unstated), `script:` (a closed list; map the publisher's vocabulary onto it — OFAC's "Farsi" is `:arabic`). A blank value raises: a blank-valued name is a record that matches everything. |
| `Address` | `street:`, `city:`, `state_province:`, `postal_code:`, `country:`, `note:`. An address that located nothing raises `ArgumentError`; rescue and drop it rather than keeping an empty one. |
| `Identifier` | `value:` plus `kind:` (`:passport`, `:national_id`, `:tax_id`, `:registration_number`, `:other`), `country:`, `issued_on:`, `expires_on:`, `note:`. `:other` is a real answer — a document we cannot classify still matches on its number. A document element with a type and no number has nothing to match on: drop it. |
| `PartialDate` | `.parse`, `.range(from, to)`, `.new(year:, month:, day:, approximate:)`. Never collapse a year to January 1st. |

### The mistakes this section exists to prevent

Each of these is caught by the conformance spec, but knowing why is cheaper than
reading the failure:

- one field read as another, because a publisher uses one name for two things;
- a date left as a string, which quietly cannot be compared with anything;
- free text dropped to keep the schema tidy, which loses screening signal
  permanently;
- an empty payload read as a list with nobody on it — see
  [section 7](#7-report-what-you-could-not-read).

## 6. Give every record a stable id

`Entity#id` is namespaced and never nil. When you pass `source_ref:` and no
`id:`, it is derived as `"#{source}:#{source_ref}"`, which is what you want
whenever the publisher supplies a reference of its own.

The id has to satisfy two properties, and the conformance spec checks both:

- **unique within a sync** — two records under one id are one record to storage,
  and the second silently replaces the first;
- **identical on a second read of the same bytes** — the snapshot diff compares
  records under their ids, and an id that moves because a `Hash` iterated
  differently or a counter was involved reports the whole list as removed and
  re-added. A diff that says everything changed says nothing at all.

So an id may never depend on position in the file, iteration order, a counter,
the wall clock, or anything else outside the record's own bytes.

### When the publisher supplies no id

Canada is the case. Global Affairs publishes no identifier of any kind; what it
publishes is a citation — which regulation, which schedule, which item — and
`CanadaSema::SourceRef` derives a deterministic id from it. The recipe
generalizes:

```ruby
module SourceRef
  NORMALIZE = /[[:space:]]+/
  SEPARATOR = "\u0000"  # cannot occur in XML character data
  LENGTH    = 16        # 64 bits of SHA-256

  module_function

  def for(country:, schedule:, item:, name:)
    parts = [country, schedule, item, name].map { |part| normalize(part) }
    -Digest::SHA256.hexdigest(parts.join(SEPARATOR))[0, LENGTH]
  end

  def normalize(value) = value.to_s.split(NORMALIZE).join(" ").downcase
end
```

Four decisions in there are worth copying deliberately:

1. **Hash the citation *and the name*.** The citation alone is already unique
   across all 5,690 published records, so the name looks redundant — until a
   schedule is amended. Item numbers are positions in a list: delete item 5 and
   everything after it moves up one, and hashing the citation alone would hand
   item 6's old id to the person who used to be item 7. The diff would then
   report that one person quietly changed their name, which is the same shape as
   a correction and reads as one. With the name in the hash that amendment
   reports as a removal and an addition — noisier, and true. The cost runs the
   other way: correcting a typo in a published name re-ids that record. Churn in
   a diff is a nuisance; one id covering two different people is a screening
   failure, so the trade goes this way.
2. **Normalize only case and whitespace.** Canada publishes `Venezuela` both
   with and without a trailing space, and a record must not change id when a
   space does. Nothing further is folded — not punctuation, not diacritics —
   because every additional fold is another way for two genuinely different
   records to collide into one id.
3. **Join with a separator that cannot occur in the data.** Otherwise
   `("a", "bc")` and `("ab", "c")` hash the same.
4. **Treat the constants as versioned.** Changing the normalization, the
   separator or the length re-ids every record of that source ever stored. That
   makes each of them a decision with a migration attached, not a cleanup.

Document the choice in the class comment. A reader of a stored snapshot has to
be able to find out where an id came from.

## 7. Report what you could not read

A sanctions list is not a file we control, and the two failure modes are
different:

**A row that could not be read** is a `Parsers::Warning`, kept rather than
raised. OFAC ships 19,321 rows, and a single unbalanced quote in the middle must
not cost the other 19,320 — refusing to load a list because one record is
malformed fails exactly when the list is most needed. The toolkits collect their
own warnings; the convention is that an adapter exposes them together with
anything it noticed itself:

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

Read `#warnings` after `#parse`; sync orchestration reports them. Give every
warning a line number where the parser can supply one — a 5.6 MB file is only
debuggable if the complaint says where.

**A payload that is not the list at all** raises `Parsers::ParseError`. Both
toolkits already refuse an empty payload for you, and the delimited reader also
gives up after enough consecutive unparseable rows, on the grounds that the
publisher probably served an error page. Do not rescue that into an empty array.
No sanctions list has ever been published empty, so an empty payload is a failed
download, a moved URL or an outage — never a day on which nobody is sanctioned,
and letting a sync succeed at screening against nothing is the most expensive
way this library can fail.

A truncated download is the middle case. It may be worth salvaging — the XML
reader keeps the records it read before the break and warns — and what the
contract requires is only that half a list never comes back looking exactly like
the whole one.

`#parse` should not rescue `ActiveSanction::Error` at all. `#sync` does not
rescue either: one source's failure being isolated from the others is a decision
about a *run*, and it belongs to sync orchestration, which needs an exception
here to notice.

## 8. Capture a fixture and wire up the conformance spec

### The fixture

**Use real published records.** A conformance run against a fixture somebody
wrote to pass it proves nothing about the list. Download the real file and cut
it down.

**Choose records by quirk, not at random.** The Canadian fixture is sixteen
records covering all three record shapes, a bilingual value split on ` / ` and
another split on `|`, a value bilingual in neither, a name padded with U+00A0, a
vessel type wrapped across three lines, a semicolon-separated alias field and a
comma-separated one, a year-only date, a full date, two candidate dates, a date
nothing can read, a record with no schedule, and a padded schedule and country.
Every one of those is a line in the spec. Aim for the same: one record per thing
the adapter had to decide, plus one ordinary record.

**Keep the bytes verbatim.** The fixture is read with `File.binread` and reaches
`#parse` undecoded, which is the point — it holds the adapter to doing its own
decoding. The committed OFAC fixture is still Windows-1252, and an editor that
helpfully re-saves it as UTF-8 turns that spec into a test of nothing. Line
endings and the trailing `0x1A` byte DOS-lineage export tooling writes matter
less — the delimited reader trims that byte for you — but the safe cut is one
made by a tool that does not touch what it was not asked to:

```bash
# delimited: the header, if there is one, plus the rows you picked
head -1 /tmp/SDN.CSV > spec/fixtures/my_source/SDN.CSV
grep -a '^36,' /tmp/SDN.CSV >> spec/fixtures/my_source/SDN.CSV
```

For XML, keep the document element **and its attributes** — that is where a
`dateGenerated` version marker lives — and any intermediate scaffolding the
records sit inside, then delete whole record elements. Verify the result parses
before committing it.

**For a multi-file source, keep the join keys aligned.** If you trim `SDN.CSV`
to eight rows and leave `ALT.CSV` whole, every unmatched alias becomes an orphan
and the fixture stops describing a coherent version of the list. The committed
OFAC fixture is 8 primary rows, 7 aliases and 5 addresses, all keyed to the same
entities.

**Keep it small.** The existing fixtures run from 250 bytes to 18 KB. They are
read on every suite run and reviewed by hand.

### The spec

```ruby
RSpec.describe ActiveSanction::Sources::CanadaSema do
  it_behaves_like "a sanction source", fixture: "canada_sema/sema.xml"
end
```

Paths are relative to `spec/fixtures`. A source whose publisher splits the list
names one fixture per declared URL, under the keys the adapter declared:

```ruby
it_behaves_like "a sanction source",
                fixture: { sdn: "ofac_sdn/SDN.CSV", alt: "ofac_sdn/ALT.CSV", add: "ofac_sdn/ADD.CSV" }
```

There is one option: `remarks: false`, for a list that publishes no free text of
its own anywhere — Canada is the only launch source that qualifies. It has to be
asked for, so that dropping a remark by accident stays a failure.

The group lives in `spec/support/shared_examples/sanction_source.rb` and checks
what everything downstream assumes and cannot check for itself: that the adapter
declares a key, a jurisdiction, an authority and a URL and registers itself; that
`#parse` returns Entities with unique, deterministic ids, a canonical type and at
least one name; that dates are `PartialDate`s; that every record survives the
round-trip through `#to_h`; that the publisher's own text survives in `remarks`;
that an empty payload is refused; and that a truncated one is not reported as the
whole list.

**It is the floor, not the ceiling.** Nothing in it knows that OFAC writes `-0-`
for null, that the UN means two different things by `QUALITY`, or which of your
fixture's records is a vessel. Only a spec that knows what is in the fixture can
check that the list was read *correctly*, so write one — every adapter here does.
Look up records the way a person would (by reference, or by name for a source
with no reference) and assert the meaning:

```ruby
def entity(ref) = entities.find { |candidate| candidate.source_ref == ref }

it "types a record carrying an IMO number as a vessel" do
  expect(entity("RT/2023/0330").type).to eq(:vessel)
end
```

The suite is hermetic: `WebMock` blocks outbound connections, so an un-stubbed
HTTP call raises rather than quietly reaching a government server. A spec that
genuinely needs a live endpoint is tagged `:live`, excluded from the default run,
and executed with `bundle exec rspec --tag live`.

## 9. Register it

An adapter whose file is required but which never registers is invisible:
`config.sources` cannot name it, `sync` will not run it, and nothing says so out
loud. The conformance spec checks for exactly this.

### Inside this gem

One explicit line at the bottom of the adapter's own file, and a `require` in
`lib/active_sanction.rb`:

```ruby
# lib/active_sanction/sources/my_source.rb
ActiveSanction::Sources.register(ActiveSanction::Sources::MySource)
```

Registration is explicit rather than hooked onto `inherited` because
auto-registering every subclass would also enrol the abstract intermediates that
adapters sharing a publisher want — `Sources::Ofac` is one, and there is no such
list as "OFAC" — along with every throwaway subclass a test defines.

### From outside this gem

The registry is open, and that is deliberate. Nothing there requires
`Sources::Base`: registration is duck-typed on `.key` and `.new`, so a source
backed by a database table rather than a published file — no URL to declare, no
payload to fetch — is a first-class citizen rather than something that has to
pretend to be a file download.

```ruby
# in your own gem or initializer
ActiveSanction::Sources.register(MyCompany::InternalWatchlist)

ActiveSanction.configure { |c| c.sources = %i[ofac_sdn my_internal_watchlist] }
```

Subclassing `Base` is the convenient way to write an adapter, not the price of
admission. If you do subclass it and your list is not fetched over HTTP,
override `#retrieve` to return a `Hash` of name => bytes (or `nil` when nothing
has changed) and leave the rest alone.

To replace a built-in adapter with a patched one, unregister first — two lists
cannot answer to one name, and registering over a claimed key raises at load
time, which is where the collision is cheap to fix:

```ruby
ActiveSanction::Sources.unregister(:ofac_sdn)
ActiveSanction::Sources.register(MyCompany::PatchedOfacSdn)
```

There is deliberately no `clear!`.

## 10. Typed, linted, and green

Every file in `lib/` is `# typed: strict`, and new files are born that way: a
signature written beside the code costs a line, and one retrofitted a milestone
later costs an afternoon of reading the code back. In practice that means
`extend T::Sig`, a `sig` on every method, `T.let` on every instance variable and
on constants, and `override.` on `#parse`, which `Base` declares. The worked
example below is written the way it would land in `lib/`.

An adapter in your own application is under no such obligation — nothing in the
public API requires signatures.

```bash
bundle exec rake        # rspec, then rubocop, then srb tc; all three must pass
```

## A worked example, end to end

Here is a complete adapter, its fixture and its spec. **The list is invented for
this document** — a real adapter's fixture must be real published bytes, as
[section 8](#8-capture-a-fixture-and-wire-up-the-conformance-spec) says. It is
otherwise exactly what lands in the repository, and it passes the conformance
spec, RuboCop and Sorbet unchanged.

The Ruritanian Ministry of Finance publishes one CSV with a header row, `N/A`
where it means nothing, a stable reference per record, semicolon-separated
aliases, a `Position` column the canonical model has no home for, and dates in
ISO.

### The fixture

`spec/fixtures/ruritania_fsl/list.csv`:

```
Reference,Name,Aliases,Type,Date of Listing,Regime,Date of Birth,Passport Number,Position,Notes
RT/2019/0014,ACME TRADING LIMITED,ACME TRADE; ACME TRADING LTD,Entity,2019-03-14,Ruritania (Financial Measures) Order 2019,N/A,N/A,N/A,Registered in Nicosia; ships through two subsidiaries
RT/2021/0102,JOHN AGYEMAN OKORO,N/A,Individual,2021-11-02,Ruritania (Financial Measures) Order 2019,1974,RT884213,Deputy Minister of Trade,Travels on a diplomatic passport
RT/2023/0330,MV NORTHERN STAR,NORTHERN STAR; SEVERNAYA ZVEZDA,Ship,2023-07-30,Ruritania (Shipping Measures) Order 2022,N/A,N/A,N/A,Reflagged twice in 2022
RT/2024/0007,MARIA ELENA VASQUEZ DE LEON,N/A,Individual,2024-01-19,Ruritania (Financial Measures) Order 2019,1988-06-04,N/A,N/A,N/A
```

Four records: an organization with two aliases and no dates, an individual with
a year-only date of birth and a passport, a vessel, and an individual with a
full date of birth and no free text of any kind.

### The adapter

`lib/active_sanction/sources/ruritania_fsl.rb`:

```ruby
# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/parsers"
require "active_sanction/sources"
require "active_sanction/sources/base"

module ActiveSanction
  module Sources
    # The Ruritanian consolidated financial sanctions list: everyone named in
    # an order made under the Financial Measures Act, plus the vessels listed
    # under the Shipping Measures Order.
    #
    #   snapshot = ActiveSanction::Sources[:ruritania_fsl].new.sync
    #
    # One file, one flat record shape, a stable reference per record, and
    # `N/A` wherever the Ministry means nothing.
    class RuritaniaFsl < Base
      extend T::Sig

      key :ruritania_fsl
      jurisdiction :rt
      authority "Ruritanian Ministry of Finance"
      format :csv

      url :main, "https://finance.gov.rt/sanctions/consolidated.csv"

      # The Ministry ships a header row, so the column names are read from the
      # file rather than declared; `N/A` is what it writes where it means
      # nothing.
      LIST = T.let(Parsers::DelimitedTable.new(null: "N/A"), Parsers::DelimitedTable)

      # `Type` is free text and the Ministry writes three values.
      TYPES = T.let(
        { "individual" => :individual, "entity" => :organization, "ship" => :vessel }.freeze,
        T::Hash[String, Symbol]
      )

      # The alias column is separated by semicolons and by nothing else.
      ALIASES = T.let(";", String)

      sig { returns(T::Array[Parsers::Warning]) }
      attr_reader :warnings

      sig { params(args: T.untyped, options: T.untyped).void }
      def initialize(*args, **options)
        super
        @warnings = T.let([], T::Array[Parsers::Warning])
        @unmapped = T.let([], T::Array[Parsers::Warning])
      end

      sig { override.params(raw: T.untyped).returns(T::Array[Entity]) }
      def parse(raw)
        reader = LIST.read(raw)
        @unmapped = []
        entities = reader.filter_map { |row| entity(row) }
        @warnings = reader.warnings + @unmapped
        entities
      end

      private

      sig { params(row: Parsers::DelimitedTable::Row).returns(T.nilable(Entity)) }
      def entity(row)
        published = names(row)
        return note_nameless(row) if published.empty?

        Entity.new(source: key, source_ref: row[:reference], type: type(row), names: published,
                   identifiers: identifiers(row), dates_of_birth: dates_of_birth(row),
                   programs: [row[:regime]].compact, listed_on: PartialDate.parse(row[:date_of_listing]),
                   remarks: Remarks.build(row[:notes], [["Position", row[:position]]]))
      end

      sig { params(row: Parsers::DelimitedTable::Row).returns(T::Array[Name]) }
      def names(row)
        primary = row[:name]
        return [] if primary.nil?

        [Name.new(value: primary)] + aliases(row)
      end

      sig { params(row: Parsers::DelimitedTable::Row).returns(T::Array[Name]) }
      def aliases(row)
        row[:aliases].to_s.split(ALIASES).filter_map do |value|
          text = value.strip
          Name.new(value: text, kind: :aka) unless text.empty?
        end
      end

      sig { params(row: Parsers::DelimitedTable::Row).returns(Symbol) }
      def type(row)
        published = row[:type].to_s.downcase
        return T.must(TYPES[published]) if TYPES.key?(published)

        @unmapped << Parsers::Warning.new(
          line: row.line, message: "unknown Type #{row[:type].inspect}; treated as an organization"
        )
        :organization
      end

      sig { params(row: Parsers::DelimitedTable::Row).returns(T::Array[PartialDate]) }
      def dates_of_birth(row) = [PartialDate.parse(row[:date_of_birth])].compact

      sig { params(row: Parsers::DelimitedTable::Row).returns(T::Array[Identifier]) }
      def identifiers(row)
        return [] if row.null?(:passport_number)

        [Identifier.new(kind: :passport, value: row[:passport_number])]
      end

      # A record with no name cannot be screened against. None of the records
      # published today is nameless; the warning exists so that the day one is,
      # it is visible rather than absent.
      sig { params(row: Parsers::DelimitedTable::Row).returns(NilClass) }
      def note_nameless(row)
        @unmapped << Parsers::Warning.new(
          line: row.line, message: "row #{row[:reference].inspect} has no Name and was skipped"
        )
        nil
      end
    end
  end
end

ActiveSanction::Sources.register(ActiveSanction::Sources::RuritaniaFsl)
```

Then add the require to `lib/active_sanction.rb`:

```ruby
require "active_sanction/sources/ruritania_fsl"
```

### The spec

`spec/active_sanction/sources/ruritania_fsl_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe ActiveSanction::Sources::RuritaniaFsl do
  def raw = File.binread(File.expand_path("../../fixtures/ruritania_fsl/list.csv", __dir__))

  let(:adapter) { described_class.new }
  let(:entities) { adapter.parse(raw) }

  def entity(ref) = entities.find { |candidate| candidate.source_ref == ref }

  it_behaves_like "a sanction source", fixture: "ruritania_fsl/list.csv"

  it "reads the publisher's reference as the entity id" do
    expect(entity("RT/2021/0102").id).to eq("ruritania_fsl:RT/2021/0102")
  end

  it "splits the alias column on semicolons" do
    expect(entity("RT/2023/0330").names.map(&:value))
      .to eq(["MV NORTHERN STAR", "NORTHERN STAR", "SEVERNAYA ZVEZDA"])
  end

  it "reads a year-only date of birth without inventing a day" do
    expect(entity("RT/2021/0102").dates_of_birth.first.to_h).to include(year: 1974, month: nil, day: nil)
  end

  it "keeps the Position column behind the source-fields marker" do
    expect(entity("RT/2021/0102").remarks)
      .to eq("Travels on a diplomatic passport [source fields] Position: Deputy Minister of Trade")
  end

  it "reads N/A as nothing at all" do
    expect(entity("RT/2019/0014").identifiers).to be_empty
  end
end
```

That is 19 conformance examples and 5 of its own, and the list is now reachable
everywhere:

```ruby
ActiveSanction::Sources[:ruritania_fsl]              # => the adapter class
ActiveSanction.configure { |c| c.sources = %i[ofac_sdn ruritania_fsl] }
snapshot = ActiveSanction::Sources[:ruritania_fsl].new.sync
```

### What a harder list adds to that

The example above is the easy shape. In roughly the order they bite:

- **No publisher id** → [section 6](#6-give-every-record-a-stable-id), and copy
  `CanadaSema::SourceRef`.
- **Several files** → declare a `url` per file, read `raw[:name]`, join with
  `Parsers::Join`, and watch the orphan counts.
- **XML** → `Parsers::XmlRecords`, and split the mapping into its own `Record`
  class the way `un_consolidated/record.rb` does.
- **An encoding the publisher does not declare** → pass `encoding:` to the
  table.
- **A field that means two things** → map it twice, per record shape, and say so
  in the class comment.
- **Free text carrying the identifiers** → OFAC's shape.
  `Sources::Ofac::RemarksParser` is the precedent, along with its coverage
  reporting: extraction is additive, the remark is kept verbatim either way, and
  every sync reports how much of the text was understood.

## Checklist

- [ ] Read the closest existing adapter, and its spec.
- [ ] Downloaded the real file and answered the eight questions in
      [section 2](#2-look-at-what-the-publisher-actually-serves).
- [ ] Declared `key`, `jurisdiction`, `authority`, `format`, and one `url` per
      file.
- [ ] Overrode `#source_version` if the document carries its own version marker.
- [ ] `#parse` returns `Entity` objects and nothing else.
- [ ] Every id is unique and identical on a second read of the same bytes.
- [ ] Every date is a `PartialDate`.
- [ ] Every type is one of the four canonical types, and an unrecognised one
      warns rather than dropping the record.
- [ ] The publisher's free text is kept verbatim; extra fields are appended with
      `Remarks.build`.
- [ ] Unreadable rows become warnings; a payload that is not the list raises.
- [ ] A trimmed fixture of real bytes, one record per quirk, committed under
      `spec/fixtures/<key>/`.
- [ ] `it_behaves_like "a sanction source"` passes, plus a spec that knows what
      is in the fixture.
- [ ] `Sources.register` at the bottom of the file, and a `require` in
      `lib/active_sanction.rb`.
- [ ] A class comment describing the list, its record counts, its quirks, and
      what the adapter refuses to do about them.
- [ ] `bundle exec rake` is green.
