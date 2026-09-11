---
title: Reference
nav_order: 4
has_children: true
permalink: /reference/
---

# Reference

Looked things up in, not read start to finish. Descriptive rather than
instructive: what a setting does, what an error means, what a list contains.

Planned: the source catalogue, configuration options, the error hierarchy,
the measured accuracy, and the bundle format.

Two of these already exist inside the gem and stay there, because they ship
with the code and are read by people who cannot reach this site:

- [`docs/bundle_format.md`](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/bundle_format.md) — the portable, signature-verified snapshot format
- [`docs/api_stability.md`](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/api_stability.md) — what is public API, and what may change

No accuracy figure on this site is typed by hand. `rake benchmark:accuracy`
writes [`benchmark/results/accuracy.md`](https://github.com/Babystep-Technologies/active_sanction/blob/main/benchmark/results/accuracy.md),
that file is committed, and the accuracy page renders it.

---

*This section is scaffolding.
[#109](https://github.com/Babystep-Technologies/active_sanction/issues/109)
writes the reference pages;
[#104](https://github.com/Babystep-Technologies/active_sanction/issues/104)
writes the source catalogue.*
