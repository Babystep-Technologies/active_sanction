# The bundle format

A bundle is one sanctions list, in one file, that a machine which has never
spoken to the publisher can load and trust. It carries the records, everything
needed to prove they are intact, and — optionally — a signature saying who
published them.

```
ofac_sdn.asb
├── ACTIVESANCTION-BUNDLE/1        the magic, and the format version
├── {"format_version":1,...}       the header: one canonical JSON line
├── ecdsa-sha256 MEUCIQ...         the signature, or "-"
└── <deflated NDJSON>              the records, one JSON object per line
```

This document specifies it completely enough to be produced and read by
something that is not this gem and is not Ruby. In Ruby it is
`ActiveSanction::Snapshot::Bundle`:

```ruby
File.open("ofac_sdn.asb", "wb") { |io| ActiveSanction::Snapshot::Bundle.write(snapshot, io: io) }
File.open("ofac_sdn.asb", "rb") { |io| ActiveSanction::Snapshot::Bundle.read(io) }
```

## Contents

1. [Why the format exists](#1-why-the-format-exists)
2. [Conventions](#2-conventions)
3. [The container](#3-the-container)
4. [The magic line](#4-the-magic-line)
5. [The header line](#5-the-header-line)
6. [The signature line](#6-the-signature-line)
7. [The payload](#7-the-payload)
8. [Producing a bundle](#8-producing-a-bundle)
9. [Reading a bundle](#9-reading-a-bundle)
10. [Determinism, and what is comparable](#10-determinism-and-what-is-comparable)
11. [Versioning](#11-versioning)
12. [A worked example](#12-a-worked-example)

## 1. Why the format exists

`Storage::FileSystem` also writes compressed JSON, and its layout is private and
expected to change. A bundle is the opposite thing: a published artifact with a
stability contract, which three situations need and a private directory layout
cannot serve.

- **Publishers go down.** Government endpoints break, change format, and
  rate-limit. A bundle produced once and distributed is the difference between
  a bad afternoon at Treasury and a failed deploy for everyone downstream.
- **Air-gapped and privacy-sensitive installations.** A compliance team that
  will not send subject names to a third-party API will happily consume fresh
  data. A file serves them; a request/response API cannot.
- **Audit.** A checksum proves a list is internally intact. A signature proves
  it is *the one that was published*, which is the claim an examiner is asking
  about.

Anyone may produce a bundle, from any source, with no key and no licence. That
is the point of specifying it here rather than in a product.

## 2. Conventions

- **Bytes.** A bundle is a byte stream. It is not text, and it must not be
  transferred in a mode that rewrites line endings.
- **Line terminator.** `LF` (`0x0A`) alone. `CRLF` is not accepted anywhere.
- **Text.** The three header lines are UTF-8. So is the decompressed payload.
- **JSON.** [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259). Serialized
  compactly: no whitespace between tokens, no trailing newline inside a line,
  and no reordering — key order is part of the format wherever this document
  gives one.
- **Digests.** SHA-256, written `sha256:` followed by 64 lowercase hex digits.
  The same form this library quotes every digest in.
- **Extension.** `.asb`, by convention. Nothing depends on it.
- **Media type.** `application/vnd.active-sanction.bundle`, by convention.

## 3. The container

```
bundle     = magic LF header LF signature LF payload
magic      = "ACTIVESANCTION-BUNDLE/" 1*DIGIT
header     = <one JSON object, serialized compactly>
signature  = "-" / algorithm SP base64
payload    = <a zlib stream, RFC 1950>
```

The payload runs to end of file and is not length-prefixed in the container:
its uncompressed length and digest are in the header, and bytes after the end of
the compressed stream are an error (§9).

The first three lines are text on purpose. `head -c 512 ofac_sdn.asb` tells an
operator what list a file holds, how many records, from when, and who says so —
with no tooling and nothing decompressed.

Each of the three lines is at most **65536 bytes** including its terminator. A
reader must refuse a longer one rather than buffering it.

## 4. The magic line

```
ACTIVESANCTION-BUNDLE/1
```

The literal `ACTIVESANCTION-BUNDLE`, a `/`, and the format version as decimal
digits. This is the first thing a reader checks, and a version it does not
implement is refused here — before any JSON is parsed, and before a byte is
decompressed.

The version also appears in the header, and the two must agree (§9). The magic
is what a reader acts on early; the copy in the header is the one a signature
covers, so the version cannot be reinterpreted without breaking the signature.

## 5. The header line

One JSON object, serialized compactly, with its keys **in this order**:

| # | Key | Type | Notes |
|---|-----|------|-------|
| 1 | `format_version` | integer | Equals the version in the magic line. |
| 2 | `gem_version` | string | The `active_sanction` that serialized the records. Diagnostic; a non-Ruby producer writes the version of whatever wrote it. |
| 3 | `generator` | string | Who published this bundle, e.g. `"active_sanction/0.1.0"`, `"acme-mirror/2.0"`. |
| 4 | `source` | string | The list's key: lowercase, `[a-z][a-z0-9_]*`, e.g. `"ofac_sdn"`. |
| 5 | `schema_version` | integer | `Snapshot::SCHEMA_VERSION` the records are written under. `2` at the time of writing. |
| 6 | `snapshot_checksum` | digest | Over the records' content. §7.3. |
| 7 | `record_count` | integer | Number of lines in the uncompressed payload. |
| 8 | `fetched_at` | string | When the publisher's file was fetched: RFC 3339, UTC, whole seconds, `Z` — `"2026-08-28T09:30:00Z"`. |
| 9 | `source_version` | string \| null | The publisher's own version string, where it gives one. |
| 10 | `payload_encoding` | string | `"ndjson"` in v1. |
| 11 | `payload_compression` | string | `"deflate"` in v1. |
| 12 | `payload_digest` | digest | SHA-256 over the **uncompressed** payload. |
| 13 | `payload_bytes` | integer | Length of the **uncompressed** payload. |

Every key is present. `source_version` is written as `null` rather than omitted
when there is none — the key order is the format, and a reader that had to cope
with holes in it would be coping with a different file for every publisher.

A reader must refuse a header carrying a key it does not know, rather than
ignoring it. A field a producer thought was meaningful and a reader silently
dropped is the shape of every quiet integrity failure this format exists to
avoid.

There is deliberately **no written-at timestamp**, and no field describing the
compressed bytes. Both would make two writes of one snapshot different files
(§10).

## 6. The signature line

```
-                              an unsigned bundle
ecdsa-sha256 MEUCIQD0kBCt...   a signed one
```

An algorithm name, a single space, and the signature in
[RFC 4648 §4](https://www.rfc-editor.org/rfc/rfc4648#section-4) base64 with
padding and no line breaks. `-` when the bundle is unsigned.

**The signed bytes are the header line's, without its terminator.** Nothing
else. Because the header carries `payload_digest`, signing a few hundred bytes stands for
every record in the file, and three things follow:

- A verifier settles who published a bundle **before inflating any of it**.
  Compressed data from a party you have not authenticated is the last thing
  worth expanding.
- Verification costs the same for a 500-record list and a 6,000-record one.
- Re-compressing a bundle at another level does not invalidate its signature.
  The claim is about the list, not about the packing.

| Algorithm | Key | Signature |
|-----------|-----|-----------|
| `rsa-sha256` | RSA | RSASSA-PKCS1-v1_5 over SHA-256 |
| `ecdsa-sha256` | EC | ECDSA over SHA-256, DER-encoded |
| `ed25519` | — | **Reserved.** Not produced or verified by v1 readers. |

`ed25519` is named so that a v1 reader refuses it with "this bundle is signed
with something I am too old for" rather than "unknown algorithm", and so that
adding it later is not a format change.

Verification is opt-in. A reader given no key does not look at this line, and an
unsigned bundle is a fully valid bundle — its records are still proven against
`payload_digest` and `snapshot_checksum`. What it is not is *attested*, and a
consumer is entitled to know which of the two it has. In this library that is
`Snapshot#trusted?`, and it reaches every screening result as
`MatchResult#verified?`.

## 7. The payload

### 7.1 Layout

Everything after the signature line's terminator is a zlib stream
([RFC 1950](https://www.rfc-editor.org/rfc/rfc1950): the 2-byte header, deflate
data, and the Adler-32 trailer). Not gzip — a gzip header carries a modification
time and an OS byte, neither of which is a fact about a sanctions list.

Compression level **6**. Named here rather than left to a library's default so
that two producers agree; the level does not affect correctness, and a reader
must not care what a file was packed at.

Decompressed, the payload is newline-delimited JSON: one entity per line, each
line terminated by `LF`, **including the last**. `payload_bytes` counts those
bytes, terminators included.

### 7.2 Record order

Records are sorted ascending by the hex SHA-256 of the line's own bytes, without
its terminator — the same per-entity fingerprint the snapshot checksum is built
from (§7.3).

Sorting rather than preserving the publisher's order is what makes the format
deterministic: a government reshuffling its file is not a new list, and two
producers who parsed the same list produce the same bytes. Duplicate records
survive it — an entity listed twice yields two identical lines.

### 7.3 The record shape, and the snapshot checksum

Each line is one `ActiveSanction::Entity` serialized as its documented hash, key
order as the model declares it: `id`, `source`, `source_ref`, `type`, `names`,
`addresses`, `identifiers`, `dates_of_birth`, `nationalities`, `programs`,
`listed_on`, `remarks`. Absent scalars are `null`; absent collections are `[]`.

`snapshot_checksum` is computed over the records and nothing else — not over
`fetched_at`, not over `source_version`, not over anything in the container. Its
definition is the snapshot's, reproduced here so that a non-Ruby implementation
can compute it:

```
fingerprints = sorted([ hex_sha256(line) for line in records ])       # ascending
material     = "{schema_version}\n{source}\n" + "".join(f + "\n" for f in fingerprints)
checksum     = "sha256:" + hex_sha256(material)
```

Two consequences are the reason it is defined that way. A refetch of an
unchanged list reproduces it exactly, so "has this list changed since we last
screened?" is answerable; and changing any field of any record changes exactly
one fingerprint.

Because the fingerprints are the sort key of §7.2, a bundle's record order and
its checksum cannot drift apart.

## 8. Producing a bundle

1. Serialize each entity to compact JSON. Sort the lines by the hex SHA-256 of
   each line (§7.2).
2. Concatenate them, each followed by `LF`. This is the uncompressed payload.
   Take its SHA-256 and its length — these are `payload_digest` and
   `payload_bytes`.
3. Compute `snapshot_checksum` (§7.3).
4. Build the header (§5) and serialize it compactly, keys in order.
5. Sign the header line's bytes if a key was supplied (§6).
6. Write: magic, `LF`, header, `LF`, signature, `LF`, then the payload
   compressed as a zlib stream at level 6.

A producer that streams the payload straight to the file cannot: the header
states a digest and a length of bytes that do not exist yet, so it must be
buffered or written in two passes. This library buffers it — the snapshot is
already in memory by then, and the compressed copy of even the largest published
list is about 25 MB.

## 9. Reading a bundle

In this order. Every step is a refusal, never a repair.

1. **Magic.** Read the first line. If it is not `ACTIVESANCTION-BUNDLE/<digits>`,
   this is not a bundle. If the version is above what the reader implements,
   stop and say so — do not parse further.
2. **Header.** Read the second line and parse it. An unknown key, a missing key,
   a malformed digest or an unusable source key are all refusals.
3. **Agreement.** `format_version` must equal the version on the magic line.
4. **Support.** `schema_version`, `payload_encoding` and `payload_compression`
   must all be ones the reader implements. Anything else is a version problem,
   not a corruption problem, and the two must be reported differently: one is
   fixed by upgrading, the other by fetching the file again.
5. **Signature.** Read the third line. If the caller supplied a key, verify it
   over the header line's bytes now, before decompressing anything. A bundle
   with `-` and a caller asking for verification is a failure, distinct from a
   bad signature.
6. **Payload.** Inflate incrementally. For each complete line: accumulate it
   into the digest, count its bytes, and parse it into a record. **Stop the
   moment the inflated total exceeds `payload_bytes`** — a file that lies about
   its own size is either damaged or built to exhaust whoever opens it.
7. **Completeness.** The compressed stream must terminate cleanly, the last
   record must be terminated, and there must be no bytes after the end of the
   stream.
8. **Digest.** The accumulated digest and length must equal `payload_digest` and
   `payload_bytes`.
9. **Content.** Re-derive `snapshot_checksum` from the records that actually
   arrived (§7.3) and compare it to the header's. Count them and compare to
   `record_count`.

Steps 8 and 9 are both required, and they catch different things: 8 says the
bytes are the bytes that were packed, and 9 says those bytes are the list the
header describes.

Nothing partial is ever returned. A reader that hands back the 8,000 records it
managed to parse out of 19,015 produces a report that looks exactly like a clean
one, which is the most expensive thing a screening library can get wrong.

### Failure modes

| Condition | `ActiveSanction::Snapshot::Bundle` raises |
|-----------|--------------------------------------------|
| Not a bundle, truncated, digest or count mismatch, trailing bytes, oversized payload, magic disagrees with header | `Corrupt` |
| Signature does not verify under the key given | `UntrustedSignature` |
| No signature, and verification was asked for | `Unsigned` (a subclass of the above) |
| Format version, snapshot schema, payload encoding or signature algorithm this reader does not implement | `UnsupportedFormat` |

`Corrupt` and `UntrustedSignature` are deliberately different: "these bytes were
damaged" and "these bytes came from somebody else" are different incidents, and
only one of them is fixed by downloading the file again.

## 10. Determinism, and what is comparable

**The same snapshot produces the same bundle.** Record order is derived from
content, header keys have a fixed order, the compression level is stated rather
than defaulted, and nothing anywhere in the file says when it was written.

Two things qualify that, and both are deliberate:

- **The header line is the invariant that survives everything.** zlib
  implementations disagree about what to emit for identical input, so a file
  packed by zlib-ng and one packed by zlib may differ byte for byte while
  holding exactly the same list. `payload_digest` is over the *uncompressed*
  payload for this reason: it is the half of the file two machines can be held
  to. Two bundles with identical header lines carry identical records.
- **A signature line may differ between two signings.** ECDSA is randomized.
  Determinism is a property of the magic line, the header and the payload.

`gem_version` and `generator` are inputs, not noise: two mirrors that bundled the
same list produce different files, and should, because they are different
publications of it. The list they carry is the same, and `snapshot_checksum`
says so.

## 11. Versioning

`format_version` is the format's own number and moves independently of the gem's.

- A reader **must** refuse a `format_version` above what it implements, at
  step 1, with an error that says to upgrade. It must never read a newer file
  partially: a newer shape will usually deserialize into plausible, wrong
  records, and the symptom is names that quietly stop matching.
- A reader **must** accept every version at or below its own.
- Within a format version, no key changes meaning, no key is removed, and no key
  is reordered. Keys are not added either: a reader that refuses unknown keys
  (§5) would reject them, which is what makes the refusal safe to require.
- `schema_version` is the record model's number and moves on its own. A bundle
  can carry records too new for a reader while its container is a version that
  reader understands, which is why the two are checked separately.

## 12. A worked example

One entity, unsigned. Reproduce it with:

```ruby
entity = ActiveSanction::Entity.new(
  source: :ofac_sdn, source_ref: "2674", type: :individual, programs: ["SDGT"],
  names: [ActiveSanction::Name.new(value: "AL ZAWAHIRI, Aiman", kind: :primary)]
)
snapshot = ActiveSanction::Snapshot.new(
  source: :ofac_sdn, entities: [entity],
  fetched_at: Time.utc(2026, 8, 28, 9, 30, 0), source_version: "2026-08-28"
)
File.open("example.asb", "wb") { |io| ActiveSanction::Snapshot::Bundle.write(snapshot, io: io) }
```

The magic line:

```
ACTIVESANCTION-BUNDLE/1
```

The header line, wrapped here and written as one line in the file:

```json
{"format_version":1,"gem_version":"0.1.0","generator":"active_sanction/0.1.0",
 "source":"ofac_sdn","schema_version":2,
 "snapshot_checksum":"sha256:ed0eebb275106f4e7075683af4ca7ae17c7aa100cd617f8bc41eebe9d9cf797d",
 "record_count":1,"fetched_at":"2026-08-28T09:30:00Z","source_version":"2026-08-28",
 "payload_encoding":"ndjson","payload_compression":"deflate",
 "payload_digest":"sha256:f07b780b3849a40ad3d2ca0a679469809ffa8e69006728123a33e1bb156c32b9",
 "payload_bytes":293}
```

The signature line:

```
-
```

The payload, decompressed — 293 bytes, one line and its terminator:

```json
{"id":"ofac_sdn:2674","source":"ofac_sdn","source_ref":"2674","type":"individual","names":[{"value":"AL ZAWAHIRI, Aiman","kind":"primary","quality":null,"script":null}],"addresses":[],"identifiers":[],"dates_of_birth":[],"nationalities":[],"programs":["SDGT"],"listed_on":null,"remarks":null}
```

The whole file is 695 bytes. Checking the two digests by hand is the shortest
useful conformance test for an implementation:

```bash
ruby -rzlib -rdigest -e 'b = File.binread(ARGV[0])
                         puts Digest::SHA256.hexdigest(Zlib::Inflate.inflate(b.split("\n", 4)[3]))' example.asb
# => f07b780b3849a40ad3d2ca0a679469809ffa8e69006728123a33e1bb156c32b9
```

Everything before the payload is text, so the rest of the file needs no tooling
at all:

```bash
head -3 example.asb
```
