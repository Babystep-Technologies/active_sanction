# Adapter rules

The rules an agent working on a source adapter is held to, stated as rules.
**The reasoning for every one of them is in
[`docs/adding_a_source.md`](../../docs/adding_a_source.md)** — this file is the
checklist form, and it is deliberately not a second copy of the argument. When a
rule here does not obviously apply to the list in front of you, read the section
it links to before deciding it does not.

Both `adding-a-source` and `repairing-a-source` read this file. It is one copy
because two copies of a procedure means one of them is wrong within a release.

## The canonical model

[`docs/adding_a_source.md` §5](../../docs/adding_a_source.md#5-map-the-publishers-fields-onto-the-canonical-model)

1. **Every date is a `PartialDate`, never the string the publisher wrote.** Use
   `PartialDate.parse`. It reads ISO, worded forms, approximations and spans,
   and returns `nil` on what it cannot read. A publisher writing `14/03/2019` is
   outside that vocabulary: convert first, and never store the string.
2. **Never collapse a year to January 1st.** A year-only date of birth is a
   year-only date of birth.
3. **Every type is one of `:individual`, `:organization`, `:vessel`,
   `:aircraft`.** Map the publisher's vocabulary onto the four. An unrecognised
   value warns and defaults to `:organization`; it never drops the record.
4. **A record with no name is not a record.** Return `nil` for it and warn,
   naming the publisher's reference.
5. **Never drop the publisher's free text.** It goes into `Entity#remarks`
   verbatim. Fields the canonical model has no home for are appended with
   `Sources::Remarks.build`, behind the shared `[source fields]` marker — never
   a convention invented for one source. Anything reading a remark for what the
   publisher actually wrote uses `Sources::Base.published_remarks` to strip what
   adapters appended.
6. **One publisher field may mean two things.** The UN's `QUALITY` grades an
   alias under one record shape and names the alias kind under another; Canada's
   date element is a date of birth or a ship's build date depending on the
   record. Map it per record shape and say so in the class comment. This is the
   bug that produces a list which parses cleanly and is wrong.
7. **Do not normalize names in an adapter.** Case, punctuation, particles and
   transliteration are the matcher's job, and `Normalizer` deliberately
   *preserves* `bin`, `ibn`, `bint`, `abu`, `abd`, `al`, `el`, `van`, `von`,
   `de` and the rest
   ([`lib/active_sanction/normalizer/dictionaries/particles.txt`](../../lib/active_sanction/normalizer/dictionaries/particles.txt)) —
   they look like noise to a stopword filter and are structural parts of real
   Arabic and Slavic names. An adapter that folds a name before storing it has
   destroyed what the matcher needed.

## Ids

[`docs/adding_a_source.md` §6](../../docs/adding_a_source.md#6-give-every-record-a-stable-id)

8. **An id is unique within a sync and identical on a second read of the same
   bytes.** The conformance group checks both.
9. **An id may never depend on** position in the file, iteration order, a
   counter, the wall clock, or anything outside the record's own bytes. An id
   that moves reports the whole list as removed and re-added, and a diff that
   says everything changed says nothing at all.
10. **Never derive an id from a field the publisher can revise** without also
    hashing enough of the record to make the revision visible. Where the
    publisher supplies no id, copy `CanadaSema::SourceRef`: hash the citation
    *and the name*, normalize case and whitespace and nothing else, join with a
    separator that cannot occur in the data, and treat the constants as
    versioned. Changing any of them re-ids every record of that source ever
    stored.
11. **Where the publisher does supply a reference, pass `source_ref:` and no
    `id:`.** The namespaced id is derived for you.

## Reporting what could not be read

[`docs/adding_a_source.md` §7](../../docs/adding_a_source.md#7-report-what-you-could-not-read)

12. **A row that could not be read is a `Parsers::Warning`, kept rather than
    raised.** One unbalanced quote must not cost the other 19,320 rows. Expose
    `#warnings` as the parser's warnings plus anything the adapter noticed
    itself, and give every warning a line number where one exists.
13. **A payload that is not the list raises `ParseError`.** Never rescue an
    empty payload into an empty array. No sanctions list has ever been published
    empty, so an empty payload is a failed download or an outage — never a day
    on which nobody is sanctioned.
14. **Nothing an adapter raises is a bare `RuntimeError`, an `ArgumentError`, or
    an exception belonging to a parsing library.** It is in the
    `ActiveSanction::Error` hierarchy, so a host rescuing `ActiveSanction::Error`
    catches it. `#parse` does not rescue `ActiveSanction::Error` at all.

## What never happens

15. **No autonomous fetching of a government endpoint.** OFAC 403s a non-browser
    user agent and several publishers block cloud IP ranges. Write down the
    `curl` a person should run and hand it to them. The same goes for
    `rake canary` and `rake canary:refresh`, which reach real publishers: name
    the command, do not run it.
16. **No inventing a record.** Every fixture row is a real published record,
    lifted verbatim from the real file. A transcribed corpus measures the
    transcription. If you have no real bytes, stop and ask for them.
17. **No widening the public surface to make something convenient.**
    [`docs/api_stability.md`](../../docs/api_stability.md) enumerates what is
    public, and [`spec/api_surface_spec.rb`](../../spec/api_surface_spec.rb)
    fails the build in both directions. A new adapter's class **is** public and
    is added to the list under *Sources, and the toolkits an adapter is written
    with*. Its `Record` class, its column constants and its `MEMBERS` lists are
    **not**, and are marked `@api private` — those track what a government
    publishes, and a publisher changing a column must not need a major version
    here.
18. **No second copy of a procedure.** If something belongs in
    `docs/adding_a_source.md`, put it there and link to it.

## The gates

19. **`bundle exec rake` is the build**: RSpec, then RuboCop, then `srb tc`.
    All three must pass. Run it before saying the work is done.
20. **New files in `lib/` are born `# typed: strict`**: `extend T::Sig`, a `sig`
    on every method, `T.let` on every instance variable and constant, and
    `override.` on `#parse`.
21. **Every public module, class, method and attribute in `lib/` carries a
    comment.** Types are not written twice — `yard-sorbet` reads the `sig`.
22. **The conformance group is not optional.**
    `it_behaves_like "a sanction source", fixture: "<key>/<file>"` in the
    adapter's spec, from
    [`lib/active_sanction/testing/sanction_source.rb`](../../lib/active_sanction/testing/sanction_source.rb),
    which reaches the suite through `require "active_sanction/testing"` and
    ships, so an adapter outside this repository runs the same group.
    It is the floor and not the ceiling: it does not know which of your
    fixture's records is a vessel, so write a spec that knows what is in the
    fixture too.
23. **The suite never reaches the internet.** WebMock blocks outbound
    connections. A spec that genuinely needs a live endpoint is tagged `:live`
    and excluded from the default run.
24. **If the change touches the normalizer, the index, the similarity
    algorithms, the scorer or the weights,** run
    `bundle exec rake benchmark:accuracy` and commit the report it rewrites at
    `benchmark/results/accuracy.md`, and bump `MATCHER_VERSION` in
    [`lib/active_sanction/version.rb`](../../lib/active_sanction/version.rb). An
    adapter alone touches none of these.
25. **Sign every commit off**: `git commit -s`, per
    [`CONTRIBUTING.md`](../../CONTRIBUTING.md). A pull request whose commits are
    not all signed off fails CI. The name and address must be real and must
    match the author.
26. **One change per pull request**, with the reasoning in the commit message
    rather than only in the pull request body.
27. **Add a `CHANGELOG.md` entry** under `Unreleased`.
