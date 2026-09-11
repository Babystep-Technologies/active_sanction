#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes site/src/data/weights.json, which the "How matching works" page
# renders (#106).
#
#     $ bundle exec rake site:weights
#
# Every number the scorer uses lives in `ActiveSanction::Scorer::Weights::DEFAULTS`,
# with the reason for it as a comment beside the constant. Typing those numbers
# a second time onto a page is how a table drifts the first time somebody tunes
# a weight and forgets the site exists -- the same argument that keeps
# site/bin/generate_sources.rb reading the registry instead of a spreadsheet.
#
# The output is committed so the site builds with Node alone, and
# spec/site_weights_data_spec.rb regenerates it and fails if the committed copy
# has drifted from the constant.
#
# What is not here: which numbers are shares of the name score and which are
# points on the 0..100 total, what each one is worth and why, and the display
# order. That is editorial judgment about how to present the numbers, it
# belongs where a writer can edit it, and it lives in how-matching-works.mdx.

require "json"

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "active_sanction"

module GenerateWeights
  ROOT = File.expand_path("../..", __dir__)
  OUTPUT = File.join(ROOT, "site", "src", "data", "weights.json")

  module_function

  def call
    weights = ActiveSanction::Scorer::Weights::DEFAULTS
    raise "no default weights found -- did the scorer load?" if weights.empty?

    payload = {
      "generated_by" => "site/bin/generate_weights.rb, via `rake site:weights`",
      "matcher_version" => ActiveSanction::MATCHER_VERSION,
      "weights" => weights.sort.to_h { |member, value| [member.to_s, value] }
    }
    JSON.pretty_generate(payload) << "\n"
  end
end

if $PROGRAM_NAME == __FILE__
  File.write(GenerateWeights::OUTPUT, GenerateWeights.call)
  puts "wrote #{GenerateWeights::OUTPUT.sub("#{GenerateWeights::ROOT}/", "")}"
end
