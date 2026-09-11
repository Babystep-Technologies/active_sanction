---
title: Detect when a publisher changes its format
description: The doctor, and why a file that still parses cleanly is the dangerous kind of change.
sidebar:
  order: 8
---

Notice when a government publisher has changed what its file means, not just
whether the file still parses.

**The dangerous change is the one where the file still parses cleanly and
means something different.** 19,321 entities carrying zero passport numbers
looks exactly as healthy as 19,321 carrying 23,429 if the only thing anyone
counts is records — and screening a passport number against the first
returns a clean result for somebody who is actually on the list. A sync
would not notice that for months; the doctor exists to.

## Run it

<!-- sample: illustrative -- reaches live government endpoints -->

```ruby
report = ActiveSanction.doctor                    # every configured source
report = ActiveSanction.doctor(:ofac_sdn)         # one
report = ActiveSanction.doctor(tolerance: 0.05)   # report smaller movements

report.ok?                    # => false
report.findings                # => [Doctor::Finding, ...]
report[:ofac_sdn].severity     # => :warn
report[:ofac_sdn].profile.fill # => { dates_of_birth: 0.12, identifiers: 0.34, ... }
exit report.exit_code          # 1 on any error; exit_code(on: :warn) for a build that should fail on warnings too
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

`Doctor::Report#to_h` round-trips through JSON, the same as a sync report —
alert on a finding through whatever your job runner already uses rather than
scraping console output.

## Run it nightly, on its own schedule

**A `doctor` invoked by hand only confirms a regression somebody already
suspected.** The value is in catching one nobody suspected, which means
something has to run it when nobody is looking:

<!-- sample: illustrative -- a Rake task definition, needs Rake and a real doctor run -->

```ruby
# lib/tasks/sanctions.rake
task doctor_sanctions: :environment do
  report = ActiveSanction.doctor
  warn report.to_s
  exit report.exit_code(on: :warn)
end
```

The doctor never writes anything — no snapshot, no payload cache, no
conditional-GET validators — so it always diagnoses bytes the publisher is
serving right now, and a doctor run never makes a later sync think an
unchanged list is unchanged when the doctor already fetched it. That costs a
full download of every list on every run; run it on its own cadence rather
than folding it into every `sync!`.

## Compare against yesterday's run, not just the stored snapshot

The doctor's default baseline is the last stored snapshot, which is free and
never goes stale on its own. Two things it measures only exist while a parse
is actually running — warning counts and free-text coverage — so a job that
wants those tracked week over week keeps its own report:

<!-- sample: illustrative -- needs a doctor.json written by a previous run, and reaches live endpoints -->

```ruby
yesterday = JSON.parse(File.read("doctor.json"))
report = ActiveSanction.doctor(baseline: ActiveSanction::Doctor::Report.from_h(yesterday))
File.write("doctor.json", JSON.generate(report.to_h))
```

## Read `warn` versus `error` correctly

**It is not about the size of the movement — it is whether the reading can
be explained by the list changing rather than the file changing.** A third
of the records disappearing is a `warn`: a delisting wave looks exactly like
a truncated download, and deciding automatically that it was the delisting
is how a compliance tool ends up quietly screening against a list it threw
half away. A column that used to hold numbers and now holds company names is
an `error`, and so is every record on a list losing a field all of them used
to carry — nothing a government does to its own list produces either of
those.

Fill rate is the specific check that catches a clean parse of a changed
file, because record counts do not move when a publisher renames or
reorders a column but the share of records carrying each field does. A date
of birth is measured over individuals alone — an organization never has
one — and a swapped-but-not-inserted column is invisible to a declared
width, which is why declaring column *values*, not just column *count*,
matters for a headerless file:

<!-- sample: illustrative -- a sketch inside an adapter's own class body -->

```ruby
class Ofac < ActiveSanction::Sources::Base
  floor :remarks_coverage, 0.90
end
```

A `floor` is a coarse backstop for the run that has nothing to compare
against — a first sync, a new source, a store that was cleared — not a
substitute for the snapshot-to-snapshot comparison, which catches drift a
fixed number wide enough to survive years of a growing list cannot.

## The upstream canary: the same idea, run on a schedule against real endpoints

Where the doctor is something you run and read, the canary is the same
comparison run automatically: it fetches every registered source on
weekdays and holds each against `.github/baselines/<key>.json`, opening an
issue when a number moves outside its tolerance.

```console
$ bundle exec rake canary                    # what every source measures right now
$ CANARY_SOURCES=ofac_sdn bundle exec rake canary:refresh   # accept the current numbers as the new baseline
```

It is deliberately excluded from the normal test suite and from CI's default
run — it reaches seven government endpoints, and a red build should mean
this gem's own code broke rather than that a publisher rate-limited a runner.
`.github/workflows/canary.yml` is what runs it on a schedule, and
[`.github/baselines/README.md`](https://github.com/Babystep-Technologies/active_sanction/blob/main/.github/baselines/README.md)
documents the baseline format and the per-key tolerances. When adding a new
source, commit its baseline in the same pull request as the adapter — see
[Add a sanctions source](/active_sanction/how-to/adding-a-source/).
