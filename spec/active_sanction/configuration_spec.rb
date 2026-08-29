# frozen_string_literal: true

RSpec.describe ActiveSanction::Configuration do
  after { ActiveSanction.reset_configuration! }

  describe "defaults" do
    it "identifies the library, since a publisher watching its logs needs something to name" do
      expect(described_class.new.user_agent).to include("active_sanction/#{ActiveSanction::VERSION}")
    end

    it "points at the project, so a publisher has somewhere to complain to" do
      expect(described_class.new.user_agent).to include("github.com/Babystep-Technologies/active_sanction")
    end

    it "ships working timeouts, redirect and retry caps" do
      config = described_class.new

      expect(config).to have_attributes(open_timeout: 10, read_timeout: 60, max_redirects: 5,
                                        max_retries: 2, retry_backoff: 1.0)
    end
  end

  describe "#user_agent=" do
    it "accepts an application's own identifier" do
      config = described_class.new
      config.user_agent = "my-app/1.0 (compliance@example.com)"

      expect(config.user_agent).to eq("my-app/1.0 (compliance@example.com)")
    end

    it "strips surrounding whitespace" do
      config = described_class.new
      config.user_agent = "  my-app/1.0  "

      expect(config.user_agent).to eq("my-app/1.0")
    end

    it "rejects nil" do
      expect { described_class.new.user_agent = nil }
        .to raise_error(ActiveSanction::ConfigurationError, /user_agent is required/)
    end

    it "rejects an empty string" do
      expect { described_class.new.user_agent = "" }.to raise_error(ActiveSanction::ConfigurationError)
    end

    # A header of " " is what a publisher sees as no header at all.
    it "rejects whitespace" do
      expect { described_class.new.user_agent = "   " }.to raise_error(ActiveSanction::ConfigurationError)
    end

    it "names the setting to fix in the message" do
      expect { described_class.new.user_agent = "" }
        .to raise_error(ActiveSanction::ConfigurationError, /ActiveSanction\.configure/)
    end
  end

  describe "timeouts" do
    it "accepts a number of seconds" do
      config = described_class.new
      config.open_timeout = 2
      config.read_timeout = 5.5

      expect(config).to have_attributes(open_timeout: 2.0, read_timeout: 5.5)
    end

    it "rejects zero, which would fail every request" do
      expect { described_class.new.open_timeout = 0 }
        .to raise_error(ActiveSanction::ConfigurationError, /greater than zero/)
    end

    it "rejects a negative timeout" do
      expect { described_class.new.read_timeout = -1 }.to raise_error(ActiveSanction::ConfigurationError)
    end

    it "rejects something that is not a number" do
      expect { described_class.new.read_timeout = "soon" }
        .to raise_error(ActiveSanction::ConfigurationError, /number of seconds/)
    end
  end

  describe "caps" do
    it "accepts zero redirects, which is a caller declining to follow any" do
      config = described_class.new
      config.max_redirects = 0

      expect(config.max_redirects).to eq(0)
    end

    it "accepts zero retries" do
      config = described_class.new
      config.max_retries = 0

      expect(config.max_retries).to eq(0)
    end

    it "rejects a negative cap" do
      expect { described_class.new.max_retries = -1 }
        .to raise_error(ActiveSanction::ConfigurationError, /cannot be negative/)
    end

    it "rejects a non-integer cap" do
      expect { described_class.new.max_redirects = "many" }
        .to raise_error(ActiveSanction::ConfigurationError, /whole number/)
    end

    it "rejects a non-positive backoff" do
      expect { described_class.new.retry_backoff = 0 }.to raise_error(ActiveSanction::ConfigurationError)
    end
  end

  describe "ActiveSanction.configure" do
    it "yields the global configuration" do
      ActiveSanction.configure { |c| c.user_agent = "my-app/1.0 (compliance@example.com)" }

      expect(ActiveSanction.config.user_agent).to eq("my-app/1.0 (compliance@example.com)")
    end

    it "returns the configuration, so a caller can chain off it" do
      expect(ActiveSanction.configure { |c| c.max_retries = 0 }).to be(ActiveSanction.config)
    end

    it "builds a configuration on first read, so nothing has to initialize it" do
      expect(ActiveSanction.config).to be_a(described_class)
    end

    it "is reset back to the defaults by reset_configuration!" do
      ActiveSanction.configure { |c| c.user_agent = "my-app/1.0" }
      ActiveSanction.reset_configuration!

      expect(ActiveSanction.config.user_agent).to eq(described_class::DEFAULT_USER_AGENT)
    end
  end
end
