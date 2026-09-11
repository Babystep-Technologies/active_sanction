#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes site/src/data/sources.json, which is what the source catalogue page
# renders (#104).
#
#     $ bundle exec rake site:sources
#
# ### Why this is generated, and why the output is committed
#
# Every mechanical fact on the catalogue page has a source of truth already:
# the adapter declares its authority, its endpoint, its format and its licence
# notice, and `.github/baselines` holds what the canary (#69) last measured
# from the real published file. Typing any of that onto a page means it is
# wrong within a month and nobody notices, which is the same argument that
# keeps the accuracy report committed rather than quoted.
#
# The output is committed so the site builds with Node alone -- a writer
# working on prose should not need a Ruby toolchain -- and
# `spec/site_sources_data_spec.rb` regenerates it and fails if the committed
# copy has drifted. So the file is both static and unable to go stale.
#
# ### What is not here
#
# The per-source limitations prose. That is editorial writing about what a
# publisher does and does not publish, it belongs where a writer can edit it,
# and generating it would mean hand-typing it into this file instead.

require "json"

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "active_sanction"

module GenerateSources
  ROOT = File.expand_path("../..", __dir__)
  OUTPUT = File.join(ROOT, "site", "src", "data", "sources.json")
  BASELINES = File.join(ROOT, ".github", "baselines")

  # Spelled the way a reader expects to see it, rather than the way a key is
  # spelled. The adapter declares `:uk`; a catalogue page says "United Kingdom".
  JURISDICTIONS = {
    us: "United States",
    un: "United Nations",
    ca: "Canada",
    eu: "European Union",
    uk: "United Kingdom",
    au: "Australia"
  }.freeze

  FORMATS = {
    csv: "CSV",
    xml: "XML",
    xlsx: "Excel workbook (.xlsx)",
    json: "JSON"
  }.freeze

  module_function

  def call
    sources = ActiveSanction::Sources.all.sort_by { |source| source.key.to_s }.map { |source| describe(source) }
    raise "no sources registered -- did the adapters load?" if sources.empty?

    payload = {
      "generated_by" => "site/bin/generate_sources.rb, via `rake site:sources`",
      "sources" => sources
    }
    JSON.pretty_generate(payload) << "\n"
  end

  def describe(source)
    baseline = baseline_for(source.key)

    {
      "key" => source.key.to_s,
      "jurisdiction" => JURISDICTIONS.fetch(source.jurisdiction, source.jurisdiction.to_s.upcase),
      "authority" => source.authority,
      "format" => FORMATS.fetch(source.format, source.format.to_s),
      # Every file the adapter fetches, named the way the adapter names it.
      # OFAC publishes three that only mean something joined, and a catalogue
      # that showed one of them would misdescribe the work of a sync.
      "files" => source.urls.map { |name, address| { "name" => name.to_s, "url" => address } },
      "licence_notice" => source.licence_notice,
      "licence_url" => source.licence_url,
      "record_count" => baseline&.dig("profile", "record_count"),
      # Only the kinds the list actually carries. A zero here is a fact about
      # the publisher -- the EU lists no vessels -- and printing "0 aircraft"
      # for six of seven sources would be noise in a table read by eye.
      "cohorts" => cohorts(baseline),
      "measured_at" => baseline&.fetch("captured_at", nil)
    }
  end

  def cohorts(baseline)
    counts = baseline&.dig("profile", "cohorts") || {}
    counts.reject { |kind, count| kind == "all" || count.to_i.zero? }
          .map { |kind, count| { "kind" => kind, "count" => count } }
  end

  def baseline_for(key)
    path = File.join(BASELINES, "#{key}.json")
    return nil unless File.exist?(path)

    JSON.parse(File.read(path))
  end
end

if $PROGRAM_NAME == __FILE__
  File.write(GenerateSources::OUTPUT, GenerateSources.call)
  puts "wrote #{GenerateSources::OUTPUT.sub("#{GenerateSources::ROOT}/", "")}"
end
