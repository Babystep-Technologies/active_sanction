# typed: true
# frozen_string_literal: true

# Tapioca generates a gem's RBI from what that gem has loaded, so anything a
# gem defers has to be named here or its RBI comes out empty and every
# constant that reaches our code through it is unresolved.
#
# Neither `active_record` nor `nokogiri` is a dependency of this gem -- see the
# gemspec. Both are here because the optional adapters that use them are still
# code in `lib/`, and code in `lib/` is typechecked.
require "active_record"
require "nokogiri"

# `concurrent-ruby` installs under a name that is not the file it defines, so
# tapioca finds nothing to require by the gem's own name. ActiveSupport's RBI
# refers to `Concurrent` throughout.
require "concurrent"

# Test-only, and here for the same reason: `spec/` is typechecked too.
# ActiveSupport's shipped annotations refer to `Minitest::Assertion`, and the
# two conformance groups run their nested examples inside RSpec's sandbox,
# which rspec-core does not load until something asks for it.
require "minitest"
require "rspec/core/sandbox"
