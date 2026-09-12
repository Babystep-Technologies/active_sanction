# frozen_string_literal: true

require "json"

# Not a spec for a class: this is #109's rule that no default value on the
# configuration reference page is typed by hand.
#
# The page renders `site/src/data/configuration.json`, which is generated from
# `Configuration.settings` -- itself derived from the writer methods, not
# listed -- and from a freshly built `Configuration`, the same object a caller
# who configures nothing gets. These examples run the generator and compare,
# the same shape as spec/site_sources_data_spec.rb and
# spec/site_weights_data_spec.rb.
#
# A setting appearing or disappearing here is a change to what
# `ActiveSanction.configure` accepts, which is exactly the kind of change a
# reviewer should see in a diff rather than discover on the reference page.
RSpec.describe "the generated configuration data behind the configuration reference page" do
  let(:root) { File.expand_path("..", __dir__) }

  let(:path) { File.join(root, "site", "src", "data", "configuration.json") }

  let(:committed) { File.read(path) }

  let(:generated) do
    load File.join(root, "site", "bin", "generate_configuration.rb")
    GenerateConfiguration.call
  end

  let(:settings) { JSON.parse(committed).fetch("settings") }

  it "is committed" do
    expect(File).to exist(path)
  end

  # The whole point. If this fails, run `bundle exec rake site:configuration`
  # and read the diff: it is either a setting that was added or removed, or a
  # default that changed, and both are worth seeing.
  it "matches what the generator produces today" do
    expect(committed).to eq(generated),
                         "site/src/data/configuration.json is stale. Run `bundle exec rake site:configuration`."
  end

  it "carries every setting Configuration accepts, and none it does not" do
    expect(settings.map { |setting| setting["name"] })
      .to match_array(ActiveSanction::Configuration.settings.map(&:to_s))
  end

  describe "every setting in it" do
    it "names a non-blank type" do
      types = settings.map { |setting| setting["type"] }
      expect(types.reject(&:empty?)).to eq(types)
    end

    it "names a default, even when the default is nil" do
      missing = settings.reject { |setting| setting.key?("default") }
      expect(missing.map { |setting| setting["name"] }).to be_empty
    end

    # #109's reason for special-casing these two: `Dir.home` on the machine
    # that ran the generator is not a fact about the library, and committing
    # it would make this file drift on every contributor's laptop.
    it "does not leak the generating machine's home directory into a path default" do
      home = Dir.home
      leaked = settings.select { |setting| setting["default"].to_s.include?(home) }

      expect(leaked.map { |setting| setting["name"] }).to be_empty
    end
  end
end
