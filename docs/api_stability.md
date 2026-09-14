# API stability

What this gem promises not to break, and what it reserves the right to change
in any release.

**The public surface is enumerated below, not inferred.** A constant being
reachable does not make it public; over 500 of them are reachable and 142 are
promised. Everything else is marked `@api private` in the source, is hidden
from the rendered documentation, and may be renamed, moved or deleted in a
patch release without a note anywhere. If you need something that is not on
this list, open an issue rather than reaching for it — the whole point of
writing the boundary down is that widening it is a conversation rather than an
accident.

[`spec/api_surface_spec.rb`](../spec/api_surface_spec.rb) reads this file and
fails when the code and this list stop agreeing, in either direction. A new
public constant that nobody added here fails the suite; a name here that no
longer exists fails it too.

## Versioning

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**The first release is 1.0.0, and there was no 0.x.** A leading zero says a
minor version may remove what the last one promised, and that is not what this
library is doing: the surface below was inventoried before it shipped and
`spec/api_surface_spec.rb` fails the build in both directions. Publishing an
enumerated, test-enforced surface under a number that means *this may move* is
a contradiction, so the number matches the inventory instead.

**So the deprecation path below is in force from 1.0.0.** Nothing enumerated
here is removed without a warning first, and a breaking change waits for 2.0.0.
A patch release never breaks anything.

Two version numbers move independently, and only one of them is what this
document is about:

| | |
|---|---|
| `ActiveSanction::VERSION` | The gem. This document governs it. |
| `ActiveSanction::MATCHER_VERSION` | The matching pipeline. Bumped whenever a change could move a score. |

`MATCHER_VERSION` is not a compatibility promise and never gates a rescue or a
version constraint. It is stamped onto every `MatchResult` so that an auditor
asking *would this screening have come out the same?* has an answer that a gem
version cannot give them — a release that only adds a source adapter moves one
of these numbers and not the other.

## Deprecation

Nothing on the enumerated list is removed without a warning first.

1. The release that deprecates something keeps it working and warns.
2. It goes on working for **one full minor release** after that one.
3. It may be removed in the minor after that.

So something deprecated in `1.4.0` works through all of `1.5.x` and may be
removed in `1.6.0`. An application that upgrades one minor at a time always
meets the warning at least one release before the breakage.

`ActiveSanction::Deprecation.removal_for` computes that date rather than
leaving it to be remembered, and the warning says it out loud:

```
active_sanction: ActiveSanction.old_thing is deprecated since 1.4.0 and will
be removed in 1.6.0. Use ActiveSanction.new_thing instead.
Called from app/jobs/screen_job.rb:31
```

**Warnings go through Ruby's own switch.** They are `Kernel#warn` with
`category: :deprecated`, so `Warning[:deprecated] = false` silences them —
the same line that silences every other deprecation in a Ruby process, rather
than a setting of ours that has to be discovered. Ruby's default is off outside
verbose mode, which is kept: the audience for a deprecation is a developer
running `ruby -w`, a suite, or a CI build.

Each call site warns once, however many times it is reached. A deprecated
method called while looping over 19,000 records writes one line, not 19,000.

Every deprecation also gets a `CHANGELOG.md` entry under `Deprecated` in the
release that introduces it, and a second under `Removed` in the release that
carries it out.

## The extension points carry the strongest guarantee

Three of these are load-bearing for code that is not in this repository:

```
ActiveSanction::Sources::Base
ActiveSanction::Storage::Base
ActiveSanction::ValidatorStore
```

Breaking one of them forks every downstream adapter at once — a bank's internal
watchlist, a store backed by somebody's own database — and those authors are
not reading this repository's release notes. So the required methods of each,
their arguments and what they must return do not change within a major version,
and the shared conformance groups
([`lib/active_sanction/testing/sanction_source.rb`](../lib/active_sanction/testing/sanction_source.rb),
[`lib/active_sanction/testing/storage_adapter.rb`](../lib/active_sanction/testing/storage_adapter.rb))
are the executable statement of what they require. An adapter that passes them
today passes them for the life of the major version — and **they ship**, so an
adapter outside this repository can run them: `require "active_sanction/testing"`.

New *optional* hooks may be added — a method with a default implementation on
the base class is not a break, because an adapter that does not define it goes
on working.

## Contracts that are not constants

Five promises here are about behaviour rather than about a name, and none of
them is enforceable by the surface spec.

**The error hierarchy.** Within a major version an error does not move to a
different parent, and no attribute is removed from one. New subclasses may
appear under an existing parent — that is what keeps `rescue FetchError`
working when a new transport failure earns a name of its own — so a `case` over
error classes wants an `else`. `retryable?`, `source_id`, `status` and `to_h`
are part of the promise; the wording of a message is not, and was never
something to match on.

**The bundle format** is specified in [`bundle_format.md`](bundle_format.md),
which is the contract — not the Ruby constants that implement it, which are
private. A bundle carries its own format version, and this gem reads every
version in its declared readable range. The format is open and unencumbered:
anyone may produce or consume one, in any language.

**The stored snapshot format** carries a schema version for the same reason. A
store written against one schema version keeps being readable; the file layout
underneath a shipped store is not public and may change.

**The instrumentation events.** `ActiveSanction::Instrumentation::EVENTS`
names the six, and each one's payload keys are promised the same way a method
signature is: within a major version a key is not removed, renamed, or made to
mean something else, and a dashboard written against one keeps working. Keys
may be **added** to an event — that is how a new measurement ships without a
major version — so a subscriber reads the keys it knows and ignores the rest,
and must not assume the set is closed.

Every event carries `name`, `started_at` and `duration`, plus the keys below.
`error` is present only when the stage raised, in which case the keys it had
not reached yet are **absent rather than zero**.

| Event | Payload keys |
|---|---|
| `:fetch` | `source`, `key`, `url`, `forced`, `conditional`, `status`, `not_modified`, `bytes` |
| `:parse` | `source`, `bytes`, `records`, `warnings` |
| `:store` | `source`, `snapshot_id`, `entities`, `store`, `imported` (on an import only) |
| `:"index.build"` | `store`, `sources`, `snapshots`, `entities`, `names`, `keys`, `postings`, `bytes` |
| `:screen` | `candidates`, `scored`, `results`, `threshold`, `limit`, `sources`, `snapshots` |
| `:sync` | `sources`, `forced`, `concurrency`, `outcomes`, `updated`, `unchanged`, `failed`, `records` |

Two things about them are contracts rather than incidental. **A `:fetch` event
is one HTTP round trip** — a file served out of the payload cache after a 304
costs no request and emits nothing, and a source re-fetching one because its
cache was empty emits a second event rather than amending the first. And
**`bytes` on `:"index.build"` is an estimate**, documented as one on
`Index#profile`; it is good to within a factor a dashboard cares about and is
not a heap measurement.

**A `MatchResult` is reproducible.** The snapshot checksum, matcher version,
weights and query it stamps are what let a screening decision be re-derived
years later. Fields may be added to that stamp; the meaning of an existing one
does not change under it.

## What is deliberately not public

Named here because their absence from the list is a decision rather than an
oversight:

- **The instrumenter contract's other half.** A subscriber is anything
  answering `#call(event)`, and that is public. `Instrumentation.instrument`
  and `.emit`, which the library's own stages call, are not: where an event is
  emitted from is an implementation detail of the stage, and a host that
  wanted to emit one of these names itself would be publishing a measurement
  of something this library did not do.
- **The matching internals** — `Index`, `Similarity`, `Phonetics`, and the
  scorer's `Adjustments` and `NameScore`. These are where accuracy work
  happens, and accuracy work that had to preserve a signature would stop.
  `Scorer`, `Scorer::Weights` and `Normalizer` are public because a host tunes
  and calls them; the machinery underneath them is not.
- **`HttpClient`, `Fetcher` and `PayloadCache`** as classes. Their *errors* are
  public, because a host rescues those, but nothing else about how bytes are
  obtained is. A host that wants to control fetching does it through
  `Configuration`.
- **Every `MEMBERS` list.** They are the serialization order of a value object,
  read by `to_h` and by the snapshot checksum. They look like an enumeration of
  a record's fields and they are not one.
- **The per-adapter `Record` classes and column constants.** Nothing under
  `Sources::OfacSdn::Record` or its siblings is public: those track what a
  government publishes, and a publisher changing a column is exactly the change
  that must not require a major version here.
- **The parser toolkits' readers, backends and workbooks.** The toolkits
  themselves are public — they are how an adapter is written — but the classes
  that do the reading underneath them are not.
- **Anything under `spec/`, `benchmark/`, `canary/` or `bin/`.** None of it
  ships in the gem. The two conformance groups used to be the exception in
  spirit — expected to be run by adapter authors who had no way to get them —
  and they are now under `lib/active_sanction/testing/` and public, which is
  what the section above is about.

## The enumerated public surface

Every name below is promised under the rules above. Nothing else is.

### The entry point, and configuration

```
ActiveSanction
ActiveSanction::VERSION
ActiveSanction::MATCHER_VERSION
ActiveSanction::Client
ActiveSanction::Client::CAPABILITIES
ActiveSanction::Configuration
ActiveSanction::Deprecation
ActiveSanction::Configuration::DEFAULT_CACHE_DIRNAME
ActiveSanction::Configuration::DEFAULT_CANDIDATE_LIMIT
ActiveSanction::Configuration::DEFAULT_DOCTOR_TOLERANCE
ActiveSanction::Configuration::DEFAULT_MAX_REDIRECTS
ActiveSanction::Configuration::DEFAULT_MAX_RETRIES
ActiveSanction::Configuration::DEFAULT_OPEN_TIMEOUT
ActiveSanction::Configuration::DEFAULT_READ_TIMEOUT
ActiveSanction::Configuration::DEFAULT_RETAIN_PAYLOADS
ActiveSanction::Configuration::DEFAULT_RETRY_BACKOFF
ActiveSanction::Configuration::DEFAULT_SCREENING_LIMIT
ActiveSanction::Configuration::DEFAULT_SCREENING_THRESHOLD
ActiveSanction::Configuration::DEFAULT_SOURCES
ActiveSanction::Configuration::DEFAULT_STALE_AFTER
ActiveSanction::Configuration::DEFAULT_STORAGE_DIRNAME
ActiveSanction::Configuration::DEFAULT_SYNC_CONCURRENCY
ActiveSanction::Configuration::DEFAULT_USER_AGENT
ActiveSanction::Configuration::DEFAULT_XML_BACKEND
```

### Instrumentation

```
ActiveSanction::Instrumentation
ActiveSanction::Instrumentation::EVENTS
ActiveSanction::Instrumentation::Event
ActiveSanction::Instrumentation::Notifications
ActiveSanction::Instrumentation::Notifications::NAMESPACE
```

### The canonical record

```
ActiveSanction::Entity
ActiveSanction::Entity::TYPES
ActiveSanction::Name
ActiveSanction::Name::KINDS
ActiveSanction::Name::QUALITIES
ActiveSanction::Name::SCRIPTS
ActiveSanction::PartialDate
ActiveSanction::PartialDate::PRECISIONS
ActiveSanction::Address
ActiveSanction::Identifier
ActiveSanction::Identifier::KINDS
ActiveSanction::Snapshot
ActiveSanction::Subject
```

### Screening

```
ActiveSanction::Matcher
ActiveSanction::Query
ActiveSanction::MatchResult
ActiveSanction::Normalizer
ActiveSanction::Normalizer::Form
ActiveSanction::Normalizer::Dictionary
ActiveSanction::Scorer
ActiveSanction::Scorer::Subject
ActiveSanction::Scorer::Result
ActiveSanction::Scorer::Reason
ActiveSanction::Scorer::Weights
ActiveSanction::Scorer::Weights::DEFAULTS
ActiveSanction::Country
```

### Sources, and the toolkits an adapter is written with

```
ActiveSanction::Sources
ActiveSanction::Sources::Base
ActiveSanction::Sources::Definition
ActiveSanction::Sources::Remarks
ActiveSanction::Sources::OfacSdn
ActiveSanction::Sources::OfacConsolidated
ActiveSanction::Sources::UnConsolidated
ActiveSanction::Sources::CanadaSema
ActiveSanction::Sources::EuFsf
ActiveSanction::Sources::UkSanctionsList
ActiveSanction::Sources::AustraliaDfat
ActiveSanction::Parsers
ActiveSanction::Parsers::DelimitedTable
ActiveSanction::Parsers::DelimitedTable::Row
ActiveSanction::Parsers::XmlRecords
ActiveSanction::Parsers::XmlRecords::Record
ActiveSanction::Parsers::Spreadsheet
ActiveSanction::Parsers::Spreadsheet::Row
ActiveSanction::Parsers::Join
ActiveSanction::Parsers::Warning
ActiveSanction::Parsers::ColumnShape
```

### Testing your own adapter

```
ActiveSanction::Testing
ActiveSanction::Testing::DEFAULT_FIXTURE_ROOT
ActiveSanction::Testing::StorageAdapterDefaults
```

Loaded by `require "active_sanction/testing"`, never by `require
"active_sanction"`. The two shared example group **names** — `"a sanction
source"` and `"a storage adapter"` — are public on the same terms as the
constants: a group is not renamed or removed within a major version, and the
options it accepts do not change meaning under an adapter that passes it
today.

New examples may be **added** to a group, and that is not a breaking change
even though it can turn a passing adapter red. It is the same promise the
extension points make read from the other side: what the group checks is what
`Sources::Base` and `Storage::Base` required all along, and an adapter that
fails a newly added example was always violating the contract — the group
merely started saying so. Additions land in a minor, with a `CHANGELOG.md`
entry naming them.

### Storage, and what a fetch remembers

```
ActiveSanction::Storage
ActiveSanction::Storage::Base
ActiveSanction::Storage::Memory
ActiveSanction::Storage::FileSystem
ActiveSanction::Storage::ActiveRecord
ActiveSanction::Storage::Meta
ActiveSanction::Validators
ActiveSanction::ValidatorStore
ActiveSanction::ValidatorStore::FileSystem
ActiveSanction::ValidatorStore::Memory
ActiveSanction::Snapshot::Bundle
ActiveSanction::Snapshot::Bundle::Header
```

### Operations

```
ActiveSanction::Sync
ActiveSanction::Sync::Report
ActiveSanction::Sync::Result
ActiveSanction::Sync::Result::STATUSES
ActiveSanction::Diff
ActiveSanction::Diff::Change
ActiveSanction::Rescreen
ActiveSanction::Rescreen::Alert
ActiveSanction::Rescreen::Alert::CHANGES
ActiveSanction::Doctor
ActiveSanction::Doctor::Report
ActiveSanction::Doctor::Diagnosis
ActiveSanction::Doctor::Diagnosis::STATUSES
ActiveSanction::Doctor::Finding
ActiveSanction::Doctor::Finding::SEVERITIES
ActiveSanction::Doctor::Checkup
ActiveSanction::Doctor::Profile
```

### The error hierarchy

```
ActiveSanction::Error
ActiveSanction::ConfigurationError
ActiveSanction::SourceError
ActiveSanction::FetchError
ActiveSanction::ParseError
ActiveSanction::IntegrityError
ActiveSanction::StorageError
ActiveSanction::UnsupportedError
ActiveSanction::InvalidArgument
ActiveSanction::QueryError
ActiveSanction::MissingKey
ActiveSanction::Sources::DeclarationError
ActiveSanction::Sources::DuplicateKey
ActiveSanction::Sources::MissingPayload
ActiveSanction::Sources::UnknownSource
ActiveSanction::Parsers::ParseError
ActiveSanction::Parsers::XmlRecords::MalformedDocument
ActiveSanction::Storage::CorruptSnapshot
ActiveSanction::Storage::MissingSnapshot
ActiveSanction::Storage::UnsupportedSchema
ActiveSanction::ValidatorStore::CorruptStore
ActiveSanction::Snapshot::ChecksumMismatch
ActiveSanction::Snapshot::Bundle::Corrupt
ActiveSanction::Snapshot::Bundle::UntrustedSignature
ActiveSanction::Snapshot::Bundle::Unsigned
ActiveSanction::Snapshot::Bundle::UnsupportedFormat
ActiveSanction::HttpClient::Error
ActiveSanction::HttpClient::ConnectionError
ActiveSanction::HttpClient::TimeoutError
ActiveSanction::HttpClient::ResponseError
ActiveSanction::HttpClient::InvalidRedirect
ActiveSanction::HttpClient::RedirectLoop
ActiveSanction::HttpClient::TooManyRedirects
ActiveSanction::PayloadCache::CorruptEntry
ActiveSanction::PayloadCache::ChecksumMismatch
ActiveSanction::PayloadCache::PayloadMissing
ActiveSanction::Matcher::NotSynced
ActiveSanction::Sync::Failed
```

### Also public, and not a constant

- Every **public instance and class method** on the types above, and their
  documented keyword arguments. A method that YARD marks `@api private` is not,
  wherever it happens to live.
- The **module-level shorthand** — `ActiveSanction.screen`, `.sync!`, `.diff`,
  `.rescreen`, `.doctor`, `.export`, `.import`, `.configure`, `.config`,
  `.client`, `.storage`, `.matcher`, `.with_configuration`, `.reset!`,
  `.reload!` — which is the documented quickstart and is the same API as
  `Client`.
- The **Rails install generator** as a command — `rails generate
  active_sanction:install` — and the schema of the migration it writes. The
  generator *class* is marked private, because nothing outside Rails' own
  generator lookup refers to it by name.
- The **source keys** — `:ofac_sdn`, `:ofac_consolidated`, `:un_consolidated`,
  `:canada_sema`, `:eu_fsf`, `:uk_sanctions_list`, `:australia_dfat`. A key
  names a list in configuration, in a snapshot and in a stored audit record, so
  it does not change once published.
