# frozen_string_literal: true

require "json"
require "openssl"
require "stringio"
require "zlib"

RSpec.describe ActiveSanction::Snapshot::Bundle do
  def entity(ref, **overrides)
    ActiveSanction::Entity.new(
      source: :ofac_sdn, source_ref: ref, type: :individual,
      names: [ActiveSanction::Name.new(value: "AL ZAWAHIRI, Aiman", kind: :primary)],
      identifiers: [ActiveSanction::Identifier.new(kind: :passport, value: ref, country: "EG")],
      dates_of_birth: [ActiveSanction::PartialDate.parse("1951-06-19")],
      programs: ["SDGT"], remarks: "DOB 19 Jun 1951; POB Egypt", **overrides
    )
  end

  def snapshot(refs = %w[2674 1234], **overrides)
    ActiveSanction::Snapshot.new(source: :ofac_sdn, entities: refs.map { |ref| entity(ref) },
                                 fetched_at: Time.utc(2026, 8, 28, 9, 30, 0), source_version: "2026-08-28",
                                 **overrides)
  end

  # A bundle as bytes, which is the only form any of this is interesting in.
  def write(list = snapshot, **options)
    io = StringIO.new(+"", "wb")
    described_class.write(list, io: io, **options)
    io.string
  end

  def read(bytes, **options) = described_class.read(StringIO.new(bytes), **options)

  def lines(bytes) = bytes.split("\n", 4)
  def header_of(bytes) = JSON.parse(lines(bytes)[1])
  def payload_of(bytes) = Zlib::Inflate.inflate(lines(bytes)[3])

  # Re-assembles a bundle from parts, so an example can put one thing wrong and
  # leave everything else exactly as it was written.
  def rebuild(bytes, magic: nil, header: nil, signature: nil, payload: nil)
    parts = lines(bytes)
    packed = payload.nil? ? parts[3] : Zlib::Deflate.deflate(payload, 6)
    "#{magic || parts[0]}\n#{header || parts[1]}\n#{signature || parts[2]}\n#{packed}"
  end

  let(:key) { OpenSSL::PKey::EC.generate("prime256v1") }
  let(:other_key) { OpenSSL::PKey::EC.generate("prime256v1") }

  describe "the container" do
    let(:bytes) { write }

    it "begins with the magic and the format version" do
      expect(bytes).to start_with("ACTIVESANCTION-BUNDLE/1\n")
    end

    # The point of three lines of text: an operator finds out what a file holds
    # with `head`, without this gem and without decompressing anything.
    it "puts the whole header on one readable line" do
      expect(header_of(bytes)).to include("source" => "ofac_sdn", "record_count" => 2,
                                          "generator" => "active_sanction/#{ActiveSanction::VERSION}")
    end

    it "marks an unsigned bundle with a dash rather than an empty line" do
      expect(lines(bytes)[2]).to eq("-")
    end

    it "writes the records as one JSON object per line" do
      expect(payload_of(bytes).lines.map { |line| JSON.parse(line)["source_ref"] }).to contain_exactly("1234", "2674")
    end

    it "states the digest and length of the payload before compression" do
      payload = payload_of(bytes)

      expect(header_of(bytes)).to include("payload_bytes" => payload.bytesize,
                                          "payload_digest" => "sha256:#{Digest::SHA256.hexdigest(payload)}")
    end
  end

  describe "the round trip" do
    it "comes back as the same list" do
      loaded = read(write)

      expect(loaded.checksum).to eq(snapshot.checksum)
    end

    it "keeps every field of every record" do
      expect(read(write).entities.map(&:to_h)).to match_array(snapshot.entities.map(&:to_h))
    end

    it "keeps when the list was fetched and what the publisher called it" do
      loaded = read(write)

      expect([loaded.fetched_at, loaded.source_version]).to eq([snapshot.fetched_at, "2026-08-28"])
    end

    it "reads a list with nobody on it" do
      empty = ActiveSanction::Snapshot.new(source: :ofac_sdn, entities: [])

      expect(read(write(empty)).checksum).to eq(empty.checksum)
    end

    it "refuses to write something that is not a snapshot" do
      expect { write({ source: :ofac_sdn }) }
        .to raise_error(ActiveSanction::InvalidArgument, /takes an ActiveSanction::Snapshot/)
    end
  end

  # The acceptance criterion behind "checksums are comparable across machines".
  describe "determinism" do
    it "writes the same bytes for the same list twice" do
      first = write
      second = write

      expect(second).to eq(first)
    end

    it "is unmoved by the order a publisher happened to emit its records in" do
      reordered = ActiveSanction::Snapshot.new(source: :ofac_sdn, entities: snapshot.entities.reverse,
                                               fetched_at: Time.utc(2026, 8, 28, 9, 30, 0),
                                               source_version: "2026-08-28")

      expect(write(reordered)).to eq(write)
    end

    it "changes when a single field of a single record changes" do
      edited = ActiveSanction::Snapshot.new(source: :ofac_sdn, source_version: "2026-08-28",
                                            entities: [entity("2674"), entity("1234", programs: %w[SDT])],
                                            fetched_at: Time.utc(2026, 8, 28, 9, 30, 0))

      expect(write(edited)).not_to eq(write)
    end

    it "records who published it, so two mirrors of one list are still distinguishable" do
      expect(write(generator: "acme-mirror/2.0")).not_to eq(write)
    end
  end

  describe "a bundle that is not what it says it is" do
    let(:bytes) { write }

    # The acceptance criterion: flipping one byte fails.
    it "refuses a payload with one byte flipped" do
      flipped = bytes.dup
      last = flipped.bytesize - 5
      flipped[last] = (flipped[last].ord ^ 0xff).chr

      expect { read(flipped) }.to raise_error(described_class::Corrupt)
    end

    # The one an attacker would actually attempt: edit a record and repack it,
    # so that zlib's own checks pass and only the digest in the header does not.
    it "refuses an edited record that was re-compressed cleanly" do
      forged = rebuild(bytes, payload: payload_of(bytes).sub("AL ZAWAHIRI", "AL ZAWAHIRJ"))

      expect { read(forged) }.to raise_error(described_class::Corrupt, /records hash to/)
    end

    it "refuses a truncated file" do
      expect { read(bytes[0..-20]) }.to raise_error(described_class::Corrupt)
    end

    it "refuses bytes appended after the payload" do
      expect { read("#{bytes}and more") }.to raise_error(described_class::Corrupt, /after the end of its payload/)
    end

    it "refuses a file that is not a bundle at all" do
      expect { read("{\"source\":\"ofac_sdn\"}\n") }
        .to raise_error(described_class::Corrupt, /does not begin with ACTIVESANCTION-BUNDLE/)
    end

    it "refuses a header that is not JSON" do
      expect { read(rebuild(bytes, header: "not json")) }
        .to raise_error(described_class::Corrupt, /header cannot be read/)
    end

    it "refuses a header naming a record count the payload does not hold" do
      edited = header_of(bytes).merge("record_count" => 3)

      expect { read(rebuild(bytes, header: JSON.generate(edited))) }
        .to raise_error(described_class::Corrupt, /does not hold the list its header describes/)
    end

    it "refuses a header whose snapshot checksum is not what the records come to" do
      edited = header_of(bytes).merge("snapshot_checksum" => "sha256:#{"0" * 64}")

      expect { read(rebuild(bytes, header: JSON.generate(edited))) }
        .to raise_error(described_class::Corrupt, /does not hold the list its header describes/)
    end

    # The version is on the first line so a reader can act on it early, and in
    # the header so that it is covered by the signature. They have to agree.
    it "refuses a magic line that disagrees with the header" do
      expect { read(rebuild(bytes, header: JSON.generate(header_of(bytes).merge("format_version" => 2)))) }
        .to raise_error(described_class::Corrupt, /only one of them is signed/)
    end

    it "refuses a payload that decompresses to more than the header declares" do
      long = rebuild(bytes, payload: payload_of(bytes) + ("#{JSON.generate(entity("9999").to_h)}\n" * 50))

      expect { read(long) }.to raise_error(described_class::Corrupt, /decompresses to more than/)
    end

    it "refuses a header line longer than it will read" do
      expect { read("ACTIVESANCTION-BUNDLE/1\n#{"x" * 70_000}") }
        .to raise_error(described_class::Corrupt, /longer than 65536 bytes/)
    end
  end

  # The acceptance criterion: a version mismatch is specific and actionable.
  describe "a bundle from a newer gem" do
    let(:bytes) { write }

    it "refuses a format version it does not know, and says to upgrade" do
      expect { read(rebuild(bytes, magic: "ACTIVESANCTION-BUNDLE/2")) }
        .to raise_error(described_class::UnsupportedFormat, /bundle format version 2.*Upgrade the gem/m)
    end

    it "refuses a snapshot schema it does not know" do
      edited = header_of(bytes).merge("schema_version" => 99)

      expect { read(rebuild(bytes, header: JSON.generate(edited))) }
        .to raise_error(described_class::UnsupportedFormat, /schema_version 99/)
    end

    it "refuses a payload encoding it has never heard of" do
      edited = header_of(bytes).merge("payload_encoding" => "protobuf")

      expect { read(rebuild(bytes, header: JSON.generate(edited))) }
        .to raise_error(described_class::UnsupportedFormat, %r{protobuf/deflate})
    end

    # A format version this reader cannot read is refused before its header is
    # even parsed, which is what makes the message about the version rather
    # than about whatever else a future header might carry.
    it "refuses it before parsing anything else" do
      expect { read("ACTIVESANCTION-BUNDLE/7\n") }
        .to raise_error(described_class::UnsupportedFormat, /version 7/)
    end
  end

  describe "signing" do
    it "loads an unsigned bundle, and says it is not attested" do
      expect(read(write).trusted?).to be(false)
    end

    it "does not look at a signature nobody asked about" do
      expect(read(write(sign_with: key)).trusted?).to be(false)
    end

    it "marks a bundle that verified under the key given" do
      expect(read(write(sign_with: key), verify_with: key).trusted?).to be(true)
    end

    it "verifies against a public key on its own" do
      public_key = OpenSSL::PKey.read(key.public_to_pem)

      expect(read(write(sign_with: key), verify_with: public_key).trusted?).to be(true)
    end

    it "verifies against a PEM string" do
      expect(read(write(sign_with: key), verify_with: key.public_to_pem).trusted?).to be(true)
    end

    it "signs with RSA as well" do
      rsa = OpenSSL::PKey::RSA.new(2048)

      expect(read(write(sign_with: rsa), verify_with: rsa).trusted?).to be(true)
    end

    it "names the algorithm on the signature line" do
      expect(lines(write(sign_with: key))[2]).to match(%r{\Aecdsa-sha256 [A-Za-z0-9+/=]+\z})
    end

    # The acceptance criterion: an unknown signer fails distinctly from a
    # corrupt file, because only one of the two is fixed by downloading again.
    it "refuses a bundle signed by somebody else" do
      expect { read(write(sign_with: key), verify_with: other_key) }
        .to raise_error(described_class::UntrustedSignature, /somebody other than the expected publisher/)
    end

    it "refuses an unsigned bundle when verification was asked for" do
      expect { read(write, verify_with: key) }
        .to raise_error(described_class::Unsigned, /carries no signature/)
    end

    it "leaves an unsigned bundle catchable as any other verification failure" do
      expect { read(write, verify_with: key) }.to raise_error(described_class::UntrustedSignature)
    end

    it "refuses a bundle signed with a key of a different kind" do
      rsa = OpenSSL::PKey::RSA.new(2048)

      expect { read(write(sign_with: rsa), verify_with: key) }
        .to raise_error(described_class::UntrustedSignature, /signed rsa-sha256/)
    end

    it "refuses to sign with a key the format does not define" do
      expect { write(sign_with: Object.new) }
        .to raise_error(ActiveSanction::InvalidArgument, /OpenSSL::PKey or a PEM string/)
    end

    it "reserves ed25519 rather than guessing at it" do
      forged = rebuild(write(sign_with: key), signature: "ed25519 #{["x" * 64].pack("m0")}")

      expect { read(forged, verify_with: key) }
        .to raise_error(described_class::UnsupportedFormat, /reserves but does not verify/)
    end

    # Signing covers the header, and the header covers the payload's digest --
    # so an unknown signer is refused without a byte of what they sent being
    # decompressed.
    it "settles who signed a bundle before inflating any of it" do
      damaged = write(sign_with: key)[0..-30]

      expect { read(damaged, verify_with: other_key) }.to raise_error(described_class::UntrustedSignature)
    end

    it "signs the header, so editing it breaks the signature" do
      signed = write(sign_with: key)
      forged = rebuild(signed, header: JSON.generate(header_of(signed).merge("generator" => "somebody-else/1.0")))

      expect { read(forged, verify_with: key) }.to raise_error(described_class::UntrustedSignature)
    end
  end

  describe ".header" do
    it "answers what a bundle holds without reading its records" do
      header = described_class.header(StringIO.new(write))

      expect([header.source, header.record_count, header.snapshot_checksum])
        .to eq([:ofac_sdn, 2, snapshot.checksum])
    end

    # What makes it worth having: deciding whether a 25 MB file holds a list
    # you already have should not cost 25 MB of inflation.
    it "reads no further than the header" do
      io = StringIO.new(write)
      described_class.header(io)

      expect(io.pos).to be < 600
    end

    it "refuses a bundle it could not read either" do
      expect { described_class.header(StringIO.new("nope\n")) }.to raise_error(described_class::Corrupt)
    end
  end

  # The acceptance criterion: a bundle written on one machine loads on another
  # and screens identically.
  describe "screening what came out of a bundle" do
    let(:corpus) { ActiveSanction::Snapshot.new(source: :ofac_sdn, entities: SyntheticCorpus.build(500)) }
    let(:queries) { corpus.entities.first(25).map { |record| record.names.first.value } }

    def results(list)
      store = ActiveSanction::Storage::Memory.new
      store.write_snapshot(list)
      ActiveSanction::Matcher.build(store).screen_all(queries)
    end

    def comparable(sets) = sets.map { |set| set.map { |hit| hit.to_h.except(:screened_at, :verified) } }

    it "produces the results screening the original produces" do
      expect(comparable(results(read(write(corpus))))).to eq(comparable(results(corpus)))
    end

    it "stamps every hit with the checksum the original had" do
      stamps = results(read(write(corpus))).flatten.map(&:snapshot_id).uniq

      expect(stamps).to eq([corpus.checksum])
    end

    it "records on every hit that its list was verified" do
      loaded = read(write(corpus, sign_with: key), verify_with: key)

      expect(results(loaded).flatten.map(&:verified?).uniq).to eq([true])
    end

    it "records on every hit that an unverified list was not" do
      expect(results(read(write(corpus))).flatten.map(&:verified?).uniq).to eq([false])
    end
  end
end
