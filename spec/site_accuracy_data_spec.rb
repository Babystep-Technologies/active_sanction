# frozen_string_literal: true

# Not a spec for a class: this is #109's rule that the site's only rendering
# of measured accuracy can never disagree with `benchmark/results/accuracy.md`.
#
# The reference page is generated from that file rather than written
# separately -- see site/bin/generate_accuracy.rb -- so a matcher retune that
# rewrites the committed benchmark report is caught here rather than leaving
# the site quoting a stale F1 curve.
RSpec.describe "the generated accuracy reference page" do
  let(:root) { File.expand_path("..", __dir__) }

  let(:source_path) { File.join(root, "benchmark", "results", "accuracy.md") }

  let(:page_path) { File.join(root, "site", "src", "content", "docs", "reference", "accuracy.md") }

  let(:committed) { File.read(page_path) }

  let(:generated) do
    load File.join(root, "site", "bin", "generate_accuracy.rb")
    GenerateAccuracy.call
  end

  it "is committed" do
    expect(File).to exist(page_path)
  end

  # The whole point. If this fails, run `bundle exec rake site:accuracy` and
  # read the diff: it is a `rake benchmark:accuracy` re-run, and that is
  # exactly the change a reader of this page should see.
  it "matches what the generator produces today" do
    expect(committed).to eq(generated),
                         "site/src/content/docs/reference/accuracy.md is stale. Run `bundle exec rake site:accuracy`."
  end

  it "carries every figure benchmark/results/accuracy.md reports" do
    source_body = File.read(source_path).sub(/\A# .*\n\n?/, "")
    expect(committed).to include(source_body)
  end

  it "declares a Starlight title so the copied file's own heading is not duplicated" do
    expect(committed).to start_with("---\ntitle:")
  end
end
