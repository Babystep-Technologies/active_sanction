# Contributing to ActiveSanction

Bug reports and pull requests are welcome at
<https://github.com/Babystep-Technologies/active_sanction>. This file is the
whole of what a contributor needs: what is worth working on, how to get from a
clone to a green suite, what the checks are, and how to sign a commit.

## What is open, and what is not

**The gem is complete on its own, and stays that way.** Every public sanctions
list it supports is fetchable, parseable and screenable with the gem alone,
forever, with no account and no key. The entity model, the fetch layer, every
source adapter, storage, the whole matching engine with its weights and
dictionaries, sync, diff, rescreening and the bundle format are all in this
repository, and they are the whole of what we run.

**A commercial hosted service exists, and what it sells is operations rather
than capability** — data kept fresh through upstream breakage, an availability
guarantee, continuous monitoring of a book of business, and a retained audit
trail. Nothing is withheld from the gem to make it more attractive.

The rule that settles scope questions: **anything that runs on a user's machine
against public data belongs in the gem; anything that requires somebody to
operate infrastructure belongs in the service.** A contribution is never
declined for being too useful, and no contribution is relicensed — see
[Sign your work](#sign-your-work), which is a sign-off rather than a
contributor licence agreement precisely because there is no relicensing right
to reserve.

## Where documentation goes

Reference and explanation belong on [the documentation site](https://babystep-technologies.github.io/active_sanction/); the README links to them rather than restating them. The README stays the narrative and the quickstart — what stays there, what stays disclaimer, what a reader needs to evaluate the library without leaving GitHub — and everything else that the site has taken ownership of leaves the README as a one-line pointer. If a change touches a section the site already covers, update the site page rather than growing the README back; if a fact would then exist in full in both places, that is a bug, not a style choice.

## The two most useful contributions

**A new list.** [`docs/adding_a_source.md`](docs/adding_a_source.md) is written
for exactly that, and the shared conformance group means an adapter written
outside this repository is held to the same checklist the shipped ones are.
The documentation site has a shorter
[field guide](https://babystep-technologies.github.io/active_sanction/how-to/adding-a-source/)
version, pointing into the file's sections rather than restating them. A
source can also be registered from your own application without touching this
gem at all, which is the point of the extension seam — open an issue first if
you would rather have it shipped here, so two people do not write the same
adapter.

**A name this version gets wrong.** A missed record or a false alert belongs in
[`benchmark/fixtures/labeled_set.yml`](benchmark/fixtures/labeled_set.yml)
with what it is supposed to find, whether or not the matching is changed in the
same pull request. A case nobody has written down is a case that regresses
silently, and the accuracy report is the only place a two-point weight change
becomes visible.

## From a clone to a green suite

Ruby 3.1 or newer. The version this gem is developed on is in
[`.ruby-version`](.ruby-version), and CI builds every series from the floor
up — 3.1, 3.2, 3.3, 3.4 and 4.0 — plus `ruby-head`, which is allowed to fail:
a change upstream is news rather than a broken build, so that job reports in
the checks list and leaves the badge green.
[`spec/supported_rubies_spec.rb`](spec/supported_rubies_spec.rb) reads that
matrix, `.ruby-version`, the gemspec's `required_ruby_version` and RuboCop's
`TargetRubyVersion`, and fails when they stop agreeing — the version a
change is written on being the one version no build ever ran is how that
drift stays invisible
([#80](https://github.com/Babystep-Technologies/active_sanction/issues/80)).

    $ git clone https://github.com/Babystep-Technologies/active_sanction.git
    $ cd active_sanction
    $ bin/setup                # bundle install
    $ bundle exec rake         # specs, RuboCop, Sorbet -- all three must pass

`bin/console` gives a prompt with the library loaded. Nothing else is required:
the suite is hermetic, so a green run needs no network, no credentials and no
synced data.

## The three checks

`bundle exec rake` runs RSpec, then RuboCop, then `srb tc`. CI runs the same
three on every Ruby the gem supports, plus `ruby-head`, which is allowed to
fail.

**The suite never reaches the internet.** `spec_helper.rb` calls
`WebMock.disable_net_connect!`, so an un-stubbed HTTP call raises rather than
quietly fetching a government file. Parser specs run against committed
fixtures. A spec that genuinely needs a real endpoint is tagged `:live`, is
excluded from the default run, and is never run in CI — a red build should mean
our code broke, not that a source went down.

    $ bundle exec rspec --tag live

**Every file in `lib/` is `# typed: strict`,** and new files are born that way.
A signature written beside the code costs a line; one retrofitted a milestone
later costs an afternoon of reading the code back.

**If you change the normalizer, the index, the similarity algorithms, the
scorer or the weights,** run the accuracy benchmark and commit the report it
rewrites:

    $ bundle exec rake benchmark:accuracy

[`benchmark/results/accuracy.md`](benchmark/results/accuracy.md) is committed
for the same reason the source baselines are: a diff there is a change in what
this library finds, which is otherwise invisible in a code review.

## Static typing

Every file in `lib/` is `# typed: strict`, and new files are born that way: a
signature written beside the code costs a line, and one retrofitted a
milestone later costs an afternoon of reading the code back.

    $ bundle exec srb tc      # or `bundle exec rake`, which runs it last

`sorbet-runtime` is a dependency of the gem, because the signatures are
inline `sig` blocks and inline `sig` blocks are ordinary method calls. It is
pure Ruby and compiles nothing, so it clears the same bar the gemspec sets
for Nokogiri. The static half — `sorbet` and `tapioca` — is in the Gemfile
and never reaches an application.

**What the types are for, and where they deliberately stop.** The canonical
model is declared: `Entity` states that `dates_of_birth` is an array of
`PartialDate`, so an adapter handing over the string a publisher wrote is a
type error rather than a bug found three layers downstream. The runtime half
of a signature is shallow — it sees the Array and not what is in it — so the
adapter conformance group goes on asserting the element types per fixture,
which is what covers an adapter written outside this repository. Everything
a publisher wrote is `T.untyped` on the way in, because the value objects
already coerce it and raise `InvalidArgument` — an `ArgumentError`, so the
code around this library keeps its existing rescue — with messages written
for whoever has to fix the record, and a type error would say less. Three
places are `T.untyped` on purpose and say why in a comment where they sit:
the source registry (duck-typed on `.key` and `.new`, which is what makes a
bank's internal watchlist a first-class source), `XmlRecords::Backends`
(same, for a backend registered from outside), and `Snapshot#entities` (the
storage conformance group builds a snapshot of half-deserialized hashes on
purpose, to prove it catches a store that hands them back).

A host that wants none of it can turn every check off before requiring the
gem, which is supported and tested:

```ruby
T::Configuration.default_checked_level = :never
require "active_sanction"
```

**Consumers who typecheck their own code** need nothing from us but the gem:

    $ bundle exec tapioca gem active_sanction

reads the inline signatures through `sorbet-runtime` and writes an RBI that
says what this version actually declares. No `rbi/active_sanction.rbi` is
shipped, deliberately — a hand-maintained copy of the signatures would be a
second source of truth, and a signature that lies is worse than none.

The RBIs under `sorbet/` are the checker's own working files — generated
definitions for the gems `lib/` reaches, plus one hand-written shim for the
Rails generator surface — and are excluded from the packaged gem. Regenerate
one with `bin/tapioca gem <name>`.

## Benchmarks and the upstream canary

`benchmark/` holds measurements that answer a design question rather than
pass or fail, so they are not part of `rake`:

    $ bundle exec rake benchmark:similarity          # the matching algorithms
    $ bundle exec rake benchmark:index               # index build, memory, query latency
    $ bundle exec rake benchmark:scorer              # scoring latency, and what a threshold buys
    $ bundle exec rake benchmark:accuracy            # precision, recall and F1 against the labeled set
    $ bundle exec rake benchmark:latency             # what a whole screening call costs
    $ bundle exec rake benchmark:rescreen            # applying a diff to a book, against the naive full rescreen
    $ RUBYOPT=--yjit bundle exec rake benchmark:similarity

The labeled set behind `benchmark:accuracy` is
[`benchmark/fixtures/labeled_set.yml`](benchmark/fixtures/labeled_set.yml):
87 queries against the real published records the source fixtures hold, each
one labeled with what it is supposed to find and what kind of damage it is
doing to the name. Both harnesses hide the labeled records inside a
synthetic corpus the size and shape of the real lists; run either against a
real synced corpus instead with `BACKGROUND=store bundle exec rake
benchmark:accuracy`.

**The upstream canary** is a scheduled workflow that fetches every list from
its real publisher on weekdays and compares what it measures against the
baselines committed under [`.github/baselines`](.github/baselines)
([#69](https://github.com/Babystep-Technologies/active_sanction/issues/69)),
filing an issue when a government has changed something the gem must adapt
to. It never runs as part of CI and never turns the CI badge red — a red
build should mean our code broke, not that a source went down.
[Detect when a publisher changes its format](https://babystep-technologies.github.io/active_sanction/how-to/detecting-format-drift/#the-upstream-canary-the-same-idea-run-on-a-schedule-against-real-endpoints)
has the commands and the full mechanics; when adding a new source, commit
its baseline in the same pull request as the adapter.

## API documentation

    $ bundle exec rake doc          # renders doc/
    $ bundle exec yard stats --list-undoc

Every public module, class, method and attribute in `lib/` carries a
comment, and `rake doc` renders them. Types are not written twice:
`yard-sorbet` reads the inline `sig` blocks and turns them into `@param` and
`@return`, so the signature the checker reads is the signature the
documentation shows. What is deliberately left undocumented is internal
constants — column names, regex fragments, the `MEMBERS` lists the value
objects serialize through — named for the code that reads them, where a
comment restating the name would be noise.

## Releasing

`bundle exec rake install` installs the gem locally. A release is: bump
`VERSION` in [`lib/active_sanction/version.rb`](lib/active_sanction/version.rb),
move the `Unreleased` section of [`CHANGELOG.md`](CHANGELOG.md) under the new
version with its date, then `bundle exec rake release`, which tags, pushes
and publishes to [rubygems.org](https://rubygems.org).

`MATCHER_VERSION` in the same file is bumped on a different occasion and for
a different reason — whenever a change to the normalizer, the index, the
similarity algorithms or the scorer could move a score — because an auditor
asking "would this screening come out the same today?" needs the answer to
that specific question rather than a release number that also answers
several others.

## Sign your work

Contributions are accepted under the
[Developer Certificate of Origin](https://developercertificate.org) 1.1. It is
a statement that you wrote the patch or otherwise have the right to submit it
under this project's licence, and it is made by adding one trailer to the
commit message:

    Signed-off-by: Your Name <your.email@example.com>

Git writes it for you:

    $ git commit -s

The name and address must be real and must match the commit author, because the
sign-off is what records who certified the contribution. Pseudonyms are fine;
anonymous contributions are not.

**A pull request whose commits are not all signed off fails CI,** and the
failing job prints the fix. To sign off work you have already committed:

    $ git rebase --signoff origin/main
    $ git push --force-with-lease

**There is no contributor licence agreement.** The commercial advantage here is
operational rather than code secrecy, so there is no need to reserve a right to
relicense what you send. The DCO gives clean provenance for every contribution
and costs a contributor one flag.

## Opening a pull request

One change per pull request, with a message that says what moved and why.
Describe the reasoning in the commit message rather than only in the pull
request body — a commit message survives in `git log` after the forge that
hosted the review has changed.

Specs come with the change rather than after it. A bug fix arrives with the
spec that would have caught the bug.

## Security-relevant bugs

**Do not open a public issue for one.** A screening library reporting a false
negative is a security-relevant bug: somebody may be relying on an empty result
to clear a payment. [`SECURITY.md`](SECURITY.md) says what is in scope, how to
report privately, and what response to expect.

## The name

**The code licence grants no rights in the name.** ActiveSanction, the project
name and any associated branding are not licensed by
[the MIT licence](LICENSE.txt), which covers the software and nothing else.
A fork, a derivative work or a plugin may say that it is built on, compatible
with, or derived from ActiveSanction; it may not use the name in a way that
suggests it is this project or is endorsed by it. Anyone can produce and
distribute a sanctions snapshot bundle in [the published format](docs/bundle_format.md)
under the same rule.

This is the ordinary position under MIT, which grants no trademark rights
either way. It is written down only so nobody has to guess.

## Code of conduct

This project is intended to be a safe, welcoming space for collaboration.
Everyone interacting with it is expected to follow the
[code of conduct](CODE_OF_CONDUCT.md).
