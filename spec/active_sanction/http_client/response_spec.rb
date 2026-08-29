# frozen_string_literal: true

RSpec.describe ActiveSanction::HttpClient::Response do
  def response(status)
    described_class.new(status: status, headers: {}, uri: URI("https://example.gov/sdn.csv"))
  end

  it "joins a header a server repeated, the way the wire format does" do
    built = described_class.new(status: 200, headers: { "Set-Cookie" => %w[a=1 b=2] },
                                uri: URI("https://example.gov"))

    expect(built["set-cookie"]).to eq("a=1, b=2")
  end

  it "is frozen, so a response cannot be edited after the fact" do
    expect(response(200)).to be_frozen
  end

  it { expect(response(200)).to be_success }
  it { expect(response(304)).to be_not_modified }
  it { expect(response(302)).to be_redirect }
  it { expect(response(403)).to be_client_error }
  it { expect(response(503)).to be_server_error }

  it "returns itself from #success! when the server was happy" do
    built = response(200)

    expect(built.success!).to be(built)
  end

  it "raises from #success! for a status the caller declared fatal" do
    expect { response(403).success! }
      .to raise_error(ActiveSanction::HttpClient::ResponseError, %r{https://example.gov/sdn.csv returned 403})
  end

  it "carries the response on the error, so a rescuer can still log it" do
    response(403).success!
  rescue ActiveSanction::HttpClient::ResponseError => e
    expect(e.response.status).to eq(403)
  end
end
