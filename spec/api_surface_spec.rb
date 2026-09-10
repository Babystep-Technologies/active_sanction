# frozen_string_literal: true

require "yard"

# Not a spec for a class: this is #62, and it is the reason `docs/api_stability.md`
# is a promise rather than an essay.
#
# Every constant a user can reach is a constant somebody will reach. Without a
# stated boundary an internal becomes load-bearing by accident, and the release
# that renames it turns into a breaking change nobody meant to ship. So the
# public surface is enumerated in that document, everything else is marked
# `@api private` in the source, and these examples hold the two to each other
# in both directions: a new public constant that nobody wrote down fails, and
# a name written down that no longer exists fails too.
#
# The document is the source of truth and this file reads it. Keeping the list
# in a spec instead would put the promise somewhere no user looks.
RSpec.describe "the public API surface" do
  let(:document) { File.expand_path("../docs/api_stability.md", __dir__) }

  # Constants that exist only when an optional dependency is loaded. They are
  # public when present, and their absence is not a failure -- ActiveRecord is
  # not a dependency of this gem and a host without it is a supported host.
  let(:optional) { %w[ActiveSanction::Storage::ActiveRecord] }

  # The enumerated surface, read out of the fenced blocks under its own
  # heading. Fences elsewhere in the document -- the extension points, a sample
  # warning -- are deliberately not read: that section is the list, and a name
  # mentioned in prose is not a promise.
  let(:promised) do
    lines = File.readlines(document, chomp: true)
    start = lines.index { |line| line.start_with?("## The enumerated public surface") }
    raise "the enumerated surface heading is gone from #{document}" unless start

    fenced = false
    lines[start..].each_with_object([]) do |line, names|
      next fenced = !fenced if line.start_with?("```")

      names << line.strip if fenced && line.start_with?("ActiveSanction")
    end
  end

  # Everything a host can actually reach by walking constants from the root,
  # which is the surface as a user experiences it rather than as the source
  # happens to be laid out.
  let(:reachable) do
    found = []
    walk = lambda do |mod, prefix|
      mod.constants(false).sort.each do |name|
        path = "#{prefix}::#{name}"
        next if found.include?(path)

        value = begin
          mod.const_get(name, false)
        rescue StandardError, LoadError
          next
        end
        found << path
        walk.call(value, path) if value.is_a?(Module)
      end
    end
    walk.call(ActiveSanction, "ActiveSanction")
    found
  end

  # What the source says about itself. Parsing `lib/` costs a couple of seconds
  # once, which is the price of the tags being read from where an author writes
  # them rather than from a second list that would drift.
  let(:marked_private) do
    YARD::Registry.clear
    YARD.parse(Dir[File.expand_path("../lib/**/*.rb", __dir__)], [], YARD::Logger::ERROR)
    YARD::Registry.all(:constant, :class, :module)
                  .select { |object| object.tag(:api)&.text == "private" }
                  .map(&:path)
  end

  # A namespace marked private carries everything under it. Tagging
  # `Similarity` privately is a statement about its forty constants, and
  # repeating the tag on each of them would be forty lines saying what one
  # already said.
  def private?(path, marked)
    marked.any? { |name| path == name || path.start_with?("#{name}::") }
  end

  it "promises names that all exist" do
    missing = promised - reachable - optional - ["ActiveSanction"]

    expect(missing).to be_empty,
                       "#{document} promises constants that are gone: #{missing.join(", ")}"
  end

  # Listed whether or not they can be loaded here. ActiveRecord is not a
  # dependency of this gem and a host without it is a supported host, but the
  # promise about that adapter is the same promise -- and somebody deciding
  # whether to build on it should not have to install Rails to find out.
  it "promises the optional constants, loadable in this process or not" do
    expect(promised).to include(*optional)
  end

  # The acceptance criterion of #62: widening the surface is a deliberate diff.
  it "reaches nothing that is neither promised nor marked private" do
    marked = marked_private
    unclassified = reachable.reject do |path|
      promised.include?(path) || private?(path, marked)
    end

    expect(unclassified).to be_empty,
                            "neither in #{document} nor marked `@api private`: " \
                            "#{unclassified.sort.join(", ")}"
  end

  # The other direction. A name cannot be promised in the document and denied
  # in the source, which is the state that would let a `rake doc` hide
  # something a user was told to rely on.
  it "marks nothing private that it also promises" do
    marked = marked_private
    contradicted = promised.select { |path| marked.include?(path) }

    expect(contradicted).to be_empty,
                            "promised and marked `@api private`: #{contradicted.join(", ")}"
  end

  it "lists each promised name once" do
    expect(promised).to eq(promised.uniq)
  end

  # The three that carry the strongest guarantee, because breaking one forks
  # every adapter written outside this repository at once.
  describe "the extension points" do
    %w[
      ActiveSanction::Sources::Base
      ActiveSanction::Storage::Base
      ActiveSanction::ValidatorStore
    ].each do |extension_point|
      it "promises #{extension_point}" do
        expect(promised).to include(extension_point)
      end
    end
  end

  # The document is what a user reads before depending on something, so the
  # README has to be able to get them there.
  it "is linked from the README" do
    readme = File.read(File.expand_path("../README.md", __dir__))

    expect(readme).to include("docs/api_stability.md")
  end

  # And it travels with the code. A dependency is often read from a vendored
  # bundle or an air-gapped host, where the question "may I rely on this?" is
  # being asked by somebody who cannot reach GitHub to find the answer.
  it "ships inside the gem" do
    gemspec = Gem::Specification.load(File.expand_path("../active_sanction.gemspec", __dir__))

    expect(gemspec.files).to include("docs/api_stability.md")
  end
end
