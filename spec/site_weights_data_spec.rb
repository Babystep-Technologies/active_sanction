# frozen_string_literal: true

require "json"

# Not a spec for a class: this is #106's rule that no weight on the "How
# matching works" page is typed by hand.
#
# The page renders `site/src/data/weights.json`, which is generated straight
# from `ActiveSanction::Scorer::Weights::DEFAULTS` -- the one place these
# numbers are defined. The generated file is committed so the site builds
# with Node alone, and these examples are what stop it drifting from the
# constant: they run the generator and compare, the same shape as
# spec/site_sources_data_spec.rb.
#
# A number moving here is a retuned weight, and it is exactly the kind of
# change #106 says an auditor needs to see: it is also a MATCHER_VERSION bump,
# which this file checks travelled with it.
RSpec.describe "the generated weights data behind the matching explanation" do
  let(:root) { File.expand_path("..", __dir__) }

  let(:path) { File.join(root, "site", "src", "data", "weights.json") }

  let(:committed) { File.read(path) }

  let(:generated) do
    load File.join(root, "site", "bin", "generate_weights.rb")
    GenerateWeights.call
  end

  let(:weights) { JSON.parse(committed).fetch("weights") }

  it "is committed" do
    expect(File).to exist(path)
  end

  # The whole point. If this fails, run `bundle exec rake site:weights` and
  # read the diff: it is a weight that changed, and that is worth seeing.
  it "matches what the generator produces today" do
    expect(committed).to eq(generated),
                         "site/src/data/weights.json is stale. Run `bundle exec rake site:weights`."
  end

  it "carries every weight the scorer defines, and none it does not" do
    expect(weights.keys).to match_array(ActiveSanction::Scorer::Weights::DEFAULTS.keys.map(&:to_s))
  end

  it "matches ActiveSanction::Scorer::Weights::DEFAULTS exactly" do
    expect(weights).to eq(ActiveSanction::Scorer::Weights::DEFAULTS.transform_keys(&:to_s))
  end

  it "stamps the matcher version the weights are shipped under" do
    expect(JSON.parse(committed).fetch("matcher_version")).to eq(ActiveSanction::MATCHER_VERSION)
  end

  it "sums the five name shares to 1.0" do
    shares = %w[jaro_winkler levenshtein token_sort token_set phonetic]
    expect(weights.values_at(*shares).sum).to be_within(1e-9).of(1.0)
  end
end
