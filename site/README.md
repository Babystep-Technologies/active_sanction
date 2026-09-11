# The documentation site

Astro and [Starlight](https://starlight.astro.build), published at
<https://babystep-technologies.github.io/active_sanction>.

Nothing here ships in the gem. The gemspec's `dev_only` rule excludes this
directory, and `spec/licensing_spec.rb` fails the build if that ever stops
being true — which is the whole reason the site is not built out of `docs/`:
doing so would put a config file, a theme and a set of layouts into every
application that installs `active_sanction`.

`docs/` is the directory that ships. The site links into it rather than
copying it, because two copies of a procedure means one of them is wrong
within a release.

    $ cd site
    $ npm install
    $ npm run dev            # http://localhost:4321/active_sanction/

## Node

Astro needs Node 20.19 or newer, and the deploy workflow pins 22. That is
deliberately not the gem's Ruby matrix: the library is built on every Ruby from
3.1 to 4.0, while the site is one artifact built once, and Astro's floor has
nothing to do with what `active_sanction` supports.

## The whole build, the way the workflow does it

`npm run build` renders the handwritten pages and nothing else. The generated
API reference comes from YARD, at the repository root, and is copied in
afterwards — so to reproduce a deploy locally, from the repository root:

    $ bundle exec rake site:check

That builds the site, renders `rake doc` into `/api/`, and runs the link
checker over the result. It is what CI runs, in the same order.

## The link checker

    $ bundle exec ruby site/bin/linkcheck site/dist --ignore api
    $ bundle exec ruby site/bin/linkcheck site/dist --ignore api --external

Internal links and anchors gate the build; external ones are counted and not
fetched. The reasoning is in the header of `bin/linkcheck`, and it is the same
reasoning that keeps the upstream canary out of CI: half the external links on
this site point at government publishers that 403 a non-browser user agent on
purpose, and a build that went red when Treasury rate-limited a runner would be
muted inside a week.

`--ignore api` skips YARD's output as a *source* of links while leaving it a
valid *target*. YARD renders the README as its index page, and the README's
relative links resolve against the repository rather than against this site.

## Code samples

Every fenced Ruby block declares itself. Markdown takes an HTML comment, MDX
takes an expression comment, and both mean the same thing:

    <!-- sample: runnable -->
    {/* sample: illustrative -- needs a synced OFAC snapshot */}

`spec/site_samples_spec.rb` runs the runnable ones, parses all of them, and
fails on a block that declares neither. An illustrative block has to say why it
cannot run. The dangerous sample is not the one somebody marked wrong — it is
the one nobody thought about, which looks exactly like a tested one to a
reader.

## Where things are

| | |
|---|---|
| `src/content/docs/` | The pages, one directory per Diátaxis quadrant |
| `src/pages/404.astro` | The only page outside the collection; GitHub Pages serves `/404.html` and only that path |
| `src/styles/custom.css` | Theme tokens, and the rules that keep wide tables from taking the page sideways on a phone |
| `astro.config.mjs` | Navigation, which is the Diátaxis map named for what a reader wants |
| `bin/linkcheck` | Ruby, so it runs in the bundle this repository already has |
