---
title: Handle errors
description: The error hierarchy, which failures are retryable, and what to log.
sidebar:
  order: 9
---

Rescue this library's failures the way you rescue everything else in a
request path: by asking what to do about them, not by matching on a message
string.

## Rescue the marker, branch on `retryable?`

<!-- sample: illustrative -- params and render are a Rails controller's, needs a synced store -->

```ruby
begin
  ActiveSanction.screen(name: params[:name], threshold: params[:threshold])
rescue ActiveSanction::QueryError => e
  render json: { error: e.message }, status: :unprocessable_entity   # the caller's fault
rescue ActiveSanction::Error => e
  raise unless e.retryable?

  ResyncLater.enqueue(e.source_id)                                   # the publisher's fault, try again later
end
```

`rescue ActiveSanction::Error` catches everything this library raises from a
public method. `retryable?` answers the one question a caller embedding this
in a request path actually needs answered before deciding whether to back
off:

| Raised by | `retryable?` |
|---|---|
| 503, 500, 429, 408 from a publisher | `true` |
| A timeout, a refused connection, a reset | `true` |
| 403, 404, a redirect loop, a TLS failure | `false` |
| A parse error, a corrupt snapshot, a bad query | `false` |
| Anything unclassified | `false` — a failure nobody has looked at yet is one to look at, not one to hammer with retries |

`ConfigurationError` answers `false` unconditionally — nothing about waiting
changes what an initializer got wrong.

## The hierarchy

```
ActiveSanction::Error              the marker; rescue this
├── ConfigurationError             this installation is set up wrong; never retry
├── SourceError                    something went wrong with one list
│   ├── FetchError                 the bytes could not be obtained
│   ├── ParseError                 the bytes could not be read
│   └── IntegrityError             the bytes are not what they claim to be
├── StorageError                   the store could not answer
├── UnsupportedError               this object cannot do that
├── InvalidArgument                a public method was called wrongly
│   └── QueryError                 ...specifically, with an unusable query
└── MissingKey                     a field or column that does not exist
```

It is public API within a major version: an error does not move to a
different parent, and an attribute is not removed. New subclasses can appear
under an existing parent — that is what keeps `rescue ActiveSanction::FetchError`
working the day a new transport failure earns a name of its own — so a
`case` over error classes wants an `else`.

**Two members are also a Ruby built-in, by necessity.** `InvalidArgument` is
an `::ArgumentError` and `MissingKey` is a `::KeyError`, because Ruby only
gives you one superclass and both mistakes already had a standard-library
class before this gem existed. Both still answer `rescue ActiveSanction::Error`
and both answer `is_a?`; the one consequence is that `ActiveSanction::Error`
itself cannot be raised — raise the specific member that names the failure.

**Nothing from underneath reaches you.** A malformed CSV row, a truncated
gzip member, an XML document that turned out to be an HTML error page, a TLS
certificate that does not verify — each is translated at the boundary it
happens on. Rescuing this library's errors never requires knowing which XML
backend is configured, or that a sync uses `net/http` at all.

## What to log

Every error carries structured attributes rather than only a message —
`to_h` renders the lot for a log line or a job record that has to outlive
the process:

<!-- sample: illustrative -- error comes from a real rescued failure -->

```ruby
error.to_h
# => { error: "ActiveSanction::FetchError", message: "https://... returned 503",
#      source_id: :ofac_sdn, status: 503, retryable: true }
```

Log the hash, not just `error.message`. `source_id` names which list was
involved even when the layer that raised did not know — the HTTP client
sees a URL, not a source key, so it is stamped on as the error leaves the
adapter. `status` carries the HTTP status where a server produced one.

A `ParseError` additionally carries `line`, `record` and `offset` —
whichever of them the parser could produce — appended to its own message, so
a log line that kept nothing but the message still says where to look in a
25 MB file. All three are `nil` where the parser genuinely cannot say; an
error that cannot point at a location does not point at the wrong one.

## Where this shows up in the guides you'll actually use

- [Sync on a schedule](/active_sanction/how-to/syncing-on-a-schedule/) —
  `sync!` catches every source's `ActiveSanction::Error` internally and
  reports it per source, so one failing publisher does not stop the others.
- [Add a sanctions source](/active_sanction/how-to/adding-a-source/) — an
  adapter's `#parse` should raise `ParseError` (or a subclass in the
  hierarchy) for a payload it can see is wrong, and never a bare
  `RuntimeError`, an `ArgumentError`, or an exception class belonging to
  whatever library it happens to parse with.
