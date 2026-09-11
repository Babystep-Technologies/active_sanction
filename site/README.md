# The documentation site

Jekyll sources for <https://babystep-technologies.github.io/active_sanction>.
Nothing here ships in the gem — the gemspec's `dev_only` rule excludes this
whole directory, and `spec/licensing_spec.rb` fails the build if that ever
stops being true.

    $ cd site
    $ bundle install
    $ bundle exec jekyll serve        # http://127.0.0.1:4000/active_sanction/

`docs/` is the directory that ships inside the gem. The site links into it
rather than copying it: two copies of a procedure means one of them is wrong
within a release.

Generated API documentation is not built here. `rake doc` renders YARD into
`doc/` at the repository root, and the deploy workflow copies that output to
`/api/` on the published site.

## Ruby

`site/.ruby-version` pins 3.3, and the deploy workflow uses the same. That is
deliberately not the gem's matrix: the library is built on every Ruby from 3.1
to 4.0, while the site is one artifact built once, and Jekyll's own
dependencies — `eventmachine` among them — have nothing to do with what
`active_sanction` runs on. A Jekyll release must never be the reason the
library's matrix goes red.

## The link checker

    $ bundle exec jekyll build
    $ bundle exec ruby bin/linkcheck _site
    $ bundle exec ruby bin/linkcheck _site --external

Internal links and anchors gate the build; external ones are counted and not
fetched. The reasoning is in the header of `bin/linkcheck`, and it is the same
reasoning that keeps the upstream canary out of CI: half the external links on
this site point at government publishers that 403 a non-browser user agent on
purpose.

## Code samples

Every fenced Ruby block on the site declares itself:

    <!-- sample: runnable -->
    <!-- sample: illustrative -- needs a synced OFAC snapshot -->

`spec/site_samples_spec.rb` runs the runnable ones and parses all of them, and
fails on a block that declares nothing. The dangerous sample is not the one
somebody marked wrong — it is the one nobody thought about, which looks exactly
like a tested one to a reader.
