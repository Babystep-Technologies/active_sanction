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
[`.ruby-version`](.ruby-version), and CI builds every series from the floor up.

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
