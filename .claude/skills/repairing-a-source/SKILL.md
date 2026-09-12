---
name: repairing-a-source
description: Fix an active_sanction source adapter after a publisher changed its file: work a canary drift issue, decide whether it is a parse break or a change of meaning, fix it, re-capture the fixture and refresh the committed baseline. Use when the canary opened an issue, a source drifted, a fill rate moved, or a list stopped parsing.
user-invocable: true
---

# Repairing a sanctions source

The upstream canary fetches every registered list on weekdays, parses it, and
holds what it measures against `.github/baselines/<key>.json`. When a number
moves outside its tolerance it opens one issue per source and keeps that issue
rewritten. This is the loop from that issue to the fix.

**Read [`.claude/rules/adapter-rules.md`](../../rules/adapter-rules.md) first.**
Every rule that governs a new adapter governs a repair, and two of them do most
of the work here: an id may never move (rules 8 to 11), and a field's meaning
may never change quietly (rule 6).

**The failure mode of this job is fixing the parse while changing what a field
means.** The list goes green, the suite passes, and a mapped-to-the-wrong-element
field screens clean for somebody who is on the list. Every step below exists to
keep that visible.

## 1. Read the issue, and work out which kind it is

The issue body names the source, says whether two consecutive runs agreed, and
carries a findings table and a measurements table. Three different jobs hide
behind one issue title:

| The issue says | What it is | What to do |
| --- | --- | --- |
| "could not be fetched", with an exception | **Not drift.** Nothing here knows whether the list changed, only that it could not be read. | Establish whether the file is reachable from somewhere that is not a GitHub runner. If it is, the canary is being blocked and the fix is in the workflow, not the adapter. |
| A finding at `error` severity | A column that used to hold numbers now holds names, or every record lost a field all of them carried. **No government does either to its own list.** | The file changed. Go to step 2. |
| A finding at `warn`, with fill rates or coverage moved | The dangerous case: the file still parses cleanly and means something different. | The file changed. Go to step 2. |
| Counts moved, nothing else | Probably churn. These lists designate and delist every business day. | Confirm against the file, then step 7 alone. |

`bundle exec rake canary` reports every source's current numbers and
`ActiveSanction.doctor(:key)` diagnoses one locally against the last stored
snapshot. **Both reach real publishers** — rule 15. Name them; let a person run
them.

Note what the issue does *not* tell you: the canary measures the adapter's
output, not the publisher's bytes. A fill rate that halved names a field, not an
element.

## 2. Get the published file, and diff it against the committed fixture

Rule 15: ask for the bytes rather than fetching them. The adapter's declared
`url`s are in its class body and the issue body links them.

```bash
curl -sSL -o /tmp/new.xml "<the declared url>"
```

Then compare **structure**, not content. The records differ every day; that is
not the change you are looking for.

```bash
# XML: what element names exist now, and in what nesting, versus the fixture
grep -o '<[A-Za-z_:][^ >/]*' /tmp/new.xml | sort -u > /tmp/now.txt
grep -o '<[A-Za-z_:][^ >/]*' spec/fixtures/<key>/<file> | sort -u > /tmp/then.txt
diff /tmp/then.txt /tmp/now.txt

# delimited: the header row, or the first row's width
head -1 /tmp/new.csv
head -1 spec/fixtures/<key>/<file>
awk -F, 'NR<=5 {print NF}' /tmp/new.csv
```

What to look for, in the order it bites:

- **A renamed or re-nested element**, or a column renamed in a header.
- **A column inserted or reordered.** An insert changes the width and warns; a
  reorder keeps the width, parses cleanly and shifts every field. This is why
  `#column_shapes` exists, and a positional file that drifted and did not warn is
  the case it was written for.
- **A new value in a vocabulary** — an `SDN_Type` or a record kind the adapter's
  map does not know. The adapter warns and defaults to `:organization`, so this
  shows up as an `info` finding and a moved cohort count.
- **A new label in free text.** `remarks_coverage` has a 2% tolerance precisely
  because it does not move on its own: it moves when a publisher spells a label
  differently, and that is the thing the canary exists to catch.
- **A changed encoding or a changed null sentinel.**
- **The document's own version marker**, if the adapter reads one.

## 3. Decide: parse break or change of meaning

Write the answer down before touching the adapter, because it decides everything
after it.

**A parse break** is loud. Rows warn, a width is wrong, an element is missing,
`ParseError` is raised. The publisher's intent is unchanged and the adapter has
to read a new spelling of the same thing. Fix the reading.

**A change of meaning** is silent. The file parses, and a field now holds
something else — an element reused for a second purpose, a date that is now a
build date for some record shapes, a reference that now identifies a designation
rather than a person. Fixing this is a mapping decision, not a parsing one, and
it goes in the class comment (rule 6).

**Churn** is neither. Nothing about the file changed; the list did.

Then ask the question that outranks all three: **does the fix move any id?** If
the publisher changed the field an id is derived from, or if the fix changes how
`SourceRef` normalizes, every record of that source ever stored is re-identified
and the next diff reports the whole list as removed and re-added. That is a
migration with a decision attached, not a cleanup — say so explicitly in the pull
request, and prefer a fix that keeps ids stable where one exists.

## 4. Fix the adapter

Keep the change as small as the upstream change was. In particular:

- **Do not widen a map to make a warning go away.** An unrecognised type
  defaulting to `:organization` and warning is the designed behaviour; adding the
  new value to the map is the fix, and only once you know what the publisher
  means by it.
- **Do not rescue a `ParseError` into an empty array** to make a red run green.
  Rule 13.
- **Do not drop a field that no longer fits.** It goes into `remarks` behind the
  `[source fields]` marker. Rule 5.
- **Do not tighten or loosen a `floor` to make the numbers agree.** A floor is a
  backstop for a first sync, not a build control.
- **Update the class comment.** The record counts and quirks in it are now wrong,
  and they are checkable against the file, which is the whole reason they are
  numbers.

## 5. Re-capture the fixture

Only if the format actually changed. A meaning change with no format change
needs a spec, not new bytes.

Rule 16: real published records, lifted verbatim, cut with a tool that does not
touch what it was not asked to. And one constraint that does not apply when
adding a source:

**Preserve the quirk coverage the old fixture had.** Every record in it was
chosen because some line of the spec asserts on it. Re-capture the same quirks —
all the record shapes, the bilingual value, the padded field, the year-only date,
the unreadable date — plus a record exhibiting whatever just changed. Re-read the
adapter's spec and check that every `entity("...")` lookup still resolves before
committing. For a multi-file source, keep the join keys aligned.

## 6. Write the spec that would have caught it

Rule 22. The conformance group is the floor and knew nothing about this: it does
not know which element carries a date of birth. A repair lands with an example
that asserts the specific meaning that moved, named after what the publisher
changed, against the record in the fixture that exhibits it.

```bash
bundle exec rake     # rspec, then rubocop, then srb tc -- all three must pass
```

## 7. Refresh the baseline

```console
$ CANARY_SOURCES=<key> bundle exec rake canary          # what it measures now
$ CANARY_SOURCES=<key> bundle exec rake canary:refresh  # accept those numbers
```

Rule 15 — hand these over rather than running them. `refresh` rewrites the
profile and leaves `tolerances` alone, because tolerances are the part a human
tuned. Touch a tolerance only when the same movement is going to keep arriving,
and put the reason in the baseline's optional `note` field rather than in a
commit message nobody will find again.
[`.github/baselines/README.md`](../../../.github/baselines/README.md) documents
the format.

Commit the baseline diff in the same pull request as the fix. **A diff in that
directory is a change in what a government publishes**, which is the entire
reason it is a committed file rather than a cache.

## 8. Say what moved upstream

The pull request body and the commit message both state, in plain words:

1. **What the publisher changed** — the element, column, label or vocabulary,
   named as the publisher names it, with the old spelling and the new one.
2. **Whether it was a parse break or a change of meaning**, and how you decided.
3. **Whether any id moved**, and if so, what a stored snapshot will do on the
   next sync.
4. **Which numbers in the baseline moved and why** — a fill rate that recovered
   because a field was remapped reads very differently from one that moved
   because the list did.
5. `Closes #<the canary issue>`. The canary closes its own issue on the first
   clean run, but the issue should point at the commit that fixed it.

`git commit -s` (rule 25), reasoning in the commit message rather than only in
the pull request body (rule 26), and a `CHANGELOG.md` entry under `Unreleased`
(rule 27).

## Done when

- [ ] The issue was classified: fetch failure, parse break, change of meaning, or
      churn.
- [ ] The real published file was compared against the committed fixture by
      structure.
- [ ] The adapter reads the new spelling without any field quietly meaning
      something else, and the class comment says so.
- [ ] No id moved, or the pull request says one did and what that costs.
- [ ] The fixture was re-captured from real bytes with its quirk coverage intact,
      if the format changed.
- [ ] A spec exists that would have caught this, asserting the meaning rather
      than the parse.
- [ ] `.github/baselines/<key>.json` refreshed and committed alongside the fix.
- [ ] `bundle exec rake` green, commits signed off, and the pull request names
      what the publisher changed.
