# frozen_string_literal: true

require "yaml"

# Not a spec for a class: this is the half of #61 with no file of its own to
# check. Contributions are certified rather than assigned -- a `Signed-off-by`
# trailer under the Developer Certificate of Origin, and no contributor licence
# agreement, because the commercial advantage here is operational rather than
# code secrecy and there is no right to relicense worth reserving.
#
# A policy documented in CONTRIBUTING.md and enforced nowhere is one a
# contributor learns about only when it is too late to fix a branch cheaply, so
# if the check ever leaves CI these fail and ask why.
RSpec.describe "the sign-off contributors are asked for" do
  let(:root) { File.expand_path("..", __dir__) }

  let(:contributing) { File.read(File.join(root, "CONTRIBUTING.md")) }

  let(:workflow) { YAML.load_file(File.join(root, ".github", "workflows", "dco.yml")) }

  # `on:` is not a string. YAML 1.1 reads it as a boolean, so the trigger block
  # of every GitHub workflow is filed under `true` -- which is worth a line here
  # rather than a surprise in whatever reads this file next.
  let(:triggers) { workflow.fetch(true) }

  it "is enforced by a job" do
    expect(workflow.dig("jobs", "signed-off-by")).not_to be_nil
  end

  # Pull requests and not pushes. The trunk's own history predates the policy,
  # and a check that retroactively failed `main` would be red forever with
  # nothing anybody could do about it.
  it "runs where a contributor can still act on it" do
    expect(triggers).to have_key("pull_request")
  end

  it "names the trailer it actually asks for" do
    expect(contributing).to include("Signed-off-by:")
  end

  it "cites the certification that trailer is a sign-off on" do
    expect(contributing).to include("developercertificate.org")
  end

  # The fix has to travel with the failure. A contributor who has already
  # pushed needs the rebase, not just the flag they should have used.
  it "tells a contributor how to sign work already committed" do
    expect(contributing).to include("git rebase --signoff")
  end
end
