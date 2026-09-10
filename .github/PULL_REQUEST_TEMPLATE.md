<!--
Thank you. A few things below are load-bearing rather than ceremonial; each
one says why. Delete anything that does not apply.
-->

## What this changes, and why

<!--
The why, not just the what. Put the reasoning in the commit message as well as
here -- a commit message survives in `git log` after the forge that hosted this
review has changed.
-->

Closes #

## Before it can be reviewed

- [ ] **Every commit is signed off.** `git commit -s`, with the address matching
      the commit author. CI checks this and prints the fix if it is missing.
      There is no CLA — see [CONTRIBUTING.md](https://github.com/Babystep-Technologies/active_sanction/blob/main/CONTRIBUTING.md).
- [ ] `bundle exec rake` passes: specs, RuboCop and `srb tc`.
- [ ] Specs come with the change. A bug fix arrives with the spec that would
      have caught the bug.
- [ ] New files in `lib/` are `# typed: strict`, with signatures written beside
      the code.

## If this touches matching

<!--
The normalizer, the index, the similarity algorithms, the scorer, the weights
or the dictionaries.
-->

- [ ] `bundle exec rake benchmark:accuracy` was run and
      `benchmark/results/accuracy.md` is committed with the change. A weight
      nudged by two points does not look like anything in a patch, and it is
      exactly what moves a name from found to missed.
- [ ] Any name this fixes, or newly gets wrong, is a row in
      `benchmark/fixtures/labeled_set.yml`.
- [ ] `MATCHER_VERSION` is bumped if a screening done today could now come out
      differently. That is a separate question from the gem version, and an
      auditor asking "would this come out the same?" is the one who needs it.

## If this adds or changes a source

- [ ] A fixture captured from the real published file, and the shared
      conformance group wired up.
- [ ] `.github/baselines` refreshed if the record counts moved, so the canary
      is comparing against what the publisher serves now.
- [ ] The README's per-source notes say anything a user would be surprised by.

## If this changes public API

- [ ] The behaviour is documented where a user will find it, not only in the
      commit message.
- [ ] `CHANGELOG.md` has an entry under `Unreleased`.
