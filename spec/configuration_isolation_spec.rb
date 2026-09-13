# frozen_string_literal: true

# Guards the guard, as `network_isolation_spec.rb` does for WebMock: the suite
# resets `ActiveSanction.config` after every example, and if it ever stops the
# failure it causes is a different spec failing on some seeds. That is the
# hardest kind of red build to read, because the spec that breaks is not the
# spec that is wrong -- #123 spent its length establishing that the example
# asserting the default threshold was correct and the one before it had moved
# the world underneath it.
#
# Ordered, because the claim is about what one example leaves for the next and
# a randomised pair cannot make it. These two run in the order written even
# when the rest of the suite does not.
RSpec.describe "global configuration isolation", order: :defined do
  it "lets an example configure the library globally" do
    ActiveSanction.configure { |c| c.screening_threshold = 80 }

    expect(ActiveSanction.config.screening_threshold).to eq(80.0)
  end

  it "does not let that reach the next example" do
    expect(ActiveSanction.config.screening_threshold)
      .to eq(ActiveSanction::Configuration::DEFAULT_SCREENING_THRESHOLD)
  end
end
