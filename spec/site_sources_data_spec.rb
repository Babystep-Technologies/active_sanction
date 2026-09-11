# frozen_string_literal: true

require "json"

# Not a spec for a class: this is #104's rule that no record count on the
# documentation site is typed by hand.
#
# The catalogue page renders `site/src/data/sources.json`, which is generated
# from two things that already know the answer -- what each adapter declares,
# and what the canary (#69) last measured into `.github/baselines`. The
# generated file is committed so that the site builds with Node alone, and a
# writer working on prose never needs a Ruby toolchain. The cost of committing
# it is that it can drift, and these examples are what stop it: they run the
# generator and compare.
#
# A number moving here is a change in what a government publishes, which is
# exactly what `.github/baselines` exists to make visible in a review.
RSpec.describe "the generated source data behind the catalogue page" do
  let(:root) { File.expand_path("..", __dir__) }

  let(:path) { File.join(root, "site", "src", "data", "sources.json") }

  let(:committed) { File.read(path) }

  let(:generated) do
    load File.join(root, "site", "bin", "generate_sources.rb")
    GenerateSources.call
  end

  let(:sources) { JSON.parse(committed).fetch("sources") }

  it "is committed" do
    expect(File).to exist(path)
  end

  # The whole point. If this fails, run `bundle exec rake site:sources` and
  # read the diff: it is either an adapter that changed or a publisher that
  # did, and both are worth seeing.
  it "matches what the generator produces today" do
    expect(committed).to eq(generated),
                         "site/src/data/sources.json is stale. Run `bundle exec rake site:sources`."
  end

  it "describes every registered source" do
    expect(sources.map { |source| source["key"] })
      .to match_array(ActiveSanction::Sources.keys.map(&:to_s))
  end

  describe "every source in it" do
    it "carries a record count measured from the real published file" do
      missing = sources.reject { |source| source["record_count"].to_i.positive? }

      expect(missing.map { |source| source["key"] }).to be_empty
    end

    it "says when that count was measured" do
      expect(sources.map { |source| source["measured_at"] }).to all(be_a(String))
    end

    it "names at least one file the adapter fetches" do
      expect(sources.map { |source| source["files"].length }).to all(be_positive)
    end

    # #104's licence column. A source whose publisher's terms nobody has read
    # should say so by failing here rather than by rendering an empty cell
    # that reads as "no conditions".
    it "states what the publisher says about reuse, and links to where it says it" do
      unstated = sources.reject { |source| source["licence_notice"] && source["licence_url"] }

      expect(unstated.map { |source| source["key"] }).to be_empty
    end
  end
end
