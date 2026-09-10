# frozen_string_literal: true

RSpec.describe ActiveSanction::Deprecation do
  # Ruby's switch is off by default outside verbose mode, so every example that
  # expects a warning has to turn it on -- and put it back, because leaving it
  # on would change what every other spec in the suite prints.
  around do |example|
    previous = Warning[:deprecated]
    Warning[:deprecated] = true
    described_class.reset!
    example.run
  ensure
    Warning[:deprecated] = previous
    described_class.reset!
  end

  # The message goes through `Kernel.warn`, which is what a host silences.
  # Capturing stderr is therefore testing the thing a host actually sees.
  def warnings
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  describe ".warn" do
    it "names what is deprecated" do
      output = warnings { described_class.warn("ActiveSanction.old", since: "0.4.0") }

      expect(output).to include("ActiveSanction.old is deprecated since 0.4.0")
    end

    it "computes the removal version rather than asking for one" do
      output = warnings { described_class.warn("ActiveSanction.old", since: "0.4.0") }

      expect(output).to include("will be removed in 0.6.0")
    end

    it "takes a removal version when the policy is being departed from" do
      output = warnings do
        described_class.warn("ActiveSanction.old", since: "0.4.0", removal: "1.0.0")
      end

      expect(output).to include("will be removed in 1.0.0")
    end

    it "says what to use instead" do
      output = warnings do
        described_class.warn("ActiveSanction.old", since: "0.4.0", replacement: "ActiveSanction.new")
      end

      expect(output).to include("Use ActiveSanction.new instead.")
    end

    # Nothing to move to is worth saying by omission rather than by inventing a
    # replacement that does not exist.
    it "says nothing about a replacement when there is none" do
      output = warnings { described_class.warn("ActiveSanction.old", since: "0.4.0") }

      expect(output).not_to include("instead")
    end

    it "is silent when the host has turned deprecations off" do
      Warning[:deprecated] = false

      output = warnings { described_class.warn("ActiveSanction.old", since: "0.4.0") }

      expect(output).to be_empty
    end
  end

  describe "the call site it reports" do
    # The frame that matters is the host's, and it is not the frame directly
    # beneath the warning: `sig` wraps every method in this library, so the
    # immediate caller of anything in `lib/` is sorbet-runtime.
    it "names the caller's own file and line" do
      output = warnings { described_class.warn("ActiveSanction.old", since: "0.4.0") }

      expect(output).to include("Called from #{__FILE__}:#{__LINE__ - 2}")
    end

    it "names neither sorbet-runtime nor this library" do
      output = warnings { described_class.warn("ActiveSanction.old", since: "0.4.0") }

      expect(output).not_to match(%r{sorbet-runtime|/lib/active_sanction/})
    end
  end

  describe "how often it warns" do
    # A deprecated method called while looping over 19,000 records would write
    # 19,000 identical lines, and a log nobody can read is a log nobody reads.
    it "warns once for a call site, however many times it is reached" do
      output = warnings do
        3.times { described_class.warn("ActiveSanction.old", since: "0.4.0") }
      end

      expect(output.scan("ActiveSanction.old").length).to eq(1)
    end

    it "warns again for a different call site" do
      output = warnings do
        described_class.warn("ActiveSanction.old", since: "0.4.0")
        described_class.warn("ActiveSanction.old", since: "0.4.0")
      end

      expect(output.scan("ActiveSanction.old").length).to eq(2)
    end

    it "warns separately about separate subjects" do
      output = warnings do
        described_class.warn("ActiveSanction.one", since: "0.4.0")
        described_class.warn("ActiveSanction.two", since: "0.4.0")
      end

      expect(output.lines.length).to eq(2)
    end

    it "forgets what it has said when reset" do
      output = warnings do
        described_class.warn("ActiveSanction.old", since: "0.4.0")
        described_class.reset!
        described_class.warn("ActiveSanction.old", since: "0.4.0")
      end

      expect(output.scan("ActiveSanction.old").length).to eq(2)
    end
  end

  # One full minor release of overlap, so an application upgrading one minor at
  # a time always meets the warning before the breakage.
  describe ".removal_for" do
    {
      "0.4.0" => "0.6.0",
      "0.4.7" => "0.6.0",
      "1.0.0" => "1.2.0",
      "1.11.3" => "1.13.0"
    }.each do |since, removal|
      it "puts a #{since} deprecation's removal at #{removal}" do
        expect(described_class.removal_for(since)).to eq(removal)
      end
    end
  end
end
