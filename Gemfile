# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in active_sanction.gemspec
gemspec

# Not a dependency of the gem -- see the gemspec. It is here so the Nokogiri
# XML backend is covered by the suite rather than shipped on the assumption
# that it works.
gem "nokogiri", "~> 1.15"

gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"
gem "rubocop", "~> 1.75"
gem "rubocop-rspec", "~> 3.5"
gem "webmock", "~> 3.25"

# The static half of Sorbet. `sorbet-runtime` is a dependency of the gem -- see
# the gemspec -- because the `sig` blocks in `lib/` are executed. The checker
# and the RBI generator only ever run here, so a host never installs them.
gem "sorbet", "~> 0.6"
gem "sorbet-runtime", "~> 0.6"
gem "tapioca", "~> 0.16", require: false

# Not dependencies of the gem -- Storage::ActiveRecord loads only when a host
# has already loaded ActiveRecord, and the gem is fully usable without it. They
# are here so that adapter is covered by the suite rather than shipped on the
# assumption that it works.
gem "activerecord", ">= 7.1"
gem "sqlite3", ">= 1.6"
