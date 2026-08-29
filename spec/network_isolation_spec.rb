# frozen_string_literal: true

require "net/http"

# Guards the guard: if this ever passes by reaching the internet instead of
# raising, the whole suite has quietly stopped being hermetic.
RSpec.describe "network isolation" do
  it "refuses an un-stubbed HTTP call" do
    expect { Net::HTTP.get(URI("https://sanctionslistservice.ofac.treas.gov/api/download/sdn.xml")) }
      .to raise_error(WebMock::NetConnectNotAllowedError)
  end

  it "allows a stubbed HTTP call" do
    stub_request(:get, "https://example.gov/sdn.xml").to_return(body: "<sdnList/>")

    expect(Net::HTTP.get(URI("https://example.gov/sdn.xml"))).to eq("<sdnList/>")
  end

  # Excluded from the default run; reachable only via `rspec --tag live`.
  # Source adapters hang their real-endpoint smoke tests off this same tag.
  it "lifts the block for :live examples", :live do
    expect(WebMock).to be_net_connect_allowed
  end
end
