# frozen_string_literal: true

require "openssl"

RSpec.describe ActiveSanction::Snapshot::Bundle::Signature do
  let(:key) { OpenSSL::PKey::EC.generate("prime256v1") }
  let(:other_key) { OpenSSL::PKey::EC.generate("prime256v1") }
  let(:line) { "{\"format_version\":1,\"source\":\"ofac_sdn\"}" }

  describe ".sign" do
    it "answers the unsigned marker when there is no key" do
      expect(described_class.sign(line, nil)).to eq("-")
    end

    it "names the algorithm and encodes the signature" do
      expect(described_class.sign(line, key)).to start_with("ecdsa-sha256 ")
    end

    it "names RSA as rsa-sha256" do
      expect(described_class.sign(line, OpenSSL::PKey::RSA.new(2048))).to start_with("rsa-sha256 ")
    end

    it "takes a PEM as well as a key" do
      expect(described_class.sign(line, key.to_pem)).to start_with("ecdsa-sha256 ")
    end

    it "refuses a key it cannot read" do
      expect { described_class.sign(line, "-----BEGIN PRIVATE KEY-----\nnope\n") }
        .to raise_error(ActiveSanction::InvalidArgument, /not a readable PEM/)
    end
  end

  describe ".verify!" do
    it "accepts a signature over the bytes it was made over" do
      expect(described_class.verify!(described_class.sign(line, key), line, key)).to be(true)
    end

    it "verifies with the public half alone, which is all a consumer has" do
      signature = described_class.sign(line, key)

      expect(described_class.verify!(signature, line, key.public_to_pem)).to be(true)
    end

    # The whole point of signing the header: change any of it and the signature
    # no longer stands, which covers the payload through its digest.
    it "refuses a signature over different bytes" do
      expect { described_class.verify!(described_class.sign(line, key), "#{line} ", key) }
        .to raise_error(ActiveSanction::Snapshot::Bundle::UntrustedSignature)
    end

    it "refuses a signature by another key" do
      expect { described_class.verify!(described_class.sign(line, key), line, other_key) }
        .to raise_error(ActiveSanction::Snapshot::Bundle::UntrustedSignature)
    end

    it "refuses the unsigned marker" do
      expect { described_class.verify!("-", line, key) }
        .to raise_error(ActiveSanction::Snapshot::Bundle::Unsigned)
    end

    it "refuses a line that is not a signature line" do
      expect { described_class.verify!("ecdsa-sha256", line, key) }
        .to raise_error(ActiveSanction::Snapshot::Bundle::Corrupt, /not a signature line/)
    end

    it "refuses a signature that is not base64" do
      expect { described_class.verify!("ecdsa-sha256 !!!!", line, key) }
        .to raise_error(ActiveSanction::Snapshot::Bundle::Corrupt)
    end

    it "refuses an algorithm the format does not define" do
      expect { described_class.verify!("md5 #{["x"].pack("m0")}", line, key) }
        .to raise_error(ActiveSanction::Snapshot::Bundle::Corrupt, /not a signature algorithm/)
    end

    # Reserved rather than unknown: a bundle from a newer publisher should
    # diagnose itself as one this gem is too old for.
    it "refuses a reserved algorithm as a version problem, not a corrupt file" do
      expect { described_class.verify!("ed25519 #{["x"].pack("m0")}", line, key) }
        .to raise_error(ActiveSanction::Snapshot::Bundle::UnsupportedFormat, /reserves but does not verify/)
    end

    it "raises rather than answering false, so a caller cannot forget to check" do
      expect { described_class.verify!(described_class.sign(line, key), line, other_key) }
        .to raise_error(ActiveSanction::Error)
    end
  end

  describe ".signed?" do
    it "is false for the unsigned marker" do
      expect(described_class.signed?("-")).to be(false)
    end

    it "is true for a signature line" do
      expect(described_class.signed?(described_class.sign(line, key))).to be(true)
    end
  end
end
