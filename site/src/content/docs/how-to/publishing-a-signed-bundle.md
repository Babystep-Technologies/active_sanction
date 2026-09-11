---
title: Publish and verify a signed bundle
description: Move a list between machines, for an air-gapped install or the afternoon a publisher is down.
sidebar:
  order: 7
---

Move one synced list, as one file, to a machine that cannot or should not
reach the publisher directly — and let the machine receiving it verify who
produced it before trusting it.

For the byte-level format — enough detail to implement outside Ruby — see
[`docs/bundle_format.md`](https://github.com/Babystep-Technologies/active_sanction/blob/main/docs/bundle_format.md).
This page is the two commands and the decisions around them.

## Export, transfer, import

<!-- sample: illustrative -- needs a synced store and a real signing key -->

```ruby
ActiveSanction.export(:ofac_sdn, to: "ofac_sdn.asb", sign_with: private_key)
```

<!-- sample: illustrative -- needs the bundle file this produced, and the matching public key -->

```ruby
# ...on another host, in another datacentre, next week
snapshot = ActiveSanction.import("ofac_sdn.asb", verify_with: public_key)
snapshot.trusted?   # => true
```

RSA and EC keys, through `openssl` and nothing else — generate one however
your organization already manages key material; nothing here mints or
distributes keys. Signing is optional: `ActiveSanction.import("ofac_sdn.asb")`
with no `verify_with:` loads the bundle unchecked, which is fine for a mirror
you already trust the transport of and simply do not want to attest.

## When to reach for this instead of a second sync

**A publisher is down or has changed format without notice.** A bundle
produced once and distributed is the difference between a bad afternoon at
Treasury and a failed deploy for everyone downstream that depends on you.

**The installation is air-gapped or privacy-sensitive.** It will not send
subject names to a third-party API but will happily consume a file somebody
else produced — a bundle serves that; a request/response sync cannot.

**An audit is asking a question a checksum alone cannot answer.** A checksum
proves a list is internally intact; a signature proves it is the one that
was actually published, by whoever holds the signing key.

## Check which failure you got — they mean different things

<!-- sample: illustrative -- needs a real bundle file and key -->

```ruby
ActiveSanction.import("ofac_sdn.asb", verify_with: public_key)

# => Snapshot::Bundle::Corrupt             a byte was flipped, or a record edited — fetch it again
# => Snapshot::Bundle::UntrustedSignature  intact, and signed by somebody else — do not screen against it
# => Snapshot::Bundle::Unsigned            nobody signed it, and you asked for verification — a subclass of the above
# => Snapshot::Bundle::UnsupportedFormat   written by a newer active_sanction — upgrade the gem
```

Rescue these separately rather than as one generic import failure — a
`Corrupt` bundle is a transport problem worth retrying the download for; an
`UntrustedSignature` is a security event worth escalating, not retrying.

## Keep `verified?` if your process needs it

The verified flag survives only as long as the imported snapshot itself
does — write it into a store and read it back, and `trusted?` is `false`,
because nothing signed covers what is now sitting in that store's own
gzipped JSON or table:

<!-- sample: illustrative -- store and snapshot are placeholders -->

```ruby
store.write_snapshot(snapshot)
store.read_snapshot(:ofac_sdn).trusted?   # => false — the honest answer
```

If a downstream process needs to see `verified?` on its results, hold the
imported snapshot in memory instead of round-tripping it through a directory
store:

<!-- sample: illustrative -- needs a real imported snapshot -->

```ruby
client = ActiveSanction::Client.new(storage: ActiveSanction::Storage::Memory.new)
client.storage.write_snapshot(snapshot)
client.screen(name: "Vladimir Putin").first.verified?   # => true
```

## Two properties worth relying on

**The same snapshot always produces the same bundle.** Records are ordered
by the fingerprint the snapshot checksum is built from, the header's keys
have a fixed order, and there is no written-at timestamp in the file. Two
mirrors that bundled the same list can be diffed byte-for-byte against each
other, which is a useful check that they really are the same list version.

**Verification is cheap regardless of list size.** The signature covers the
header, and the header covers a SHA-256 over the payload — so a verifier
settles who published a bundle before inflating any of it, and checking an
OFAC-sized bundle costs the same as checking the EU's.
