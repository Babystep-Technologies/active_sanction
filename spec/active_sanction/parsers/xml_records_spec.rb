# frozen_string_literal: true

require "nokogiri"

RSpec.describe ActiveSanction::Parsers::XmlRecords do
  # The UN's shape, in miniature: two record elements in one document, a name
  # split across numbered siblings, repeated elements, a placeholder alias made
  # entirely of self-closing tags, and the generation date on the root.
  def un_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <CONSOLIDATED_LIST dateGenerated="2026-08-28T00:00:00">
        <INDIVIDUALS>
          <INDIVIDUAL>
            <DATAID>6907993</DATAID>
            <FIRST_NAME>ERIC</FIRST_NAME>
            <SECOND_NAME>BADEGE</SECOND_NAME>
            <NATIONALITY><VALUE>Chad</VALUE></NATIONALITY>
            <NATIONALITY><VALUE>Sudan</VALUE></NATIONALITY>
            <INDIVIDUAL_ALIAS><QUALITY/><ALIAS_NAME/></INDIVIDUAL_ALIAS>
            <INDIVIDUAL_ALIAS><QUALITY>Low</QUALITY><ALIAS_NAME>Ben &amp; Co</ALIAS_NAME></INDIVIDUAL_ALIAS>
            <INDIVIDUAL_DATE_OF_BIRTH><TYPE_OF_DATE>EXACT</TYPE_OF_DATE><YEAR>1971</YEAR></INDIVIDUAL_DATE_OF_BIRTH>
            <COMMENTS1>   </COMMENTS1>
          </INDIVIDUAL>
        </INDIVIDUALS>
        <ENTITIES>
          <ENTITY id="e-42"><DATAID>42</DATAID><FIRST_NAME>ACME LTD</FIRST_NAME></ENTITY>
        </ENTITIES>
      </CONSOLIDATED_LIST>
    XML
  end

  # Every example below runs twice, once per backend, and asserts the same
  # answers from both. That is the acceptance criterion for #15 -- a backend is
  # swappable without changing adapter code -- and it is also the only way to
  # keep it true: two XML libraries disagree about self-closing tags, entity
  # references and whitespace unless something makes them agree.
  shared_examples "an XML record reader" do |backend|
    subject(:table) { described_class.new(records: %w[INDIVIDUAL ENTITY], backend: backend) }

    let(:xml_backend) { backend }
    let(:reader) { table.read(un_xml) }
    let(:records) { reader.to_a }
    let(:individual) { records.first }

    def read(xml, records: "R") = described_class.new(records: records, backend: xml_backend).read(xml)

    describe "finding records" do
      it "yields every named record and skips the scaffolding around them" do
        expect(records.map(&:name)).to eq(%w[INDIVIDUAL ENTITY])
      end

      it "reads a field by name" do
        expect(individual["FIRST_NAME"]).to eq("ERIC")
      end

      it "reads a nested field by path" do
        expect(individual["INDIVIDUAL_DATE_OF_BIRTH/YEAR"]).to eq("1971")
      end

      it "returns every value of a repeated element, in document order" do
        expect(individual.values("NATIONALITY/VALUE")).to eq(%w[Chad Sudan])
      end

      it "resolves entity references, so an ampersand is an ampersand" do
        expect(individual.nodes("INDIVIDUAL_ALIAS").last["ALIAS_NAME"]).to eq("Ben & Co")
      end
    end

    describe "empty, self-closing, and absent" do
      it "reads a self-closing element as nil rather than as a blank string" do
        expect(individual.nodes("INDIVIDUAL_ALIAS").first["ALIAS_NAME"]).to be_nil
      end

      it "reads a whitespace-only element as nil" do
        expect(individual["COMMENTS1"]).to be_nil
      end

      it "reads an element the record does not carry as nil" do
        expect(individual["PASSPORT"]).to be_nil
      end

      it "still yields the placeholder node itself, so a count is honest" do
        expect(individual.nodes("INDIVIDUAL_ALIAS").size).to eq(2)
      end

      it "resolves a declared null sentinel the way the CSV toolkit does" do
        table = described_class.new(records: "R", null: "-0-", backend: xml_backend)
        expect(table.read("<L><R><A>-0-</A></R></L>").to_a.first["A"]).to be_nil
      end
    end

    describe "attributes" do
      it "reads a record's own attribute" do
        expect(records.last["@id"]).to eq("e-42")
      end

      it "reads the document element's attributes, which is where a version lives" do
        expect(reader.root["dateGenerated"]).to eq("2026-08-28T00:00:00")
      end

      it "answers root without a full pass, so an adapter can ask first" do
        fresh = table.read(un_xml)
        expect(fresh.root["dateGenerated"]).to eq("2026-08-28T00:00:00")
      end
    end

    describe "namespaces" do
      it "matches an element regardless of the prefix a publisher adds" do
        xml = %(<un:L xmlns:un="urn:x"><un:R><un:A>1</un:A></un:R></un:L>)
        expect(read(xml).to_a.map { |record| record["A"] }).to eq(["1"])
      end
    end

    describe "fetch" do
      it "returns the value when the field is there" do
        expect(individual.fetch("DATAID")).to eq("6907993")
      end

      it "names the record and what it does carry when the field is missing" do
        expect { individual.fetch("SURNAME") }
          .to raise_error(KeyError, /no value at "SURNAME" in <INDIVIDUAL>.*DATAID/m)
      end

      it "takes a default for the genuinely optional case" do
        expect(individual.fetch("SURNAME", "unstated")).to eq("unstated")
      end
    end

    describe "when the document is not what it claimed to be" do
      it "refuses a payload that was never XML rather than reporting an empty list" do
        expect { read("<!DOCTYPE html><html><body>Access Denied<br>x</body></html>").to_a }
          .to raise_error(ActiveSanction::Parsers::ParseError, /never XML|not the XML it was read as/)
      end

      it "refuses an empty payload" do
        expect { read("   ").to_a }
          .to raise_error(ActiveSanction::Parsers::ParseError, /empty payload/)
      end

      it "keeps the records it read before a truncated download ran out" do
        reader = read("<L><R><A>1</A></R><R><A>2</A>")
        expect(reader.to_a.map { |record| record["A"] }).to eq(["1"])
      end

      it "says so in a warning rather than silently returning a short list" do
        reader = read("<L><R><A>1</A></R><R><A>2</A>")
        reader.to_a
        expect(reader.warnings.map(&:message)).to include(/document ended after 1 record/)
      end

      it "notices a download cut between two records, where nothing else would" do
        reader = read("<L><R><A>1</A></R>")
        reader.to_a
        expect(reader.warnings).not_to be_empty
      end

      it "reads a document that simply has no records as an empty list, not a failure" do
        reader = read("<L></L>")
        expect([reader.to_a, reader.warnings]).to eq([[], []])
      end
    end

    describe "streaming" do
      def generated(count)
        body = (1..count).map { |i| "<R><A>#{i}</A><B>#{"x" * 100}</B></R>" }.join
        "<L>#{body}</L>"
      end

      it "holds one record at a time rather than the whole document" do
        live = nil
        read(generated(2_000)).each_with_index do |_record, index|
          next unless index == 1_000

          GC.start
          live = ObjectSpace.each_object(ActiveSanction::Parsers::XmlRecords::Record).count
        end
        expect(live).to be < 100
      end
    end

    describe "re-enumerating" do
      it "re-parses from the start rather than reusing a spent pass" do
        expect([reader.count, reader.count]).to eq([2, 2])
      end

      it "resets warnings, so two passes are not reported as one" do
        reader = read("<L><R><A>1</A></R><R><A>2</A>")
        2.times { reader.to_a }
        expect(reader.warnings.size).to eq(1)
      end
    end
  end

  describe "the REXML backend" do
    it_behaves_like "an XML record reader", :rexml

    # The divergence between the two backends, asserted from both sides so it
    # stays a documented property rather than a surprise in production. REXML
    # discovers a structural error where it sits, so everything parsed before
    # it stands; libxml2 checks the document before yielding anything, and
    # refuses the payload whole. Neither is wrong, and a list that arrives
    # mangled mid-file is a list to investigate either way -- but an operator
    # comparing two installations needs to know why one reported 400 records
    # and a warning where the other reported a failure.
    it "salvages the records parsed before a structural error, and warns" do
      reader = described_class.new(records: "R", backend: :rexml).read("<L><R><A>1</A></R><R><A>2</A></OOPS></L>")
      expect([reader.to_a.map { |record| record["A"] }, reader.warnings.size]).to eq([["1"], 1])
    end

    it "reports the line a record starts on, which is what makes a warning actionable" do
      table = described_class.new(records: "INDIVIDUAL", backend: :rexml)
      expect(table.read(un_xml).to_a.first.line).to eq(4)
    end

    it "counts lines in bytes, so an accented name upstream does not shift them" do
      xml = "<L>\n<A>Bélarus — Bélarus</A>\n<R><V>1</V></R>\n</L>"
      table = described_class.new(records: "R", backend: :rexml)
      expect(table.read(xml).to_a.first.line).to eq(3)
    end
  end

  describe "the Nokogiri backend" do
    it_behaves_like "an XML record reader", :nokogiri

    # libxml2's reader exposes no position. Asserted rather than left implicit,
    # because a nil line here is a known cost of the backend and not a bug for
    # somebody to rediscover.
    it "parses without line numbers, which is what it costs" do
      table = described_class.new(records: "INDIVIDUAL", backend: :nokogiri)
      expect(table.read(un_xml).to_a.first.line).to be_nil
    end

    # The other side of the REXML example above.
    it "refuses a structurally broken document whole, rather than salvaging" do
      reader = described_class.new(records: "R", backend: :nokogiri).read("<L><R><A>1</A></R><R><A>2</A></OOPS></L>")
      expect { reader.to_a }.to raise_error(ActiveSanction::Parsers::ParseError)
    end
  end

  describe "choosing a backend" do
    after { ActiveSanction.reset_configuration! }

    it "parses with REXML unless an installation says otherwise" do
      expect(described_class.new(records: "R").backend)
        .to eq(ActiveSanction::Parsers::XmlRecords::Backends::Rexml)
    end

    it "follows the configured backend, resolved at parse time rather than at boot" do
      table = described_class.new(records: "R")
      ActiveSanction.configure { |config| config.xml_backend = :nokogiri }
      expect(table.backend).to eq(ActiveSanction::Parsers::XmlRecords::Backends::Nokogiri)
    end

    it "names what is registered when asked for a backend that is not" do
      ActiveSanction.configure { |config| config.xml_backend = :libxml }
      expect { described_class.new(records: "R").backend }
        .to raise_error(ArgumentError, /unknown XML backend :libxml.*rexml/m)
    end

    it "lets a host register its own, since the seam is the point" do
      described_class::Backends.register(:fake, Class.new { def self.available? = true })
      expect(described_class::Backends.available).to include(:fake)
    ensure
      described_class::Backends.registry.delete(:fake)
    end
  end

  describe "declaring the table" do
    it "insists on at least one record element" do
      expect { described_class.new(records: []) }.to raise_error(ArgumentError, /at least one element/)
    end

    it "takes a single element name as well as a list" do
      expect(described_class.new(records: "INDIVIDUAL").record_names).to eq(["INDIVIDUAL"])
    end

    it "rejects an encoding nobody has" do
      expect { described_class.new(records: "R", encoding: "utf-9") }
        .to raise_error(ArgumentError, /unknown encoding/)
    end

    it "replaces bytes that are not valid in the declared encoding, and says it did" do
      reader = described_class.new(records: "R").read("<L><R><A>caf\xE9</A></R></L>")
      reader.to_a
      expect(reader.warnings.map(&:message)).to include(/not valid UTF-8/)
    end
  end
end
