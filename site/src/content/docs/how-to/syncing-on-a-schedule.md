---
title: Sync on a schedule, and handle a source that is down
description: The rake task, per-source failure isolation, and what to alert on.
sidebar:
  order: 5
---

Run a sync on a schedule, and alert on the right thing when one of the seven
publishers is unreachable.

## The task

<!-- sample: illustrative -- a Rake task definition, needs Rake and a real sync -->

```ruby
# lib/tasks/sanctions.rake
task sync_sanctions: :environment do
  report = ActiveSanction.sync!    # calls ActiveSanction.reload! itself when anything changed
  warn report.to_s
  exit report.exit_code            # 1 if any source failed
end
```

Wire that into cron, a scheduled CI job, or whatever runs recurring jobs in
your deployment. `sync!` fetches, parses and stores every configured source,
then rebuilds the shared matcher if anything actually changed — a sync that
found nothing new leaves the running index alone.

<!-- sample: illustrative -- reaches live government endpoints -->

```ruby
ActiveSanction.sync!                   # every configured source
ActiveSanction.sync!(:ofac_sdn)        # one
ActiveSanction.sync!(force: true)      # bypass conditional GET
ActiveSanction.sync!(concurrency: 3)   # fetch from up to three publishers at once
```

`concurrency:` bounds how many *publishers* are fetched from at once, never
how hard any one of them is asked — sources sharing a host are grouped and
fetched in order, since two of the built-in adapters share Treasury's file
server. It defaults to 1.

## Alert on the exit code, then read the report

<!-- sample: illustrative -- report comes from a real sync! run -->

```ruby
report.failed?                  # => true
report[:ofac_sdn].status        # => :updated
report[:un_consolidated].error  # => "ActiveSanction::HttpClient::TimeoutError: GET https://... failed"
```

```
7 sources in 27.14s: 2 updated, 4 unchanged, 1 failed
  ofac_sdn           updated    19015 records  just fetched   12.41s
  un_consolidated    failed       612 records  3d old          1.11s  ActiveSanction::HttpClient::TimeoutError
```

`report.exit_code` is 1 if any source failed — that is what makes cron and
CI able to alert without parsing text. `Sync::Report#to_h` round-trips
through JSON, so a host alerting through a job queue or a dashboard does not
have to scrape console output to notice a source that has been quietly
failing since Tuesday.

## The point that actually matters: alert on age, not just failure

**A failed source keeps its previous snapshot.** Nothing clears a stored list
on failure — not a 500, not a parse error, not a publisher serving HTML where
XML used to be. Screening against yesterday's OFAC list produces a report
with a known, visible age on it; screening against an empty list produces a
clean report for every customer, which is the more expensive failure by far.

That trade is only safe while the age stays visible, so **the thing to alert
on is the age of what is being screened against, not just whether the last
run reported a failure.** A single missed sync that resolves the next day is
not usually worth paging anyone; a source stuck failing for a week, still
being screened against silently, is. `report.unscreenable` is the harder
case underneath a failure — a source with nothing stored at all is not
screened against, rather than screened against something stale:

<!-- sample: illustrative -- report comes from a real sync! run -->

```ruby
report[:ofac_sdn].age            # how old the list actually being screened against is
report.unscreenable              # sources with no snapshot at all — the harder failure
```

Build the alert around age crossing a threshold your compliance policy sets
(a day, a week — whatever "stale" means for your risk appetite), not around
the binary pass/fail of the most recent run.

## One source down does not stop the others

Every source runs inside its own rescue during `sync!`; a UN outage does not
stop OFAC from syncing. `StandardError` is caught and not `Exception`, so an
`Interrupt` still stops the whole run — swallowing it to keep downloading
would be a job that will not die, not isolation. What each source's
`exception` carries is an
[`ActiveSanction::Error`](/active_sanction/how-to/handling-errors/), so a
run that failed on a slow publisher (`retryable?`) is distinguishable from
one that failed on a list that changed format, without matching on the
message.

## Unchanged sources cost nothing

A publisher answering 304 is never parsed and never stored — for OFAC's
three-file join, that skips the expensive half of the work along with the
download. A source whose bytes changed but whose parsed content hashes to
what is already stored is also reported unchanged: a publisher regenerating
an identical file with a new timestamp is not a new list version, and
rewriting it to say so would churn the checksum every audit record cites.

## Re-screen your book after every sync

Syncing keeps the lists current; it does not by itself notice which
customers are affected. Follow every sync with a diff-driven rescreen rather
than re-screening the whole book against the whole list:

<!-- sample: illustrative -- needs a stored previous snapshot -->

```ruby
diff = ActiveSanction.diff(:ofac_sdn, from: last_nights_snapshot)
diff.changed    # => [Entity], the additions and amendments to re-screen against
diff.removed    # => [Entity], delistings — the alerts you can now close
```

The full mechanics, and why this costs proportional to what changed rather
than to the size of your book, are in
[Rescreen a book of business against a diff](/active_sanction/how-to/rescreening-a-book/).
