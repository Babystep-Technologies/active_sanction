---
title: The gem and the service
description: Where the open library ends and the commercial service begins.
sidebar:
  order: 3
---

**The gem is complete on its own.** Every supported list is fetchable,
parseable and screenable locally, forever, with no account and no key.
Nothing in `active_sanction` is a trial, a rate-limited tier, or a feature
withheld until a plan upgrade. The seven adapters, the normalizer, the
index, the scorer and the storage layer are all here, and they are all the
same code a paying customer runs.

A commercial hosted service exists, and what it sells is **operations, not
capability**: the lists kept fresh on someone else's schedule, the syncs run
on someone else's infrastructure, the disk someone else provisions. Nothing
it does could not be self-hosted by running this library on a cron job and
a volume — the service is a convenience for a team that would rather not
run that job, not a feature this library holds back to sell separately.

That boundary is a design decision, not a marketing position. A screening
library used to decide who a business is allowed to transact with is a
poor place to be coy about what depends on a vendor staying in business and
what does not. A compliance program built on a library it can audit,
run offline and fork if it has to is a different kind of dependency than
one built on an API key — and this project is the former on purpose,
whichever way a team chooses to run it.

Nothing else on this site sells anything. Where a page names the service at
all, it is to state this same boundary in the same terms — never to argue a
reader into it.
