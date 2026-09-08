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

    # The launch lists change daily at most.
    it "considers a source due for another look after a day" do
      expect(described_class.new.stale_after).to eq(86_400)
    end

    it "normalizes against the shipped token dictionaries" do
      expect(described_class.new.normalizer_dictionary).to be(ActiveSanction::Normalizer::Dictionary.default)
    end

    it "logs nothing until an application hands it a logger" do
      expect(described_class.new.logger).to be_nil
    end

    # Enough to diff a suspicious list against the two before it, and small
    # enough that a cache directory does not grow by 126 MB a day.
    it "keeps three raw payloads per source" do
      expect(described_class.new.retain_payloads).to eq(3)
    end

    # Where the recall curve flattens and the query budget lands -- see
    # Index::POSTINGS_BUDGET for the measurement both numbers come from.
    it "hands the scorer two hundred candidate names per query" do
      expect(described_class.new.candidate_limit).to eq(200)
    end
  end

  describe "#sync_concurrency=" do
    # These are government file servers with nobody waiting on the result, and
    # a library that opens four connections to Treasury by default is one that
    # gets a jurisdiction's operators asking who we are.
    it "fetches from one publisher at a time by default" do
      expect(described_class.new.sync_concurrency).to eq(1)
    end

    it "takes a whole number of publishers" do
      expect(described_class.new.tap { |config| config.sync_concurrency = 3 }.sync_concurrency).to eq(3)
    end

    # A sync that runs no sources is a typo, and one is what sequential is
    # spelled as.
    it "refuses a concurrency of zero" do
      expect { described_class.new.sync_concurrency = 0 }
        .to raise_error(ActiveSanction::ConfigurationError, /at least 1/)
    end

    it "refuses a concurrency that is not a number" do
      expect { described_class.new.sync_concurrency = "all of them" }
        .to raise_error(ActiveSanction::ConfigurationError, /whole number of sources/)
    end
  end

  describe "#doctor_tolerance=" do
    # These lists move by single-digit percentages between syncs, while the
    # changes the doctor is looking for halve a fill rate.
    it "reports a movement of more than a tenth by default" do
      expect(described_class.new.doctor_tolerance).to eq(0.10)
    end

    it "takes a share" do
      expect(described_class.new.tap { |config| config.doctor_tolerance = 0.05 }.doctor_tolerance).to eq(0.05)
    end

    it "refuses a percentage written as a whole number" do
      expect { described_class.new.doctor_tolerance = 10 }
        .to raise_error(ActiveSanction::ConfigurationError, /between 0 and 1/)
    end

    it "refuses a tolerance that is not a number" do
      expect { described_class.new.doctor_tolerance = "a bit" }
        .to raise_error(ActiveSanction::ConfigurationError, /between 0 and 1/)
    end
  end

  describe "#candidate_limit=" do
    it "takes a whole number of names" do
      expect(described_class.new.tap { |config| config.candidate_limit = 50 }.candidate_limit).to eq(50)
    end

    # An index that returns nothing screens nobody, and a configuration that
    # turns screening off silently has to be a typo rather than a setting.
    it "refuses a limit of zero" do
      expect { described_class.new.candidate_limit = 0 }
        .to raise_error(ActiveSanction::ConfigurationError, /at least 1/)
    end

    it "refuses a limit that is not a number" do
      expect { described_class.new.candidate_limit = "lots" }
        .to raise_error(ActiveSanction::ConfigurationError, /whole number of names/)
    end
  end

  describe "#scorer_weights" do
    it "defaults to the shipped numbers" do
      expect(described_class.new.scorer_weights).to be(ActiveSanction::Scorer::Weights.default)
    end

    it "replaces only the numbers a Hash names" do
      config = described_class.new.tap { |c| c.scorer_weights = { dob_conflict: -20.0 } }

      expect(config.scorer_weights).to have_attributes(dob_conflict: -20.0, identifier_match: 40.0)
    end

    it "takes a Weights outright" do
      weights = ActiveSanction::Scorer::Weights.new(dob_exact: 20.0)

      expect(described_class.new.tap { |c| c.scorer_weights = weights }.scorer_weights).to be(weights)
    end

    # A misconfigured installation, not a malformed record -- which is the
    # whole distinction ConfigurationError draws.
    it "raises a ConfigurationError for shares that do not sum to 1" do
      expect { described_class.new.scorer_weights = { token_set: 0.9 } }
        .to raise_error(ActiveSanction::ConfigurationError, /must sum to 1\.0/)
    end

    it "raises a ConfigurationError for a weight it does not have" do
      expect { described_class.new.scorer_weights = { vibes: 1.0 } }
        .to raise_error(ActiveSanction::ConfigurationError, /unknown weight/)
    end
  end

  describe "#cache_dir" do
    it "defaults under the XDG cache directory" do
      expect(described_class.new.cache_dir).to eq(File.join(Dir.home, ".cache", "active_sanction"))
    end

    it "honours XDG_CACHE_HOME" do
      allow(ENV).to receive(:fetch).with("XDG_CACHE_HOME", nil).and_return("/var/cache")

      expect(described_class.new.cache_dir).to eq("/var/cache/active_sanction")
    end

    it "expands a relative path, so the directory does not follow the working directory" do
      config = described_class.new
      config.cache_dir = "tmp/lists"

      expect(config.cache_dir).to eq(File.expand_path("tmp/lists"))
    end

    it "rejects a blank directory" do
      expect { described_class.new.cache_dir = "  " }
        .to raise_error(ActiveSanction::ConfigurationError, /cache_dir cannot be blank/)
    end
  end

  describe "#storage_dir" do
    it "defaults to a directory of its own in the user's home" do
      expect(described_class.new.storage_dir).to eq(File.join(Dir.home, ".active_sanction"))
    end

    # Not under XDG_CACHE_HOME, and the split is the point: everything in
    # cache_dir can be fetched again, and a stored snapshot cannot -- once a
    # publisher overwrites its file, the version a past decision was screened
    # against exists only in storage.
    it "is not under the cache directory a user is entitled to delete" do
      config = described_class.new

      expect(config.storage_dir).not_to start_with(config.cache_dir)
    end

    it "expands a relative path, so the directory does not follow the working directory" do
      config = described_class.new
      config.storage_dir = "tmp/lists"

      expect(config.storage_dir).to eq(File.expand_path("tmp/lists"))
    end

    it "rejects a blank directory" do
      expect { described_class.new.storage_dir = "  " }
        .to raise_error(ActiveSanction::ConfigurationError, /storage_dir cannot be blank/)
    end
  end

  describe "#retain_payloads" do
    it "takes a count" do
      config = described_class.new
      config.retain_payloads = 10

      expect(config.retain_payloads).to eq(10)
    end

    # A cache that keeps nothing still writes every payload to disk before
    # deleting it; an installation that wants none should not build one.
    it "refuses a retention that keeps nothing" do
      expect { described_class.new.retain_payloads = 0 }
        .to raise_error(ActiveSanction::ConfigurationError, /at least 1/)
    end

    it "refuses a negative retention" do
      expect { described_class.new.retain_payloads = -1 }
        .to raise_error(ActiveSanction::ConfigurationError, /at least 1/)
    end

    it "refuses something that is not a count" do
      expect { described_class.new.retain_payloads = "a few" }
        .to raise_error(ActiveSanction::ConfigurationError, /whole number of payloads/)
    end
  end

  describe "#stale_after" do
    it "accepts a caller's own window" do
      config = described_class.new
      config.stale_after = 3600

      expect(config.stale_after).to eq(3600)
    end

    # Then only the publisher's own 304 decides whether a sync did any work.
    it "accepts nil, which disables the clock" do
      config = described_class.new
      config.stale_after = nil

      expect(config.stale_after).to be_nil
    end

    it "rejects a window that is not a duration" do
      expect { described_class.new.stale_after = "daily" }
        .to raise_error(ActiveSanction::ConfigurationError, /stale_after/)
    end

    it "rejects a negative window" do
      expect { described_class.new.stale_after = -1 }
        .to raise_error(ActiveSanction::ConfigurationError, /greater than zero/)
    end
  end

  describe "#logger" do
    it "accepts anything Logger-shaped" do
      logger = Object.new.tap { |object| def object.info(message) = message }
      config = described_class.new
      config.logger = logger

      expect(config.logger).to be(logger)
    end

    it "accepts nil, which turns logging off again" do
      config = described_class.new
      config.logger = nil

      expect(config.logger).to be_nil
    end

    it "rejects something that cannot log" do
      expect { described_class.new.logger = "stdout" }
        .to raise_error(ActiveSanction::ConfigurationError, /logger must respond to #info/)
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

  describe "#sources" do
    # nil rather than a list of the built-ins: an application that has not
    # thought about it should get every registered source, so a gem adding a
    # jurisdiction takes effect without an edit to the host app's initializer.
    it "defaults to every registered source" do
      expect(described_class.new.sources).to be_nil
    end

    it "takes the keys an application names" do
      config = described_class.new
      config.sources = %i[ofac_sdn my_internal_watchlist]

      expect(config.sources).to eq(%i[ofac_sdn my_internal_watchlist])
    end

    it "accepts strings, since a CLI argument is one" do
      config = described_class.new
      config.sources = ["ofac_sdn"]

      expect(config.sources).to eq([:ofac_sdn])
    end

    it "keeps the order it was given, and drops a repeat" do
      config = described_class.new
      config.sources = %i[un_consolidated ofac_sdn un_consolidated]

      expect(config.sources).to eq(%i[un_consolidated ofac_sdn])
    end

    it "goes back to every source when set to nil" do
      config = described_class.new
      config.sources = %i[ofac_sdn]
      config.sources = nil

      expect(config.sources).to be_nil
    end

    # An empty list would silently sync nothing, which is the one outcome a
    # compliance job must never reach quietly.
    it "refuses an empty list" do
      expect { described_class.new.sources = [] }
        .to raise_error(ActiveSanction::ConfigurationError, /cannot be empty/)
    end

    it "refuses a blank key" do
      expect { described_class.new.sources = ["ofac_sdn", " "] }
        .to raise_error(ActiveSanction::ConfigurationError, /blank key/)
    end

    # Resolving here would make the order of an application's requires decide
    # whether its configuration is valid; Sources.enabled resolves at the start
    # of a run instead.
    it "does not resolve the keys, so an initializer may name a source not yet required" do
      expect { described_class.new.sources = %i[not_registered_yet] }.not_to raise_error
    end
  end

  # The lists the normalizer strips per entity type (#27). A Hash adds to the
  # shipped ones, which is what a host almost always wants; a Dictionary
  # replaces them, which is the operation that has to be spelled out.
  describe "#normalizer_dictionary=" do
    it "takes a Hash of lists to add to the shipped ones" do
      config = described_class.new
      config.normalizer_dictionary = { legal_forms: %w[OYJ] }

      expect(config.normalizer_dictionary.legal_forms)
        .to eq(ActiveSanction::Normalizer::Dictionary.default.legal_forms + %w[OYJ])
    end

    it "takes string keys, since an initializer is not always written in symbols" do
      config = described_class.new
      config.normalizer_dictionary = { "particles" => %w[ben] }

      expect(config.normalizer_dictionary.particles.last).to eq("ben")
    end

    it "takes a dictionary, which replaces the shipped lists outright" do
      replacement = ActiveSanction::Normalizer::Dictionary.new(legal_forms: %w[LTD], honorifics: [],
                                                               organization_stopwords: [], particles: [])
      config = described_class.new
      config.normalizer_dictionary = replacement

      expect(config.normalizer_dictionary).to be(replacement)
    end

    # A typo in a list name would silently configure nothing, which is the
    # class of failure the strip lists are dangerous enough to deserve.
    it "names the lists it knows when handed one it does not" do
      expect { described_class.new.normalizer_dictionary = { legal_form: %w[OYJ] } }
        .to raise_error(ActiveSanction::ConfigurationError, /unknown normalizer dictionary list\(s\): legal_form/)
    end

    it "rejects anything that is neither a dictionary nor a Hash of lists" do
      expect { described_class.new.normalizer_dictionary = %w[LTD] }
        .to raise_error(ActiveSanction::ConfigurationError, /must be an ActiveSanction::Normalizer::Dictionary/)
    end
  end

  describe "#screening_threshold" do
    it "defaults to 75, where the scorer's own table separates a true match from a shared given name" do
      expect(described_class.new.screening_threshold).to eq(75.0)
    end

    it "takes a number a host set" do
      expect(described_class.new.tap { |c| c.screening_threshold = 85 }.screening_threshold).to eq(85.0)
    end

    # The mistake this catches is an 85 arriving where 0.85 was meant, which
    # would reject every pair and read as "nothing matched".
    it "rejects a threshold outside 0..100" do
      expect { described_class.new.screening_threshold = 101 }
        .to raise_error(ActiveSanction::ConfigurationError, /percentage, not a similarity/)
    end

    it "rejects a threshold that is not a number" do
      expect { described_class.new.screening_threshold = "high" }
        .to raise_error(ActiveSanction::ConfigurationError, /must be a number/)
    end
  end

  describe "#screening_limit" do
    it "defaults to a review queue rather than a report" do
      expect(described_class.new.screening_limit).to eq(10)
    end

    it "takes a number a host set" do
      expect(described_class.new.tap { |c| c.screening_limit = 50 }.screening_limit).to eq(50)
    end

    # A screening call that can return nothing reports every customer clear.
    it "rejects a limit of zero" do
      expect { described_class.new.screening_limit = 0 }
        .to raise_error(ActiveSanction::ConfigurationError, /at least 1/)
    end

    it "rejects a limit that is not a whole number" do
      expect { described_class.new.screening_limit = "ten" }
        .to raise_error(ActiveSanction::ConfigurationError, /whole number/)
    end
  end

  describe "#storage" do
    it "defaults to gzipped JSON under storage_dir, so screening needs nothing provisioned" do
      config = described_class.new.tap { |c| c.storage_dir = "/srv/lists" }

      expect(config.storage).to be_a(ActiveSanction::Storage::FileSystem)
    end

    it "builds the default store once and holds it" do
      config = described_class.new.tap { |c| c.storage_dir = "/srv/lists" }
      built = config.storage

      expect(config.storage).to be(built)
    end

    it "takes a store a host supplied" do
      memory = ActiveSanction::Storage::Memory.new

      expect(described_class.new.tap { |c| c.storage = memory }.storage).to be(memory)
    end

    it "rejects anything that is not held to the storage contract" do
      expect { described_class.new.storage = { ofac_sdn: [] } }
        .to raise_error(ActiveSanction::ConfigurationError, /must be an ActiveSanction::Storage::Base/)
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
