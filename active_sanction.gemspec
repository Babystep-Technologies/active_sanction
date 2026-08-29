require_relative 'lib/active_sanction/version'

Gem::Specification.new do |spec|
  spec.name          = "active_sanction"
  spec.version       = ActiveSanction::VERSION
  spec.authors       = ["Marshall Shen"]
  spec.email         = ["shen.marshall@gmail.com"]

  spec.summary       = %q{A Ruby toolkit that manages sanction lists around the world.}
  spec.description   = %q{ActiveSanction fetches government sanctions lists, normalizes them into a single record model, persists them in preferred storage, and screens names against them with explainable fuzzy match scores. Every match carries structured reasons and stamps the snapshot checksum, matcher version, and thresholds so a screening decision can be re-derived during an audit. New sources register through public extension points without forking the gem.}
  spec.homepage      = "https://github.com/Babystep-Technologies/active_sanction"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/Babystep-Technologies/active_sanction/tree/main"
  spec.metadata["changelog_uri"]   = "https://github.com/Babystep-Technologies/active_sanction/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
