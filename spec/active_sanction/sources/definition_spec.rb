# frozen_string_literal: true

RSpec.describe ActiveSanction::Sources::Definition do
  def un
    Class.new(ActiveSanction::Sources::Base) do
      key :un_consolidated
      jurisdiction :un
      authority "United Nations Security Council"
      format :xml
      url :main, "https://scsanctions.un.org/resources/xml/en/consolidated.xml"
    end
  end

  # OFAC publishes the SDN list as three files that only mean something joined.
  def ofac
    Class.new(ActiveSanction::Sources::Base) do
      key :ofac_sdn
      jurisdiction :us
      authority "Office of Foreign Assets Control"
      format :csv
      url :sdn, "https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV"
      url :alt, "https://sanctionslistservice.ofac.treas.gov/api/download/ALT.CSV"
      url :add, "https://sanctionslistservice.ofac.treas.gov/api/download/ADD.CSV"
    end
  end

  describe "declaring" do
    it "reads every declaration back with no argument" do
      expect(un).to have_attributes(key: :un_consolidated, jurisdiction: :un, format: :xml,
                                    authority: "United Nations Security Council")
    end

    it "summarises them for a CLI listing" do
      expect(un.to_h).to eq(key: :un_consolidated, jurisdiction: :un, format: :xml,
                            authority: "United Nations Security Council",
                            urls: { main: "https://scsanctions.un.org/resources/xml/en/consolidated.xml" })
    end

    it "reports what has been declared without insisting on it" do
      list = Class.new(ActiveSanction::Sources::Base) { key :bare_list }

      expect(list).to be_declared(:key).and(satisfy { |k| !k.declared?(:authority) })
    end

    it "normalises a jurisdiction to a lowercase symbol" do
      list = Class.new(ActiveSanction::Sources::Base) { jurisdiction "CA" }

      expect(list.jurisdiction).to eq(:ca)
    end
  end

  describe "a declaration that was never made" do
    it "says which class is missing a key, and what to add" do
      expect { Class.new(ActiveSanction::Sources::Base).key }
        .to raise_error(ActiveSanction::Sources::DeclarationError, /does not declare a key.*`key :something`/)
    end

    it "says the same about a jurisdiction" do
      expect { Class.new(ActiveSanction::Sources::Base).jurisdiction }
        .to raise_error(ActiveSanction::Sources::DeclarationError, /jurisdiction/)
    end

    it "says the same about an authority" do
      expect { Class.new(ActiveSanction::Sources::Base).authority }
        .to raise_error(ActiveSanction::Sources::DeclarationError, /authority/)
    end

    # A source that builds entities from a database has no format to name, and
    # nothing here dispatches on the value anyway.
    it "leaves format optional" do
      expect(Class.new(ActiveSanction::Sources::Base).format).to be_nil
    end

    it "refuses a blank authority rather than storing an empty string" do
      expect { Class.new(ActiveSanction::Sources::Base) { authority "  " } }
        .to raise_error(ActiveSanction::Sources::DeclarationError, /authority cannot be blank/)
    end
  end

  describe "keys" do
    it "accepts lowercase snake_case" do
      expect(Class.new(ActiveSanction::Sources::Base) { key :eu_fsf }.key).to eq(:eu_fsf)
    end

    # Keys are typed into configuration and become directory names under the
    # payload cache, so they are checked rather than quietly rewritten.
    it "refuses spaces, capitals, and a leading digit" do
      base = ActiveSanction::Sources::Base

      ["OFAC SDN", "ofac/sdn", "2ofac", ""].each do |bad|
        expect { Class.new(base) { key bad } }
          .to raise_error(ActiveSanction::Sources::DeclarationError, /not a usable source key/)
      end
    end
  end

  describe "urls" do
    it "reads the primary back with no argument" do
      expect(un.url).to eq("https://scsanctions.un.org/resources/xml/en/consolidated.xml")
    end

    it "reads one back by the name it was declared under" do
      expect(ofac.url(:alt)).to end_with("ALT.CSV")
    end

    it "keeps them in declaration order" do
      expect(ofac.urls.keys).to eq(%i[sdn alt add])
    end

    it "names what is declared when asked for a file that is not" do
      expect { ofac.url(:sdn_advanced) }
        .to raise_error(ActiveSanction::Sources::DeclarationError, /no :sdn_advanced URL. Declared: sdn, alt, add/)
    end

    it "points a source with no URL at the override it wants" do
      expect { Class.new(ActiveSanction::Sources::Base).url }
        .to raise_error(ActiveSanction::Sources::DeclarationError, /declares no URL.*override #retrieve/m)
    end

    it "refuses something that is not an http URL" do
      expect { Class.new(ActiveSanction::Sources::Base) { url :main, "/var/lists/sdn.csv" } }
        .to raise_error(ActiveSanction::Sources::DeclarationError, /is not an http\(s\) URL/)
    end

    it "knows when there is more than one file to join" do
      expect(ofac).to be_multi_url
    end

    it "knows when there is only one" do
      expect(un).not_to be_multi_url
    end
  end

  describe "the name each file is filed under" do
    # One file, one name: the common case stays legible on disk and in a
    # validators.json somebody is reading to find out why a sync downloaded
    # more than it should have.
    it "is the source key itself for a single-file source" do
      expect(un.file_key(:main)).to eq(:un_consolidated)
    end

    # Three files sharing one name would evict each other out of a cache that
    # retains N payloads per name, and would share one ETag.
    it "is qualified by the file name for a multi-file source" do
      expect(ofac.file_key(:alt)).to eq(:"ofac_sdn-alt")
    end
  end

  describe "inheritance" do
    def publisher
      Class.new(ActiveSanction::Sources::Base) do
        jurisdiction :us
        authority "Office of Foreign Assets Control"
        format :csv
        url :sdn, "https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV"
      end
    end

    it "shares what two lists from one publisher have in common" do
      consolidated = Class.new(publisher) { key :ofac_consolidated }

      expect(consolidated).to have_attributes(jurisdiction: :us, format: :csv,
                                              authority: "Office of Foreign Assets Control")
    end

    it "inherits the parent's files too" do
      expect(Class.new(publisher) { key :ofac_consolidated }.urls.keys).to eq([:sdn])
    end

    it "lets a subclass add a file without disturbing the parent" do
      parent = publisher
      Class.new(parent) do
        key :ofac_consolidated
        url :add, "https://sanctionslistservice.ofac.treas.gov/api/download/ADD.CSV"
      end

      expect(parent.urls.keys).to eq([:sdn])
    end

    it "lets a subclass point a file at a mirror" do
      child = Class.new(publisher) do
        key :ofac_consolidated
        url :sdn, "https://mirror.example.test/SDN.CSV"
      end

      expect(child.url(:sdn)).to eq("https://mirror.example.test/SDN.CSV")
    end

    # The one mistake the registry cannot let through: a subclass silently
    # inheriting a key would try to register under a name already taken.
    it "never inherits a key" do
      expect { Class.new(publisher.tap { |k| k.key(:ofac_sdn) }).key }
        .to raise_error(ActiveSanction::Sources::DeclarationError, /does not declare a key/)
    end

    it "does not take over Class#inherited on the way" do
      expect { Class.new(ActiveSanction::Sources::Base) }.not_to raise_error
    end
  end
end
