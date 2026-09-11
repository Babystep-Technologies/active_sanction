---
title: Rescreen a book of business against a diff
description: Keep continuous screening affordable — cost proportional to churn, not to corpus size.
sidebar:
  order: 6
---

Notice who a list change affects, without re-screening your whole book of
customers against the whole corpus every time a list moves.

## Get a diff first

<!-- sample: illustrative -- needs stored snapshots to diff -->

```ruby
diff = ActiveSanction.diff(:ofac_sdn, from: last_months_snapshot, to: todays_snapshot)
diff = ActiveSanction.diff(:ofac_sdn, from: last_months_snapshot)   # `to:` is what is stored now

diff.added      # => [Entity], newly listed
diff.removed    # => [Entity], delisted
diff.modified   # => [Diff::Change], amended, with the fields that moved
diff.changed    # => [Entity], what to re-screen the book against
diff.churn      # => 0.001104, the fraction of the previous list that moved
```

`diff.changed` is additions and amendments — the records worth re-screening
against. `diff.removed` is a different job with the same diff: clearing
alerts that are already open.

## Rescreen your book against it

<!-- sample: illustrative -- needs a real diff -->

```ruby
book = [
  ActiveSanction::Subject.new(id: "cust_1", name: "Vladimir Putin", date_of_birth: "1952-10-07"),
  ActiveSanction::Subject.new(id: "cust_2", name: "Jane Miller")
]

alerts = ActiveSanction.rescreen(book, diff: diff, threshold: 75)

alerts.first.subject_id      # => "cust_1", the caller's own id
alerts.first.change          # => :newly_listed | :delisted | :details_changed
alerts.first.result          # => MatchResult, scored against the record as the new list has it
alerts.first.previous_score  # => 71.0 — what it scored against the old list version
alerts.first.score           # => 94.1
```

`Subject` carries your own id, unread and uninterpreted, so it travels onto
every alert — a book screened as bare names comes back needing to be
re-joined by position, which breaks the moment the book is filtered,
streamed in batches, or contains the same name twice. Give it everything
`screen` takes, in any spelling `screen` takes it: `date_of_birth:` or
`dates_of_birth:`, `country:`, `countries:` or `nationalities:`.

## What `change` means, and act on each differently

| | |
|---|---|
| `:newly_listed` | Did not reach the threshold against this record before, does now — a new record, or an amendment that gave an existing one the alias, identifier, or date of birth that brought the subject over the line. Both are the same event for a compliance team |
| `:delisted` | Reached the threshold before, does not now — the record was withdrawn, or an amendment moved it out of range. This is the half a re-screen against *new* records only would miss, and the half that lets a customer back through the door |
| `:details_changed` | Matched before, matches now, and the record moved underneath it |

`alert.fields` names what moved on a `:details_changed` alert. **This fires
even when the score did not move** — a program added or an address
corrected changes what a hit *means* without changing what it scores, and
treating that as too small to report would be deciding which sanctions hits
you are willing to miss.

## Do this at scale: one `Rescreen`, called per batch

<!-- sample: illustrative -- needs a real diff and an ActiveRecord-style Customer model -->

```ruby
rescreening = ActiveSanction::Rescreen.new(diff: diff, threshold: 75)

Customer.find_in_batches(batch_size: 1_000) do |batch|
  rescreening.call(batch.map { |c| { id: c.id, name: c.name, dob: c.born_on } }) do |alert|
    ComplianceAlert.create!(alert.to_h)
  end
end
```

Build one `Rescreen` per diff so its index is built once, then stream your
book through it — nothing about the book is held in memory beyond the
current batch, so memory tracks the size of the diff rather than the number
of customers.

## Why this is affordable and a full re-screen is not

A rescreen never touches the matcher — it indexes only the diff, so applying
one does not cost an index build over the whole 46,000-name corpus, and an
empty diff does no work at all: not one subject is folded. Measured on
`rake benchmark:rescreen`:

| | |
|---|---|
| 10,000 subjects against a typical daily diff (12 added, 4 removed, 5 amended) | ~1.2 s — 124 µs a subject |
| The same book screened against the whole list instead | ~54 s, roughly 44× the cost |

That is what makes rescreening after every sync affordable where a nightly
full re-screen is not, and it is why services that re-screen the naive way
tend to do it weekly instead of nightly.

## Store the results, not just the alert

<!-- sample: illustrative -- needs a real alert -->

```ruby
JSON.generate(alert.to_h)
ActiveSanction::Rescreen::Alert.from_h(JSON.parse(json))   # == alert, years later
```

Both `previous_result` and `result` are full `MatchResult`s, each stamped
with the checksum of the list version it was scored against, so an alert is
defensible the same way a screening decision is — the explanation is on it,
and it adds up. `snapshot_id` and `previous_snapshot_id` travel with the
alert, so keeping the alert is keeping enough to re-derive the whole run.

## What this does not do

There is no alert store, no deduplication against what was raised
yesterday, and no disposition tracking — that queue belongs to your
application, deliberately, since only it knows what "already reviewed" means
for your process. Two runs over the same diff produce the same alerts in the
same order, which is what makes that queue re-derivable rather than a black
box.

A first sync has no previous snapshot to diff against, so
`ActiveSanction.diff` reports `baseline?` and there is nothing to rescreen
— run `screen_all` against the whole book instead for that one deliberate
full pass, and switch to diff-driven rescreening from the next sync onward.

A rescreen also cannot find what was already there: a subject matching a
record that did not change is not in a diff at all, and remains whatever
your last full screening run reported.
