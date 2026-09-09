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
- **Australia's Consolidated List (DFAT)** — 3,906 records, read with no change to core
  ([#41](https://github.com/Babystep-Technologies/active_sanction/issues/41)). The endpoint the
  issue named was unverified and is now gone: `regulation8_consolidated.xlsx` redirects to a
  `.xls` last modified in **March 2022**, which is served 200 and would look healthy on every
  sync. This adapter reads the file DFAT's own page links today. Two things are worth knowing
  before relying on it. **The Control Date is not a listing date** — DFAT defines it as when
  the entry was last edited, it is on all 11,163 rows, and mapping it to `listed_on` would
  report the Taliban listings of January 2001 as having been made this year; the real listing
  date is prose, and is read on 1,438 of the 3,906 records. And **DFAT publishes no document
  number of any kind** — no passport, no national identity number, no company registration —
  so the only identifier on the list is an IMO number on 344 vessel rows, which makes a clean
  Australian result weaker evidence than a clean OFAC one for the same reason a Canadian one
  is. The endpoint also rejects this gem's User-Agent outright: its edge drops a request whose
  leading product token it does not recognise, so this source sends the configured agent
  inside `Mozilla/5.0 (compatible; …)` — the same identification, in a shape the edge parses.
  It is the only place any source departs from `Sources::Base`.
- `Parsers::Spreadsheet`, a reusable `.xlsx` toolkit, **and no new dependency**. Australia
  publishes its list as a spreadsheet and as nothing else, so reading one is the price of
  screening against Australian sanctions at all — but an `.xlsx` is a ZIP of XML parts, `zlib`
  is stdlib and this gem already reads XML, so what was missing was a ZIP header unpacker. It
  resolves the shared string table and reads `xl/styles.xml`, which is not optional: `18798`
  is a date if the cell is formatted as one and a year if it is not, and the Australian list
  has 4,183 of the first and 2,709 of the second in the same column. Date cells arrive as ISO
  8601 at the precision the cell displays, which `PartialDate::Parser` reads directly.
- Two spellings added to `countries.txt` — `Democratic People's Republic of Korea (North
  Korea)` and `Slovak Republic` — which resolve the only 2 of Australia's 77 nationality
  values that previously did not. Purely additive: no existing spelling resolves differently.
- `docs/adding_a_source.md`, the end-to-end walkthrough for an eighth
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
- **The bundle format**: one list in one file that a different machine loads and trusts without
  reaching the publisher, specified byte for byte in
  [`docs/bundle_format.md`](docs/bundle_format.md) so that it can be produced and read outside
  Ruby ([#57](https://github.com/Babystep-Technologies/active_sanction/issues/57)).
  `ActiveSanction.export` writes one and `.import` loads it, over
  `Snapshot::Bundle.write`/`.read`. Deterministic — the same snapshot always produces the same
  bytes, since records are ordered by content, header keys have a fixed order, the compression
  level is named by the specification and nothing in the file says when it was written — so two
  mirrors of one list are comparable.
- Detached signatures over a bundle, `openssl` and nothing else. The signature covers the
  header, which carries a digest of every record, so an unknown signer is refused *before* a
  byte of what they sent is decompressed. Verification is opt-in and unsigned bundles stay
  fully usable; a tampered file, a file signed by the wrong key, an unsigned file somebody
  asked to verify, and a file from a newer gem each raise a different error, because each has a
  different fix.
- `Snapshot#trusted?` and `MatchResult#verified?`, so a screening decision records whether the
  list that answered it was attested. Deliberately in-memory: a signature covers a bundle's
  bytes, not the copy a store rewrites into its own layout, so `trusted?` does not survive a
  write to disk. `MatchResult` gains `verified` as the sixth field of its reproducibility
  stamp — an addition to the serialized shape, which a record written without it reads back
  as `false`.

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
- `ActiveSanction.rescreen`: who a list change affects, which is the step that turns a diff
  into an alert ([#60](https://github.com/Babystep-Technologies/active_sanction/issues/60)).
  Screening a customer once is a checkbox; the obligation is ongoing, and the naive way to meet
  it — every subject against every record, every night — costs the whole book times the whole
  corpus. This costs the book times the handful of records that moved: 10,000 subjects against
  a typical daily OFAC diff in 1.2 s, against 54 s to screen the same book against the whole
  list.
  - `Subject`, a book entry: the host's own stable id plus every evidence field `screen`
    accepts, in every spelling it accepts them in. An alert names a customer rather than a
    name, because a book screened by position cannot survive being filtered, streamed in
    batches, or containing the same name twice.
  - `Rescreen::Alert` classifies what happened to *the subject's match* — `newly_listed`,
    `delisted`, `details_changed` — and carries a full `MatchResult` for each side of the
    change, each stamped with the checksum of the list version it was scored against. Both
    checksums are on the alert itself, so keeping one is keeping enough to derive the run
    again, and the prior score is what lets it say a subject moved from 71 to 94 rather than
    only that it now matches. It round-trips through `to_h` / `from_h` like a `MatchResult`.
  - **A delisting raises an alert too.** It is a change of status a compliance team has to
    record, and it is the half a re-screen against new records only would miss.
  - **An amendment that does not move the score still raises one.** A program added or an
    address corrected changes what a hit means without changing what it scores, and filtering
    those would be deciding which sanctions hits a host is willing to miss.
  - **A large book streams past a small diff.** Subjects are read one at a time and only alerts
    are kept, the block is called with each alert as it is raised, and one `Rescreen` is
    reusable across batches so its index is built once. Nothing here touches the matcher: a
    rescreen indexes the diff and nothing else, so applying one never costs an index build over
    the whole corpus.
  - **An empty diff does no work at all** — not one subject is folded — which is what makes
    rescreening after every sync affordable. A first sync is a baseline rather than a list of
    additions, so it raises nothing either.
- `ActiveSanction.doctor`: whether a source's format has drifted, aggregated out of the health
  signals a normal fetch and parse already produce
  ([#68](https://github.com/Babystep-Technologies/active_sanction/issues/68)). It catches the
  format change a sync cannot see — the one where the file still parses cleanly and means
  something different, which today nothing would notice for months.
  - **Field fill rates per source**, the check that catches a clean parse of a changed file:
    19,321 entities carrying zero passports looks exactly as healthy as 19,321 carrying 23,429
    if the only thing counted is records. Measured over the records that could carry the field,
    so a date of birth is a share of individuals.
  - **The baseline is the last stored snapshot**, not a threshold committed per adapter — one
    of those goes stale on its own, and the day somebody widens it to make a build pass is the
    day it stops being read. Floors declared with `floor :remarks_coverage, 0.90` remain as a
    coarse backstop for a run with nothing to compare against.
  - **Column shape assertions for positional files.** OFAC ships headerless CSVs, so the
    declared width catches a column *inserted* upstream and nothing catches one *reordered* —
    which parses cleanly and builds entities out of shifted fields. `Parsers::ColumnShape`
    asserts what the values are, not only how many there are.
  - Free-text coverage, warning classes and orphaned child rows compared the same way, with the
    severities meaning something specific: `error` is a reading no publisher could produce by
    changing its *list*, `warn` is one a human should look at before the next sync.
  - A serializable `Doctor::Report` with `exit_code` for cron and CI, and human-readable
    `to_s` for the CLI verb to print. **The doctor writes nothing** — not the snapshot, not the
    payload cache, not the conditional-GET validators — so diagnosing a source can never be the
    reason a later sync decides it is unchanged, and nothing here repairs anything.
- `ActiveSanction.configure`, with a working default for every setting and a
  `ConfigurationError` raised where a bad value is set rather than three hours into a sync. A
  setting that does not exist is refused too, and the message names the ones that do.
- `Client`, the object a server holds, and the end of process-global configuration
  ([#55](https://github.com/Babystep-Technologies/active_sanction/issues/55)). Everything at
  the module level — `ActiveSanction.screen`, `.sync!`, `.diff`, `.doctor` — is now sugar over
  a default client that `ActiveSanction.configure` populates, so the quickstart is unchanged
  and a script never has to know this exists. What it buys is what a global could not express:
  several configurations alive at once.
  - `ActiveSanction::Client.new(storage:, sources:, user_agent:, ...)` takes every setting
    `configure` takes, holds it frozen, and shares nothing with another client — its own store,
    its own lists, its own index, its own publisher identity. Two clients screen against their
    own data with no cross-talk, which is what a pinned list version for an audit re-run beside
    the current one for live traffic, and a source set per tenant, both need.
  - `Configuration` became that client's value object rather than global state. It is frozen
    when a client is built, `#with` derives a mutable copy from a frozen one, and the default
    store is settled at freeze rather than memoized on first read — so no two threads can race
    to construct it.
  - **The thread-safety contract is written down**: a built client and its loaded index are
    safe to screen from concurrently, and `sync!` is safe alongside readers but is not
    concurrent-safe against another sync of the same storage. See the README table.
  - `ActiveSanction.reset!` (previously `reset_configuration!`) drops the default client
    outright, which is what a suite runs between examples.
  - A sync that fans out now carries the configuration it was started under into each worker
    thread, so a client's User-Agent does not depend on `sync_concurrency:`; and the source
    registry is built at load rather than on first write, so two adapters registering from two
    threads cannot each create half of it.
- One documented error hierarchy under `ActiveSanction::Error`, which `rescue` catches
  everything this library raises from a public method
  ([#58](https://github.com/Babystep-Technologies/active_sanction/issues/58)):
  `ConfigurationError`, `SourceError` (`FetchError`, `ParseError`, `IntegrityError`),
  `StorageError`, `UnsupportedError`, `InvalidArgument` (`QueryError`) and `MissingKey`.
  - Every error carries structured attributes rather than only a message: `source_id`,
    `status`, `retryable?` and `to_h`. `retryable?` is first-class, so a host application
    builds backoff from a predicate instead of from message strings — a 503 or a timeout is
    retryable, a 403 or a parse failure is not, and a misconfiguration never is.
  - `ParseError` says *where*: `line`, `record` or `offset`, appended to its own message, so a
    25 MB payload that turns out not to be XML is diagnosable.
  - The list a failure belongs to is stamped on as the error leaves the adapter, since the
    layer that raises usually cannot know it — the HTTP client sees a URL.
  - No public method leaks an exception class from `net/http`, `openssl`, `csv`, `rexml`,
    `nokogiri`, `zlib` or `json`, and nothing raises a bare `RuntimeError` or `ArgumentError`.
    `InvalidArgument` is an `::ArgumentError` and `MissingKey` a `::KeyError`, so surrounding
    code keeps the rescue it already has; `ActiveSanction::Error` is a module so that both can
    be in the hierarchy anyway.

#### Measurement and tooling

- `rake benchmark:rescreen`, which measures applying a diff to a book of business against the
  naive full rescreen it replaces, and sweeps how the cost moves with how much the list did
  ([#60](https://github.com/Babystep-Technologies/active_sanction/issues/60)).
- `rake benchmark:accuracy` and `rake benchmark:latency`, an 87-query labeled set, and a
  **committed** accuracy report — a diff in
  [`benchmark/results/accuracy.md`](benchmark/results/accuracy.md) is a change in what this
  library finds ([#37](https://github.com/Babystep-Technologies/active_sanction/issues/37)).
  The default threshold of 75 is where F1 peaks on that set, measured rather than chosen.
- **The upstream canary**: a scheduled workflow that fetches all seven lists from their real
  publishers on weekdays, parses them, and compares what it measures against the baselines
  committed under [`.github/baselines`](.github/baselines)
  ([#69](https://github.com/Babystep-Technologies/active_sanction/issues/69)). It is
  `ActiveSanction.doctor` pointed at a file instead of a snapshot, and it is for the
  maintainer rather than the operator — a downstream doctor warning that OFAC's remarks
  vocabulary moved can only ever result in an issue filed here, because the label table lives
  here.
  - **The output is a GitHub issue, one per source**, opened with the findings, rewritten by
    every run that still finds something, and closed by the first run that comes back clean.
    Deliberately not a red badge: this never runs as part of CI, because a red build should
    mean our code broke rather than that a source went down.
  - **A fetch failure is reported separately from a parse difference**, and nothing is opened
    until two consecutive runs agree about it. Government endpoints 403 a non-browser user
    agent and block cloud IP ranges, and a canary that cried wolf on one bad afternoon would
    be muted inside a week. Each run keeps its report as a workflow artifact and the next run
    confirms against it.
  - **The baseline is a committed file, with tolerances per key** — 5% on a record count,
    which moves every business day, and 2% on free-text coverage, which does not move on its
    own at all. A diff in `.github/baselines` is a change in what a government publishes, and
    a clean run opens a rolling pull request keeping those numbers current.
  - It found something on its first run: OFAC's Consolidated list inherited the SDN file's
    90% remarks-coverage floor and reads at 80.3%, because the CMIC rows publish a vocabulary
    — `Purchase/Sales For Divestment`, `Equity Ticker`, `HKAA Section 5` — that has no
    equivalent on the SDN file and nothing for this parser to do with it. The floor is now
    declared on the Consolidated adapter at 0.75, so a first `doctor` run against a fresh
    deployment no longer warns about a list that is doing exactly what it always does.
- Benchmarks for the similarity algorithms, the index and the scorer
  ([#28](https://github.com/Babystep-Technologies/active_sanction/issues/28),
  [#31](https://github.com/Babystep-Technologies/active_sanction/issues/31),
  [#32](https://github.com/Babystep-Technologies/active_sanction/issues/32)).
- Sorbet at `typed: strict` across `lib/`, with per-query signatures declared
  `.checked(:tests)` and a supported way for a host to turn every runtime check off
  ([#73](https://github.com/Babystep-Technologies/active_sanction/issues/73)).
- CI across every Ruby the gem supports — 3.1, 3.2, 3.3, 3.4 and 4.0, plus a non-blocking
  `ruby-head` — with the matrix, `.ruby-version`, `required_ruby_version` and RuboCop's
  `TargetRubyVersion` held to each other by a spec, so the version a change is developed on
  cannot again be the one version no build runs
  ([#2](https://github.com/Babystep-Technologies/active_sanction/issues/2),
  [#80](https://github.com/Babystep-Technologies/active_sanction/issues/80)).
- A hermetic suite — an un-stubbed HTTP call fails rather than quietly reaching a government
  server ([#3](https://github.com/Babystep-Technologies/active_sanction/issues/3)).

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
