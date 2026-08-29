# frozen_string_literal: true

RSpec.describe ActiveSanction::Validators do
  # The real values OFAC served, since the point of the class is to echo a
  # publisher's own strings back to it untouched.
  let(:url) { "https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV" }
  let(:etag) { '"0953154d0fb5aff918c5ec1daf6e9c0e"' }
  let(:last_modified) { "Fri, 28 Aug 2026 14:02:55 GMT" }

  def response(status: 200, headers: {}, uri: URI(url))
    ActiveSanction::HttpClient::Response.new(status: status, headers: headers, uri: uri)
  end

  describe "#request_headers" do
    it "sends If-None-Match for a stored ETag" do
      validators = described_class.new(url: url, etag: etag)

      expect(validators.request_headers).to eq("If-None-Match" => etag)
    end

    it "sends If-Modified-Since for a stored Last-Modified" do
      validators = described_class.new(url: url, last_modified: last_modified)

      expect(validators.request_headers).to eq("If-Modified-Since" => last_modified)
    end

    it "sends both when the publisher gave both, as all three launch sources do" do
      validators = described_class.new(url: url, etag: etag, last_modified: last_modified)

      expect(validators.request_headers).to eq("If-None-Match" => etag, "If-Modified-Since" => last_modified)
    end

    it "sends nothing when the publisher gave nothing" do
      expect(described_class.new(url: url).request_headers).to be_empty
    end

    # An ETag is opaque and a Last-Modified is the server's own formatting.
    # Re-rendering either is how a working conditional GET quietly becomes a
    # full download.
    it "echoes a weak ETag back exactly as it arrived" do
      validators = described_class.new(url: url, etag: 'W/"0x8DF0558663FC719"')

      expect(validators.request_headers["If-None-Match"]).to eq('W/"0x8DF0558663FC719"')
    end

    it "echoes the publisher's date string rather than reformatting it" do
      validators = described_class.new(url: url, last_modified: "Mon, 24 Aug 2026 19:02:14 GMT")

      expect(validators.request_headers["If-Modified-Since"]).to eq("Mon, 24 Aug 2026 19:02:14 GMT")
    end
  end

  describe ".from_response" do
    it "takes both validators off the response" do
      raw = response(headers: { "ETag" => etag, "Last-Modified" => last_modified })

      expect(described_class.from_response(raw, url: url))
        .to have_attributes(etag: etag, last_modified: last_modified)
    end

    it "reads them case-insensitively, since a CDN may capitalize them differently" do
      raw = response(headers: { "etag" => etag })

      expect(described_class.from_response(raw, url: url).etag).to eq(etag)
    end

    # OFAC redirects to blob storage, and the hop that finally answers is not
    # stable enough to key a cache by.
    it "records the URL asked for, not the redirect target that answered" do
      raw = response(uri: URI("https://ofacblob.blob.core.windows.net/sdn/SDN.CSV"))

      expect(described_class.from_response(raw, url: url).url).to eq(url)
    end

    it "is empty when the publisher served neither validator" do
      expect(described_class.from_response(response, url: url)).to be_empty
    end
  end

  describe "#for?" do
    it "recognizes the URL it was stored against" do
      expect(described_class.new(url: url, etag: etag)).to be_for(url)
    end

    it "does not recognize a URL a publisher has moved its file to" do
      expect(described_class.new(url: url, etag: etag)).not_to be_for("#{url}?v=2")
    end

    it "accepts a URI as readily as a string" do
      expect(described_class.new(url: url, etag: etag)).to be_for(URI(url))
    end
  end

  describe "#confirmed_by" do
    let(:stored) do
      described_class.new(url: url, etag: etag, last_modified: last_modified,
                          checked_at: Time.utc(2026, 8, 28, 14, 2, 55))
    end

    it "moves the moment we last asked" do
      confirmed = stored.confirmed_by(response(status: 304), at: Time.utc(2026, 8, 29, 6, 0, 0))

      expect(confirmed.checked_at).to eq(Time.utc(2026, 8, 29, 6, 0, 0))
    end

    # The bytes did not change; only our confidence in them is newer.
    it "leaves the moment the list last changed alone" do
      confirmed = stored.confirmed_by(response(status: 304), at: Time.utc(2026, 8, 29, 6, 0, 0))

      expect(confirmed.updated_at).to eq(Time.utc(2026, 8, 28, 14, 2, 55))
    end

    it "keeps the validators when the 304 repeats none" do
      confirmed = stored.confirmed_by(response(status: 304))

      expect(confirmed).to have_attributes(etag: etag, last_modified: last_modified)
    end

    # RFC 9110 permits it, and the newer value is the one to send next time.
    it "takes a fresh ETag when the 304 carries one" do
      confirmed = stored.confirmed_by(response(status: 304, headers: { "ETag" => '"newer"' }))

      expect(confirmed.etag).to eq('"newer"')
    end
  end

  describe "serialization" do
    it "round-trips through #to_h" do
      validators = described_class.new(url: url, etag: etag, last_modified: last_modified)

      expect(described_class.from_h(validators.to_h)).to eq(validators)
    end

    # Which is what the JSON on disk hands back.
    it "round-trips through string keys" do
      validators = described_class.new(url: url, etag: etag)
      rehydrated = described_class.from_h(validators.to_h.transform_keys(&:to_s))

      expect(rehydrated).to eq(validators)
    end

    it "serializes times as ISO 8601, so a stored record reloads equal to what was written" do
      validators = described_class.new(url: url, etag: etag, checked_at: Time.utc(2026, 8, 28, 14, 2, 55))

      expect(validators.to_h[:checked_at]).to eq("2026-08-28T14:02:55Z")
    end

    it "rejects an attribute it does not know, rather than dropping it" do
      expect { described_class.from_h(url: url, sha256: "abc") }
        .to raise_error(ArgumentError, /unknown Validators attribute/)
    end
  end

  describe "construction" do
    it "requires a URL, since validators only mean anything against one" do
      expect { described_class.new(url: " ") }.to raise_error(ArgumentError, /url is required/)
    end

    it "treats a blank ETag as no ETag" do
      expect(described_class.new(url: url, etag: "  ")).to be_empty
    end

    it "defaults updated_at to checked_at for a first fetch" do
      validators = described_class.new(url: url, etag: etag, checked_at: Time.utc(2026, 8, 28))

      expect(validators.updated_at).to eq(Time.utc(2026, 8, 28))
    end

    it "is frozen" do
      expect(described_class.new(url: url, etag: etag)).to be_frozen
    end

    it "compares by value" do
      at = Time.utc(2026, 8, 28)
      validators = described_class.new(url: url, etag: etag, checked_at: at)

      expect(described_class.from_h(validators.to_h)).to eq(validators)
    end

    # Two fetches of the same file from two addresses are not interchangeable:
    # the URL is what says whose ETag this is.
    it "distinguishes records differing only in the URL they came from" do
      at = Time.utc(2026, 8, 28)

      expect(described_class.new(url: url, etag: etag, checked_at: at))
        .not_to eq(described_class.new(url: "#{url}?v=2", etag: etag, checked_at: at))
    end
  end
end
