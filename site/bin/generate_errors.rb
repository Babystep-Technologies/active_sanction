#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes site/src/data/errors.json, which the error hierarchy reference page
# renders (#109).
#
#     $ bundle exec rake site:errors
#
# The class and its parent come from walking the object space rather than
# from a list somebody remembers to update: every class this library can
# raise mixes in `ActiveSanction::Error` somewhere in its ancestry (directly,
# or through a superclass that does), so filtering `ObjectSpace` for exactly
# that finds every one of them, including a subclass added under an existing
# parent tomorrow. The alternative -- a hand-maintained list -- is exactly the
# kind of reference the acceptance criteria on #109 rule out: it is correct on
# the day it is written and silently wrong the first time somebody adds a
# subclass and forgets the page.
#
# `own_attributes` is also mechanical: the instance methods a class defines
# directly, minus the handful that are behaviour rather than data --
# `retryable?` (covered by `own_overrides_retryable` instead), and `to_h` /
# `to_s`, which every override here uses to fold its own attributes into the
# inherited rendering rather than to add a new one.
#
# What is not here: when each error is raised, what its `retryable?` resolves
# to, and the two-line explanation the reference page needs for a class like
# `Sync::Failed` whose answer depends on a whole report rather than on one
# status code. That is prose, judged from reading the raising code, and it
# belongs where a writer can edit it -- the `editorial` map in
# reference/errors.mdx, next to this data. `spec/site_errors_data_spec.rb`
# fails if a class generated here has no matching entry in that map, which is
# what keeps the two from drifting apart.

require "json"

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "active_sanction"

module GenerateErrors
  ROOT = File.expand_path("../..", __dir__)
  OUTPUT = File.join(ROOT, "site", "src", "data", "errors.json")

  module_function

  def call
    classes = ObjectSpace.each_object(Class).select { |klass| raisable?(klass) }
    raise "no error classes found -- did the library load?" if classes.empty?

    payload = {
      "generated_by" => "site/bin/generate_errors.rb, via `rake site:errors`",
      "errors" => classes.sort_by(&:name).map { |klass| describe(klass) }
    }
    JSON.pretty_generate(payload) << "\n"
  end

  # Exactly the classes `rescue ActiveSanction::Error` catches: an exception
  # whose ancestry includes the marker module, at any distance.
  def raisable?(klass)
    klass < Exception && klass.ancestors.include?(ActiveSanction::Error)
  end

  BEHAVIOR_METHODS = %i[retryable? to_h to_s].freeze

  def describe(klass)
    own = klass.instance_methods(false) - Object.instance_methods
    {
      "name" => relative(klass),
      "parent" => relative(klass.superclass),
      "own_attributes" => (own - BEHAVIOR_METHODS).map(&:to_s).sort,
      "own_overrides_retryable" => own.include?(:retryable?)
    }
  end

  def relative(klass)
    klass.name.delete_prefix("ActiveSanction::")
  end
end

if $PROGRAM_NAME == __FILE__
  File.write(GenerateErrors::OUTPUT, GenerateErrors.call)
  puts "wrote #{GenerateErrors::OUTPUT.sub("#{GenerateErrors::ROOT}/", "")}"
end
