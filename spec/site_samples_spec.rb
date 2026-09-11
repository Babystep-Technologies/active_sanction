# frozen_string_literal: true

# Not a spec for a class: this is #103's answer to "every Ruby sample on the
# site must be executed somewhere, or it will rot".
#
# ### The decision
#
# The issue offered two approaches -- keep samples in `spec/` fixtures and
# include them into pages, or extract fenced blocks from the site and evaluate
# them. This is the second, with one addition that does most of the work:
# **every fenced Ruby block must declare which kind it is**, and a block that
# declares nothing fails.
#
#     <!-- sample: runnable -->
#     <!-- sample: illustrative -- needs a synced OFAC snapshot -->
#
# The reason for forcing the declaration is that the dangerous sample is not
# the one somebody marked wrong. It is the one nobody thought about, which
# looks exactly like a tested one to a reader. Making the author write down
# which they meant turns that into a line in a diff.
#
# **Runnable blocks are evaluated.** If the code raises, this fails and names
# the page and the line.
#
# **Illustrative blocks are still parsed.** They are not run -- they need a
# synced government list, a configured store, or they show output rather than
# input -- but a sample that does not parse is a sample nobody ever ran, and
# that is worth catching whatever the block was for. The marker carries its
# reason after `--`, because "why can this one not run?" is the question the
# next author will have.
RSpec.describe "the Ruby samples on the documentation site" do
  # An HTML comment in Markdown, and an expression comment in MDX, which cannot
  # carry an HTML comment at all. Both forms mean the same thing, and an author
  # should not have to remember which kind of file they are in.
  let(:marker) do
    %r{(?:<!--|\{/\*)\s*sample:\s*(runnable|illustrative)(.*?)(?:-->|\*/\})}m
  end

  let(:fence) { /^```ruby[^\n]*\n(.*?)^```/m }

  let(:root) { File.expand_path("..", __dir__) }

  let(:samples) do
    Dir.glob(File.join(root, "site", "src", "**", "*.{md,mdx}"))
       .flat_map { |page| extract(page) }
  end

  # Blocks in document order, each carrying the marker that most recently
  # preceded it. Consuming the marker after the block it applies to is what
  # keeps a single marker from vouching for every block below it on the page.
  def extract(page)
    content = File.read(page)
    found = []
    kind = nil
    reason = nil

    content.scan(/#{marker}|#{fence}/) do
      match = Regexp.last_match

      if match[1]
        kind = match[1].to_sym
        reason = match[2].to_s.sub(/\A\s*--\s*/, "").strip
      else
        found << { page: page.sub("#{root}/", ""), kind: kind, reason: reason,
                   line: content[0...match.begin(0)].count("\n") + 1,
                   code: match[3] }
        kind = nil
        reason = nil
      end
    end
    found
  end

  # `page:line`, which is what an author needs to find the block again.
  def where(sample)
    "#{sample[:page]}:#{sample[:line]}"
  end

  it "has samples to check at all" do
    expect(samples).not_to be_empty
  end

  it "declares every block runnable or illustrative" do
    undeclared = samples.select { |sample| sample[:kind].nil? }
                        .map { |sample| where(sample) }

    expect(undeclared).to be_empty,
                          "a fenced Ruby block with no `<!-- sample: ... -->` before it. " \
                          "Say which it is: #{undeclared.join(", ")}"
  end

  it "gives a reason for every block it does not run" do
    unexplained = samples.select { |sample| sample[:kind] == :illustrative && sample[:reason].to_s.empty? }
                         .map { |sample| where(sample) }

    expect(unexplained).to be_empty,
                           "illustrative with no reason after `--`: #{unexplained.join(", ")}"
  end

  it "parses every sample, whatever it is for" do
    broken = samples.filter_map do |sample|
      RubyVM::InstructionSequence.compile(sample[:code])
      nil
    rescue SyntaxError => e
      "#{where(sample)} -- #{e.message.lines.first&.strip}"
    end

    expect(broken).to be_empty,
                      "a sample that does not parse is one nobody ran: #{broken.join("; ")}"
  end

  # Evaluated in a module of its own, so a constant or a method defined by one
  # sample is never what makes the next one pass.
  it "runs every runnable sample without raising" do
    failures = samples.select { |sample| sample[:kind] == :runnable }.filter_map do |sample|
      Module.new.module_eval(sample[:code], sample[:page], sample[:line])
      nil
    rescue StandardError, ScriptError => e
      "#{where(sample)} -- #{e.class}: #{e.message}"
    end

    expect(failures).to be_empty, failures.join("; ")
  end

  it "actually has a runnable sample, so the example above means something" do
    expect(samples.map { |sample| sample[:kind] }).to include(:runnable)
  end
end
