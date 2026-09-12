# AGENTS.md

Instructions for a coding agent working in this repository. It is a pointer
rather than a copy: everything here is stated in full somewhere else, and a
second copy of a procedure means one of them is wrong within a release.

## Read these, in this order

1. **[`CONTRIBUTING.md`](CONTRIBUTING.md)** — what is worth working on, how to
   get from a clone to a green suite, the three checks, and how to sign a
   commit. This is the whole of what a contributor needs.
2. **[`.claude/rules/adapter-rules.md`](.claude/rules/adapter-rules.md)** — the
   rules a change to a source adapter is held to, stated as rules. Written for
   an agent, which is why it is a numbered list rather than prose.
3. **[`docs/adding_a_source.md`](docs/adding_a_source.md)** — the reasoning
   behind every one of those rules, and the walkthrough for a new list.
4. **[`docs/api_stability.md`](docs/api_stability.md)** — what is public. A
   constant being reachable does not make it public.

## The two procedures, already written down

`.claude/skills/` holds them as Claude Code skills, and they are ordinary
Markdown that reads fine without one:

- [`adding-a-source`](.claude/skills/adding-a-source/SKILL.md) — adding a list
  the gem does not read yet.
- [`repairing-a-source`](.claude/skills/repairing-a-source/SKILL.md) — the
  canary-to-fix loop, for a publisher that changed its file.

## The things that are easy to get wrong

- **`bundle exec rake` is the build**: RSpec, then RuboCop, then `srb tc`. All
  three must pass, and it is the only command that tells you the work is done.
- **New files in `lib/` are born `# typed: strict`.**
- **Commits are signed off**: `git commit -s`. A pull request whose commits are
  not all signed off fails CI.
- **The suite never reaches the internet**, and neither should you on its
  behalf. Government publishers 403 non-browser user agents and block cloud IP
  ranges. `rake canary`, `rake canary:refresh` and `ActiveSanction.doctor` all
  reach real endpoints: name the command and let a person run it.
- **Fixtures are trimmed from real published files**, never written by hand. A
  transcribed corpus measures the transcription.
- **The public surface is enumerated, not inferred.**
  `spec/api_surface_spec.rb` fails the build in both directions.
- **If a change touches the normalizer, the index, the similarity algorithms,
  the scorer or the weights**, run `bundle exec rake benchmark:accuracy`, commit
  the report it rewrites, and bump `MATCHER_VERSION`.

## Reporting a security-relevant bug

A false negative is one. Do not open a public issue —
[`SECURITY.md`](SECURITY.md) says how to report privately.
