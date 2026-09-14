# frozen_string_literal: true

require "date"
require "fileutils"
require "tmpdir"

# Not a spec for a class in `lib/`: this is the changelog surgery that
# `bin/prepare_release` does and that `.github/workflows/prepare-release.yml`
# runs, held to doing the same thing every time.
#
# It is worth a spec for one reason. The edits are three, they all have to
# agree, and doing them by hand is what failed between #138 and #141: two open
# pull requests, one renaming `## [Unreleased]` to `## [1.0.1]` and the other
# adding entries under `## [Unreleased]`, merged cleanly in sequence and filed
# a feature under a patch release that did not contain it. Nothing conflicted,
# nothing went red, and the changelog said something false about a published
# version. A script cannot make that mistake; a script nobody checks can make
# a different one.
RSpec.describe "bin/prepare_release" do
  before(:all) { load File.expand_path("../bin/prepare_release", __dir__) } # rubocop:disable RSpec/BeforeAfterAll

  let(:root) { Dir.mktmpdir("prepare_release") }

  let(:changelog) do
    <<~MARKDOWN
      # Changelog

      ## [Unreleased]

      ### Added

      - **Something new** (#144). It does a thing.

      ### Fixed

      - **Something old.** It did the wrong thing.

      ## [1.1.0] - 2026-09-14

      ### Added

      - **The last release.**

      [Unreleased]: https://github.com/acme/thing/compare/v1.1.0...main
      [1.1.0]: https://github.com/acme/thing/compare/v1.0.1...v1.1.0
      [1.0.1]: https://github.com/acme/thing/releases/tag/v1.0.1
    MARKDOWN
  end

  let(:version_rb) do
    <<~RUBY
      module ActiveSanction
        VERSION = "1.1.0"
        MATCHER_VERSION = "1"
      end
    RUBY
  end

  after { FileUtils.remove_entry(root) if File.directory?(root) }

  before do
    FileUtils.mkdir_p(File.join(root, "lib", "active_sanction"))
    File.write(File.join(root, "CHANGELOG.md"), changelog)
    File.write(File.join(root, "lib", "active_sanction", "version.rb"), version_rb)
  end

  def prepare(version = "1.2.0")
    PrepareRelease.call(version, root: root, today: Date.new(2026, 9, 15))
  end

  def written = File.read(File.join(root, "CHANGELOG.md"))

  def declared = File.read(File.join(root, "lib", "active_sanction", "version.rb"))

  # What `release.yml`'s announce job does, so these examples assert the note
  # a reader actually gets rather than the file it is cut from.
  def release_note(version)
    written.each_line.drop_while { |line| !line.start_with?("## [#{version}]") }
           .drop(1).take_while { |line| !line.start_with?("## ") }.join
  end

  describe "the version" do
    it "bumps VERSION to the one being prepared" do
      prepare

      expect(declared).to include('VERSION = "1.2.0"')
    end

    # `MATCHER_VERSION` answers a different question -- would this screening
    # come out the same today -- and a release that only adds a source adapter
    # must not move it. See lib/active_sanction/version.rb.
    it "leaves MATCHER_VERSION alone" do
      prepare

      expect(declared).to include('MATCHER_VERSION = "1"')
    end

    it "says what it did" do
      expect(prepare).to eq("1.1.0 -> 1.2.0, moving 2 changelog entries under ## [1.2.0] - 2026-09-15")
    end
  end

  describe "the changelog" do
    it "files the accrued entries under the new version" do
      prepare

      expect(release_note("1.2.0")).to include("Something new", "Something old")
    end

    # The #141 failure, asserted from the other side: the new section must not
    # reach into the one below it.
    it "leaves the previous release's entries where they were" do
      prepare

      expect(release_note("1.2.0")).not_to include("The last release")
    end

    it "leaves an empty Unreleased behind for the next change" do
      prepare

      expect(release_note("Unreleased").strip).to eq("Nothing yet.")
    end

    it "dates the heading" do
      prepare

      expect(written).to include("## [1.2.0] - 2026-09-15")
    end

    it "keeps the section headings the entries were written under" do
      prepare

      expect(release_note("1.2.0")).to include("### Added", "### Fixed")
    end
  end

  describe "the link definitions" do
    it "points Unreleased at the new tag" do
      prepare

      expect(written).to include("[Unreleased]: https://github.com/acme/thing/compare/v1.2.0...main")
    end

    it "adds a comparison for the new version against the one before it" do
      prepare

      expect(written).to include("[1.2.0]: https://github.com/acme/thing/compare/v1.1.0...v1.2.0")
    end

    it "leaves the older definitions alone" do
      prepare

      expect(written).to include("[1.1.0]: https://github.com/acme/thing/compare/v1.0.1...v1.1.0")
    end
  end

  describe "what it refuses" do
    # Releasing out of an empty Unreleased produces a release note of nothing.
    # `release.yml` already refuses that -- in the announce job, after the gem
    # is published, which is far too late to be useful.
    it "refuses a version with nothing to say" do
      File.write(File.join(root, "CHANGELOG.md"), changelog.sub(/### Added.*?(?=## \[1\.1\.0\])/m, "Nothing yet.\n\n"))

      expect { prepare }.to raise_error(PrepareRelease::Error, /empty/)
    end

    it "refuses a version that does not come after this one" do
      expect { prepare("1.0.0") }.to raise_error(PrepareRelease::Error, /does not come after 1\.1\.0/)
    end

    it "refuses a version that is not MAJOR.MINOR.PATCH" do
      expect { prepare("1.2") }.to raise_error(PrepareRelease::Error, /MAJOR\.MINOR\.PATCH/)
    end

    # Compared component by component, so a tenth minor is not read as less
    # than a ninth.
    it "accepts 1.10.0 after 1.9.0" do
      File.write(File.join(root, "lib", "active_sanction", "version.rb"), version_rb.sub("1.1.0", "1.9.0"))

      expect { prepare("1.10.0") }.not_to raise_error
    end

    it "takes a v-prefixed tag name as readily as a bare version" do
      prepare("v1.2.0")

      expect(declared).to include('VERSION = "1.2.0"')
    end

    it "changes nothing when it refuses" do
      suppress = -> { prepare("1.0.0") rescue PrepareRelease::Error } # rubocop:disable Style/RescueModifier
      suppress.call

      expect(declared).to include('VERSION = "1.1.0"')
    end
  end

  # The whole point of preparing a release is that `release.yml` then accepts
  # it, so the two gates it applies are asserted here rather than discovered
  # by a dispatch that fails.
  describe "what release.yml checks afterwards" do
    before { prepare }

    it "leaves a changelog section the workflow can find" do
      expect(written).to include("## [1.2.0]")
    end

    it "leaves the tag and VERSION able to agree" do
      expect(declared[/VERSION = "([^"]+)"/, 1]).to eq("1.2.0")
    end

    it "leaves a release note that is not empty" do
      expect(release_note("1.2.0").strip).not_to be_empty
    end
  end
end
