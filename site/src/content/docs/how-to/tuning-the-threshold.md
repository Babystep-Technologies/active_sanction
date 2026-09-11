---
title: Tune the threshold for your risk appetite
description: Move the cutoff, know what it costs in noise per query, and read reasons instead of banding by score.
sidebar:
  order: 4
---

Move the screening threshold away from the shipped default of 75, and know
what that costs before you do it in production.

For *why* 75 is the default and what the measured precision/recall/F1 curve
looks like at every threshold, see
[Why the threshold defaults to 75](/active_sanction/explanation/how-matching-works/#why-the-threshold-defaults-to-75).
This page is the mechanics: how to move it, and how to read a result once you
have.

## Move it globally, or per query

<!-- sample: illustrative -- changes ActiveSanction's process-global configuration -->

```ruby
ActiveSanction.configure { |c| c.screening_threshold = 65 }
```

<!-- sample: illustrative -- needs a synced store -->

```ruby
ActiveSanction.screen(name: "Vladimir Putin", threshold: 85)
```

A per-query `threshold:` overrides the configured default for that one call
and nothing else — it does not change a score, only which results clear the
cutoff. Set it per query wherever different customer segments carry
different risk: a new-account check might run at 65, a periodic re-screen of
an existing book at 75.

## What moving it costs

Lowering the threshold finds more true positives and returns more noise;
raising it does the reverse, and the trade is not symmetric. From the
measured curve:

```
threshold  precision  recall      F1   found  missed  false alerts  noise/query
       60      0.831   0.970   0.895      64       2            13          6.7
       75      0.899   0.939   0.919      62       4             7          1.7
       85      0.963   0.788   0.867      52      14             2          1.2
```

Lowering 75 to 60 finds two more listed records and costs six more false
alerts and roughly four times the noise per query. Raising it to 85 removes
five false alerts and stops returning ten records that were previously
found. Neither move is free, and **noise per query is the number to watch**
— it is what an analyst actually has to clear, and it grows faster than
recall improves as the threshold drops.

Run `bundle exec rake benchmark:accuracy` after any change to the matching
itself (weights, dictionaries, the index) to regenerate
[`benchmark/results/accuracy.md`](https://github.com/Babystep-Technologies/active_sanction/blob/main/benchmark/results/accuracy.md)
against the labeled set and see where the curve actually sits today, rather
than tuning against numbers from a previous release.

## Read the reasons, don't band by score

A 97 that is all name similarity and an 82 with a matching passport number
are different findings, and the score alone does not distinguish them. Read
`hit.explanation` rather than bucketing on the number:

<!-- sample: illustrative -- hit comes from a real screening call -->

```ruby
hit.explanation.any? { |r| r.factor == :identifier }   # a document number matched — near-decisive
hit.explanation.any? { |r| r.factor == :dob }          # a date of birth agreed
```

If your review queue currently bands by score range ("auto-clear under 80,
escalate over 95"), that banding is a proxy for what actually separates a
coincidence from a corroborated match. Query the reasons directly instead —
an identifier or date-of-birth agreement is worth acting on differently than
name similarity alone, whatever the two scores happen to be.

## Supply more of the query before lowering the threshold

The largest available improvement to a noisy queue is rarely a lower
threshold — it is a fuller query. An exact document number is worth +40, a
full date of birth +15, a nationality +6 by default, and every adjustment
fires only when both sides carry the field. A subject carrying the right
passport number needs forty points less name similarity than one carrying
nothing, so a screening call passing only a name is leaving most of this
library's discrimination unused — discrimination against the false
positives, not against the hits. Passing `date_of_birth:` and
`countries:` where your customer record has them costs nothing and typically
buys more precision than moving the threshold does.

## `candidate_limit` is a different knob

Raising or lowering `screening_threshold` never changes retrieval — the
number of names considered before scoring is `candidate_limit` (200 by
default), a separate setting. Confusing the two is the common mistake: a
threshold that is too high can make a true match score below the cutoff, but
a `candidate_limit` that is too low can mean the true match was never scored
at all, and nothing on the result tells you it happened.

<!-- sample: illustrative -- changes ActiveSanction's process-global configuration -->

```ruby
ActiveSanction.configure { |c| c.candidate_limit = 500 }
```

Raise it only if you suspect true matches are missing the candidate set
entirely — a long organization name against a query that dropped its legal
form is the shape that most often needs it — since it costs latency roughly
linearly and buys very little recall past the shipped default.
