---
title: Reference
description: Sources, configuration, errors, measured accuracy, performance, the bundle format, and the adapter contract.
sidebar:
  order: 1
  # The group heading in the sidebar is already this page's title, so listing
  # it underneath repeats the word and buys nothing. Hidden from the tree,
  # not from the site: the landing page's cards still link here, and so does
  # every cross-reference between quadrants.
  hidden: true
---

Looked things up in, not read start to finish. Descriptive rather than
instructive: what a setting does, what an error means, what a list contains.
Nothing here explains why, and nothing instructs — see
[Explanation](/active_sanction/explanation/) for why, and
[Guides](/active_sanction/how-to/) for how.

- [Supported sanctions lists](/active_sanction/reference/sources/) — every
  list this gem reads, one uniform block each: jurisdiction, authority,
  endpoint, format, record count, known data limitations, licence and
  attribution.
- [Configuration](/active_sanction/reference/configuration/) — every setting
  `Configuration` accepts, its type, its default, and one line on effect.
- [Error hierarchy](/active_sanction/reference/errors/) — every error class,
  its parent, when it is raised, whether it is retryable, and the structured
  attributes it carries.
- [Accuracy](/active_sanction/reference/accuracy/) — precision, recall and F1
  against the labeled set, by threshold, by source, by variation.
- [Performance characteristics](/active_sanction/reference/performance/) —
  what determines index build time, screening latency, and rescreening cost,
  and what to run to measure your own.
- [Bundle format](/active_sanction/reference/bundle-format/) — the container
  shape, the header fields, and the four failure modes, pointing to the full
  specification.
- [Adapter contract](/active_sanction/reference/adapter-contract/) —
  `Sources::Base`, the `Definition` DSL, and the registry: every declaration
  and hook, its signature and required return.

## What ships with the code instead of living only here

Two documents stay inside the gem, under `docs/`, because they ship with the
code and are read by people who cannot reach this site — an offline
implementer, or a contributor mid-release:

- [`docs/bundle_format.md`](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/bundle_format.md) — the full, byte-level bundle specification. [Bundle format](/active_sanction/reference/bundle-format/) is the field reference over it.
- [`docs/api_stability.md`](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/api_stability.md) — the enumerated public API surface, versioning, and the deprecation path.

## Generated from the source

Every class, method and attribute this library ships as public API is
rendered from its own signatures and comments under
[`/api/`](/active_sanction/api/). The pages above link into it rather than restating a
signature; `/api/` is where the signature itself lives.

## Nothing here is typed by hand

Every default on [Configuration](/active_sanction/reference/configuration/),
every class on the [error hierarchy](/active_sanction/reference/errors/),
every figure on [Accuracy](/active_sanction/reference/accuracy/), and every
field on [Supported sanctions lists](/active_sanction/reference/sources/) is
generated from the code or from a committed benchmark report, not retyped
onto a page — see each page's own note on where its numbers come from.
