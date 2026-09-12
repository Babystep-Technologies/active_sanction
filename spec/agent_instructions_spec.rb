# frozen_string_literal: true

# Not a spec for a class: this is #113, and it is what makes the skills under
# `.claude/` go stale visibly rather than silently.
#
# ### What is being held to what
#
# A skill is a procedure written beside the code it describes, which is the
# whole argument for keeping it in the repository rather than in somebody's
# dotfiles. That argument only survives if a rename in `lib/` or a section
# retitled in `docs/adding_a_source.md` breaks a build rather than leaving a
# confident pointer into nothing. An agent following a stale instruction does
# not stop -- it writes something plausible, which in a sanctions library is
# the specific failure the instruction existed to prevent.
#
# So: every relative link in an agent-facing document resolves to a file that
# exists, every anchor it names is a heading that exists, and the frontmatter
# a skill loader reads is well formed. Absolute URLs are not fetched, for the
# same reason the site's link checker does not fetch them.
#
# ### And the packaging half
#
# None of it ships. `spec/licensing_spec.rb` owns the same rule for `.github/`
# and `site/`; this file owns it for `.claude/` and `AGENTS.md`, next to the
# examples that read them.
RSpec.describe "the agent instructions" do
  let(:root) { File.expand_path("..", __dir__) }

  # The three kinds of file an agent is pointed at, in the order it meets them:
  # the entry point, the skills a loader reads, and the rules both skills share.
  let(:documents) do
    ["AGENTS.md"] +
      Dir.glob(".claude/**/*.md", base: root).sort
  end

  let(:skills) { Dir.glob(".claude/skills/*/SKILL.md", base: root).sort }

  # `[text](target)`, minus the ones that are not ours to check: absolute URLs,
  # bare anchors, and the angle-bracketed placeholders a command sketch uses.
  let(:link) { /\[[^\]]*\]\(([^)\s]+)\)/ }

  def body(path) = File.read(File.join(root, path))

  def links(path)
    body(path).scan(link).flatten.reject do |target|
      target.start_with?("http://", "https://", "mailto:", "#") || target.include?("<")
    end
  end

  # A GitHub-flavoured anchor: the heading text, lowercased, punctuation
  # dropped, spaces hyphenated. The same slugs `docs/adding_a_source.md`
  # already links itself by.
  def anchors(path)
    body(path).scan(/^#+\s+(.+?)\s*$/).flatten.map do |heading|
      heading.downcase.gsub(/[^\w\s-]/, "").strip.gsub(/\s+/, "-")
    end
  end

  it "has documents to check at all" do
    expect(documents).to include("AGENTS.md", ".claude/rules/adapter-rules.md")
  end

  # Two rather than one, because adding a list and repairing one are two jobs
  # with different failure modes.
  it "has both skills" do
    expect(skills).to include(".claude/skills/adding-a-source/SKILL.md",
                              ".claude/skills/repairing-a-source/SKILL.md")
  end

  it "links only to files that exist" do
    missing = documents.flat_map do |document|
      links(document).filter_map do |target|
        path = File.expand_path(target.split("#").first.to_s, File.dirname(File.join(root, document)))
        "#{document} -> #{target}" unless File.exist?(path)
      end
    end

    expect(missing).to be_empty, "a pointer into nothing is worse than no pointer: #{missing.join(", ")}"
  end

  # The failure this catches is a section of `docs/adding_a_source.md` being
  # retitled. The link still lands somewhere real -- the top of the page --
  # and the agent reads the wrong section, silently.
  it "links only to anchors that exist" do
    broken = documents.flat_map do |document|
      links(document).filter_map do |target|
        file, anchor = target.split("#")
        next if anchor.nil? || anchor.empty?

        path = File.expand_path(file.to_s, File.dirname(File.join(root, document)))
        next unless File.exist?(path)

        "#{document} -> #{target}" unless anchors(path.sub("#{root}/", "")).include?(anchor)
      end
    end

    expect(broken).to be_empty, "a heading was retitled and a pointer was left behind: #{broken.join(", ")}"
  end

  describe "every skill" do
    # Deliberately not a YAML parse: what matters is that the frontmatter is
    # the shape a loader reads, and the failure worth catching is a `#` in an
    # unquoted value, which YAML reads as a comment and silently truncates.
    def frontmatter(path)
      match = body(path).match(/\A---\n(.*?)\n---\n/m)
      raise "#{path} has no frontmatter" unless match

      match[1].lines.to_h { |line| line.split(":", 2).map(&:strip) }
    end

    it "names itself after its own directory" do
      named = skills.to_h { |skill| [skill, frontmatter(skill)["name"]] }

      expect(named).to eq(skills.to_h { |skill| [skill, File.basename(File.dirname(skill))] })
    end

    # The description is the whole of what a loader decides on. One that says
    # too little never loads, and one past the limit is truncated.
    it "says when to load in a description a loader will keep whole" do
      wrong = skills.reject { |skill| (80..400).cover?(frontmatter(skill)["description"].to_s.length) }

      expect(wrong).to be_empty, "a description nothing would match on: #{wrong.join(", ")}"
    end

    # The description is the whole of what a loader decides on, and an
    # unquoted ` #` truncates it at the hash without any error anywhere.
    it "keeps a comment character out of an unquoted frontmatter value" do
      offenders = skills.select do |skill|
        frontmatter(skill).values.any? { |value| value.match?(/\s#/) && !value.match?(/\A["']/) }
      end

      expect(offenders).to be_empty,
                           "YAML reads ` #` in an unquoted value as a comment and drops the rest: #{offenders}"
    end

    # Two skills, one copy of the rules. Two copies of a procedure means one of
    # them is wrong within a release, which is the argument this whole
    # directory rests on.
    it "points at the shared rules rather than restating them" do
      skills.each do |skill|
        expect(body(skill)).to include("adapter-rules.md"),
                               "#{skill} does not send its reader to the rules"
      end
    end
  end

  # The gemspec's `dev_only` rule. `.claude/` is excluded by the leading-dot
  # alternative and `AGENTS.md` by name -- both are instructions for working on
  # this repository, and neither says anything to an application that installed
  # the gem.
  describe "what gem build packages" do
    let(:packaged) do
      Gem::Specification.load(File.join(root, "active_sanction.gemspec")).files
    end

    it "ships nothing from .claude/" do
      expect(packaged.grep(%r{\A\.claude/})).to be_empty
    end

    it "ships no AGENTS.md" do
      expect(packaged).not_to include("AGENTS.md")
    end
  end
end
