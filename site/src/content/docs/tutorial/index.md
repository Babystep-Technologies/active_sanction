---
title: Get started
description: Screening a name against a real sanctions list, one path followed start to finish.
sidebar:
  order: 1
---

At the end of this page you will have:

- a real, government-published sanctions list, synced onto your own disk;
- a name on that list, screened and scored, with the reasons that produced the score;
- a name that is not on it, and the one thing an empty result actually means.

One path, no choices along the way. Where you want to know *why* a step is
what it is, [Explanation](/active_sanction/explanation/) answers it; where you
want to do something other than the one path,
[Guides](/active_sanction/how-to/) does.

## Install

<!-- sample: illustrative -- a Gemfile line, not Ruby -->

```ruby
gem "active_sanction"
```

```
$ bundle install
```

Ruby 3.1 or newer.

## Configure a store

A sync needs somewhere to put what it downloads. Name a directory:

<!-- sample: illustrative -- changes ActiveSanction's process-global configuration -->

```ruby
ActiveSanction.configure do |c|
  c.storage_dir = "./sanctions-data"
  c.sources     = [:un_consolidated]
end
```

## Sync one list

`un_consolidated` — the UN Security Council's list — is one file and the
smallest of the seven this gem reads, so this step takes seconds rather than
minutes.

<!-- sample: illustrative -- reaches the UN's live endpoint and needs the store configured above -->

```ruby
report = ActiveSanction.sync!
puts report
```

```
1 source in 2.83s: 1 updated
  un_consolidated  updated    1011 records  just fetched    2.83s
```

## Read the sync report

<!-- sample: illustrative -- needs the report from the sync above -->

```ruby
report.updated.map(&:source)            # => [:un_consolidated]
report[:un_consolidated].record_count   # => 1011
report[:un_consolidated].age            # => 0
```

A sync tells you what it did. Hold onto that; it pays off once this is running
on a schedule.

## Screen a name that matches

Bosco Ntaganda has been on this list since 2005.

<!-- sample: illustrative -- needs the sync above -->

```ruby
hit = ActiveSanction.screen(name: "Bosco Ntaganda", type: :individual).first

hit.score               # => 100.0
hit.matched_name.value  # => "Bosco Ntaganda"
```

## Read the explanation

The score is the sum of these:

<!-- sample: illustrative -- needs the screening call above -->

```ruby
hit.explanation.map(&:to_s)
# => ["+100.0 name: matched alias \"Bosco Ntaganda\" (aka)"]
```

## Screen a name that does not match

<!-- sample: illustrative -- needs the sync above -->

```ruby
ActiveSanction.screen(name: "Daniel Ashworth", type: :individual)
# => []
```

An empty array means nothing over the threshold in the list you hold — it
does not mean [*not sanctioned*](/active_sanction/#screening-aid).

## Where to go next

- [Guides](/active_sanction/how-to/) — for the next job: adding a source,
  choosing a store, syncing on a schedule.
- [Reference](/active_sanction/reference/) — the seven lists, one uniform
  block each.
- [Explanation](/active_sanction/explanation/) — why a score is what it is,
  and where the gem ends and the service begins.
