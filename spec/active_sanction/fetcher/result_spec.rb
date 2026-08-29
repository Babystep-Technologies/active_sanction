# frozen_string_literal: true

RSpec.describe ActiveSanction::Fetcher::Result do
  let(:url) { "https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV" }

  def result(status:, body: nil, headers: {})
    response = ActiveSanction::HttpClient::Response.new(status: status, headers: headers, uri: URI(url), body: body)
    described_class.new(key: :ofac_sdn, url: url, response: response)
  end

  # Three outcomes, not two: sync orchestration (#34) has to tell "the list did
  # not change" from "the publisher did not answer".
  describe "the three outcomes" do
    it "reads a 200 as changed" do
      expect(result(status: 200, body: "ent_num\n")).to be_changed.and be_ok
    end

    it "reads a 304 as unchanged" do
      expect(result(status: 304)).to be_unchanged.and be_ok
    end

    it "does not read a 304 as changed, so nothing is parsed" do
      expect(result(status: 304)).not_to be_changed
    end

    it "reads a 403 as failed" do
      expect(result(status: 403, body: "Forbidden")).to be_failed
    end

    it "reads a 500 that outlived its retries as failed" do
      expect(result(status: 500)).to be_failed
    end

    it "is not ok when it failed" do
      expect(result(status: 404)).not_to be_ok
    end
  end

  it "exposes the publisher's validators for a caller that wants to log them" do
    changed = result(status: 200,
                     headers: { "ETag" => '"0953154d"', "Last-Modified" => "Fri, 28 Aug 2026 14:02:55 GMT" })

    expect(changed).to have_attributes(etag: '"0953154d"', last_modified: "Fri, 28 Aug 2026 14:02:55 GMT")
  end

  it "looks headers up case-insensitively, as the response does" do
    expect(result(status: 200, headers: { "Content-Type" => "text/csv" })["content-type"]).to eq("text/csv")
  end

  describe "#success!" do
    it "returns itself for a changed list" do
      changed = result(status: 200, body: "ok")

      expect(changed.success!).to be(changed)
    end

    # Unlike Response#success!, since an unchanged list is the outcome the
    # whole mechanism exists to produce.
    it "lets a 304 through" do
      unchanged = result(status: 304)

      expect(unchanged.success!).to be(unchanged)
    end

    it "raises for a status the publisher will not stand behind" do
      expect { result(status: 403).success! }
        .to raise_error(ActiveSanction::HttpClient::ResponseError, /403/)
    end
  end

  it "says whether it was unchanged when printed" do
    expect(result(status: 304).to_s).to include("304", "unchanged")
  end

  it "is frozen" do
    expect(result(status: 200, body: "ok")).to be_frozen
  end
end
