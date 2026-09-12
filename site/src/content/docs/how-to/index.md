---
title: Guides
description: One job per page, for somebody who already knows what they are trying to achieve.
sidebar:
  order: 1
  # The group heading in the sidebar is already this page's title, so listing
  # it underneath repeats the word and buys nothing. Hidden from the tree,
  # not from the site: the landing page's cards still link here, and so does
  # every cross-reference between quadrants.
  hidden: true
---

One job per page, for somebody who already knows what they are trying to
achieve. A guide assumes competence: it does not teach the domain and it does
not explain its own reasoning — where that is needed,
[Explanation](/active_sanction/explanation/) has it.

- [Add a sanctions source](/active_sanction/how-to/adding-a-source/) — register
  an adapter for a list this gem does not yet read, and get it through the
  conformance suite.
- [Choose a storage backend](/active_sanction/how-to/choosing-a-store/) —
  filesystem, ActiveRecord, memory, or your own, and what each costs.
- [Tune the threshold for your risk appetite](/active_sanction/how-to/tuning-the-threshold/) —
  move the cutoff, and read reasons instead of banding by score.
- [Sync on a schedule, and handle a source that is down](/active_sanction/how-to/syncing-on-a-schedule/) —
  the rake task, per-source failure isolation, and what to alert on.
- [Rescreen a book of business against a diff](/active_sanction/how-to/rescreening-a-book/) —
  continuous screening at a cost proportional to what changed, not to the
  size of your book.
- [Publish and verify a signed bundle](/active_sanction/how-to/publishing-a-signed-bundle/) —
  move a list to a machine that cannot reach the publisher.
- [Detect when a publisher changes its format](/active_sanction/how-to/detecting-format-drift/) —
  the doctor, and the canary that runs it on a schedule.
- [Handle errors](/active_sanction/how-to/handling-errors/) — the error
  hierarchy, which failures are retryable, and what to log.

Adding a source already has a full walkthrough inside the gem, at
[`docs/adding_a_source.md`](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/adding_a_source.md).
That file ships with the code and stays canonical — it is what an offline
contributor has, and it is where the full contract and worked example live.
The guide above is the field guide: shorter, and pointing into the file's
sections rather than restating them.
