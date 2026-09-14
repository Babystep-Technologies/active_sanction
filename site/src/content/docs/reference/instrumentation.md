---
title: Instrumentation events
description: The six structured events this library emits, their payload keys, and what a subscriber is.
sidebar:
  order: 9
---

Six events, one per stage, each carrying a duration and the ids needed to
correlate it. Looked up when you are writing a subscriber or a dashboard panel
and need to know which key holds which number. For how to set one up on a
schedule, see [Sync on a schedule](/active_sanction/how-to/syncing-on-a-schedule/).

<!-- sample: illustrative -- StatsD is the host's, not this gem's -->

```ruby
ActiveSanction.configure do |c|
  c.instrumenter = ->(event) do
    StatsD.timing("sanctions.#{event.name}", event.duration_ms, tags: ["source:#{event.source}"])
  end
end
```

A subscriber is **anything answering `#call(event)`** — a lambda, a `Method`, an
object with a `call`. There is no registry and no base class. A host wanting
several composes them itself:

<!-- sample: illustrative -- `c` is the block parameter above, and the two subscribers are the host's -->

```ruby
c.instrumenter = ->(event) { [metrics, audit_log].each { |s| s.call(event) } }
```

Rails hosts have an adapter already:

<!-- sample: illustrative -- needs ActiveSupport loaded, which this gem does not depend on -->

```ruby
c.instrumenter = ActiveSanction::Instrumentation::Notifications.new
```

which republishes every event into `ActiveSupport::Notifications` under
`<event>.active_sanction` — `fetch.active_sanction`,
`index.build.active_sanction`, and so on. It is an adapter and not a
dependency: nothing in this gem requires ActiveSupport, and building one in a
process that has not loaded it raises `ConfigurationError` rather than quietly
instrumenting nothing.

## The events

Every event carries `name`, `started_at` (UTC, wall clock) and `duration`
(seconds, monotonic), whatever else is in the table. `error` is present only
when the stage raised — in which case **the keys it had not reached yet are
absent rather than zero**.

### `:fetch` — one HTTP round trip

Emitted per request, by the fetch layer.

| Key | Meaning |
|---|---|
| `source` | The list this file belongs to, e.g. `:ofac_sdn`. |
| `key` | What the conditional-GET validators are filed under. `:"ofac_sdn-sdn"` for one file of a multi-file source; the same as `source` otherwise. |
| `url` | The address asked for. |
| `forced` | Whether validators were deliberately withheld, so the publisher had no way to answer 304. |
| `conditional` | Whether stored validators were actually sent. |
| `status` | The HTTP status the publisher answered. |
| `not_modified` | `true` for a 304 — the copy already held is current. |
| `bytes` | Body size. `0` on a 304. |

A file served out of the payload cache after a 304 costs no request and emits
nothing. A source re-fetching one because its cache was empty emits a **second**
event rather than amending the first.

A publisher answering 500 emits an event with `status: 500` and **no `error`**:
the round trip completed and the publisher answered, which is a different fact
from a connection that never opened. The exception is raised above this layer
and lands on the `:sync` event's `outcomes`.

### `:parse` — bytes into records

| Key | Meaning |
|---|---|
| `source` | The list. |
| `bytes` | How large the document was, across every file of a multi-file source. |
| `records` | Entities the adapter produced. |
| `warnings` | Rows that could not be read, kept rather than raised. |

`warnings` is the number to alert on. A list that parses to the usual record
count while its warning count triples is a publisher that changed something,
and it is the failure a record count alone cannot see.

### `:store` — a list version written

| Key | Meaning |
|---|---|
| `source` | The list. |
| `snapshot_id` | The checksum of the version written — the same string every `MatchResult` off it is stamped with. |
| `entities` | How many records are in it. |
| `store` | The storage adapter's class name. |
| `imported` | `true` when it arrived through `import` from a signed bundle rather than from a sync. Absent otherwise. |

Timed around the write and nothing else: a store that takes eleven seconds to
persist 19,321 entities is a different operational problem from a publisher
that takes eleven seconds to serve them.

### `:"index.build"` — what a matcher cost to build

| Key | Meaning |
|---|---|
| `store` | The storage adapter's class name. |
| `sources` | The lists indexed. |
| `snapshots` | Their checksums, keyed by source. |
| `entities` | Records indexed. |
| `names` | Searchable name strings — more than `entities`, because an entity with six aliases is six of these. |
| `keys` | Distinct features across the three feature spaces. |
| `postings` | Total postings held. |
| `bytes` | **An estimate** of what the index is holding. |

`bytes` is deliberately crude and says so — see `Index#profile`. It counts
the three things that dominate and does not count the entities themselves,
which belong to the snapshot and are shared with it. Good to within a factor
a dashboard cares about; anything finer wants a heap profiler.

### `:screen` — one query

Emitted once per query, including once per element of a `screen_all` batch.

| Key | Meaning |
|---|---|
| `candidates` | Names the index retrieved. |
| `scored` | Entities they came down to. |
| `results` | Hits returned, after threshold and limit. |
| `threshold` | The lowest score this query reported. |
| `limit` | Results it could return. |
| `sources` | Lists screened against. |
| `snapshots` | Their checksums — which list *versions* answered. |

`candidates` against the configured candidate limit is the number to watch when
tuning it: a query pinned at the cap is one whose true match may have fallen
off the end. See [Tune the threshold](/active_sanction/how-to/tuning-the-threshold/).

### `:sync` — a whole run

| Key | Meaning |
|---|---|
| `sources` | The lists the run covered. |
| `forced` | Whether conditional GET was bypassed. |
| `concurrency` | How many publishers were fetched from at once. |
| `outcomes` | `{source => :updated \| :unchanged \| :failed}`. |
| `updated`, `unchanged`, `failed` | Counts of each. |
| `records` | Records across every source that stored one. |

This is the freshness signal. A source reporting `:failed` is still screenable
— a failed sync keeps the previous snapshot on purpose — so the alert to write
is on *age*, not on the failure alone.

## A subscriber must be safe to call from several threads

`sync!(concurrency: 3)` fetches from three publishers at once, and the
`:fetch`, `:parse` and `:store` events of those three arrive on three threads.
Nothing serializes them — a lock around a subscriber would make
instrumentation a source of contention in the one place this library
deliberately fans out. A subscriber that appends to a plain Array wants a Mutex
of its own; one that hands an event to a metrics client is already fine,
because those are.

`:screen` is the same statement from the other direction: a matcher is screened
from every thread a host has.

## Two guarantees

**A raising subscriber cannot break a sync.** Instrumentation is a measurement
of the work and is never part of it. An exception from a subscriber is caught,
reported once through the configured logger, and dropped; the stage carries on
and returns what it was going to return.

**Instrumentation never swallows the library's own exceptions.** A stage that
raises emits its event with `error:` set, and then the exception continues
exactly as if nothing were listening.

## Nothing is listening by default, and that costs nothing

`instrumenter` defaults to `nil`, and `nil` is a branch taken before anything
is allocated rather than a no-op object that gets called. An installation that
instruments nothing builds no event and allocates no payload, which is the only
way a per-query event could be affordable at all.

## What is promised

The event names and every payload key above are public API, held to the same
rule as a method signature: within a major version a key is not removed,
renamed or made to mean something else. Keys may be **added**, which is how a
new measurement ships without a major version — so read the keys you know and
ignore the rest. See
[`docs/api_stability.md`](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/api_stability.md).

Where an event is emitted *from* is not public. `Instrumentation.instrument`
is the library's own call and is marked private.
