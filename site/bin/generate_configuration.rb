#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes site/src/data/configuration.json, which the configuration reference
# page renders (#109).
#
#     $ bundle exec rake site:configuration
#
# `Configuration.settings` is already the generated list of every setting a
# caller may name -- it is derived from the writer methods, not typed out, so
# a setting added to the class is picked up here without anything remembering
# to say so twice. The type for each one comes from its reader's own Sorbet
# sig, read at runtime with `T::Utils.signature_for_method`, and the default
# comes from a freshly built Configuration -- the same object `Client.new`
# gets when a caller configures nothing.
#
# Two settings are handled apart from the rest: `cache_dir` and `storage_dir`
# default to a path built from `Dir.home`, which is a fact about the machine
# that ran this generator and not about the library. Those two report the
# symbolic form instead -- the environment variable and the directory name the
# library actually decides -- which is what stays true on every machine.
#
# What is not here: the one-line description of what a setting does. That is
# editorial writing about effect and trade-off, it belongs where a writer can
# edit it, and it lives in reference/configuration.mdx next to this data.

require "json"

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "active_sanction"

module GenerateConfiguration
  ROOT = File.expand_path("../..", __dir__)
  OUTPUT = File.join(ROOT, "site", "src", "data", "configuration.json")

  # Settings whose default is a filesystem path built from `Dir.home` --
  # a fact about the machine that generated this file, not about the library.
  # See #symbolic_default.
  PATH_SETTINGS = %i[cache_dir storage_dir].freeze

  module_function

  def call
    config = ActiveSanction::Configuration.new
    settings = ActiveSanction::Configuration.settings.map { |name| describe(name, config) }

    payload = {
      "generated_by" => "site/bin/generate_configuration.rb, via `rake site:configuration`",
      "settings" => settings
    }
    JSON.pretty_generate(payload) << "\n"
  end

  def describe(name, config)
    {
      "name" => name.to_s,
      "type" => type_of(name),
      "default" => PATH_SETTINGS.include?(name) ? symbolic_default(name) : default_of(name, config)
    }
  end

  def type_of(name)
    method = ActiveSanction::Configuration.instance_method(name)
    signature = T::Utils.signature_for_method(method)
    raise "#{name} has no Sorbet sig -- every Configuration reader is `# typed: strict`" if signature.nil?

    signature.return_type.to_s
  end

  def default_of(name, config)
    value = config.public_send(name)
    literal(value)
  end

  # A value simple enough to print as itself. Anything else -- a
  # Normalizer::Dictionary, a Scorer::Weights, a Storage::FileSystem -- is
  # printed by its class name, relative to ActiveSanction, because the value
  # itself is either too large for a table cell or, for `storage`, describes
  # this machine's filesystem rather than the library's default.
  def literal(value)
    case value
    when nil, true, false, Integer, Float, Symbol, String
      value.inspect
    when Array
      value.empty? ? "[]" : value.inspect
    else
      value.class.name.delete_prefix("ActiveSanction::")
    end
  end

  def symbolic_default(name)
    case name
    when :cache_dir
      "$#{ActiveSanction::Configuration::XDG_CACHE_HOME}/#{ActiveSanction::Configuration::DEFAULT_CACHE_DIRNAME}, " \
      "or ~/.cache/#{ActiveSanction::Configuration::DEFAULT_CACHE_DIRNAME} when unset"
    when :storage_dir
      "~/#{ActiveSanction::Configuration::DEFAULT_STORAGE_DIRNAME}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  File.write(GenerateConfiguration::OUTPUT, GenerateConfiguration.call)
  puts "wrote #{GenerateConfiguration::OUTPUT.sub("#{GenerateConfiguration::ROOT}/", "")}"
end
