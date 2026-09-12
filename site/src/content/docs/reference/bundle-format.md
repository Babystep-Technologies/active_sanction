---
title: Bundle format
description: One sanctions list, in one file, that a machine which has never spoken to the publisher can load and trust.
sidebar:
  order: 7
---

**[`docs/bundle_format.md`](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/bundle_format.md)
is the canonical specification** — complete enough to be produced and read by
something that is not this gem and not Ruby. It ships inside the gem, in
`docs/`, so an offline implementer always has it. This page is the field
reference: the container shape, the header fields, and the four failure
modes, for a reader who already knows the format and wants the fields without
re-reading the prose.

## The container

```
ofac_sdn.asb
├── ACTIVESANCTION-BUNDLE/1        magic, and the format version
├── {"format_version":1,...}       header: one canonical JSON line
├── ecdsa-sha256 MEUCIQ...         signature, or "-"
└── <deflated NDJSON>              records, one JSON object per line, to EOF
```

Each of the first three lines is text, at most 65,536 bytes including its
terminator. `head -c 512 file.asb` names the list, its record count, when it
was fetched, and who signed it, with no tooling and nothing decompressed.

<!-- sample: illustrative -- snapshot is a placeholder for a real Snapshot -->

```ruby
File.open("ofac_sdn.asb", "wb") { |io| ActiveSanction::Snapshot::Bundle.write(snapshot, io: io) }
File.open("ofac_sdn.asb", "rb") { |io| ActiveSanction::Snapshot::Bundle.read(io) }
```

## The header line

One JSON object, keys in this exact order. A reader refuses one it does not
recognize, and refuses a header carrying a key it does not know.

| # | Key | Type | Notes |
|---|-----|------|-------|
| 1 | `format_version` | integer | Equals the version in the magic line |
| 2 | `gem_version` | string | The `active_sanction` that serialized the records |
| 3 | `generator` | string | Who published this bundle — `"active_sanction/0.1.0"`, or a mirror's own name |
| 4 | `source` | string | The list's key, e.g. `"ofac_sdn"` |
| 5 | `schema_version` | integer | `Snapshot::SCHEMA_VERSION` the records are written under |
| 6 | `snapshot_checksum` | digest | Over the records' content |
| 7 | `record_count` | integer | Lines in the uncompressed payload |
| 8 | `fetched_at` | string | RFC 3339, UTC, whole seconds — `"2026-08-28T09:30:00Z"` |
| 9 | `source_version` | string \| null | The publisher's own version string, where it gives one |
| 10 | `payload_encoding` | string | `"ndjson"` in v1 |
| 11 | `payload_compression` | string | `"deflate"` in v1 |
| 12 | `payload_digest` | digest | SHA-256 over the uncompressed payload |
| 13 | `payload_bytes` | integer | Length of the uncompressed payload |

No written-at timestamp, and nothing describing the compressed bytes — either
would make two writes of one snapshot two different files.

## The signature line

`-` for an unsigned bundle, or an algorithm name, a space, and RFC 4648 §4
base64 with padding. The signed bytes are the header line's alone, without
its terminator — because the header carries `payload_digest`, a few hundred
signed bytes stand for every record in the file.

| Algorithm | Key | Signature |
|---|---|---|
| `rsa-sha256` | RSA | RSASSA-PKCS1-v1_5 over SHA-256 |
| `ecdsa-sha256` | EC | ECDSA over SHA-256, DER-encoded |
| `ed25519` | — | Reserved. Not produced or verified by v1 readers |

Verification is opt-in: a reader given no key does not look at this line, and
an unsigned bundle is fully valid — its records are still proven against
`payload_digest` and `snapshot_checksum`. What it is not is *attested*.
`Snapshot#trusted?` says which; `MatchResult#verified?` carries it to a
screening result.

## The four failure modes

| Condition | Raises |
|---|---|
| Not a bundle, truncated, digest or record-count mismatch, trailing bytes, oversized payload, magic disagrees with header | `Snapshot::Bundle::Corrupt` |
| Signature does not verify under the key given | `Snapshot::Bundle::UntrustedSignature` |
| No signature, and verification was asked for | `Snapshot::Bundle::Unsigned` (a subclass of the above) |
| Format version, snapshot schema, payload encoding or signature algorithm this reader does not implement | `Snapshot::Bundle::UnsupportedFormat` |

Full detail, including retryable status and every other error this library
raises, is on the [error hierarchy](/active_sanction/reference/errors/) page.

## Versioning

- A reader must refuse a `format_version` above what it implements, before
  reading anything past the magic line, with an error that says to upgrade.
- A reader must accept every version at or below its own.
- Within a format version, no key changes meaning, is removed, or is
  reordered.
- `schema_version` moves independently of `format_version` — a bundle can
  carry records too new for a reader while its container is a version that
  reader understands.

## Determinism

The same snapshot produces the same bundle byte for byte, except the
signature line — ECDSA is randomized, so two signings of the same header
differ even though both verify. Record order is derived from content, header
keys have a fixed order, and there is no field anywhere that records when the
file was written.
