---
title: Adapter contract
description: Sources::Base, the Definition DSL, and the registry — every declaration and hook, its signature and required return.
sidebar:
  order: 8
---

`Sources::Base`, `Sources::Definition`, and the registry: what a source
adapter declares, the one method it must write, and the hooks it may
override. The worked walkthrough — reading a publisher's file, choosing a
parser, cutting a fixture — is
[Add a sanctions source](/active_sanction/how-to/adding-a-source/); this page
is the contract alone. Full signatures are in the generated API documentation
for [`Sources::Base`](/active_sanction/api/ActiveSanction/Sources/Base.html) and
[`Sources::Definition`](/active_sanction/api/ActiveSanction/Sources/Definition.html).

The registry is duck-typed: an adapter registers by answering `.key` and
`.new`, and nothing below requires subclassing `Sources::Base`.

## Declarations (`Definition`, extended into every adapter class)

Each reads back with no argument. `jurisdiction`, `authority`, `format`,
`url`, `licence_notice`, `licence_url` and `floor` resolve up the superclass
chain, so adapters sharing a publisher can share a base declaring them once.
`key` does not: it is looked up on the exact class only, so a subclass never
silently inherits its parent's key.

| Declaration | Type | Required | Inherited | Notes |
|---|---|---|---|---|
| `key` | `Symbol` | Yes | No | Lowercase `snake_case`, `/\A[a-z][a-z0-9_]*\z/`. Never inherited — the registry's, a stored snapshot's, and the payload cache's name for this list |
| `jurisdiction` | `Symbol` | Yes | Yes | Not validated against a country list — an internal watchlist's jurisdiction is whatever its owner says |
| `authority` | `String` | Yes | Yes | The body behind the list, spelled the way it spells itself |
| `format` | `Symbol` | No | Yes | Informational; not dispatched on. A source with no published file — built from a database — declares none |
| `url(name, address)` | `String` | One `url`, or an overridden `#retrieve` | Yes | Declares a file with two arguments, reads one back with a name, returns the primary (first declared) with none |
| `licence_notice` | `String` | No | Yes | A dated summary of what the publisher says about reuse — not legal advice |
| `licence_url` | `String` | No | Yes | Must be an `http(s)` URL |
| `floor(name, value)` | `Numeric` | No | Yes, merged | A lower bound a Doctor check is held to when there is no prior snapshot to compare against. A subclass's floor of the same name replaces its parent's |

A declaration violated at the class body raises `Sources::DeclarationError` —
see the [error hierarchy](/active_sanction/reference/errors/) — at load time,
which is where a typo in an adapter is cheapest to see.

## Hooks (`Sources::Base`)

| Method | Required | Given | Returns | Default |
|---|---|---|---|---|
| `#parse(raw)` | **Yes** | The bytes for a single-file source, or a `Hash[Symbol, String]` keyed by declared file name for a multi-file one | `Array[Entity]` | Raises `UnsupportedError` |
| `#retrieve(force: false)` | No | — | `Hash[Symbol, untyped]` of file name to bytes, or `nil` when every file is unchanged | Fetches every declared `url` over HTTP, conditionally, through the payload cache |
| `#column_shapes(raw)` | No | What `#parse` is given | `Array[Parsers::ColumnShape::Tally]` | `[]` — override for a source over a headerless, positionally-columned file (see `Sources::Ofac`) |
| `#source_version` | No | — | `String` or `nil` | The most recent fetch's `Last-Modified` header. Override when the publisher's document carries its own version marker, so an examiner sees the string the publisher itself uses |
| `.published_remarks(remarks)` | No (inherited, not overridden) | A record's `remarks` | `String` or `nil` | Strips this adapter's own `Remarks.build` additions back off, leaving only what the publisher wrote |

`#sync` and `#snapshot` are not overridden by an adapter — they are the fixed
orchestration every source shares: `#sync` calls `#retrieve` then `#snapshot`,
and `#snapshot` wraps whatever `#parse` returns in a checksummed `Snapshot`,
stamping the failing source's key onto any `ActiveSanction::Error` that
escapes.

## The registry (`Sources`)

| Method | Returns | Notes |
|---|---|---|
| `.register(source)` | The registered source | Raises `Sources::DuplicateKey` if a different class already claims the key. Registering the same class twice is a no-op |
| `.[](key)` | The adapter class or instance registered under `key` | Raises `Sources::UnknownSource`, naming what is registered, rather than returning `nil` |
| `.registered?(key)` | `Boolean` | — |
| `.all` | Every registered adapter, sorted by key | — |
| `.keys` | Every registered key, sorted | — |
| `.enabled(configured = config.sources)` | The adapters a sync should run | Every registered source when `configured` is `nil`; raises `Sources::UnknownSource` at the start of a run for an unresolvable key, rather than partway through |
| `.unregister(key)` | What was registered there, or `nil` | The supported way to replace a built-in adapter: unregister, then register a patched one |

A source is registrable by answering `.key` and `.new` — `Sources::Base` is
the convenient way to write one, not a requirement the registry checks for.
