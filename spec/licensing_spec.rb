# frozen_string_literal: true

require "yaml"

# Not a spec for a class: this is #61, which is the promise that this gem says
# MIT in every place a person or a tool looks for a licence, and that the files
# governing a contribution actually reach the people governed by them.
#
# It is asserted here rather than written down in a comment because none of it
# is visible in a diff. A `spec.license` changed without `LICENSE.txt` produces
# a gem whose rubygems.org page and whose own text disagree, and the first
# person to notice is a lawyer at a company deciding whether they may install
# it. The same goes the other way: a licence file rewritten while the gemspec
# still claims MIT is worse, because the machine-readable half is what every
# dependency scanner reads and no human reads at all.
RSpec.describe "what this gem says about its own licence" do
  let(:root) { File.expand_path("..", __dir__) }

  let(:gemspec) { Gem::Specification.load(File.join(root, "active_sanction.gemspec")) }

  let(:license_file) { File.read(File.join(root, "LICENSE.txt")) }

  # What `gem build` actually packages. The gemspec computes it from
  # `git ls-files`, so a file that is not committed is not in here -- which is
  # the failure mode these examples exist to catch, a governance file written
  # and then never shipped.
  let(:packaged) { gemspec.files }

  it "declares MIT to rubygems, and nothing else" do
    expect(gemspec.licenses).to eq(["MIT"])
  end

  it "ships the licence text the gemspec names" do
    expect(packaged).to include("LICENSE.txt")
  end

  it "heads that file with the licence the gemspec declares" do
    expect(license_file).to start_with("The MIT License (MIT)")
  end

  # The clause is the licence. A file headed "The MIT License" whose body had
  # been edited would satisfy every scanner and grant something else.
  it "grants MIT's permission verbatim, rather than merely being headed MIT" do
    expect(license_file).to include(
      "Permission is hereby granted, free of charge, to any person obtaining a copy"
    )
  end

  it "disclaims warranty in MIT's own words" do
    expect(license_file).to include('THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND')
  end

  it "tells a reader the same thing the gemspec tells a scanner" do
    expect(File.read(File.join(root, "README.md"))).to include("[MIT License](LICENSE.txt)")
  end

  # These three ship deliberately. A gem is often read where GitHub is not
  # reachable -- inside a vendored bundle, on an air-gapped host, by somebody
  # auditing an installed dependency -- and the address to report a
  # vulnerability to is exactly what that reader is looking for.
  %w[CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md].each do |file|
    it "ships #{file}" do
      expect(packaged).to include(file)
    end
  end

  # The other half of the gemspec's `dev_only` rule. `.github/` is the
  # toolchain -- workflows, templates, the canary's baselines -- and none of it
  # does anything inside an installed gem.
  it "ships nothing from .github/" do
    expect(packaged.grep(%r{\A\.github/})).to be_empty
  end
end
