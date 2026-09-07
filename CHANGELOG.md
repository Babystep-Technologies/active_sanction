# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Two version numbers move independently in this project, and only one of them is this file's
subject. `ActiveSanction::VERSION` is the gem, and is what a release note is about.
`ActiveSanction::MATCHER_VERSION` is the matching pipeline, is stamped onto every
`MatchResult`, and is bumped whenever a change to the normalizer, the index, the similarity
algorithms or the scorer could move a score. **A change that moves `MATCHER_VERSION` is
called out here as such**, because it is the one kind of change that alters what a past
screening decision would come out as today.

## [Unreleased]

Everything below is the first release, and becomes `0.1.0` when it is tagged.

### Added

#### The canonical record

- `Entity`, one source-agnostic record model every adapter parses into: names, dates of birth,
  addresses, identifiers, nationalities, programs, type, and the publisher's own text kept
  verbatim in `remarks` ([#4](https://github.com/Babystep-Technologies/active_sanction/issues/4)).
- `Name` with alias kind and quality ([#5](https://github.com/Babystep-Technologies/active_sanction/issues/5)),
  `PartialDate` for the year-only, approximate and ranged dates these lists actually publish
  ([#6](https://github.com/Babystep-Technologies/active_sanction/issues/6)), and `Address` and
  `Identifier` ([#7](https://github.com/Babystep-Technologies/active_sanction/issues/7)).
- `Snapshot`: one source's entities plus a checksum over their content, re-derived on
  construction, so a truncated or edited list raises rather than screening quietly short
  ([#8](https://github.com/Babystep-Technologies/active_sanction/issues/8)).

#### Fetching

- `HttpClient` with a mandatory User-Agent, bounded redirects and retries with backoff
  ([#9](https://github.com/Babystep-Technologies/active_sanction/issues/9)).
- Conditional GET on ETag and Last-Modified, so an unchanged list costs one request and no
  parse ([#10](https://github.com/Babystep-Technologies/active_sanction/issues/10)).
- `PayloadCache`, a bounded, integrity-verified cache of the raw bytes each publisher served
  ([#11](https://github.com/Babystep-Technologies/active_sanction/issues/11)).

#### Sources

- `Sources::Base`, the adapter contract, and an open registry — a source registered from
  outside this gem is a first-class source
  ([#12](https://github.com/Babystep-Technologies/active_sanction/issues/12)), with a
  declarative field-mapping DSL ([#13](https://github.com/Babystep-Technologies/active_sanction/issues/13)).
- `Parsers::DelimitedTable`, a reusable CSV toolkit
  ([#14](https://github.com/Babystep-Technologies/active_sanction/issues/14)), and
  `Parsers::XmlRecords`, a streaming XML toolkit with pluggable REXML and Nokogiri backends
  ([#15](https://github.com/Babystep-Technologies/active_sanction/issues/15)).
- The shared `"a sanction source"` conformance group, and a spec that holds it to being able
  to fail ([#16](https://github.com/Babystep-Technologies/active_sanction/issues/16)).
- **OFAC SDN** — the SDN, ALT and ADD CSVs, joined
  ([#18](https://github.com/Babystep-Technologies/active_sanction/issues/18)).
- **OFAC Consolidated (non-SDN)** — the same shape, plus derivation of which of the six
  sub-lists a record is on from its program codes, exact for 478 of 481 published records
  ([#20](https://github.com/Babystep-Technologies/active_sanction/issues/20)).
- The OFAC remarks parser, which reads dates of birth, places of birth, nationalities and
  passport numbers out of the one free-text field they are published in — currently
  recognizing 97.3% of 88,827 segments, and reporting its own coverage per sync
  ([#19](https://github.com/Babystep-Technologies/active_sanction/issues/19)).
- **UN Security Council consolidated list**
  ([#21](https://github.com/Babystep-Technologies/active_sanction/issues/21)).
- **Canada SEMA / JVCFOA consolidated list**, with deterministic synthetic ids for a list that
  publishes none ([#22](https://github.com/Babystep-Technologies/active_sanction/issues/22)).
- **EU Consolidated Financial Sanctions List (FSF)** — 6,234 records in one 25.7 MB document,
  the first list large enough to exercise the streaming XML interface, read with no change to
  core ([#39](https://github.com/Babystep-Technologies/active_sanction/issues/39)). Three
  judgment calls in it are worth knowing about before relying on the list: the EU marks no
  name as the official one, so a stated rule picks one; alias quality and alias kind are prose
  in a per-name `<remark>` rather than a column, and are read from it; and four birth dates
  are published in the Islamic calendar, three of which therefore produce no date of birth at
  all rather than a Gregorian year in the fourteenth century that would *conflict* with the
  real one. The endpoint does not honour conditional GET, so this is the one list that
  downloads in full on every sync.
- **UK Sanctions List** — 6,334 designations in one 21.8 MB XML document, read with no change
  to core ([#40](https://github.com/Babystep-Technologies/active_sanction/issues/40)). The
  issue was scoped against OFSI's Consolidated List of Asset Freeze Targets, which the UK
  retired on 28 January 2026 when it moved every designation onto one list; its blob still
  answers 200 with a frozen 16.6 MB file, so an adapter reading it would look healthy on every
  sync and screen against a list that stopped moving in January. **If you have your own
  integration against `ConList.csv`, that is the thing to check today.** Two things about the
  data are worth knowing before relying on it: a date component the FCDO does not know is
  spelled out rather than omitted — `dd/mm/1962` is a year, `00/00/1975` is another spelling
  of the same, and 824 of 3,788 birth dates carry one, every one of which reads as nil through
  an ordinary date parser — and the publisher's own non-Latin script labels disagree with its
  own strings on three records, which is why `Name#script` is left unstated here. The endpoint
  honours conditional GET on both ETag and Last-Modified, so an unchanged list downloads
  nothing.
- Four UK spellings added to `countries.txt` — `Congo (Democratic Republic)`, `St Kitts and
  Nevis`, `St Lucia`, `St Vincent` — and `Palestinian` and `Occupied Palestinian Territories`,
  which between them resolve 53 of the 63 UK nationality values that previously did not. Purely
  additive: no existing spelling resolves differently, and the accuracy report is unchanged.
- `docs/adding_a_source.md`, the end-to-end walkthrough for a seventh
  ([#17](https://github.com/Babystep-Technologies/active_sanction/issues/17)).

#### Storage

- `Storage::Base`, five methods, and nothing on the query path naming a concrete store; plus
  `Storage::Memory` ([#23](https://github.com/Babystep-Technologies/active_sanction/issues/23)).
- `Storage::FileSystem`, the gzipped-JSON default, committing with one atomic rename so an
  interrupted sync leaves the previous list intact
  ([#24](https://github.com/Babystep-Technologies/active_sanction/issues/24)).
- `Storage::ActiveRecord`, optional, with an indexed prefilter and a Rails install generator.
  ActiveRecord is not a dependency of this gem and the adapter loads only where a host has
  already loaded it ([#25](https://github.com/Babystep-Technologies/active_sanction/issues/25)).
- The shared `"a storage adapter"` conformance group, and a spec that holds it to being able
  to fail.

#### Matching

- `Normalizer`: Unicode NFKD, mark stripping, casefolding, punctuation, whitespace, and a
  table for the Latin letters decomposition cannot reach. One code path for the index and the
  query, memoized and thread-safe
  ([#26](https://github.com/Babystep-Technologies/active_sanction/issues/26)).
- Token dictionaries — legal forms, honorifics, organization stopwords, and a preserve list
  that always wins — applied per entity type, as editable data files
  ([#27](https://github.com/Babystep-Technologies/active_sanction/issues/27)).
- Jaro-Winkler and Levenshtein
  ([#28](https://github.com/Babystep-Technologies/active_sanction/issues/28)), token sort and
  token set ratios ([#29](https://github.com/Babystep-Technologies/active_sanction/issues/29)),
  and Double Metaphone phonetic keys
  ([#30](https://github.com/Babystep-Technologies/active_sanction/issues/30)) — all pure Ruby.
- An inverted index for candidate generation, keyed on tokens and phonetic codes
  ([#31](https://github.com/Babystep-Technologies/active_sanction/issues/31)).
- `Scorer`: a 0-100 score that **is** the sum of its reasons, with secondary-identifier
  adjustments on document numbers, dates of birth and nationality, an absent-is-not-conflict
  rule, and early exits that are bounds rather than approximations — a thresholded call
  returns exactly the scores an unthresholded one does
  ([#32](https://github.com/Babystep-Technologies/active_sanction/issues/32)).
- `Country`, resolving both sides of a nationality comparison against a shipped ISO 3166-1
  table, so `RU` meets `Russian Federation` and an unrecognized value is absent rather than a
  contradiction.

#### The public API

- `Matcher`, `Query` and `MatchResult`, plus `ActiveSanction.screen` and `.screen_all`. A
  matcher is immutable once built and screens from many threads without a lock; nothing on the
  query path reads configuration
  ([#33](https://github.com/Babystep-Technologies/active_sanction/issues/33)).
- Every `MatchResult` carries the snapshot checksum, matcher version, weights and query, and
  round-trips losslessly through `to_h` / `from_h`, so a screening decision can be re-derived
  by somebody who has neither this process nor this version of the gem.
- `ActiveSanction.sync!`: per-source failure isolation, a failed source keeping its previous
  snapshot with a visible age, polite by-publisher concurrency, and a serializable report with
  an exit code ([#34](https://github.com/Babystep-Technologies/active_sanction/issues/34)).
- `ActiveSanction.diff`: additions, delistings and amendments between two snapshots, joined by
  entity id, so a book of business is re-screened against what moved
  ([#35](https://github.com/Babystep-Technologies/active_sanction/issues/35)).
- `ActiveSanction.configure`, with a working default for every setting and a
  `ConfigurationError` raised where a bad value is set rather than three hours into a sync.

#### Measurement and tooling

- `rake benchmark:accuracy` and `rake benchmark:latency`, an 87-query labeled set, and a
  **committed** accuracy report — a diff in
  [`benchmark/results/accuracy.md`](benchmark/results/accuracy.md) is a change in what this
  library finds ([#37](https://github.com/Babystep-Technologies/active_sanction/issues/37)).
  The default threshold of 75 is where F1 peaks on that set, measured rather than chosen.
- Benchmarks for the similarity algorithms, the index and the scorer
  ([#28](https://github.com/Babystep-Technologies/active_sanction/issues/28),
  [#31](https://github.com/Babystep-Technologies/active_sanction/issues/31),
  [#32](https://github.com/Babystep-Technologies/active_sanction/issues/32)).
- Sorbet at `typed: strict` across `lib/`, with per-query signatures declared
  `.checked(:tests)` and a supported way for a host to turn every runtime check off
  ([#73](https://github.com/Babystep-Technologies/active_sanction/issues/73)).
- CI across Ruby 3.1-3.3, and a hermetic suite — an un-stubbed HTTP call fails rather than
  quietly reaching a government server
  ([#2](https://github.com/Babystep-Technologies/active_sanction/issues/2),
  [#3](https://github.com/Babystep-Technologies/active_sanction/issues/3)).

### Known limitations at this release

Documented in full in the README under
[Known data limitations, per source](README.md#known-data-limitations-per-source), and
summarized here because they are what a reader of a first release most needs:

- Five lists: two US, one UN, one Canada, one EU. The UK
  ([#40](https://github.com/Babystep-Technologies/active_sanction/issues/40)) and Australia
  ([#41](https://github.com/Babystep-Technologies/active_sanction/issues/41)) are not read.
- Non-Latin script is not transliterated. A Cyrillic name matches a Cyrillic query and nothing
  else.
- OFAC's secondary identifiers come from heuristic parsing of free text, at 97.3% segment
  coverage.
- Canada publishes no nationality, address, place of birth or document number at all, and no
  identifier of its own — so its ids are synthetic, and a clean Canadian result is weaker
  evidence than a clean OFAC one.
- The EU publishes no primary name and no alias-quality column, so which of a record's names
  is called primary is this library's rule rather than the Commission's, and most EU aliases
  arrive ungraded. Its endpoint ignores conditional GET, so every sync of it transfers 25.7 MB.
- The labeled accuracy set does not yet carry EU cases, so the committed recall and precision
  figures describe the other four lists. The EU adapter's own spec covers it; the accuracy
  report does not.
- Recall at the default threshold is 0.939 overall on the labeled set, and every record this
  version misses is named in the committed accuracy report.

[Unreleased]: https://github.com/Babystep-Technologies/active_sanction/commits/main
