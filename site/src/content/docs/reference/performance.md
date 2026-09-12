---
title: Performance characteristics
description: What determines index build time, resident size, and screening latency, and what to run to measure your own.
sidebar:
  order: 6
---

What determines the cost of running this library, not a number claiming to
be it. **A benchmark measures the machine it ran on** — `benchmark/latency.rb`
and `benchmark/rescreen.rb` say so in their own header comments, and print
rather than commit, because a number fixed to one laptop says nothing about
the hardware a deployment actually runs on. Nothing on this page is a
committed or measured figure; run the commands below against your own corpus
and your own machine before sizing anything.

For one measured example — a specific run, on one specific machine, useful
for a rough sense of scale before running your own — see the
[Performance section of the README](https://github.com/Babystep-Technologies/active_sanction#performance).

## What each stage costs, and what changes it

| Stage | What it costs | Measure it with |
|---|---|---|
| Building the matcher | Paid once, when a store is first read — at boot, or after a sync changes it. Never paid per query. Scales with corpus size: more entities and more aliases mean a longer build and a larger resident index | `rake benchmark:index` |
| Scoring one query | Bounded by `candidate_limit`, not by corpus size — the index narrows a query to at most that many names before the scorer ever runs. A `screening_threshold` turns off the scorer's more expensive comparisons for a candidate that cannot clear it, without changing which candidates clear | `rake benchmark:scorer`, `rake benchmark:latency` |
| A full screening call | `Matcher#screen`, end to end: fold the query, retrieve from the index, score, filter, sort, cap at `screening_limit`. What a service is sized from | `rake benchmark:latency` |
| Rescreening a book of business | The book times what a diff actually changed, not the book times the whole corpus — see [Rescreen](/active_sanction/how-to/rescreening-a-book/). An empty diff scores nothing | `rake benchmark:rescreen` |
| A sync where nothing changed | One conditional request per declared file; no download, no parse | `rake benchmark:latency` measures the parse, not the sync |
| The similarity algorithms themselves | Four comparisons per candidate name; the token-set ratio is the one an early exit buys the least, because a name that is a subset of another scores 1.0 at any length | `rake benchmark:similarity` |

`RUBYOPT=--yjit` before any of the above measures the same stage under YJIT,
which is meaningfully cheaper for the scoring-heavy stages. Every command
accepts no arguments and reaches no network — see each script's own header
comment in `benchmark/` for what corpus it builds and why.

## The shape, not the number

- **A matcher is immutable once built.** Many threads screen through one
  index without a lock; a sync builds a new matcher rather than mutating the
  old one, so a request in flight finishes against one consistent list
  version. See [Holding a client, and screening from many threads](/active_sanction/how-to/syncing-on-a-schedule/).
- **Threshold changes cost, never the answer.** Every early exit in the
  scorer is a bound on what a pair of names *could* still reach, never an
  approximation of what it did reach, so a result at or above a threshold is
  exactly the result the same call with no threshold at all would return.
  `rake benchmark:scorer` scores every candidate twice — with and without a
  cutoff — and fails loudly if the two ever disagree.
- **`candidate_limit` trades recall for latency; `screening_threshold` trades
  recall for precision.** Raising the limit costs milliseconds for candidates
  the scorer already sees everything that could clear a threshold among;
  lowering the threshold finds more names and returns more noise per query.
  See [Configuration](/active_sanction/reference/configuration/) for both,
  and [Accuracy](/active_sanction/reference/accuracy/) for what moving the
  threshold costs in precision and recall, measured against the labeled set.
- **Rescreening scales with what moved, not with the book.** A book of
  ordinary customer names shares almost no feature with the handful of
  records a daily diff touches, so almost none of it reaches the scorer at
  all — the cost is dominated by describing each subject's name, not by
  comparing it to anything.
