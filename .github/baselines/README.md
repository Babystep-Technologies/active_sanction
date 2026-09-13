# Canary baselines

One file per source, holding what that list measured the last time somebody
accepted its numbers. The upstream canary (
[#69](https://github.com/Babystep-Technologies/active_sanction/issues/69))
fetches every list on weekdays, parses it, and compares what it measures
against these — see [`canary/canary.rb`](../../canary/canary.rb) and
[`canary.yml`](../workflows/canary.yml).

**A diff in this directory is a change in what a government publishes.** That
is the whole reason the baseline is a committed file rather than a cache: a
number moving here has a date on it, an author, and a review, and a pull
request is a far better place to notice that OFAC's remarks coverage went from
97.3% to 96.8% than a line in a log nobody opens.

## What is in one

```jsonc
{
  "source": "ofac_sdn",
  "captured_at": "2026-09-08T15:31:26Z",   // when these numbers were measured
  "tolerances": { "record_count": 0.05 },  // what each check may move by
  "profile": { /* ActiveSanction::Doctor::Profile#to_h */ }
}
```

`profile` is the doctor's own measurement of the list: record count and
cohorts, the share of records carrying each field, the classes of warning the
parse produced, child rows that matched no parent, how much of the publisher's
free text the parser understood, and the shape of every positional column an
adapter asserts. Nothing in it is written by hand.

`tolerances` is the one part a human tunes. Each is a **share of the baseline
value**, so `0.05` on a record count of 19,365 is roughly a thousand records.
Two keys are set by default and the rest fall back to `0.10`, which is the
doctor's own:

| key | default | why |
| --- | --- | --- |
| `record_count` | `0.05` | these lists designate and delist every business day |
| `remarks_coverage` | `0.02` | free-text coverage does not move on its own — it moves when a label is spelled differently, which is the thing the canary exists to catch |
| anything else | `0.10` | `Doctor`'s default, and the same rule it applies |

`note` is optional free text, for a baseline whose numbers need a sentence:
a coverage figure that is low on purpose, a count that jumped for a reason
somebody has already established.

## Changing one

```console
$ bundle exec rake canary                                 # what has moved
$ bundle exec rake canary:refresh                          # accept it
$ CANARY_SOURCES=ofac_sdn bundle exec rake canary:refresh  # accept one list
```

`refresh` also regenerates
[`site/src/data/sources.json`](../../site/src/data/sources.json), the catalogue page's
record counts, which are read out of these files rather than typed (#104). Accepting
numbers here and leaving that behind is what `spec/site_sources_data_spec.rb` fails on.

`refresh` rewrites the profiles and leaves the tolerances alone — they are the
part somebody tuned, and a refresh that reset them every weekday would quietly
undo that. It touches only sources that actually parsed: a publisher that was
down has measured nothing, and writing a baseline of nothing would make the
next run report the list coming back as drift.

A clean canary run opens a rolling pull request doing exactly this, so the
numbers stay current without anybody editing JSON.

## A source with no file here

Nothing breaks. A newly added adapter has no baseline until a run commits one,
and until then it is held to the coarse floors the adapter itself declared
(`floor :remarks_coverage, 0.90` and friends — see
`ActiveSanction::Sources::Definition#floor`). The report says `compared: false`
rather than reading as a clean comparison, because a first look and "nothing
changed" are not the same thing.
