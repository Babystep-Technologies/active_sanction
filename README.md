<p align="center">
  <img src="https://babystep.tech/active_sanction/logo.svg" alt="" width="180" height="180">
</p>

# ActiveSanction

[![Gem](https://img.shields.io/gem/v/active_sanction?label=gem&color=CC342D)](https://rubygems.org/gems/active_sanction)
[![CI](https://github.com/Babystep-Technologies/active_sanction/actions/workflows/ci.yml/badge.svg)](https://github.com/Babystep-Technologies/active_sanction/actions/workflows/ci.yml)

**[Full documentation, guides and the source catalogue →](https://babystep.tech/active_sanction/)**

Screen a name against government sanctions lists, in Ruby, in your own process.

ActiveSanction fetches the lists a jurisdiction publishes, parses each of them into one record model, stores them where you tell it to, and scores a name against them with an account of every point it awarded. The lists live on your disk or in your database, screening runs in your process, and no name you screen leaves it.

```ruby
ActiveSanction.sync!

ActiveSanction.screen(name: "Bosco Ntaganda", type: :individual, date_of_birth: "1973")
# => [#<MatchResult score=100.0 source=:un_consolidated matched_name="Bosco Ntaganda">]
```

## A screening aid, not legal advice

**This library is a screening aid. It is not legal advice, and it is not a compliance program.**

**Verify every hit against the official published list before acting on it.** What this gem produces is one library's reading of a government file. The government's own published list is the record that counts, and a report generated here has no standing of its own.

**A clean result is not a legal clearance.** No name matcher finds everything. A spelling this version does not reach, a jurisdiction this gem does not yet read, a designation published an hour after your last sync — each of them returns an empty array, and an empty array means *nothing over the threshold in the lists we currently hold*. It does not mean *not sanctioned*. [`benchmark/results/accuracy.md`](benchmark/results/accuracy.md) names every record this version misses and every one it wrongly alerts on, because a user deciding whether to rely on this is entitled to see them.

**You remain responsible for your own compliance obligations.** Which lists to screen, at what threshold, how often, what to do with a hit, and what your regulator expects of you are decisions this library cannot make and does not make. A false negative here can mean a sanctions violation, and the liability for one stays with you.

## The gem, and the service

**The gem is complete on its own.** Every supported list is fetchable, parseable and screenable locally, forever, with no account and no key. Nothing is withheld to make anything else more attractive: the matching engine, every adapter, the weights, the dictionaries and the measured accuracy of all of it are in this repository, and they are the whole of what we run.

**A commercial hosted service exists, and what it sells is operations rather than capability** — data kept fresh through upstream breakage, an availability guarantee, continuous monitoring of a book of business, and a retained audit trail. Upgrading is one configuration line ([#56](https://github.com/Babystep-Technologies/active_sanction/issues/56)). Not upgrading costs no capability; it costs the work of running the sync yourself, and noticing when a publisher changes its format.

## What it does

- **Fetches.** Conditional GET on ETag and Last-Modified, bounded redirects, retries with backoff, a checksum-verified cache of the raw payloads, and a User-Agent that identifies you to the publisher.
- **Parses.** Seven lists today, into one `Entity`: names and aliases with their kind and quality, dates of birth as `PartialDate` (year-only, approximate and ranged dates are all real on these lists), addresses, document numbers, nationalities, programs — and the publisher's own text kept verbatim in `remarks` whether the parser understood it or not.
- **Stores.** One checksummed `Snapshot` per source, in gzipped JSON on disk, in your application's database, in memory, or in a store you write. Nothing on the query path names a concrete store.
- **Publishes.** Any stored list, as one signed, versioned, byte-for-byte reproducible file that another machine loads and trusts without reaching the publisher — for an air-gapped installation, or for the afternoon a government endpoint is down. The [format is specified](docs/bundle_format.md) in enough detail to be implemented outside Ruby.
- **Screens.** Fold the name, retrieve candidates from an inverted index, score each with four string algorithms and a phonetic pass, adjust on dates of birth, nationalities and document numbers, and report the reasons — which sum to the score exactly.
- **Diffs.** What changed between two syncs, so a book of business is re-screened against the handful of records that moved rather than against the whole list.
- **Rescreens.** Applies that diff to a book of business and reports who it affects — newly listed, delisted, or listed under details that moved — with the prior score, both snapshot checksums, and the caller's own id on every alert.
- **Diagnoses.** Whether a list still parses the way we think it does — field fill rates, the free-text vocabulary, the shape of a positional column — measured against the version stored at the last sync, because the dangerous format change is the one where the file still parses cleanly and means something different.
- **Stamps.** Every result carries the snapshot checksum, the matcher version, the weights, the query, and whether the list that answered was a signed bundle that verified — so a screening decision made today can be re-derived in three years by somebody who has neither this process nor this version of the gem.

## What it does not do

- **It does not decide anything.** A score is evidence for a human. The threshold at which a score becomes an alert, and what happens to that alert, are policy your compliance function owns.
- **It is not a case management system.** No alert queue, no dispositions, no audit store. It produces the record; keeping it is your application's job.
- **It screens names against lists, and nothing more.** No politically-exposed-person data, no adverse media, no beneficial ownership, no OFAC 50 Percent Rule resolution — a subsidiary that is sanctioned only by virtue of its owners is not on any of these files and will not be found here.
- **Seven lists ship: two US, one UN, one Canada, one EU, one UK, one Australia.** If your obligations cover a jurisdiction outside that set, this gem does not cover them.
- **Non-Latin script is not transliterated.** `Путин` does not fold to `putin`; a Cyrillic name matches a Cyrillic query and nothing else. What makes it survivable is that these publishers ship a romanized name alongside the original — see [Normalizing a name](https://babystep.tech/active_sanction/explanation/how-matching-works/#normalizing-a-name) for what that does and does not leave open.
- **It does not monitor your deployment.** It syncs when you tell it to, and it diagnoses when you tell it to. `ActiveSanction.doctor` will notice that a publisher changed its format, but only in a job you schedule — nothing in your process runs overnight on its own, and nothing wakes anybody when it finds something. What does run overnight is [the upstream canary](https://babystep.tech/active_sanction/how-to/detecting-format-drift/#the-upstream-canary-the-same-idea-run-on-a-schedule-against-real-endpoints), on this repository rather than on yours: it watches the seven published lists on weekdays and files an issue here when one of them changes, which is how the adapters get fixed — but it knows nothing about whether *your* sync ran ([#69](https://github.com/Babystep-Technologies/active_sanction/issues/69)).
- **There is no CLI.** It is a library, called from an initializer, a rake task or a job.

## Installation

```ruby
gem "active_sanction"
```

    $ bundle install

or

    $ gem install active_sanction

Ruby 3.1 or newer. The dependencies are `csv`, `rexml` and `sorbet-runtime` — all pure Ruby, so nothing here builds a native extension or asks a deployment to. Nokogiri is supported as an XML backend and is deliberately not a dependency; see `xml_backend` under [Configuration](#configuration). Australia publishes its list as an Excel workbook and no spreadsheet gem was added for it either — see [The Australian Consolidated List](#the-australian-consolidated-list).

## Quickstart

**Configure.** One setting is worth setting; everything else has a working default.

```ruby
# config/initializers/active_sanction.rb
ActiveSanction.configure do |c|
  c.user_agent = "acme-bank/1.0 (compliance@acme.example)"
end
```

OFAC answers a request with no User-Agent with a 403, so this can never be blank — and a publisher that needs to reach whoever is hammering its endpoint can otherwise only reach this repository. Identify yourself.

**Sync.** Download every configured list and store it.

```ruby
report = ActiveSanction.sync!
puts report
```

```
7 sources in 62.31s: 7 updated
  australia_dfat     updated     3906 records  just fetched   13.33s
  canada_sema        updated     5690 records  just fetched    3.99s
  eu_fsf             updated     6234 records  just fetched   14.48s
  ofac_consolidated  updated      481 records  just fetched    3.23s
  ofac_sdn           updated    19329 records  just fetched    9.92s
  uk_sanctions_list  updated     6334 records  just fetched   13.90s
  un_consolidated    updated     1011 records  just fetched    3.44s
```

The first run downloads each list in full. Later ones ask every publisher whether anything has changed and usually download nothing at all, so a sync scheduled hourly costs a handful of conditional requests on most days. Snapshots land in `~/.active_sanction` unless you name a store. A source that fails does not stop the others and **keeps the list it already had**; `report.failed?` and `report.exit_code` are what a cron job alerts on. See [Syncing every list, and what happens when one is down](#syncing-every-list-and-what-happens-when-one-is-down).

**Screen.**

```ruby
results = ActiveSanction.screen(
  name:          "Bosco Ntaganda",
  type:          :individual,
  date_of_birth: "1973",
  countries:     %w[CD]
)

hit = results.first
hit.score                       # => 100.0
hit.source                      # => :un_consolidated
hit.matched_name.value          # => "Bosco Ntaganda", an alias; the UN
                                #    publishes him as "BOSCO TAGANDA"
hit.explanation.map(&:to_s)
# => ["+100.0 name: matched alias \"Bosco Ntaganda\" (aka)",
#     "+6.0 dob: date of birth 1973 overlaps listed 1973 to 1974",
#     "+6.0 nationality: CD matches",
#     "-12.0 clamp: 112.0 capped to 100.0"]

JSON.generate(hit.to_h)         # into your audit record
```

An empty array is the ordinary answer — most people are not on a sanctions list. Everything that could make an empty array a lie rather than a fact raises instead: screening a store nobody has synced raises `Matcher::NotSynced`, and naming a list the matcher does not hold raises `Storage::MissingSnapshot` rather than quietly screening two lists when you asked for three.

**Keep it fresh.** Sync on a schedule, and drop the shared matcher so the next screening call answers from what was just synced.

```ruby
# lib/tasks/sanctions.rake
task sync_sanctions: :environment do
  report = ActiveSanction.sync!    # calls ActiveSanction.reload! itself when anything changed
  warn report.to_s
  exit report.exit_code            # 1 if any source failed
end
```

Then re-screen your book of business against what actually moved, rather than against the whole list:

```ruby
diff = ActiveSanction.diff(:ofac_sdn, from: last_nights_snapshot)
diff.changed    # => [Entity], the additions and amendments to re-screen against
diff.removed    # => [Entity], delistings — the alerts you can now close
```

That is the whole of the working library. Everything below is either a fact about the data you should know before relying on it, or an account of how one of those five calls works.

## The lists

Seven lists ship today: two US, one UN, one Canada, one EU, one UK, one Australia. The key, jurisdiction, authority, endpoint, format and record count for each — generated from the adapter registry and the canary's last measurement, never hand-typed — are in the [source catalogue](https://babystep.tech/active_sanction/reference/sources/).

No publisher commits to a schedule, and none of them announce a change out of band, which is why every fetch here is conditional: asking daily costs one request per file on the days nothing happened. Sync on your own risk appetite rather than on a publisher's calendar.

### Known data limitations, per source

These are the facts a screening policy has to be built on. They are properties of what the government publishes, not of this parser, and none of them can be fixed downstream.

**Both OFAC lists — every secondary identifier is free text.** The SDN CSVs have no column for date of birth, place of birth, nationality or passport number. All of it — 88,827 semicolon-delimited segments, measured against the September 2026 list — is prose in one `Remarks` field, written for a person reading a page. `Sources::Ofac::RemarksParser` reads it heuristically and currently recognizes **97.3%** of those segments. Extraction is additive: a segment nobody has taught it yet costs structure and never content, because `Entity#remarks` keeps the publisher's whole string either way. `source.remarks_coverage` reports the number for the file you actually fetched, and it is worth watching — a drop in it is a publisher changing how it writes.

**`ofac_consolidated` — sub-list attribution is derived, and is exact for 478 of 481 records.** OFAC ships six lists (SSI, CMIC, NS-PLC, NS-MBS, CAPTA, FSE) in one file with no column saying which is which, so the program code is what `OfacConsolidated.lists` maps. The three records it does not get exactly right are all `RUSSIA-EO14024` — Gazprom, Transneft and Rosselkhozbank are on both SSI and NS-MBS and come out marked SSI only. A hit is still a hit; which of two US lists it names may be incomplete.

**`un_consolidated` — place of birth, gender, title and designation are not structured.** They have no home in the canonical model, so they are appended to `remarks` rather than dropped. They are readable and they are not scored on.

**`canada_sema` — the weakest list for corroborating a name match, by some distance.** Global Affairs publishes no nationality, no address, no place of birth and no document number for any of the 5,690 records, and a date of birth for a minority of them. An individual is a surname, given names and a free-text alias field, so there is nothing in a Canadian record to make a name match decisive the way an OFAC passport number usually does. **A clean Canadian result is weaker evidence than a clean OFAC one**, and the measured recall says so: 0.880 against the UN's 1.000.

Three further consequences of the same file:

* **The ids are ours.** Canada publishes no identifier of any kind, only a citation — which regulation, which schedule, which item — and item numbers get renumbered whenever a schedule is amended. `CanadaSema::SourceRef` hashes the citation *and the name*, which means correcting a typo in a published name re-ids that record and reports in a diff as a delisting plus a listing. Churn in a diff is a nuisance; one id covering two different people would be a screening failure.
* **Aliases are one comma-joined string with no declared separator, and no kinds.** They are split on semicolons and never on commas, because `Завод "Дагдизель", АО` would otherwise yield a bare Russian legal form as an alias. That costs recall on roughly 300 records whose primary name is published anyway.
* **`Country-Pays` is not a nationality** and is not read as one. It names the regulation a person is listed under, so it is mapped to `programs`.

**`eu_fsf` — no name is marked as the official one, and four birth dates are not Gregorian.** All 31,053 published names are equal `<nameAlias>` elements carrying `strong="true"`, so which one to call primary is this adapter's decision rather than the Commission's — see [The EU consolidated list](#the-eu-consolidated-list) for the rule and what it costs. Separately, `calendarType="ISLAMIC"` appears on four birth dates whose year, month and day are Hijri; three of them carry no Gregorian equivalent and so produce **no date of birth at all**, with the published date kept in `remarks`. A screening policy that expects a date of birth on every EU person will not get one, and that is the safe direction: reading `1343` as a Gregorian year would make a real date of birth *conflict* with the record and push a true hit below the threshold.

Two further consequences of the same file:

* **Conditional GET does not work, so every sync downloads 25.7 MB.** The endpoint serves `Last-Modified`, sends no `ETag` and `Cache-Control: no-store`, and answers `If-Modified-Since` with 200 and the whole file. The request is still made conditionally, and the parsed content still hashes to the same snapshot checksum, so a re-download of an unchanged list diffs to nothing — but the bandwidth is spent. Budget for it if you sync hourly.
* **Alias quality is prose, not a column.** The EU publishes no grade. 499 of the 31,053 names carry one in the free-text `<remark>` on the name — "low quality alias", "Good quality a.k.a.", "formerly known as" — which is read; the rest arrive ungraded, which the scorer treats as unstated rather than as good.

**`uk_sanctions_list` — the list this one replaced is still on the internet, and still answers 200.** The UK moved every sanctions designation onto one list on 28 January 2026. OFSI's Consolidated List of Asset Freeze Targets stopped being updated that day and its gov.uk page is marked withdrawn — but `ofsistorage.blob.core.windows.net/publishlive/2022format/ConList.csv` still serves a real 16.6 MB file. A screening system pointed at it downloads successfully, parses successfully, reports itself fresh, and screens against a list that has not moved since January. This adapter reads the UK Sanctions List instead. If you have your own integration against `ConList.csv`, that is the thing to check today.

**`uk_sanctions_list` — a date component the FCDO does not know is spelled out, not omitted.** 824 of the 3,788 published birth dates — 22% — carry a placeholder where a component goes: `dd/mm/1962` is a year, `dd/07/1978` is a year and a month, and one record spells the same absence with zeros as `00/00/1975`. Read with any ordinary date parser every one of them is nil, and 22% of everything this list says about when a person was born disappears with no warning; read credulously they become invalid dates, or dates the scorer compares as though the FCDO had been precise. `Sources::UkSanctionsList::PublishedDate` reads them at the precision the FCDO stated. One record, `15/08/19yy`, states a day and a month and no year at all: `PartialDate` has no shape for that and it produces **no date of birth**, with the published string kept in `remarks`.

Three further consequences of the same file:

* **The FCDO's own script labels disagree with its own strings, so `Name#script` is left unstated.** `NonLatinScriptType` is on 2,057 of the 3,856 non-Latin names and agrees with the characters on 2,054 of them — but three names labelled `Cyrillic` are Latin transliterations, and 185 names filed as non-Latin hold no non-Latin character at all. The label and the language are kept in `remarks`, and which script a string is in stays a question about its characters.
* **A "number" field may be a sentence.** 340 of the 721 business registration numbers open with a label (`INN: 7710137066`), a handful carry several numbers, a country and a newline in one field, and one national identity number reads `Kuwait, number 260012001546`. All of it is kept exactly as published: every rule that peels `INN: ` off the first also has to decide what to do with the rest, and each of those answers is a guess about free text. The exception is a ship's IMO number, where the prefix restates the element it is already inside — `IMO9562233` on 635 of the 670, and bare on the other 35 — and is peeled into the note so that the FCDO's own two spellings of one registry number are one identifier rather than two.
* **`<CryptoWalletAddresses>` and `<HullIdentificationNumbers>` are in the schema and empty in the data**, so neither is read. They are the first things to add when either appears.

**`australia_dfat` — the Control Date is not a listing date, and it is on every row.** DFAT's own [guide to the list](https://www.dfat.gov.au/international-relations/security/sanctions/consolidated-list/guide-australias-consolidated-list) defines it as "the last date the sanction entry was updated or edited on the Consolidated List". It is a real date on all 11,163 rows, it is the only date-typed column in the file, and reading it as `listed_on` would report the Taliban listings of January 2001 as having been made a few months ago — with nothing in a sync report looking wrong. It is kept in `remarks`, labelled. The actual listing date is prose in `Listing Information`, and is read on the **1,438 of 3,906** records that state one; the other 63% name a legislative instrument and no date at all, and get no `listed_on`.

Four further consequences of the same file:

* **No document number of any kind, for any record.** No passport, no national identity number, no company registration. The only identifier on the whole list is an IMO number, on 344 vessel rows. So an Australian name match has nothing behind it to make it decisive, the way an OFAC passport number usually settles one — the same weakness as the Canadian list, and a screening policy should know it before setting a threshold.
* **A record is several rows, joined on a reference DFAT suffixes with letters.** `1000` is the primary name, `1000a` and `1000b` its aliases, and every other column is repeated on each — so 11,163 rows are 3,906 records. The repetition is not exact: 80 groups disagree with themselves about the additional information, 39 about the birth dates, 23 about the address. Every column is unioned across the group rather than read off the primary row, because two records have a place of birth, and one an address, only because an alias row carried it.
* **Birth dates arrive in nine spellings, two of which are only distinguishable through the spreadsheet's styles.** 4,183 are Excel serial numbers, 2,709 are the year somebody was born written as a plain number, and the two are the same kind of cell — a reader that ignores `xl/styles.xml` gets one of the two wrong for every row. The rest are `dd/mm/yyyy` text (day first: DFAT writes Australian dates, and not one of the 2,013 has a middle component above twelve), `mm/yyyy`, `Approximately 1963`, `Approximately: Between 1972 and 1975`, `12 April 1965`, ten-year lists, and pairs separated by a carriage return the workbook escapes as `_x000D_`. Four records out of 3,906 carry a fragment typed wrong at the source — `1980.1981`, `/02/1961`, `7/02/1950/11/1950`, `10/061962` — and each is kept verbatim in `remarks` rather than dropped.
* **An address is one free-text column and is not decomposed.** DFAT publishes no street, city or country parts, so the whole published string is `Address#street`. Where one cell enumerates several addresses `a) ... b) ...`, which is 859 rows, they are split; a semicolon is not split on, because it appears inside single addresses too.

**All seven — non-Latin script is not transliterated.** Cyrillic, Arabic, Han, Kana and Hangul are casefolded and stripped of marks in their own script, and never romanized. These lists publish a non-Latin name as an *additional* variant rather than instead of a Latin one, which is what makes it survivable; the residue is a record carrying one romanization queried with another. See [Normalizing a name](https://babystep.tech/active_sanction/explanation/how-matching-works/#normalizing-a-name), and [the blend, and what it cannot fix](https://babystep.tech/active_sanction/explanation/how-matching-works/#the-blend-and-what-it-cannot-fix).

## Reading a score

A score is a number from 0 to 100, and it is **the sum of the reasons on the result** — rounded once, with no arithmetic anywhere in this library that can move one without the other. `hit.explanation` is the thing to read; the number is a summary of it, and a 97 that is all name similarity is a different finding from an 82 with a passport number matching even though the score alone does not say so.

The default threshold is **75**, measured rather than chosen: it is where F1 peaks against a labeled set of real published records. [How matching works](https://babystep.tech/active_sanction/explanation/how-matching-works/) has the precision/recall/F1 curve, what raising or lowering the threshold costs, and the full account of how a score is built and why absence is never treated as conflict. [Tune the threshold for your risk appetite](https://babystep.tech/active_sanction/how-to/tuning-the-threshold/) is the how-to.

## Where the lists live

Storage is an interface with five methods, and **nothing on the query path names a concrete store**: `Storage::FileSystem` (the default, gzipped JSON on disk), `Storage::ActiveRecord` (your own database, plus an indexed prefilter), `Storage::Memory`, or one you write yourself. [Choose a storage backend](https://babystep.tech/active_sanction/how-to/choosing-a-store/) has the trade-offs and the conformance group every adapter is held to.

A store is where *this* machine keeps its lists. To move one *between* machines — an air-gapped host, or a mirror for the afternoon a publisher is down — export it as a signed bundle: one file, one command, and a signature an auditor can check. See [Publish and verify a signed bundle](https://babystep.tech/active_sanction/how-to/publishing-a-signed-bundle/).

## Performance

Numbers from `rake benchmark:latency`, `rake benchmark:index` and `rake benchmark:rescreen` on the machine they were last run on, against a corpus the size of the real lists — 47,051 indexed names over 27,000 entities. Your own are one command away; these are here so you can size a deployment before installing anything.

| | |
|---|---|
| Building the matcher | **3.84 s**, 49 MB resident. Paid once at boot, not per query |
| Screening, p50 | **14.8 ms** at the default threshold of 75 |
| Screening, p95 / p99 | 47.9 ms / 85.7 ms |
| Screening with no threshold | 51.4 ms p50 — a threshold is roughly two thirds of the cost, and changes no score |
| YJIT | Roughly halves the scoring cost. `RUBYOPT=--yjit` |
| Rescreening 10,000 subjects against a typical daily diff | **1.2 s** — against 54 s to screen the same book against the whole list. See [Rescreening a book of business](#noticing-what-changed-between-two-syncs-and-rescreening-a-book-against-it) |
| A sync where nothing changed | One conditional request per file, no download and no parse |
| A full OFAC SDN sync | Three files downloaded, joined across 19,321 entities, and 88,827 remarks segments parsed. The expensive half is the parse, which is exactly what a 304 skips |

```
threshold       mean       p50       p95       p99   slowest
        0     54.7 ms   51.4 ms  100.6 ms  128.6 ms  140.3 ms
       75     18.2 ms   14.8 ms   47.9 ms   85.7 ms   91.5 ms
       85     11.7 ms   10.2 ms   22.7 ms   39.1 ms   40.2 ms
```

A matcher is immutable once built, so many threads screen through one without a lock, and a sync builds a new one rather than mutating the old — requests in flight finish against one consistent list version. See [Holding a client, and screening from many threads](#holding-a-client-and-screening-from-many-threads).

Every early exit in the scorer is a bound on what a pair *could* reach, never an approximation of what it did reach, so **a result at or above the threshold is exactly the result the same call without a threshold returns**. `rake benchmark:scorer` fails loudly if a threshold ever changes a score.

## Configuration

Everything has a working default; `ActiveSanction.configure` exists so that a caller *can* identify itself, not so that one must recite the schema.

| Setting | Default | What it is |
|---|---|---|
| `user_agent` | `active_sanction/<version> (+<repo url>)` | Sent on every request. Cannot be blank — OFAC 403s without one. Set it to your own contact address |
| `open_timeout` / `read_timeout` | `10` / `60` seconds | Read timeout is per-read, so it does not cap how long a large download may take overall |
| `max_redirects` | `5` | OFAC's download URLs redirect to blob storage |
| `max_retries` / `retry_backoff` | `2` / `1.0` s | Three attempts total for a transient failure |
| `cache_dir` | `$XDG_CACHE_HOME/active_sanction` | Cache validators and raw payloads. Recoverable by fetching again; safe to delete |
| `storage_dir` | `~/.active_sanction` | Parsed snapshots, for the filesystem store. **The system of record** — publishers overwrite their files in place, so the list version a past decision was screened against exists only here |
| `storage` | `Storage::FileSystem` over `storage_dir` | Any `Storage::Base` |
| `retain_payloads` | `3` | Raw payloads kept per source, for re-parsing and diffing a suspicious file |
| `stale_after` | `86_400` s | What `stale?` measures against. Does not cap how long a cached copy may be *used* — that is your policy |
| `sources` | `nil`, meaning every registered source | `c.sources = %i[ofac_sdn un_consolidated]` |
| `sync_concurrency` | `1` | How many *publishers* are fetched from at once, never how hard any one of them is asked |
| `doctor_tolerance` | `0.10` | How far one of the doctor's measurements may move from the last sync before it says so. Overridden per run with `tolerance:` |
| `xml_backend` | `:rexml` | `:nokogiri` for a host already parsing OFAC's 126 MB advanced XML. The default is stdlib so that every installation parses identically — a checksum has to mean the same thing everywhere |
| `candidate_limit` | `200` | Names the index hands the scorer per query |
| `screening_threshold` | `75.0` | See [Reading a score](#reading-a-score). Overridden per query with `threshold:` |
| `screening_limit` | `10` | Results returned, highest first. A review queue, not a report |
| `normalizer_dictionary` | The four shipped token lists | See [Normalizing a name](https://babystep.tech/active_sanction/explanation/how-matching-works/#normalizing-a-name) |
| `scorer_weights` | `Scorer::Weights.default` | What each signal is worth. Changing one changes what every past decision would score today, which is why `weights` travels on every `MatchResult` |
| `logger` | `nil` | Anything Logger-shaped |

A bad value raises `ConfigurationError` at the point it is set, rather than producing a puzzling failure during a sync three hours later. So does a setting that does not exist: a misspelled one is refused and the message names the settings there are, because a silently dropped `user_agnet` is an installation running on a default somebody thinks they changed.

`ActiveSanction.configure` populates a default `Client` and freezes the configuration into it, so `ActiveSanction.config` is a value object rather than global mutable state — reading it is safe from anywhere, and changing it means configuring again. Every setting in the table above is also a keyword argument to `Client.new`, which is what a process holding several configurations at once uses instead; see [Holding a client, and screening from many threads](#holding-a-client-and-screening-from-many-threads).

```ruby
ActiveSanction.reset!    # drops the default client and starts from the defaults again — what a test suite runs between examples
```

## Handling errors

`rescue ActiveSanction::Error` catches everything this library raises from a public method, and under it sit the answers to the only three questions a caller embedding this in a request path actually has — *retry this*, *alert somebody*, *this is a bug in my call* — none of which should be answered by matching on a message string. The hierarchy is public API within a major version. [Handle errors](https://babystep.tech/active_sanction/how-to/handling-errors/) has the full tree, the `retryable?` table, and what to log.

## Adding a source

[`docs/adding_a_source.md`](docs/adding_a_source.md) is the end-to-end walkthrough: reading the publisher's file before writing anything, choosing the format toolkit, mapping its fields onto the canonical model, deriving a stable id for a list that publishes none, trimming a fixture, wiring up the conformance spec, and registering the adapter — from inside this gem or from an application that never forks it. It ends with a complete worked adapter, its fixture and its spec. [Add a sanctions source](https://babystep.tech/active_sanction/how-to/adding-a-source/) is the shorter field guide, pointing into the file's sections rather than restating them.

A source registered from outside this gem is a first-class source: a bank's internal watchlist is screened, stored, diffed and stamped exactly as OFAC's is.

There is no scaffold generator, deliberately. Roughly eight adapters at maturity do not repay one that has to be kept in step with `Sources::Base`, the conformance spec and the parser toolkits, and that goes stale silently when it is not; the document plus the closest existing adapter to copy does the same job with none of the upkeep.

Every source adapter is held to one shared example group, `"a sanction source"` (`spec/support/shared_examples/sanction_source.rb`), which checks what everything downstream of an adapter assumes and cannot check for itself — a declared key, jurisdiction, authority and URL; `Entity` objects with unique, deterministic ids; dates as `PartialDate`; a round trip through `#to_h`; the publisher's own text kept in `remarks`. It is the floor and not the ceiling, so every adapter still writes its own spec on top.

## How it works

### Reading OFAC's free text

The US SDN list publishes no date of birth, place of birth, nationality or passport column. All of it — 88,827 semicolon-delimited segments, measured against the September 2026 list — is prose in one `Remarks` field, written for a person reading a page:

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

### The EU consolidated list

`Sources::EuFsf` reads the Financial Sanctions Files export the European Commission publishes for the EU Consolidated Financial Sanctions List — 6,234 records in one 25.7 MB document, the largest list this gem reads by an order of magnitude and the first one that actually exercises the streaming XML interface. It parses in a single pass; nothing ever holds two records at once.

**The token in the URL is not a credential.** The public endpoint answers 403 without a `token` parameter and 500 with a wrong one, but `dG9rZW4tMjAxNw` is base64 for `token-2017`, it has been the value on the Commission's own public download page since that year, and it is the same string for every caller. It is declared inline the way any other part of a URL is. If it ever rotates, no release of this gem is needed:

```ruby
ActiveSanction::Sources::EuFsf.token = "..."                 # or
ActiveSanction::Sources::EuFsf.url :main, "https://..."
```

**Conditional GET does not work here.** The endpoint serves `Last-Modified` but answers `If-Modified-Since` with 200 and the whole file, sends no `ETag`, and sets `Cache-Control: no-store`. So this is the one list that downloads 25.7 MB on every sync where the other five usually download nothing. The request is still made conditionally — it costs nothing, and the day the Commission honours it, it works — and the parsed content still hashes to the same snapshot checksum, so a re-download of an unchanged list is reported unchanged and diffs to nothing.

Three things about the data are worth knowing before a screening policy leans on it.

**No name is marked as the official one, so this adapter picks one.** All 31,053 `<nameAlias>` elements carry `strong="true"` and none is flagged primary, and every candidate signal in the file is wrong somewhere: document order files Qusay Hussein's French transliteration ahead of his English name, `nameLanguage` files a Cyrillic spelling of Anatoliy Sidorov's name under `EN`, and ordering by `logicalId` picks a non-Latin name for 3,203 of the 5,502 multi-name records. The rule is **the first name the Commission published that the Commission did not itself annotate as an alias** — which passes over the 24 records that lead with a name their own remark calls a low-quality alias or a former name. "Primary" therefore means less here than it does on the OFAC lists, and it costs nothing in score: an entity's score is the best of its names, and the kind reaches only the reason line.

**Alias quality and alias kind are prose in a `<remark>`, and are read as such.** There is no grade column. 499 names carry a grading the Commission wrote out — "low quality alias", "Good quality a.k.a.", "formerly known as", "Maiden name: Al Akhras" — and those become `quality` and `kind` on the `Name`. The phrase has to *begin* an annotation rather than merely appear in the remark, because it appears in prose about other entities: Zadna International's own remark says the company is "99 % owned by the Special Fund ..., formerly known as the Charity Organisation for the Support of the Armed Forces", and a loose match files Zadna's published English name as a former name on the strength of a sentence about its owner.

**Four birth dates are not in the Gregorian calendar.**

```ruby
# <birthdate calendarType="ISLAMIC" year="1343" city="Farsan" .../>
entity.dates_of_birth   # => []
entity.remarks          # => "... Date of birth as published: 1343 (islamic calendar); Place of birth: Farsan, ..."
```

`year`, `monthOfYear` and `dayOfMonth` hold a Hijri date on those records. One of the four also carries a converted `birthdate` attribute and is read from that; the other three produce **no date of birth**, and the published date goes to `remarks`. Reading `1343` as published would not merely fail to match a real date of birth — it would *conflict* with one, and the scorer penalizes a conflicting date, so a true hit would be pushed below the threshold by the very field that should have confirmed it.

Two smaller judgment calls, both visible in the parsed record:

```ruby
entity.nationalities   # => ["IQ"]      citizenship as ISO 3166 alpha-2, not "IRAQ"
entity.type            # => :organization    for a shipping company holding an IMO number
```

`countryIso2Code="00"` is the Commission's sentinel for "not stated" — it is on 1,743 of the birth dates and 1,352 of the documents — and is dropped rather than filed as a country called `00`. And `subjectType` publishes only `person` and `enterprise`: the 41 records carrying an `imo` document are shipping *companies* holding IMO company numbers, not ships, so none of them is retyped as a vessel on the strength of the document kind.

### The UK Sanctions List

`Sources::UkSanctionsList` reads the UK Sanctions List the Foreign, Commonwealth and Development Office publishes under the Sanctions and Anti-Money Laundering Act 2018 — 6,334 designations in one 21.8 MB XML document, against a published XSD.

**It is not the OFSI Consolidated List, and the difference matters more than a rename.** The UK ran two lists until 28 January 2026: the UKSL, which carried every designation, and OFSI's Consolidated List of Asset Freeze Targets, which carried the financial ones. On that date the second was retired. The FCDO's own [transition guidance](https://www.gov.uk/guidance/moving-to-a-single-list-for-uk-sanctions-designations-28-january-2026) says the Consolidated List "is no longer being updated", and its gov.uk publication page is marked `[Withdrawn]`.

The file did not go away. `ConList.csv` still answers `200 text/csv` with 16.6 MB of real designations, so an integration built against it does not break — it quietly stops being current, which is the failure mode this library is least able to survive and least able to detect. Nothing in a sync report distinguishes a fresh list from a frozen one that is still being served.

`OFSI Group ID` is retired with it: designations made since 28 January 2026 do not get one. The historic Group ID is still carried on every earlier designation and stays valid for a licence application or a breach report, so it is kept in `remarks`, and `source_ref` is built from the `Unique ID` that every record has.

```ruby
entity.source_ref   # => "AFG0001"
entity.remarks      # => "... [source fields] OFSI group id: 12703; UN reference: TAe.010; ..."
```

**The XML rather than the CSV, because the CSV is a cartesian product.** The FCDO publishes seven formats, two of them machine-readable at this size. The CSV was added in January to match the shape OFSI's readers were built for, and it is 49.9 MB and 58,424 rows for the same 6,334 designations, because it emits one row per *combination* of every repeating group. One record, `INU0075`, occupies 3,780 rows — 10 names × 7 addresses × 3 phone numbers × 2 websites × 9 subsidiaries. Reading it means grouping the rows and then de-duplicating each dimension back out of the product, which is reconstruction rather than parsing. The XML states the same structure directly, in 44% of the bytes, and carries a field the CSV has no column for.

**Conditional GET works here**, unlike the EU's endpoint. The FCDO serves both an `ETag` and a `Last-Modified` and honours both, so a sync against an unchanged list answers 304 and downloads nothing:

```
run 1: 6334 entities in 14.4s
run 2: unchanged (304) in 0.1s
```

The URLs have been static since January — the FCDO made them so precisely to stop a screening system re-discovering the link on every refresh — which is why this adapter declares one and does not scrape a publication page for it.

**Every judgment this adapter makes, the FCDO published a field for.** That is unusual, and it is what makes a clean UK result worth more than a clean EU one.

```ruby
entity.primary_name.value   # => "MUHAMMAD JAMAL ABD-AL RAHIM AHMAD AL-KASHIF"
entity.names.map(&:quality) # => [nil, :good, :low, :low, :low, ...]
entity.programs             # => ["The Russia (Sanctions) (EU Exit) Regulations 2019"]
```

Every one of the 6,334 records carries a `NameType` of `Primary Name` — six carry two, none carries none — so which name to call primary is the publisher's decision here rather than this adapter's, which is exactly the judgment the EU adapter is stuck making. Alias grading is a field (`AliasStrength`, on 2,073 names) rather than prose. The regime is the statutory instrument itself, and maps to `programs`; the measures actually imposed are a separate field and go to `remarks`.

Two mappings are worth stating because they are not the only defensible ones. A name is six numbered parts and is joined in numeric order — `Name1` to `Name6`, given names ascending with the family name last — which is *not* the order the CSV lists its columns in; the CSV files `Name 6` first because it is presenting a surname to a reader, and following that would produce `JAN ABDUL KABIR MUHAMMAD`. And `Primary Name Variation`, which is 5,513 of the 15,677 published names, is an alternative *spelling* of the designated name rather than a second designation, so it is filed as an alias — which is what leaves `Entity#primary_name` answering with the name the FCDO actually designated.

### The Australian Consolidated List

`Sources::AustraliaDfat` reads the Consolidated List the Australian Sanctions Office publishes — every person, entity and vessel designated or declared by the Foreign Minister under the Autonomous Sanctions Regulations 2011, plus every UN Security Council listing Australia gives effect to. 3,906 records, in one Excel workbook.

**It is published as a spreadsheet, and as nothing else.** DFAT's Consolidated List page offers exactly one download — `Australian_Sanctions_Consolidated_List.xlsx`, 1.3 MB, one sheet, 11,163 rows, 19 columns. There is no CSV, no XML and no JSON. So reading a spreadsheet is not a convenience here; it is the price of screening against Australian sanctions at all.

**No spreadsheet gem was added for it.** `Parsers::Spreadsheet` reads the workbook with `zlib` and the XML toolkit the other five adapters already use, because an `.xlsx` is a ZIP of XML parts and the only thing actually missing was a ZIP header unpacker. It reads one sheet of cell values as strings, resolves the shared string table, and renders a date cell as ISO 8601 at the precision its own number format displays. It does not evaluate formulas — a formula cell reads as the value cached in it — and it ignores everything a spreadsheet can hold that a sanctions list does not put data in. The older binary `.xls` is a different format and is not read.

```ruby
row[:date_of_birth]   # => "1962-08-24"   the cell holds 22882, formatted m/d/yyyy
row[:date_of_birth]   # => "1958"         the cell holds 1958, formatted General
```

That distinction is the whole reason the styles are read. `18798` is the 19th of June 1951 if the cell is formatted as a date and the year 18798 if it is not, and only `xl/styles.xml` says which — 4,183 of these birth dates are serials and 2,709 are years, in the same column.

**The URL this gem was scoped against is gone, and what replaced it still answers 200.** `regulation8_consolidated.xlsx` now redirects to `regulation8_consolidated_2.xls` — a real file, served successfully, in the old binary format, last modified in March 2022. An adapter pointed at it would download a list four years stale on every sync and never once look unhealthy. This adapter declares the URL DFAT's own page links today.

**DFAT's edge rejects this gem's User-Agent.** Verified against the live endpoint: `active_sanction/x.y.z (+https://…)` gets no response at all — not a 403, a dropped connection — while `curl/8.7.1`, `Wget/1.21` and `python-requests/2.31.0` are served. The filter is on the leading product token, and an unrecognised one is dropped, so identifying ourselves honestly is what gets us blocked. This source sends the configured agent inside the form written for exactly this case:

```
Mozilla/5.0 (compatible; active_sanction/1.0.0 (+https://github.com/Babystep-Technologies/active_sanction))
```

which is how a well-behaved crawler has identified itself since Googlebot. The agent, its version and whatever contact URL you configured are all still in the string; DFAT can still see who we are and block us on purpose. It is the same identification in a shape the edge parses. It is the only place any source departs from `Sources::Base`, and `AustraliaDfat#fetch_file` is the whole of it.

**Conditional GET works.** The endpoint serves both an `ETag` and a `Last-Modified` and honours both, so a sync against an unchanged list answers 304 and downloads nothing. The workbook also stamps its own save time inside `docProps/core.xml`, which is what `source_version` reports — `2026-09-04T05:37:12Z`, the same date DFAT prints on its download page — rather than an HTTP header.

### Storage

Storage is five methods (`Storage::Base`), and the rule they exist to enforce is that **nothing on the query path may name a concrete store**: a source nobody has synced reads back as `nil`, never as an empty snapshot, and nothing partial is ever returned — a truncated file, an edited record or a dropped row raises `Storage::CorruptSnapshot` rather than screening against a list that is quietly missing people. [Choose a storage backend](https://babystep.tech/active_sanction/how-to/choosing-a-store/) has `FileSystem`, `ActiveRecord` and `Memory` in full, plus the conformance group — `"a storage adapter"` — every one of them and every one a host writes is held to.

A store is where *this* machine keeps its lists. Moving one to another machine — an air-gapped host, or a mirror for the afternoon a publisher is down — is a signed bundle: one file, a signature an auditor can check, and the same bundle for the same snapshot every time. [`docs/bundle_format.md`](docs/bundle_format.md) is the byte-level format, specified in enough detail to be implemented outside Ruby; [Publish and verify a signed bundle](https://babystep.tech/active_sanction/how-to/publishing-a-signed-bundle/) is the two commands and the decisions around them.

### Syncing every list, and what happens when one is down

`ActiveSanction.sync!` fetches, parses and stores every configured source, isolating each behind its own rescue so a UN outage does not stop OFAC from syncing. **A failed source keeps its previous snapshot** — screening against yesterday's list with a visible age on it is safe; screening against an empty one is not, which is why the thing to alert on is the age of what is being screened against, not just whether the last run reported a failure. [Sync on a schedule, and handle a source that is down](https://babystep.tech/active_sanction/how-to/syncing-on-a-schedule/) has the rake task, the exit code, and what to alert on.

### Noticing what changed between two syncs, and rescreening a book against it

Screening is not a one-time event. A customer cleared last month may be listed today, and re-running a whole book against a whole list every night is why most services that do it the naive way do it weekly instead. `ActiveSanction.diff` computes what changed between two snapshots of one source; `ActiveSanction.rescreen` applies that diff to a book of business and reports who it affects, at a cost proportional to what changed rather than to the size of the book — **1.2 s for 10,000 subjects against a typical daily diff, versus 54 s to screen the same book against the whole list.**

A few things are easy to get wrong here, so they are worth stating rather than leaving to be discovered: **delistings matter as much as listings** — `diff.removed` is what lets a customer back through the door, and a service that only re-screens against new records never notices one; **an amendment is not a delisting plus a listing** — the two snapshots are joined by entity id, so a corrected passport number reports as one `Diff::Change` rather than a removal and an addition that would put a false delisting in front of an analyst; **a first sync is a baseline, not nineteen thousand new listings** — a diff with no `from` reports `baseline?` and nothing to re-screen, because the right response to a first sync is a deliberate full screening run; and **order is never a change**, including a reordered alias, so a publisher re-emitting the same file in a different row order diffs to nothing.

[Rescreen a book of business against a diff](https://babystep.tech/active_sanction/how-to/rescreening-a-book/) has the full mechanics — `Subject`, what `:newly_listed` / `:delisted` / `:details_changed` mean, streaming a large book past a small diff, and what this deliberately does not remember (see [What it does not do](#what-it-does-not-do)).

### Noticing when a publisher has changed its format

**The dangerous change is the one where the file still parses cleanly and means something different** — 19,321 entities carrying zero passports looks exactly as healthy as 19,321 carrying 23,429 if the only thing anyone counts is records, and a sync would not notice that for months. `ActiveSanction.doctor` measures fill rates and free-text coverage against the last stored snapshot and reports a severity per source. [Detect when a publisher changes its format](https://babystep.tech/active_sanction/how-to/detecting-format-drift/) has the full mechanics, how to read `warn` versus `error`, and the upstream canary that runs the same checks on a schedule against the real endpoints.

### Normalizing, scoring and the identifiers that make it a screening tool

`ActiveSanction::Normalizer` folds a name before anything is compared — Unicode NFKD, casefold, punctuation to spaces — and, told what kind of entity a name belongs to, drops the parts every entity of its kind shares: legal forms and function words from an organization, honorifics from an individual, never a structural particle like `bin` or `al`. There is one code path for both the index and the query, which is what keeps a stoplist change from silently stopping a match on one side only. Non-Latin script is not transliterated: `Путин` matches a Cyrillic query and nothing else, survivable only because these lists publish a romanized alias alongside the original.

`ActiveSanction::Scorer` blends four string algorithms and a phonetic pass into one name similarity — a weighted mean rather than the weighted maximum the well-known Python ratio uses, deliberately, because a maximum would put `Mohammed` against `MOHAMMED AL-ZAWAHIRI` in the nineties on a corpus where a quarter of the individuals share a handful of given names. What actually separates a coincidence from a corroborated match is the identifiers a compliance officer already has: an exact passport match is worth **+40**, a full date of birth **+15**, a nationality agreement **+6** — and every adjustment fires only when *both* sides carry the field, because treating a missing field as disagreement would under-score exactly the jurisdictions that publish least. One name transliterated two different ways — `QADHAFI, Muammar` against `Muammar Gaddafi` — is the residual case this does not solve; the mitigation is the identifier fields, not a bigger phonetic weight.

[How matching works](https://babystep.tech/active_sanction/explanation/how-matching-works/) is the full argument, end to end: the five-stage pipeline, the adjustments table, why 75 is the default threshold, and the reproducibility fields a `MatchResult` carries.

### Screening a name

`ActiveSanction.screen` is the whole pipeline behind one call: fold the query once, retrieve the names worth comparing, score each with reasons, then filter, rank, cap and stamp.

```ruby
results = ActiveSanction.screen(
  name:          "Bosco Ntaganda",
  type:          :individual,
  date_of_birth: "1973",
  countries:     %w[CD],
  sources:       %i[ofac_sdn un_consolidated],   # default: every synced list
  threshold:     75,
  limit:         10
)

hit = results.first
hit.score            # => 100.0
hit.entity           # => Entity
hit.matched_name     # => the specific Name that produced the score
hit.source           # => :un_consolidated
hit.explanation      # => [Reason, ...], summing to the score
hit.snapshot_id      # => "sha256:9f86d081884c7d65..."
hit.matcher_version  # => "1"
hit.screened_at      # => 2026-09-06 11:04:02 UTC
```

An empty array is the ordinary answer — most customers are not on a sanctions list — and everything that could make it a lie rather than a fact raises instead. A store nobody has synced raises `Matcher::NotSynced`; a query naming a list the matcher does not hold raises `Storage::MissingSnapshot` rather than quietly covering two of the three lists it was asked for. Screening against a list that is not there returns a clean report, and a clean report is the most expensive thing this library can get wrong.

`date_of_birth:` and `dates_of_birth:`, `country:`, `countries:` and `nationalities:`, `identifier:` and `identifiers:` all mean the same thing. A caller with one date writes the singular and a caller with three writes the plural, and neither should have to remember which this library prefers.

**One result per entity, in the alias that won.** An entity is retrieved once for every one of its names the query looks like, and its score is the best of those names, so each is scored once and reported once. Results are ordered by score descending and ties by entity id — ties are not a corner case on these lists, and which of two identically scored records is listed first has to be the same answer in a year's time.

#### Every result is a reproducibility stamp

`MatchResult` is the most permanent object in the gem — it is what ends up in a customer's audit record, read by people who have neither this process nor this version of the gem — so it serializes to a documented shape and `MatchResult.from_h` rebuilds it losslessly. [Reproducibility](https://babystep.tech/active_sanction/explanation/how-matching-works/#reproducibility) has the four fields that make a past decision re-derivable. `backend` is a fifth, not there: a hosted backend answers the same call against data somebody else keeps fresh, and an audit record has to say which one answered.

#### Holding a client, and screening from many threads

`ActiveSanction.screen` is sugar over a default `Client` built from the configuration on first use, and `ActiveSanction.configure` is what populates it. A server that needs more than one configuration alive at once holds its own clients instead, which is a thing a process-global cannot express at all:

```ruby
CLIENT = ActiveSanction::Client.new(
  storage:    ActiveSanction::Storage::ActiveRecord.new,
  sources:    %i[ofac_sdn un_consolidated],
  user_agent: "acme-bank/1.0 (compliance@acme.example)"
)

CLIENT.sync!
CLIENT.screen(name: "Bosco Ntaganda")
CLIENT.screen_all(customers.map { |c| { name: c.name, dob: c.born_on } })   # one array of results per query
```

Every setting `ActiveSanction.configure` takes is a keyword argument here, held to the same rule and failing with the same message. A client holds them frozen — the store, the source list, the weights, the candidate cap, the thresholds a query defaults to, the User-Agent every request carries — plus one memo, the matcher it builds from its store on first use. A client's settings cannot be edited after it is built; deriving a neighbour is `#with`:

```ruby
AUDIT = CLIENT.with(storage: januarys_snapshots)   # a pinned list version, beside the live one
```

Two clients share nothing: each indexes its own store, screens only the lists it names, and identifies itself to publishers under its own User-Agent. That is what makes a pinned snapshot for an audit re-run, a source set per tenant, and one warm index shared across every request thread all true at the same time.

##### What is safe to do concurrently, and what is not

| | |
|---|---|
| Screening a built client from many threads | **Safe**, and the reason it exists. The matcher is frozen at build, and `screen` allocates locals and touches nothing shared |
| Building the matcher | **Safe.** It happens once, under the client's lock, so eight threads racing at boot produce one index rather than eight |
| `sync!` while other threads screen | **Safe.** A store publishes a list whole, so a thread mid-screen finishes against the version it started with. The next call moves onto the new list — `sync!` calls `reload!` itself when anything changed |
| `sync!(concurrency: 3)` | **Safe.** It bounds how many *publishers* one run fetches from at once; each worker runs its own sources under the client's own settings |
| Two `sync!` runs over one store | **Not supported**, from this process or another. The last writer wins per source, and the losers' downloads are discarded. Put a lock around the run, not a bigger `concurrency:` |
| `ActiveSanction.configure` | At boot. It replaces the default client, which drops a matcher built over the old store — correct, and not something to do while requests are in flight |

Nothing here makes a store thread-safe that is not. Both shipped adapters are: `Memory` guards its hash, and `FileSystem` publishes a list by renaming one file over another.

A matcher holds an index, the checksum of every list in it, the weights it scores with and the candidate cap it retrieves with. All of it is fixed at construction and the object is frozen. **Nothing on the query path reads configuration**, which is a stronger statement than thread safety and the one that matters for an audit: a threshold, a weight or a candidate cap changed halfway through a batch cannot produce a run that is half one set of numbers and half another, because the numbers were read once — into the `Query`, and into the matcher.

A sync does not update a matcher. It builds a new one and the reference is swapped, so requests in flight finish against one consistent list version:

```ruby
ActiveSanction.reload!    # after a sync run by something else, for the default client
CLIENT.reload!            # the same, for one the application holds
```

Batch screening stamps the whole call with one `screened_at`, because a rescreening of a customer book against a new list version is one event in an audit trail rather than ten thousand a microsecond apart. Results come back index-aligned rather than keyed by name — a book of customers contains the same name twice often enough, and a Hash would silently screen one of them and report both.

## What is public, and what may change

**The public surface is enumerated, not inferred.** Nearly 500 constants are
reachable from `ActiveSanction`; 137 of them are promised. Everything else is
marked `@api private`, is hidden from the rendered documentation, and may be
renamed or removed in a patch release. [`docs/api_stability.md`](docs/api_stability.md)
is the list and the policy, and [`spec/api_surface_spec.rb`](spec/api_surface_spec.rb)
fails the build when the code and that list stop agreeing in either direction.

**The first release is 1.0.0, and there was no 0.x.** A leading zero says a minor
version may remove what the last one promised, and that is not what an enumerated,
test-enforced surface is doing. So the deprecation path is in force from the first
release: one full minor release of overlap, a warning through Ruby's own
`Warning[:deprecated]` switch, and a changelog entry in both the release that
deprecates and the release that removes. A breaking change waits for 2.0.0.

**`Sources::Base`, `Storage::Base` and `ValidatorStore` carry the strongest
guarantee**, because breaking one of them forks every adapter written outside this
repository at once — and those authors are not reading these release notes. The two
conformance groups are the executable statement of what each requires.

## Development and contributing

Bug reports and pull requests are welcome at https://github.com/Babystep-Technologies/active_sanction. After checking out the repo, `bin/setup` installs dependencies and `bin/console` gives a prompt with the library loaded; `bundle exec rake` runs RSpec, RuboCop and `srb tc`, all three hermetic and all three required.

[`CONTRIBUTING.md`](CONTRIBUTING.md) has the whole of what a contributor needs: the two most useful contributions (a new list, or a name this version gets wrong), the release process, the full benchmark suite, the upstream canary, generating the API documentation, what static typing does and does not check, and the one flag that signs a commit.

## Security

**A false negative here is a security bug, not merely an inaccuracy** — somebody may be relying on an empty result to clear a payment. So is anything that makes the gem accept a modified list as authentic, or that lets a screened name leave the host process.

Report one privately, never in a public issue: [**Report a vulnerability**](https://github.com/Babystep-Technologies/active_sanction/security/advisories/new) on the Security tab. [`SECURITY.md`](SECURITY.md) says what is in scope, what is match quality and belongs in a public issue instead, and what response to expect.

## License

Available as open source under the terms of the [MIT License](LICENSE.txt).

**The licence covers the software and not the name.** ActiveSanction, the project name and any associated branding are not granted by it. A fork or a derivative may say that it is built on, compatible with, or derived from ActiveSanction; it may not use the name in a way that suggests it is this project or is endorsed by it. This is the ordinary position under MIT, which grants no trademark rights either way, and it is written down only so nobody has to guess. [The bundle format](docs/bundle_format.md) is open and unencumbered under the same rule: anyone can produce one.

## Code of Conduct

Everyone interacting in the ActiveSanction project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](CODE_OF_CONDUCT.md).
