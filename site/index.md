---
title: Home
layout: home
nav_order: 1
description: >-
  Screen a name against government sanctions lists, in Ruby, in your own
  process.
---

# ActiveSanction
{: .no_toc }

Screen a name against government sanctions lists, in Ruby, in your own process.
{: .fs-6 .fw-300 }

ActiveSanction fetches the lists a jurisdiction publishes, parses each of them
into one record model, stores them where you tell it to, and scores a name
against them with an account of every point it awarded. Seven lists ship: two
US, one UN, one Canada, one EU, one UK, one Australia.

<!-- sample: illustrative -- reaches seven government endpoints and needs a synced store -->
```ruby
ActiveSanction.sync!

ActiveSanction.screen(name: "Vladimir Putin", type: :individual, date_of_birth: "1952-10-07")
# => [#<MatchResult score=97.3 source=:ofac_sdn matched_name="PUTIN, Vladimir Vladimirovich">]
```

{: .warning }
> **This library is a screening aid. It is not legal advice, and it is not a
> compliance program.** Verify every hit against the official published list
> before acting on it. A clean result means *nothing over the threshold in the
> lists we currently hold* — it does not mean *not sanctioned*.

Folding a name is the one thing you can try with no data at all. Screening
compares folded strings, never published ones:

<!-- sample: runnable -->
```ruby
require "active_sanction"

ActiveSanction::Normalizer.call("O'Brien, Seán").value
# => "o brien sean"

ActiveSanction::Normalizer.call("Public Joint Stock Company Gazprom", type: :organization).value
# => "gazprom"
```

---

## Where to go

| If you want to | Read |
|---|---|
| Screen a name for the first time | [Get started]({{ site.baseurl }}/tutorial/) |
| Do a specific thing you already understand | [Guides]({{ site.baseurl }}/how-to/) |
| Look up a source, a setting or an error | [Reference]({{ site.baseurl }}/reference/) |
| Understand why a score is what it is | [Explanation]({{ site.baseurl }}/explanation/) |
| Read a method signature | [API docs]({{ site.baseurl }}/api/) |

---

*This landing page is scaffolding. [#104](https://github.com/Babystep-Technologies/active_sanction/issues/104)
writes the real one, along with the source catalogue it links to.*
