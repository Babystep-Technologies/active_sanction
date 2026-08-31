# ActiveSanction

[![CI](https://github.com/Babystep-Technologies/active_sanction/actions/workflows/ci.yml/badge.svg)](https://github.com/Babystep-Technologies/active_sanction/actions/workflows/ci.yml)

Welcome to your new gem! In this directory, you'll find the files you need to be able to package up your Ruby library into a gem. Put your Ruby code in the file `lib/active_sanction`. To experiment with that code, run `bin/console` for an interactive prompt.

TODO: Delete this and the text above, and describe your gem

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'active_sanction'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install active_sanction

## Usage

TODO: Write usage instructions here

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

### Tests and linting

`bundle exec rake` runs the RSpec suite and then RuboCop; both must pass.

The suite is hermetic. `spec_helper.rb` calls `WebMock.disable_net_connect!(allow_localhost: true)`, so an un-stubbed HTTP call raises `WebMock::NetConnectNotAllowedError` instead of quietly reaching the internet. Parser specs run against committed fixtures — a suite that can reach a government server stops proving anything about our parsing and starts proving that the server is up.

Specs that genuinely need a real endpoint are tagged `:live`. They are excluded from the default run, and `WebMock` is re-enabled around each one:

    $ bundle exec rspec --tag live

### The adapter contract

Every source adapter is held to one shared example group, `"a sanction source"`, which is what turns "can we add a new sanctions list?" into a checklist. A new adapter's spec names the contract and its fixture:

```ruby
RSpec.describe ActiveSanction::Sources::CanadaSema do
  it_behaves_like "a sanction source", fixture: "canada_sema/sema.xml"
end
```

It checks what everything downstream of an adapter assumes and cannot check for itself: that the list declares a key, a jurisdiction, an authority and a URL, and registers itself; that `#parse` returns `Entity` objects with unique, deterministic ids, a canonical type and at least one name; that dates arrive as `PartialDate` rather than as the string the publisher wrote them as; that every record survives the round-trip through `#to_h`; that the publisher's own text is kept in `remarks`; and that an empty payload is refused rather than reported as a list with nobody on it. It is the floor and not the ceiling — only a spec that knows what is in the fixture can check that the list was read *correctly*, so every adapter still writes its own.

The group is `spec/support/shared_examples/sanction_source.rb`, with its options documented at the top. `spec/active_sanction/sources/conformance_spec.rb` holds it to being able to fail: each example there takes one rule out of an otherwise conforming adapter and checks that the contract notices.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/active_sanction. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/[USERNAME]/active_sanction/blob/master/CODE_OF_CONDUCT.md).


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the ActiveSanction project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/[USERNAME]/active_sanction/blob/master/CODE_OF_CONDUCT.md).
