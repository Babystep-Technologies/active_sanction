# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

RSpec.describe ActiveSanction::HttpClient do
  # A tiny backoff rather than a stubbed #sleep: the delays are real, they are
  # sub-millisecond, and the client under test stays an ordinary object.
  let(:client) { described_class.new(retry_backoff: 0.001) }

  # The real OFAC download URL, because every quirk this class exists for was
  # verified against it.
  let(:url) { "https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV" }
  let(:blob) { "https://ofacblob.blob.core.windows.net/sdn/SDN.CSV" }

  after { ActiveSanction.reset_configuration! }

  describe "#get" do
    it "returns the status, headers and body" do
      stub_request(:get, url).to_return(status: 200, body: "ent_num,SDN_Name\n",
                                        headers: { "Content-Type" => "text/csv" })

      response = client.get(url)

      expect(response).to have_attributes(status: 200, body: "ent_num,SDN_Name\n", content_type: "text/csv")
    end

    it "reports where the body finally came from" do
      stub_request(:get, url).to_return(status: 200, body: "ok")

      expect(client.get(url).uri.to_s).to eq(url)
    end

    it "looks headers up case-insensitively, since HTTP header names are" do
      stub_request(:get, url).to_return(status: 200, body: "ok", headers: { "ETag" => '"0953154d"' })

      expect(client.get(url)["etag"]).to eq('"0953154d"')
    end

    it "passes caller headers through, which is what conditional GET (#10) will need" do
      stub_request(:get, url).with(headers: { "If-None-Match" => '"0953154d"' }).to_return(status: 304)

      expect(client.get(url, headers: { "If-None-Match" => '"0953154d"' })).to be_not_modified
    end

    # A 304 carries no body by definition, and handing back the empty string
    # `read_body` produces would give a caller something to try to parse.
    it "leaves the body nil for a 304 rather than empty" do
      stub_request(:get, url).to_return(status: 304)

      expect(client.get(url).body).to be_nil
    end

    it "leaves the body encoding alone, since OFAC and the UN disagree about it" do
      stub_request(:get, url).to_return(status: 200, body: "Ali\xC3\xA9".dup.force_encoding(Encoding::BINARY))

      expect(client.get(url).body.bytesize).to eq(5)
    end
  end

  describe "the mandatory User-Agent" do
    # Verified live: OFAC answers 403 to a request without one.
    it "sends the configured identifier" do
      ActiveSanction.configure { |c| c.user_agent = "my-app/1.0 (compliance@example.com)" }
      stub = stub_request(:get, url).with(headers: { "User-Agent" => "my-app/1.0 (compliance@example.com)" })
                                    .to_return(status: 200, body: "ok")

      described_class.new.get(url)

      expect(stub).to have_been_made
    end

    it "falls back to an identifier naming the library" do
      stub = stub_request(:get, url).with(headers: { "User-Agent" => /active_sanction/ }).to_return(status: 200)

      client.get(url)

      expect(stub).to have_been_made
    end

    it "lets a single request override it" do
      stub = stub_request(:get, url).with(headers: { "User-Agent" => "one-off/2.0" }).to_return(status: 200)

      client.get(url, headers: { "user-agent" => "one-off/2.0" })

      expect(stub).to have_been_made
    end

    it "raises before opening a socket when the configured agent is blank" do
      expect { described_class.new(user_agent: " ") }
        .to raise_error(ActiveSanction::ConfigurationError, /user_agent is required/)
    end

    it "raises when a request blanks it out" do
      stub_request(:get, url).to_return(status: 200)

      expect { client.get(url, headers: { "User-Agent" => "" }) }
        .to raise_error(ActiveSanction::ConfigurationError)
    end

    it "raises before opening the socket, not after the publisher has answered 403" do
      stub_request(:get, url).to_return(status: 200)

      client.get(url, headers: { "User-Agent" => "" })
    rescue ActiveSanction::ConfigurationError
      expect(a_request(:get, url)).not_to have_been_made
    end
  end

  describe "redirects" do
    # Verified live: GET /api/download/SDN.CSV -> 302 -> 200 text/csv.
    it "follows a 302 to blob storage" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => blob })
      stub_request(:get, blob).to_return(status: 200, body: "ent_num,SDN_Name\n")

      response = client.get(url)

      expect(response).to have_attributes(status: 200, body: "ent_num,SDN_Name\n")
    end

    it "reports the URL that actually served the bytes" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => blob })
      stub_request(:get, blob).to_return(status: 200, body: "ok")

      expect(client.get(url).uri.to_s).to eq(blob)
    end

    it "records the hops it took" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => blob })
      stub_request(:get, blob).to_return(status: 200, body: "ok")

      expect(client.get(url).redirects.map(&:to_s)).to eq([url])
    end

    it "resolves a relative Location against the URL that produced it" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "/api/download/sdn.csv" })
      stub_request(:get, "https://sanctionslistservice.ofac.treas.gov/api/download/sdn.csv")
        .to_return(status: 200, body: "ok")

      expect(client.get(url).body).to eq("ok")
    end

    it "keeps sending the User-Agent on the redirected hop, which is where the file is" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => blob })
      stub = stub_request(:get, blob).with(headers: { "User-Agent" => /active_sanction/ }).to_return(status: 200)

      client.get(url)

      expect(stub).to have_been_made
    end

    [301, 302, 303, 307, 308].each do |status|
      it "follows a #{status}" do
        stub_request(:get, url).to_return(status: status, headers: { "Location" => blob })
        stub_request(:get, blob).to_return(status: 200, body: "ok")

        expect(client.get(url).body).to eq("ok")
      end
    end

    it "gives up after the configured number of hops" do
      hop = ->(n) { "https://redirect.example.gov/#{n}" }
      (0..4).each { |n| stub_request(:get, hop[n]).to_return(status: 302, headers: { "Location" => hop[n + 1] }) }

      expect { described_class.new(max_redirects: 3).get(hop[0]) }
        .to raise_error(described_class::TooManyRedirects, /exceeded 3 redirects/)
    end

    it "detects a chain that returns to a URL it already fetched" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => blob })
      stub_request(:get, blob).to_return(status: 302, headers: { "Location" => url })

      expect { client.get(url) }.to raise_error(described_class::RedirectLoop, /redirected back to/)
    end

    it "refuses to leave HTTP" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "ftp://ofac.example.gov/sdn.csv" })

      expect { client.get(url) }.to raise_error(described_class::InvalidRedirect, /ftp/)
    end

    # Zero is not "return me the 302": a caller asked for a document and a
    # pointer is not one. It is "this URL is not supposed to move".
    it "treats a cap of zero as refusing to follow at all" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => blob })

      expect { described_class.new(max_redirects: 0).get(url) }.to raise_error(described_class::TooManyRedirects)
    end

    it "returns a 3xx with no Location rather than guessing where it meant" do
      stub_request(:get, url).to_return(status: 302)

      expect(client.get(url).status).to eq(302)
    end
  end

  describe "retries" do
    it "retries a 500 and returns the success that follows" do
      stub_request(:get, url).to_return({ status: 500, body: "upstream error" }, { status: 200, body: "ok" })

      expect(client.get(url)).to have_attributes(status: 200, body: "ok")
    end

    it "backs off exponentially between attempts" do
      stub_request(:get, url).to_return({ status: 500 }, { status: 500 }, { status: 200 })
      slow = described_class.new(retry_backoff: 2, max_retries: 2)
      delays = []
      allow(slow).to receive(:sleep) { |seconds| delays << seconds }

      slow.get(url)

      expect(delays).to eq([2.0, 4.0])
    end

    it "returns the 5xx once the attempts are spent, since the server did answer" do
      stub_request(:get, url).to_return(status: 503, body: "maintenance")

      expect(client.get(url)).to have_attributes(status: 503, body: "maintenance")
    end

    it "makes exactly max_retries extra attempts" do
      stub_request(:get, url).to_return(status: 503)

      described_class.new(max_retries: 2, retry_backoff: 0.01).get(url)

      expect(a_request(:get, url)).to have_been_made.times(3)
    end

    # A 403 for a missing User-Agent says the request is wrong; repeating it
    # wastes the publisher's capacity to make the same point.
    it "hands back a 4xx rather than raising, so a source can report what happened" do
      stub_request(:get, url).to_return(status: 403, body: "Forbidden")

      expect(client.get(url)).to have_attributes(status: 403, body: "Forbidden")
    end

    it "never retries a 4xx" do
      stub_request(:get, url).to_return(status: 403, body: "Forbidden")

      client.get(url)

      expect(a_request(:get, url)).to have_been_made.once
    end

    it "retries a timeout" do
      stub_request(:get, url).to_timeout.then.to_return(status: 200, body: "ok")

      expect(client.get(url).body).to eq("ok")
    end

    it "raises a timeout that outlives its retries" do
      stub_request(:get, url).to_timeout

      expect { client.get(url) }.to raise_error(described_class::TimeoutError, /3 attempts/)
    end

    it "retries a reset connection" do
      stub_request(:get, url).to_raise(Errno::ECONNRESET).then.to_return(status: 200, body: "ok")

      expect(client.get(url).body).to eq("ok")
    end

    it "raises a connection failure that outlives its retries" do
      stub_request(:get, url).to_raise(SocketError.new("getaddrinfo: nodename nor servname provided"))

      expect { client.get(url) }.to raise_error(described_class::ConnectionError, /getaddrinfo/)
    end

    it "retries the hop that failed" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => blob })
      stub_request(:get, blob).to_return({ status: 500 }, { status: 200, body: "ok" })

      expect(client.get(url).body).to eq("ok")
    end

    it "does not replay the hops that succeeded" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => blob })
      stub_request(:get, blob).to_return({ status: 500 }, { status: 200, body: "ok" })

      client.get(url)

      expect(a_request(:get, url)).to have_been_made.once
    end

    it "honours max_retries: 0" do
      stub_request(:get, url).to_timeout

      expect { described_class.new(max_retries: 0).get(url) }
        .to raise_error(described_class::TimeoutError, /1 attempt:/)
    end
  end

  describe "#download" do
    let(:dir) { Dir.mktmpdir }
    let(:path) { File.join(dir, "sdn.csv") }

    after { FileUtils.remove_entry(dir) }

    it "writes the body to the path it was given" do
      stub_request(:get, url).to_return(status: 200, body: "ent_num,SDN_Name\n")

      client.download(url, to: path)

      expect(File.read(path)).to eq("ent_num,SDN_Name\n")
    end

    # Materializing a 126 MB list twice is how a sync job gets OOM-killed.
    it "does not also hold the body in memory" do
      stub_request(:get, url).to_return(status: 200, body: "ent_num,SDN_Name\n")

      expect(client.download(url, to: path).body).to be_nil
    end

    it "still reports the status and headers" do
      stub_request(:get, url).to_return(status: 200, body: "ok", headers: { "ETag" => '"0953154d"' })

      expect(client.download(url, to: path)).to have_attributes(status: 200, etag: '"0953154d"')
    end

    it "follows redirects on the way" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => blob })
      stub_request(:get, blob).to_return(status: 200, body: "ent_num,SDN_Name\n")

      client.download(url, to: path)

      expect(File.read(path)).to eq("ent_num,SDN_Name\n")
    end

    # An error page is not a sanctions list, and leaving one at the
    # destination is how a parser ends up reading "Forbidden" as a record.
    it "writes nothing to the destination when the server refuses" do
      stub_request(:get, url).to_return(status: 403, body: "Forbidden")

      client.download(url, to: path)

      expect(File).not_to exist(path)
    end

    it "keeps the error body in memory, where the caller can read it" do
      stub_request(:get, url).to_return(status: 403, body: "Forbidden")

      expect(client.download(url, to: path).body).to eq("Forbidden")
    end

    it "leaves no partial file behind when the fetch dies" do
      stub_request(:get, url).to_timeout

      client.download(url, to: path)
    rescue described_class::TimeoutError
      expect(Dir.children(dir)).to be_empty
    end

    it "leaves an existing file untouched on a 304, which has no body to write" do
      File.write(path, "yesterday's list")
      stub_request(:get, url).to_return(status: 304)

      client.download(url, to: path)

      expect(File.read(path)).to eq("yesterday's list")
    end

    it "writes into any IO the caller owns, which is what the payload cache (#11) needs" do
      stub_request(:get, url).to_return(status: 200, body: "ent_num,SDN_Name\n")
      sink = StringIO.new(+"", "wb")

      client.download(url, to: sink)

      expect(sink.string).to eq("ent_num,SDN_Name\n")
    end

    # Otherwise a retry appends a second prefix to the first one's bytes.
    it "starts the file over when a retry follows a partial write" do
      stub_request(:get, url).to_return({ status: 500, body: "half a" }, { status: 200, body: "the whole list" })

      client.download(url, to: path)

      expect(File.read(path)).to eq("the whole list")
    end
  end

  describe "bad URLs" do
    it "rejects a URL that is not HTTP" do
      expect { client.get("ftp://ofac.example.gov/sdn.csv") }.to raise_error(ArgumentError, /not an http/)
    end

    it "rejects a string that is not a URL at all" do
      expect { client.get("not a url") }.to raise_error(ArgumentError)
    end

    it "accepts a URI object" do
      stub_request(:get, url).to_return(status: 200, body: "ok")

      expect(client.get(URI(url)).body).to eq("ok")
    end
  end

  # Excluded from the default run; reachable only via `rspec --tag live`.
  describe "against OFAC itself", :live do
    it "downloads SDN.CSV through the 302 the endpoint really serves" do
      response = described_class.new.get("https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV")

      expect(response).to have_attributes(status: 200, content_type: a_string_including("csv"),
                                          redirects: a_collection_including(kind_of(URI::HTTP)))
    end

    # Net::HTTP sends `User-Agent: Ruby` unless the header is explicitly
    # deleted, and OFAC accepts that -- it is the *absence* of the header it
    # refuses. Deleting it is the only way to reproduce what the endpoint does
    # to a client that never thought about identifying itself.
    it "is refused without a User-Agent, which is why the header is mandatory" do
      uri = URI("https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV")
      request = Net::HTTP::Get.new(uri)
      request.delete("user-agent")
      raw = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }

      expect(raw.code).to eq("403")
    end
  end
end
