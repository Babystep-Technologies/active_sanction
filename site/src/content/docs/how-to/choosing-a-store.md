---
title: Choose a storage backend
description: Pick where synced lists live, and know what each adapter costs.
sidebar:
  order: 3
---

Pick where this installation keeps the lists it syncs, before the first
`sync!` writes anywhere.

**Nothing on the query path names a concrete store.** The matcher is written
against `Storage::Base` and nothing else, so switching adapters later is a
configuration change, not a rewrite — pick one now on the criteria below and
revisit it without cost.

| Adapter | Use it when | Costs |
|---|---|---|
| `Storage::FileSystem` *(default)* | You want to provision nothing | One writer per source at a time, within one filesystem |
| `Storage::ActiveRecord` | You already have a database, want an indexed prefilter before scoring, and want readers on other machines | A migration, and ActiveRecord loaded first — it is not a dependency of this gem |
| `Storage::Memory` | A process that syncs and screens without owning a directory — a job, a CI run, a container with no volume | A full download on every boot |
| Your own | Anything else — S3, a shared cache, an air-gapped drop | Five methods, held to the shared conformance group below |

<!-- sample: illustrative -- changes ActiveSanction's process-global configuration, and the second line needs ActiveRecord loaded -->

```ruby
ActiveSanction.configure { |c| c.storage_dir = "/srv/lists" }             # the default, elsewhere
ActiveSanction.configure { |c| c.storage = ActiveSanction::Storage::ActiveRecord.new }
```

## `Storage::FileSystem`: gzipped JSON, nothing to provision

The default. `zlib` and `json` are stdlib, so persisting a full SDN sync
costs a directory:

<!-- sample: illustrative -- would touch the real filesystem -->

```ruby
store = ActiveSanction::Storage::FileSystem.new                # ~/.active_sanction
store = ActiveSanction::Storage::FileSystem.new(root: "/srv/lists")
```

Each source gets a `meta.json` sidecar and one gzipped list, named after the
content's own checksum rather than a fixed filename — that is what makes a
sync killed mid-write leave the previous snapshot intact rather than a file
that is neither the old list nor the new one. `storage_dir` is deliberately
separate from `cache_dir`: everything in the cache can be re-fetched, a
stored snapshot cannot, because publishers overwrite their files in place.

A corrupt or truncated read raises rather than returning something that
looks like a list with fewer names in it:

<!-- sample: illustrative -- needs a store with a corrupt snapshot on disk -->

```ruby
store.read_snapshot(:ofac_sdn)   # => raises Storage::CorruptSnapshot, naming the directory to delete
```

Many readers and one writer, across processes, is the arrangement it is
built for — a scheduled sync replacing a list while web workers screen
against it. Two processes syncing the *same* source at once is not
supported.

## `Storage::ActiveRecord`: your own database, plus a prefilter

Optional in the strong sense — ActiveRecord is not a dependency of this gem,
and the adapter loads only where ActiveRecord is already loaded.

```console
$ rails generate active_sanction:install
$ rails db:migrate
```

<!-- sample: illustrative -- needs ActiveRecord loaded and migrated -->

```ruby
store = ActiveSanction::Storage::ActiveRecord.new
```

What it buys over the filesystem adapter is the prefilter: an indexed
equality probe narrows a query to a handful of candidates before anything is
loaded into Ruby.

<!-- sample: illustrative -- needs the ActiveRecord adapter migrated and synced -->

```ruby
ActiveSanction::Storage::ActiveRecord::Row::Name.matching("Aiman al-Zawahiri").pluck(:entity_id)
```

The schema is public API here, unlike the filesystem layout — five tables,
`active_sanction_snapshots` and `active_sanction_entities` with `_names`,
`_addresses` and `_identifiers` hanging off them. A write is one transaction
with batched `insert_all`, so a sync that dies partway rolls back to the list
that was there before it rather than leaving a half-updated one to screen
against.

## `Storage::Memory`: nothing to own, a full download every boot

<!-- sample: runnable -->

```ruby
store = ActiveSanction::Storage::Memory.new
```

Use it for a process that syncs and screens without wanting to own a
directory — a job, a CI run, a container with no volume. It pays a full
download on every boot and nothing else; there is no partial-write case to
worry about, because there is nothing to interrupt.

It also holds an imported bundle you want `verified?` to survive on, since a
snapshot's verified flag does not survive being rewritten into a store's own
gzipped JSON or its own table:

<!-- sample: illustrative -- needs a real signed bundle file and a matching key pair -->

```ruby
snapshot = ActiveSanction.import("ofac_sdn.asb", verify_with: public_key)
client = ActiveSanction::Client.new(storage: ActiveSanction::Storage::Memory.new)
client.storage.write_snapshot(snapshot)
client.screen(name: "Vladimir Putin").first.verified?   # => true
```

## Writing your own

Five methods are the whole interface:

<!-- sample: illustrative -- the interface, not a runnable sequence; store and snapshot are placeholders -->

```ruby
store.write_snapshot(snapshot)
store.read_snapshot(source)      # => Snapshot, or nil if it was never synced
store.fetch_snapshot(source)     # => Snapshot, or raises Storage::MissingSnapshot
store.snapshot_meta(source)      # => fetched_at, checksum, record_count — without reading the list
store.each_entity(sources: nil, &block)   # an Enumerator; reads one list at a time
```

Hold to two rules that are checked by the conformance group below, not left
to good judgment: a source nobody has synced reads back as `nil`, never as
an empty snapshot — "never fetched" and "nobody on this list" are different
states, and no sanctions list has ever meant the second. And nothing partial
is ever returned: re-derive the checksum on read and raise
`Storage::CorruptSnapshot` rather than hand back a snapshot quietly missing
records.

Every adapter — including the two shipped here — is held to one shared
example group:

<!-- sample: illustrative -- needs the real spec suite's shared example group loaded -->

```ruby
RSpec.describe MyCompany::S3Store do
  it_behaves_like "a storage adapter" do
    def build_store = described_class.new(bucket: "sanctions-test")
  end
end
```

It checks the ways a store loses records quietly — returning an empty
snapshot for a source nobody synced, dropping a third of the entities on the
way back, reordering them, accumulating two writes instead of replacing one
— none of which raise on their own, and all of which produce something that
looks like a sanctions list while reporting a customer clean who is not. It
deliberately says nothing about durability, concurrency or performance,
which differ by adapter and belong in that adapter's own spec.

`spec/support/shared_examples/storage_adapter.rb` is the group;
`spec/active_sanction/storage/conformance_spec.rb` holds it to being able to
fail, one rule at a time, against a deliberately broken adapter.
