# ActiveSanction

[![CI](https://github.com/Babystep-Technologies/active_sanction/actions/workflows/ci.yml/badge.svg)](https://github.com/Babystep-Technologies/active_sanction/actions/workflows/ci.yml)

Screen a name against government sanctions lists, in Ruby, in your own process.

ActiveSanction fetches the lists a jurisdiction publishes, parses each of them into one record model, stores them where you tell it to, and scores a name against them with an account of every point it awarded. The lists live on your disk or in your database, screening runs in your process, and no name you screen leaves it.

```ruby
ActiveSanction.sync!

ActiveSanction.screen(name: "Vladimir Putin", type: :individual, date_of_birth: "1952-10-07")
# => [#<MatchResult score=97.3 source=:ofac_sdn matched_name="PUTIN, Vladimir Vladimirovich">]
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
- **Screens.** Fold the name, retrieve candidates from an inverted index, score each with four string algorithms and a phonetic pass, adjust on dates of birth, nationalities and document numbers, and report the reasons — which sum to the score exactly.
- **Diffs.** What changed between two syncs, so a book of business is re-screened against the handful of records that moved rather than against the whole list.
- **Diagnoses.** Whether a list still parses the way we think it does — field fill rates, the free-text vocabulary, the shape of a positional column — measured against the version stored at the last sync, because the dangerous format change is the one where the file still parses cleanly and means something different.
- **Stamps.** Every result carries the snapshot checksum, the matcher version, the weights and the query, so a screening decision made today can be re-derived in three years by somebody who has neither this process nor this version of the gem.

## What it does not do

- **It does not decide anything.** A score is evidence for a human. The threshold at which a score becomes an alert, and what happens to that alert, are policy your compliance function owns.
- **It is not a case management system.** No alert queue, no dispositions, no audit store. It produces the record; keeping it is your application's job.
- **It screens names against lists, and nothing more.** No politically-exposed-person data, no adverse media, no beneficial ownership, no OFAC 50 Percent Rule resolution — a subsidiary that is sanctioned only by virtue of its owners is not on any of these files and will not be found here.
- **Seven lists ship: two US, one UN, one Canada, one EU, one UK, one Australia.** If your obligations cover a jurisdiction outside that set, this gem does not cover them.
- **Non-Latin script is not transliterated.** `Путин` does not fold to `putin`; a Cyrillic name matches a Cyrillic query and nothing else. What makes it survivable is that these publishers ship a romanized name alongside the original — see [Normalizing a name for matching](#normalizing-a-name-for-matching) for what that does and does not leave open.
- **It does not monitor your deployment.** It syncs when you tell it to, and it diagnoses when you tell it to. `ActiveSanction.doctor` will notice that a publisher changed its format, but only in a job you schedule — nothing in your process runs overnight on its own, and nothing wakes anybody when it finds something. What does run overnight is [the upstream canary](#the-upstream-canary), on this repository rather than on yours: it watches the seven published lists on weekdays and files an issue here when one of them changes, which is how the adapters get fixed — but it knows nothing about whether *your* sync ran ([#69](https://github.com/Babystep-Technologies/active_sanction/issues/69)).
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
  name:          "Vladimir Putin",
  type:          :individual,
  date_of_birth: "1952-10-07",
  countries:     %w[RU]
)

hit = results.first
hit.score                       # => 97.3
hit.source                      # => :ofac_sdn
hit.matched_name.value          # => "PUTIN, Vladimir Vladimirovich"
hit.explanation.map(&:to_s)
# => ["+76.3 name: matched primary name \"PUTIN, Vladimir Vladimirovich\"",
#     "+15.0 dob: date of birth 1952-10-07 matches",
#     "+6.0 nationality: RU matches"]

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

| Key | Jurisdiction | Authority | Records | Format | How often it moves |
|---|---|---|---|---|---|
| `ofac_sdn` | US | Treasury / OFAC | ~19,300 | three CSVs, joined | Irregular, often several times a month |
| `ofac_consolidated` | US | Treasury / OFAC | ~481 | three CSVs, joined | Irregular, much less often than the SDN list |
| `un_consolidated` | UN | UN Security Council | ~1,010 | one XML file | As the Council amends a regime |
| `canada_sema` | CA | Global Affairs Canada | ~5,690 | one XML file | As the regulations are amended |
| `eu_fsf` | EU | European Commission | ~6,234 | one XML file, 25.7 MB | As the Council adopts or amends a regulation |
| `uk_sanctions_list` | UK | FCDO | ~6,334 | one XML file, 21.8 MB | Whenever a designation is made, amended or revoked |
| `australia_dfat` | AU | DFAT / Australian Sanctions Office | ~3,906 | one XLSX workbook, 1.3 MB | As the Foreign Minister designates, and as the UN amends a regime |

Record counts are as of the fixtures this gem was written against; the live files move. No publisher commits to a schedule, and none of them announce a change out of band, which is why every fetch here is conditional: asking daily costs one request per file on the days nothing happened. Sync on your own risk appetite rather than on a publisher's calendar.

### Known data limitations, per source

These are the facts a screening policy has to be built on. They are properties of what the government publishes, not of this parser, and none of them can be fixed downstream.

**Both OFAC lists — every secondary identifier is free text.** The SDN CSVs have no column for date of birth, place of birth, nationality or passport number. All of it — 88,827 semicolon-delimited segments across 19,015 records — is prose in one `Remarks` field, written for a person reading a page. `Sources::Ofac::RemarksParser` reads it heuristically and currently recognizes **97.3%** of those segments. Extraction is additive: a segment nobody has taught it yet costs structure and never content, because `Entity#remarks` keeps the publisher's whole string either way. `source.remarks_coverage` reports the number for the file you actually fetched, and it is worth watching — a drop in it is a publisher changing how it writes.

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

**All seven — non-Latin script is not transliterated.** Cyrillic, Arabic, Han, Kana and Hangul are casefolded and stripped of marks in their own script, and never romanized. These lists publish a non-Latin name as an *additional* variant rather than instead of a Latin one, which is what makes it survivable; the residue is a record carrying one romanization queried with another. See [Normalizing a name for matching](#normalizing-a-name-for-matching), and [One name transliterated two ways is the case this does not solve](#one-name-transliterated-two-ways-is-the-case-this-does-not-solve).

## Reading a score

A score is a number from 0 to 100, and it is **the sum of the reasons on the result** — rounded once, with no arithmetic anywhere in this library that can move one without the other. `hit.explanation` is the thing to read; the number is a summary of it.

The default threshold is **75**, and it is measured rather than chosen. Against 87 labeled queries — real published records queried the way a customer record spells them, plus the common names and near misses that must not alert — F1 peaks at exactly the number this gem ships:

```
threshold  precision  recall      F1   found  missed  false alerts  noise/query
       60      0.831   0.970   0.895      64       2            13          6.7
       75      0.899   0.939   0.919      62       4             7          1.7   <- best F1
       85      0.963   0.788   0.867      52      14             2          1.2
```

**What each choice costs.** Raising it to 85 removes five false alerts and stops returning ten listed records. Lowering it to 60 finds two more and costs six false alerts and roughly four times the noise per query. F1 weighs those two errors equally and a sanctions screen does not — a false positive costs an analyst minutes, a false negative is a sanctioned counterparty onboarded — so **75 is a floor to tune down from, not a ceiling**. `threshold:` is per query, and what lowering it costs is the noise column above rather than something to be found out in production.

**Do not band by score alone.** A 97 that is all name similarity and a 82 with a passport number matching are different findings, and the score does not distinguish them. Read `hit.explanation`:

```ruby
hit.explanation.any? { |r| r.factor == :identifier }   # a document number matched — near-decisive
hit.explanation.any? { |r| r.factor == :dob }          # a date of birth agreed
```

**The largest improvement available to you is supplying more of the query.** An exact document number is worth +40, a full date of birth +15, a nationality +6. A subject carrying the right passport number needs forty points less of a name than one carrying nothing, so a screening call that passes only a name is leaving most of this library's discrimination on the table — and it is discrimination against the false positives, not against the hits.

**Absent is never conflict.** Every adjustment fires only when *both* sides carry the field; a missing date of birth produces no reason at all rather than a small penalty. Treating absence as disagreement would systematically under-score exactly the jurisdictions that publish least — Canada above all — and hide real hits below a threshold.

Recall is not uniform across the lists, and an averaged number would hide it:

```
source                 queries  recall   found
canada_sema                 25   0.880   22 of 25
un_consolidated             20   1.000   20 of 20
ofac_sdn                    15   0.933   14 of 15
```

[`benchmark/results/accuracy.md`](benchmark/results/accuracy.md) is regenerated by `rake benchmark:accuracy` and committed. It names every miss and every false alert at the default threshold, breaks recall down by what the query did to the name — transliteration, inverted order, typo, dropped token, legal form — and shows what each secondary identifier bought. It is the honest answer to "how good is this?", and it is in the repository rather than in a marketing page.

The whole argument, including why the blend is a weighted mean rather than a maximum and where the weights come from, is in [Scoring a candidate, with reasons](#scoring-a-candidate-with-reasons).

## Where the lists live

Storage is an interface with five methods, and **nothing on the query path names a concrete store**. Pick one at boot:

| Adapter | Use it when | Costs |
|---|---|---|
| `Storage::FileSystem` *(default)* | You want to provision nothing. Gzipped JSON under `~/.active_sanction`; commits with one atomic rename, so a killed sync leaves the previous list intact | One writer per source at a time, within one filesystem |
| `Storage::ActiveRecord` | You already have a database, want an indexed prefilter before scoring, and want readers on other machines | A migration, and ActiveRecord — which is *not* a dependency of this gem and loads only if the host loaded it first |
| `Storage::Memory` | A process that syncs and screens without owning a directory — a job, a CI run, a container with no volume | A full download on every boot |
| Your own | Anything else — S3, a shared cache, an air-gapped drop | Five methods, held to the shared `"a storage adapter"` example group |

```ruby
ActiveSanction.configure { |c| c.storage_dir = "/srv/lists" }             # the default, elsewhere
ActiveSanction.configure { |c| c.storage = ActiveSanction::Storage::ActiveRecord.new }
```

```console
$ rails generate active_sanction:install    # for the ActiveRecord adapter
$ rails db:migrate
```

Every adapter refuses to return anything partial: a snapshot's checksum is re-derived from the records that came back, so a truncated file, a hand-edited row or a dropped record raises `Storage::CorruptSnapshot` rather than screening a customer against a list that is quietly missing people. A source nobody has synced reads back as `nil` and never as an empty list. The details are in [Storing what a sync produced](#storing-what-a-sync-produced) and the three sections after it.

## Performance

Numbers from `rake benchmark:latency` and `rake benchmark:index` on the machine they were last run on, against a corpus the size of the real lists — 47,051 indexed names over 27,000 entities. Your own are one command away; these are here so you can size a deployment before installing anything.

| | |
|---|---|
| Building the matcher | **3.84 s**, 49 MB resident. Paid once at boot, not per query |
| Screening, p50 | **14.8 ms** at the default threshold of 75 |
| Screening, p95 / p99 | 47.9 ms / 85.7 ms |
| Screening with no threshold | 51.4 ms p50 — a threshold is roughly two thirds of the cost, and changes no score |
| YJIT | Roughly halves the scoring cost. `RUBYOPT=--yjit` |
| A sync where nothing changed | One conditional request per file, no download and no parse |
| A full OFAC SDN sync | Three files downloaded, joined across 19,321 entities, and 88,827 remarks segments parsed. The expensive half is the parse, which is exactly what a 304 skips |

```
threshold       mean       p50       p95       p99   slowest
        0     54.7 ms   51.4 ms  100.6 ms  128.6 ms  140.3 ms
       75     18.2 ms   14.8 ms   47.9 ms   85.7 ms   91.5 ms
       85     11.7 ms   10.2 ms   22.7 ms   39.1 ms   40.2 ms
```

A matcher is immutable once built, so many threads screen through one without a lock, and a sync builds a new one rather than mutating the old — requests in flight finish against one consistent list version. See [Holding a matcher, and screening from many threads](#holding-a-matcher-and-screening-from-many-threads).

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
| `normalizer_dictionary` | The four shipped token lists | See [Dropping the tokens that identify nothing](#dropping-the-tokens-that-identify-nothing) |
| `scorer_weights` | `Scorer::Weights.default` | What each signal is worth. Changing one changes what every past decision would score today, which is why `weights` travels on every `MatchResult` |
| `logger` | `nil` | Anything Logger-shaped |

A bad value raises `ConfigurationError` at the point it is set, rather than producing a puzzling failure during a sync three hours later.

## Handling errors

`rescue ActiveSanction::Error` catches everything this library raises from a public method. Under it sit the answers to the only three questions a caller embedding this in a request path actually has — *retry this*, *alert somebody*, *this is a bug in my call* — and none of them should be answered by matching on a message string.

```
ActiveSanction::Error              the marker; rescue this
├── ConfigurationError             this installation is set up wrong; never retry
├── SourceError                    something went wrong with one list
│   ├── FetchError                 the bytes could not be obtained
│   ├── ParseError                 the bytes could not be read
│   └── IntegrityError             the bytes are not what they claim to be
├── StorageError                   the store could not answer
├── UnsupportedError               this object cannot do that
├── InvalidArgument                a public method was called wrongly
│   └── QueryError                 ...specifically, with an unusable query
└── MissingKey                     a field or column that does not exist
```

```ruby
begin
  ActiveSanction.screen(name: params[:name], threshold: params[:threshold])
rescue ActiveSanction::QueryError => e
  render json: { error: e.message }, status: :unprocessable_entity   # the caller's fault
rescue ActiveSanction::Error => e
  raise unless e.retryable?

  ResyncLater.enqueue(e.source_id)                                   # the publisher's
end
```

**`retryable?` is a predicate, not a message to parse.** A host application deciding whether to back off is making that decision in the request path, and it should not be making it out of English:

| Raised by | `retryable?` |
|---|---|
| 503, 500, 429, 408 from a publisher | `true` |
| A timeout, a refused connection, a reset | `true` |
| 403, 404, a redirect loop, a TLS failure | `false` |
| A parse error, a corrupt snapshot, a bad query | `false` |
| Anything unclassified | `false` — a failure nobody has looked at is one to look at, not one to hammer |

`ConfigurationError` answers `false` unconditionally: nothing about waiting changes an initializer.

**Every error carries structured attributes.** `source_id` names the list, `status` the HTTP status where a server produced one, and `to_h` renders the lot for a log line or a job record that has to outlive the process. The layer that raises is frequently not the layer that knows which list it was working on — the HTTP client sees a URL — so the source is stamped on as the error leaves the adapter.

```ruby
error.to_h
# => { error: "ActiveSanction::FetchError", message: "https://... returned 503",
#      source_id: :ofac_sdn, status: 503, retryable: true }
```

**A parse error says where.** "This 25 MB XML file is not XML" is not a diagnosable complaint, so `ParseError` carries `line`, `record` and `offset` — whichever of them the parser could produce — and appends the `locator` to its own message, so a log line that kept nothing but the message still says where to look. All three are nil where the parser genuinely cannot say; an error that cannot point at a line does not point at the wrong one.

**Nothing from `net/http`, `csv`, `rexml`, `nokogiri`, `zlib` or `json` reaches you.** A malformed CSV row, a truncated gzip member, an XML document that turned out to be an HTML error page, a TLS certificate that does not verify — each is translated at the boundary it happens on. A host application should not have to know which XML backend is configured in order to rescue a bad download.

**`ActiveSanction::Error` is a module rather than a class**, because two of its members have to be something else as well. A caller who passes `threshold: 300` has made the mistake Ruby has had a class for since 1995, so `InvalidArgument` is an `::ArgumentError` and `MissingKey` is a `::KeyError` — and Ruby has one superclass to give. Both still answer `rescue ActiveSanction::Error`, and both answer `is_a?`. The one consequence is that `ActiveSanction::Error` cannot itself be raised; raise the member that names the failure.

**The hierarchy is public API.** Within a major version an error does not move to a different parent and an attribute is not removed. New subclasses may be added under an existing parent — that is what keeps `rescue ActiveSanction::FetchError` working when a new transport failure earns a name of its own — so a `case` over error classes wants an `else`.

## Adding a source

[`docs/adding_a_source.md`](docs/adding_a_source.md) is the end-to-end walkthrough: reading the publisher's file before writing anything, choosing the format toolkit, mapping its fields onto the canonical model, deriving a stable id for a list that publishes none, trimming a fixture, wiring up the conformance spec, and registering the adapter — from inside this gem or from an application that never forks it. It ends with a complete worked adapter, its fixture and its spec.

A source registered from outside this gem is a first-class source: a bank's internal watchlist is screened, stored, diffed and stamped exactly as OFAC's is.

There is no scaffold generator, deliberately. Roughly eight adapters at maturity do not repay one that has to be kept in step with `Sources::Base`, the conformance spec and the parser toolkits, and that goes stale silently when it is not; the document plus the closest existing adapter to copy does the same job with none of the upkeep.

## How it works

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
Mozilla/5.0 (compatible; active_sanction/0.1.0 (+https://github.com/Babystep-Technologies/active_sanction))
```

which is how a well-behaved crawler has identified itself since Googlebot. The agent, its version and whatever contact URL you configured are all still in the string; DFAT can still see who we are and block us on purpose. It is the same identification in a shape the edge parses. It is the only place any source departs from `Sources::Base`, and `AustraliaDfat#fetch_file` is the whole of it.

**Conditional GET works.** The endpoint serves both an `ETag` and a `Last-Modified` and honours both, so a sync against an unchanged list answers 304 and downloads nothing. The workbook also stamps its own save time inside `docProps/core.xml`, which is what `source_version` reports — `2026-09-04T05:37:12Z`, the same date DFAT prints on its download page — rather than an HTTP header.

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

The sidecar is exactly `Storage::Meta#to_h`, which is what makes `snapshot_meta` cheap: printing how old seven lists are reads seven small JSON files instead of inflating and deserializing tens of megabytes.

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
report[:un_consolidated].error  # => "ActiveSanction::HttpClient::TimeoutError: GET https://... failed"
exit report.exit_code           # 1 if any source failed, so cron and CI can alert
```

**One source failing must not abort the others.** Government endpoints go down, change format without notice, and occasionally serve half a file. If a UN outage stopped OFAC from syncing, the library would fail exactly when it is most needed — during an incident, which is when lists move. So every source runs inside its own rescue, and the run ends with a summary rather than an exception. `StandardError` and not `Exception`: an `Interrupt` is somebody stopping this run on purpose, and swallowing it to go on downloading three more lists is not isolation, it is a job that will not die. What each source's `exception` carries is an [`ActiveSanction::Error`](#handling-errors), so a run that failed on a slow publisher (`retryable?`) is distinguishable from one that failed on a list that changed format, without reading the message.

**A failed source keeps its previous snapshot.** Nothing clears a stored list on failure — not a 500, not a parse error, not a publisher that started serving HTML where XML used to be. Screening against yesterday's OFAC list produces a report with a known, visible age on it; screening against an empty list produces a clean report for every customer, which is the most expensive thing this library can get wrong. That trade is only safe while the age is visible, so every result carries the record count and age of the list that source is *still* being screened against:

```
7 sources in 27.14s: 2 updated, 4 unchanged, 1 failed
  ofac_sdn           updated    19015 records  just fetched   12.41s
  eu_fsf             updated     6234 records  just fetched   13.15s
  ofac_consolidated  unchanged   1203 records  2h old          0.28s
  uk_sanctions_list  unchanged   6334 records  2h old          0.21s
  australia_dfat     unchanged   3906 records  2h old          0.22s
  canada_sema        unchanged    684 records  2h old          0.19s
  un_consolidated    failed       612 records  3d old          1.11s  ActiveSanction::HttpClient::TimeoutError
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

### Noticing when a publisher has changed its format

Sanctions lists change format on three clocks. A whole-format migration is announced years ahead: the host this library fetches from is itself the result of one. A column added or an element renamed happens quietly, in months. A new document label or a new national ID type happens continuously, weekly, as new countries are designated.

Only the first of those fails loudly. The dangerous ones are the changes where **the file still parses cleanly and means something different** — 19,321 entities carrying zero passports looks exactly as healthy as 19,321 carrying 23,429 if the only thing anyone counts is records, and screening a passport number against the first returns a clean result for somebody who is on the list. Nothing in a sync would notice that for months.

```ruby
report = ActiveSanction.doctor                    # every configured source
report = ActiveSanction.doctor(:ofac_sdn)         # one
report = ActiveSanction.doctor(tolerance: 0.05)   # report smaller movements

report.ok?                              # => false
report.findings                         # => [Doctor::Finding, ...]
report[:ofac_sdn].severity              # => :warn
report[:ofac_sdn].profile.fill          # => { dates_of_birth: 0.12, identifiers: 0.34, ... }
exit report.exit_code                   # 1 on any error; exit_code(on: :warn) for a build
```

```
3 sources in 41.07s: 2 with findings, 1 unreadable
ofac_sdn         WARN  3 findings
  warn   remarks coverage 71.4% (was 97.3%): "Passport No. #####" x 1,880 unrecognized
  warn   individuals with a date of birth 12% (was 61%) of 11,704
  info   unknown SDN_Type "syndicate"; treated as an organization (41 rows)
un_consolidated  OK
eu_fsf           ERROR  1 finding
  error  could not be read: ActiveSanction::HttpClient::TimeoutError: execution expired
```

That table is `report.to_s`, and as with a sync report it is a rendering rather than the thing itself: `Doctor::Report#to_h` round-trips through JSON, so a host alerts on a finding without scraping a log.

**The signals mostly existed already.** `Parsers::Warning`, orphaned child rows, an unknown `SDN_Type`, an empty payload, `RemarksParser::Coverage`, the snapshot checksum. Each of them was visible per-adapter and only to somebody who already suspected a problem. This is aggregation, severity and a baseline over what a normal fetch and parse already produce — not a second pipeline running beside the first.

**The baseline is the last stored snapshot, not a committed threshold.** A bound written into an adapter ("expect ~19,321 rows ±2,000") goes stale on its own, and the day somebody widens one to make a build pass is the day it stops being read. The previous snapshot never goes stale, costs nothing to maintain, and catches what a fixed bound cannot: a fill rate that drifted from 61% to 12% is invisible to any threshold wide enough to have survived three years of a list growing. Committed floors survive only as a coarse backstop for the run that has nothing to compare against, declared per adapter and deliberately few:

```ruby
class Ofac < ActiveSanction::Sources::Base
  floor :remarks_coverage, 0.90
end
```

**Fill rates are the check that catches a clean parse of a changed file.** Record counts do not move when a publisher renames an element; the share of records carrying each field does. A date of birth is measured over individuals alone, because an organization never has one and including them would make the rate a function of how many companies a designation round happened to name; everything else is measured over every record, because a list whose organizations lost their registration numbers has failed in exactly the way one whose people lost their passports has.

**A swapped column is invisible to a declared width.** OFAC ships three headerless CSVs, so the adapter declares the column names — which pins the width, so a column *inserted* upstream arrives as a wrong-width row and every row says so. A column *reordered* upstream keeps the width, parses cleanly, and builds 19,321 entities out of shifted fields. So the values are asserted separately from the row: `ent_num` is numeric on essentially every row of OFAC's file, and a version of that file where it holds company names is not one to screen against.

**What separates a `warn` from an `error` is not the size of the number.** It is whether the reading can be explained by the *list* changing rather than by the *file* changing. A third of the records disappearing is a `warn`, because a delisting wave looks exactly like a truncated download and deciding automatically that it was the first is how a compliance tool ends up quietly screening against a list it has thrown half of away. A column that used to hold numbers and now holds company names is an `error`, and so is every record on a list losing a field all of them carried, because nothing a government does to its list produces either.

**The doctor never writes anything.** Not the snapshot, not the payload cache, not the conditional-GET validators — each adapter it builds gets a fetcher over an in-memory validator store and no cache. That costs a full download of every list on every run, and buys two things worth more: a diagnosis is always of bytes the publisher is serving now rather than of a 304, and a doctor run before a sync can never be the reason that sync decides a list it has not seen is unchanged. Nothing is repaired either, because deciding that a 40% drop is a delisting wave rather than a broken parse is a judgment call.

**Some of what a run measures cannot come from storage.** Fill rates and record counts are recomputable from a snapshot written months ago, which is what makes the last sync usable as a baseline for free. Warning classes and free-text coverage exist only while a parse is running. A job that wants those compared week to week keeps its own report and hands it back:

```ruby
yesterday = JSON.parse(File.read("doctor.json"))
report = ActiveSanction.doctor(baseline: ActiveSanction::Doctor::Report.from_h(yesterday))
File.write("doctor.json", JSON.generate(report.to_h))
```

**The real deployment is a nightly job, not a command somebody remembers to type.** A `doctor` invoked by hand only confirms a regression that was already suspected; the whole value here is noticing one nobody suspected, which means something has to run it when nobody is looking and alert when it says something. `exit_code` is what makes cron and CI do the second half.

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

The default was a guess until `rake benchmark:accuracy` measured it. Against 87 labeled queries — real published records queried the way a customer record spells them, plus the common names and near misses that must not alert — F1 peaks at exactly the number this library ships, and [Reading a score](#reading-a-score) is what each choice around it costs.

That the two agree is the whole argument for the number, and it is worth being clear about what it is not: F1 weighs a miss and a false alert equally and a sanctions screen does not. The default sits at the peak rather than above it, and `threshold:` stays per query for the host that has to be more careful still.

The same report breaks recall down by list, which is the number an averaged one would hide — Canada at 0.880 against the UN's 1.000. That is measurably worse and it is not the matching's fault: the list publishes no alias kinds, packs several aliases into one comma-joined string and gives a date of birth for a minority of its records, so there is less to match against. [The committed report](benchmark/results/accuracy.md) names every record this version misses and every one it wrongly alerts on, and `rake benchmark:latency` is the other half — see [Performance](#performance).

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


## Development

After checking out the repo, run `bin/setup` to install dependencies, and `bin/console` for a prompt with the library loaded.

`bundle exec rake install` installs the gem locally. A release is: bump `VERSION` in [`lib/active_sanction/version.rb`](lib/active_sanction/version.rb), move the `Unreleased` section of [`CHANGELOG.md`](CHANGELOG.md) under the new version with its date, then `bundle exec rake release`, which tags, pushes and publishes to [rubygems.org](https://rubygems.org). `MATCHER_VERSION` in the same file is bumped on a different occasion and for a different reason — whenever a change to the normalizer, the index, the similarity algorithms or the scorer could move a score — because an auditor asking "would this screening come out the same today?" needs the answer to that question rather than a release number that also answers several others.

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

### The upstream canary

A scheduled workflow that fetches every list from its real publisher on weekdays, parses it, and compares what it measures against the baselines committed under [`.github/baselines`](.github/baselines) ([#69](https://github.com/Babystep-Technologies/active_sanction/issues/69)). When a government has changed something this gem must adapt to, it opens an issue about it.

    $ bundle exec rake canary                                  # what has moved
    $ CANARY_SOURCES=ofac_sdn bundle exec rake canary          # one list
    $ bundle exec rake canary:refresh                          # accept the numbers it measured

```
7 sources in 72.25s: all as committed
australia_dfat     OK  3,906 records (baseline 3,906)
canada_sema        OK  5,690 records (baseline 5,690)
eu_fsf             OK  6,234 records (baseline 6,234)
ofac_consolidated  OK  481 records (baseline 481)
ofac_sdn           OK  19,365 records (baseline 19,365)
uk_sanctions_list  OK  6,340 records (baseline 6,340)
un_consolidated    OK  1,011 records (baseline 1,011)
```

**It is `ActiveSanction.doctor` pointed at a file instead of a snapshot, and it is for a different reader.** The doctor answers an operator's question — *is my deployment's data healthy?* — in their cron, against their storage. The canary answers the maintainer's — *has a publisher changed something the gem must adapt to?* Same signals, different consumer, different fix: a downstream doctor warning that OFAC's remarks vocabulary has moved can only ever result in an issue filed here, because the label table lives here and nobody else can change it. Every check the canary runs is the doctor's; nothing under `canary/` re-implements one, and nothing under `canary/` ships in the gem.

**It never runs as part of CI and never turns the CI badge red.** A red build should mean our code broke, not that a source went down. Treasury re-spelling a label is not a broken build, and a badge that goes red for things nobody did gets muted within a week. The output is a GitHub issue — the artifact that survives, is assignable, and links to the fix.

**A fetch that failed and a file that parsed into something different are different findings, and nothing is reported until two consecutive runs agree.** Government endpoints 403 a non-browser user agent and block cloud IP ranges, and a canary that cried wolf on one bad afternoon would be muted just as fast as a red badge. Each run keeps its report as a workflow artifact; the next run downloads it, and only a finding both of them made is opened.

**A diff in `.github/baselines` is a change in what a government publishes.** That is why the baseline is a committed file rather than an `actions/cache` entry — a number moving there has a date, an author and a review — and a clean run opens a rolling pull request keeping those numbers current without anybody editing JSON. [`.github/baselines/README.md`](.github/baselines/README.md) documents the format and the per-key tolerances.

### API documentation

    $ bundle exec rake doc          # renders doc/
    $ bundle exec yard stats --list-undoc

Every public module, class, method and attribute in `lib/` carries a comment, and `rake doc` renders them. Types are not written twice: `yard-sorbet` reads the inline `sig` blocks and turns them into `@param` and `@return`, so the signature the checker reads is the signature the documentation shows. Hand-written type tags would be a second source of truth for something already declared — the same argument that keeps a checked-in RBI out of this gem, one section down.

What is deliberately left undocumented is internal constants: column names, regex fragments, the `MEMBERS` lists the value objects serialize through. They are named for the code that reads them and a comment restating a name is noise.

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
`InvalidArgument` -- an `ArgumentError`, so the code around this library keeps
its existing rescue -- with messages written for whoever has to fix the record,
and a type error would say less. Three places are `T.untyped` on purpose and say why
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


## Contributing

Bug reports and pull requests are welcome at https://github.com/Babystep-Technologies/active_sanction.

The most useful contribution is a new list. [`docs/adding_a_source.md`](docs/adding_a_source.md) is written for exactly that, and the shared conformance group means a new adapter is held to the same checklist the shipped ones are. The UK ([#40](https://github.com/Babystep-Technologies/active_sanction/issues/40)) and Australia ([#41](https://github.com/Babystep-Technologies/active_sanction/issues/41)) are open and unclaimed.

The second most useful is a name this version gets wrong. A missed record or a false alert belongs in [`benchmark/fixtures/labeled_set.yml`](benchmark/fixtures/labeled_set.yml) with what it is supposed to find, whether or not the matching is changed in the same pull request — a case nobody has written down is a case that regresses silently.

`bundle exec rake` runs the suite, RuboCop and Sorbet; all three must pass. If you change the normalizer, the index, the similarity algorithms, the scorer or the weights, run `bundle exec rake benchmark:accuracy` and commit the report it rewrites: a weight nudged by two points does not look like anything in a patch and is exactly what moves a name from found to missed.

This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](CODE_OF_CONDUCT.md).

## License

Available as open source under the terms of the [MIT License](LICENSE.txt).

## Code of Conduct

Everyone interacting in the ActiveSanction project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](CODE_OF_CONDUCT.md).
