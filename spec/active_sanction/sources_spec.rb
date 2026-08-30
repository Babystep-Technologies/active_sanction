# frozen_string_literal: true

RSpec.describe ActiveSanction::Sources do
  # Examples register into the real registry and take their keys back out
  # again. There is deliberately no `clear!` to reach for: built-in adapters
  # register when their file is required, `require` runs once per process, and
  # a suite that emptied the registry between examples would leave every later
  # example running against a library that had forgotten its own sources.
  let(:registered) { [] }

  after { registered.each { |key| described_class.unregister(key) } }

  def register(source)
    registered << source.key
    described_class.register(source)
  end

  def source(key, parent: ActiveSanction::Sources::Base)
    Class.new(parent) do
      key(key)
      jurisdiction :un
      authority "Demonstration Authority"
      url :main, "https://example.test/#{key}.xml"
    end
  end

  describe "registering" do
    it "returns the source, so an adapter file can end with the call" do
      list = source(:demo_list)

      expect(described_class.register(list)).to be(list)
      described_class.unregister(:demo_list)
    end

    it "files it under the key it declares" do
      list = register(source(:demo_list))

      expect(described_class[:demo_list]).to be(list)
    end

    it "accepts a string or a symbol when looking one up" do
      register(source(:demo_list))

      expect(described_class["demo_list"]).to eq(described_class[:demo_list])
    end

    it "reports it as registered" do
      register(source(:demo_list))

      expect(described_class).to be_registered(:demo_list)
    end

    it "says nothing is registered under a key nobody claimed" do
      expect(described_class).not_to be_registered(:no_such_list)
    end

    # The extensibility story in one example: nothing about the registry
    # requires Sources::Base, so a watchlist read out of a database table --
    # which has no URL to declare and no payload to fetch -- registers on the
    # same terms as a government file download.
    it "takes any class answering .key and .new, not only a Sources::Base" do
      internal = Class.new do
        def self.key = :my_internal_watchlist
        def parse(_raw) = []
      end
      register(internal)

      expect(described_class[:my_internal_watchlist]).to be(internal)
    end

    it "refuses something that is not a source at all" do
      expect { described_class.register("ofac_sdn") }
        .to raise_error(ArgumentError, /must answer \.key and \.new/)
    end

    it "refuses a key that could not be typed into configuration" do
      bad = Class.new { def self.key = "OFAC SDN" }

      expect { described_class.register(bad) }
        .to raise_error(ActiveSanction::Sources::DeclarationError, /lowercase snake_case/)
    end
  end

  describe "duplicate keys" do
    it "refuses a second source claiming a key" do
      register(source(:demo_list))

      expect { described_class.register(source(:demo_list)) }
        .to raise_error(ActiveSanction::Sources::DuplicateKey, /already claims that key/)
    end

    it "names both sources and the way out" do
      first = register(source(:demo_list))

      expect { described_class.register(source(:demo_list)) }
        .to raise_error(ActiveSanction::Sources::DuplicateKey,
                        /#{Regexp.escape(first.to_s)}.*unregister\(:demo_list\)/m)
    end

    it "leaves the incumbent registered" do
      first = register(source(:demo_list))
      begin
        described_class.register(source(:demo_list))
      rescue ActiveSanction::Sources::DuplicateKey
        nil
      end

      expect(described_class[:demo_list]).to be(first)
    end

    # A file loaded twice under two paths is a packaging accident, not a
    # collision of two lists, and taking the process down for it helps nobody.
    it "lets the same class register twice" do
      list = register(source(:demo_list))
      described_class.register(list)

      expect(described_class[:demo_list]).to be(list)
    end

    it "lets a patched adapter replace a built-in one after unregistering" do
      register(source(:demo_list))
      described_class.unregister(:demo_list)
      patched = register(source(:demo_list))

      expect(described_class[:demo_list]).to be(patched)
    end
  end

  describe "looking up an unknown key" do
    # Every caller of Sources[] is resolving a name a human typed, so a nil
    # here surfaces three layers away as a NoMethodError about something else.
    it "raises rather than returning nil" do
      expect { described_class[:ofac_sdb] }
        .to raise_error(ActiveSanction::Sources::UnknownSource, /no source registered as :ofac_sdb/)
    end

    it "lists what is registered, which is also the answer when a file was never required" do
      register(source(:demo_list))

      expect { described_class[:ofac_sdb] }
        .to raise_error(ActiveSanction::Sources::UnknownSource, /Registered: demo_list/)
    end
  end

  describe "listing" do
    it "orders keys, so a CLI listing does not reshuffle between runs" do
      register(source(:zulu_list))
      register(source(:alpha_list))

      expect(described_class.keys.first(2)).to eq(%i[alpha_list zulu_list])
    end

    it "orders classes the same way" do
      register(source(:zulu_list))
      alpha = register(source(:alpha_list))

      expect(described_class.all.first).to be(alpha)
    end

    it "counts what is registered" do
      expect { register(source(:demo_list)) }.to change(described_class, :size).by(1)
    end

    it "returns nil from unregistering a key nobody claimed" do
      expect(described_class.unregister(:no_such_list)).to be_nil
    end
  end

  describe "the enabled set" do
    after { ActiveSanction.reset_configuration! }

    it "is every registered source when the application has not said otherwise" do
      list = register(source(:demo_list))

      expect(described_class.enabled).to include(list)
    end

    it "is what config.sources names, in the order it names them" do
      register(source(:alpha_list))
      register(source(:zulu_list))
      ActiveSanction.configure { |c| c.sources = %i[zulu_list alpha_list] }

      expect(described_class.enabled.map(&:key)).to eq(%i[zulu_list alpha_list])
    end

    # At the start of a run, rather than after the other lists have been
    # downloaded.
    it "raises on a key nothing is registered under" do
      ActiveSanction.configure { |c| c.sources = %i[ofac_sdb] }

      expect { described_class.enabled }.to raise_error(ActiveSanction::Sources::UnknownSource)
    end
  end
end
