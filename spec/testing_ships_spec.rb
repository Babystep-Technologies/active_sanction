# frozen_string_literal: true

require "open3"

# Not a spec for a class: this is #144, and it is the reason the two
# conformance groups live under `lib/` rather than under `spec/`.
#
# `docs/api_stability.md` calls them "the executable statement of what
# [the extension points] require". That statement was addressed to people
# writing an adapter outside this repository, and for the whole of 1.0 it
# shipped nowhere -- `spec/` is excluded from the package, so the audience for
# the promise was the one group of people who could not run it.
#
# What is asserted here is the packaging rather than the contract. The groups
# themselves are exercised by every adapter spec in this suite and by the two
# conformance specs; these examples are about whether somebody who ran
# `gem install active_sanction` can reach them at all, which nothing else can
# see, and which is exactly the kind of thing that breaks silently.
RSpec.describe "the conformance groups, as an installed gem sees them" do
  let(:root) { File.expand_path("..", __dir__) }

  let(:packaged) do
    Gem::Specification.load(File.join(root, "active_sanction.gemspec")).files
  end

  # The files are listed by `git ls-files`, so a group that was written but
  # never committed ships nowhere -- which is not a hypothetical: it is what
  # the first build of this change did, and the reason this example names
  # every file rather than the directory.
  it "packages the entry point and both groups" do
    expect(packaged).to include(
      "lib/active_sanction/testing.rb",
      "lib/active_sanction/testing/sanction_source.rb",
      "lib/active_sanction/testing/storage_adapter.rb",
      "lib/active_sanction/testing/storage_adapter_defaults.rb"
    )
  end

  # The other half of the same fact. If `spec/` ever started shipping, the
  # problem this issue fixed would be hidden rather than solved.
  it "still packages nothing from spec/" do
    expect(packaged.grep(%r{\Aspec/})).to be_empty
  end

  # Run in a subprocess, because this suite has RSpec loaded and the question
  # is what a host without it sees.
  def run(code)
    out, status = Open3.capture2e(RbConfig.ruby, "-I", File.join(root, "lib"), "-e", code)
    raise "subprocess failed: #{out}" unless status.success?

    out
  end

  # A host application is not a test suite. Requiring the library must not
  # drag RSpec into a production process, and must not define the groups
  # there either.
  it "is not loaded by `require \"active_sanction\"`" do
    answer = run(<<~RUBY)
      require "active_sanction"
      puts [defined?(::RSpec), defined?(ActiveSanction::Testing)].compact.inspect
    RUBY

    expect(answer.strip).to eq("[]")
  end

  # And the reverse, said plainly rather than as a NameError from inside a
  # shared example group somebody has never read.
  it "says so when it is required without RSpec" do
    answer = run(<<~RUBY)
      begin
        require "active_sanction/testing"
        puts "loaded anyway"
      rescue LoadError => e
        puts e.message
      end
    RUBY

    expect(answer).to include("RSpec is not loaded")
  end
end
