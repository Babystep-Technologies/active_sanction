# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# #105's tutorial page (site/src/content/docs/tutorial/index.md) runs exactly
# this sequence: configure a filesystem store, sync `un_consolidated` alone,
# screen a name that is on it, read why, and screen a name that is not.
#
# The subject is pinned: Bosco Ntaganda, published by the UN Security Council
# as "BOSCO TAGANDA" (reference CDi.030, listed 2005-11-01), with "Bosco
# Ntaganda" carried as a graded alias -- an ICC-convicted war criminal serving
# a thirty-year sentence, and about as unlikely a delisting as this list has.
# If he is ever removed, the tutorial's screening call silently returns an
# empty array, and the first person to notice would otherwise be a new user
# watching it fail. The `:live` example below is what notices first -- see
# .github/workflows/canary.yml, which runs it on schedule.
RSpec.describe "the tutorial (#105)" do
  let(:storage_dir) { Dir.mktmpdir("active_sanction_tutorial") }

  after do
    ActiveSanction.reset!
    FileUtils.remove_entry(storage_dir) if File.directory?(storage_dir)
  end

  def configure(dir)
    ActiveSanction.configure do |c|
      c.storage_dir = dir
      c.sources = [:un_consolidated]
    end
  end

  def run_tutorial
    report = ActiveSanction.sync!
    match = ActiveSanction.screen(name: "Bosco Ntaganda", type: :individual).first
    miss = ActiveSanction.screen(name: "Daniel Ashworth", type: :individual)
    [report, match, miss]
  end

  context "with a fixture-backed sync, as the normal suite runs it" do
    let(:raw) { File.binread(File.expand_path("fixtures/un_consolidated/consolidated.xml", __dir__)) }

    before do
      configure(storage_dir)
      stub_request(:get, ActiveSanction::Sources::UnConsolidated.url(:main))
        .to_return(status: 200, body: raw, headers: { "ETag" => '"tutorial"' })
    end

    # `age_in_words` rather than `age: 0`, and not as a weakening. A snapshot's
    # `fetched_at` is stored to the second -- Snapshot#time! truncates it, so
    # that a stored snapshot reloads equal to the one that was written -- so
    # the age of a list fetched a moment ago is 0 or 1 according to nothing but
    # whether the run crossed a second boundary between downloading the file
    # and reporting on it. Asserting 0 asserts that it did not, which is a fact
    # about the clock rather than about this library, and it failed on roughly
    # one CI job in six.
    #
    # "just fetched" is also the string the tutorial page actually shows in its
    # summary table, which makes this the output a reader is promised rather
    # than a number underneath it. See Storage::Meta#age.
    it "syncs one list and says what it did" do
      report, = run_tutorial

      expect(report[:un_consolidated])
        .to have_attributes(status: :updated, record_count: 7, age_in_words: "just fetched")
    end

    it "screens the pinned subject over the default threshold, on his name alone" do
      _report, match, = run_tutorial

      expect(match).to have_attributes(
        source: :un_consolidated,
        matched_name: have_attributes(value: "Bosco Ntaganda"),
        score: (be >= ActiveSanction.config.screening_threshold)
      )
    end

    it "explains the match with reasons that sum to the score" do
      _report, match, = run_tutorial

      expect(match.explanation.sum(&:contribution).round(1)).to eq(match.score)
    end

    it "screens a name that is not on the list as an empty array" do
      _report, _match, miss = run_tutorial

      expect(miss).to eq([])
    end
  end

  # Excluded by default, like every other `:live` example -- see
  # spec/spec_helper.rb. Run by hand with `bundle exec rspec --tag live`, and
  # wired into .github/workflows/canary.yml so a delisting fails that workflow
  # rather than a new user's first sync.
  describe "against the published list", :live do
    before { configure(storage_dir) }

    it "still finds the pinned subject" do
      ActiveSanction.sync!
      hit = ActiveSanction.screen(name: "Bosco Ntaganda", type: :individual).first

      expect(hit).to have_attributes(score: (be >= ActiveSanction.config.screening_threshold))
    end
  end
end
