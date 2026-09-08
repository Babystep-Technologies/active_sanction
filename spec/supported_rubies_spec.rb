# frozen_string_literal: true

require "yaml"

# Not a spec for a class: this is #80, which is the promise that the Rubies
# this gem says it runs on are the Rubies a build actually ran. That promise
# was broken by four files quietly disagreeing -- CI built 3.1 through 3.3,
# `.ruby-version` said 4.0.1, and the one Ruby every change was written on was
# the one no build ever exercised.
#
# Nothing about that is visible in a diff, which is why it is asserted here
# rather than written down in a comment. The normalizer is the reason it
# matters: `String#encode(invalid: :replace)`, NFKD and `downcase(:fold)` all
# come from the interpreter and all move between its versions, and all three
# decide whether a name matches.
RSpec.describe "the Rubies this gem supports" do
  # Every Ruby series released since the floor, oldest first. Ruby 3 ended at
  # 3.4 and 4.0 followed it, which is knowledge no file in this repository
  # holds and this list therefore has to. It is not decoration: the examples
  # below hold `.ruby-version` to being in it, so a new series cannot arrive in
  # development without being named here and, one example later, in the matrix.
  let(:released) { %w[3.1 3.2 3.3 3.4 4.0] }

  # What CI builds. `include:`'s `ruby-head` is deliberately not read: it is
  # allowed to fail, it is not a Ruby this gem claims to support, and counting
  # it here would make it one.
  let(:matrix) do
    YAML.load_file(File.expand_path("../.github/workflows/ci.yml", __dir__))
        .dig("jobs", "test", "strategy", "matrix", "ruby")
  end

  # What this gem is developed on.
  let(:development) { series(File.read(File.expand_path("../.ruby-version", __dir__)).strip) }

  # What the gemspec promises a host. `>= 3.1` is the only bound there, and the
  # floor is the whole promise: a host on the oldest supported Ruby is the one
  # who finds out first when a build stops covering it.
  let(:floor) do
    requirement = Gem::Specification.load(File.expand_path("../active_sanction.gemspec", __dir__))
                                    .required_ruby_version
    series(requirement.requirements.find { |operator, _| operator == ">=" }.last)
  end

  # What RuboCop is told to lint for. YAML reads `3.1` as a number, which is
  # how RuboCop's own documentation writes it -- a two-digit minor will have to
  # be quoted in `.rubocop.yml` when one arrives, or `3.10` becomes `3.1`
  # before anything here sees it.
  let(:target) do
    YAML.load_file(File.expand_path("../.rubocop.yml", __dir__)).dig("AllCops", "TargetRubyVersion")
  end

  it "builds the Ruby it is developed on" do
    expect(matrix).to include(development)
  end

  it "builds the floor it promises a host, and nothing below it" do
    expect(matrix.min_by { |ruby| Gem::Version.new(ruby) }).to eq(floor)
  end

  # The linter reads the oldest Ruby's syntax rules, so the version it targets
  # and the oldest version actually built have to be the same one -- otherwise
  # RuboCop is either permitting syntax the floor job will reject or rejecting
  # syntax nothing builds any more.
  it "lints for that same floor" do
    expect(series(target)).to eq(floor)
  end

  # The gap that opened last time was in the middle -- 3.4 released, nobody
  # added it, and 3.3 and 4.0 sitting on either side looked like a complete
  # list. Every released series from the floor up to the development Ruby has
  # to be named, in order.
  it "has no holes between the floor and the Ruby it is developed on" do
    expected = released.select do |ruby|
      Gem::Version.new(ruby).between?(Gem::Version.new(floor), Gem::Version.new(development))
    end

    expect(matrix).to eq(expected)
  end

  # What keeps `released` honest. Bumping `.ruby-version` to a series this spec
  # has never heard of fails here first, and the fix -- naming it -- is what
  # makes the example above ask for it in the matrix too.
  it "knows about the Ruby it is developed on" do
    expect(released).to include(development)
  end

  # MAJOR.MINOR is the unit all four files speak in: `.ruby-version` pins a
  # patch, the gemspec and the matrix do not, and a patch release is not a
  # thing a matrix can be held to.
  def series(version)
    version.to_s[/\A\d+\.\d+/]
  end
end
