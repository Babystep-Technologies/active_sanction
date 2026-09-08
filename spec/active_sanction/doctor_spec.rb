# frozen_string_literal: true

RSpec.describe ActiveSanction::Doctor do
  after { ActiveSanction.reset! }

  let(:store) { ActiveSanction::Storage::Memory.new }

  def listed(source, id = 1, **without) = FakeDoctorSource.entity(source, id, **without)

  def source(key = :ofac_sdn, **options) = FakeDoctorSource.new(key, **options)

  def doctor(*sources, **options) = described_class.new(sources: sources, store: store, **options).call

  # What the last sync left behind, which is the baseline everything here is
  # measured against.
  def stored(key, entities)
    store.write_snapshot(ActiveSanction::Snapshot.new(source: key, entities: entities))
  end

  def finding(report, check) = report.findings.find { |one| one.check == check }

  describe ".new" do
    it "resolves source keys through the registry" do
      expect(described_class.new(sources: %i[ofac_sdn], store: store).sources)
        .to eq([ActiveSanction::Sources::OfacSdn])
    end

    it "raises for a key nothing is registered under" do
      expect { described_class.new(sources: %i[ofac_sdb], store: store) }
        .to raise_error(ActiveSanction::Sources::UnknownSource, /ofac_sdb/)
    end

    it "covers every configured source when it is given none" do
      ActiveSanction.configure { |c| c.sources = %i[un_consolidated] }

      expect(described_class.new(store: store).keys).to eq(%i[un_consolidated])
    end

    it "refuses a tolerance that is not a share" do
      expect { described_class.new(sources: [source], store: store, tolerance: 4) }
        .to raise_error(ActiveSanction::ConfigurationError, /between 0 and 1/)
    end
  end

  describe "#call" do
    it "returns one diagnosis per source, in the order they were given" do
      report = doctor(source(:un_consolidated, entities: [listed(:un_consolidated)]), source)

      expect(report.sources).to eq(%i[un_consolidated ofac_sdn])
    end

    it "asks the publisher for the bytes unconditionally" do
      one = source(entities: [listed(:ofac_sdn)])
      doctor(one)

      expect(one).to be_forced
    end

    it "reports a source it could measure and compare as checked" do
      stored(:ofac_sdn, [listed(:ofac_sdn)])

      expect(doctor(source(entities: [listed(:ofac_sdn)])).first)
        .to have_attributes(status: :checked, compared?: true, ok?: true)
    end

    it "calls the block with each diagnosis as that source finishes" do
      seen = []
      described_class.new(sources: [source(entities: [listed(:ofac_sdn)])], store: store)
                     .call { |diagnosis| seen << diagnosis.source }

      expect(seen).to eq([:ofac_sdn])
    end

    # The whole point of the exercise: two runs of a list nobody has touched
    # have nothing to say about it.
    it "says nothing above info about an unchanged list" do
      entities = [listed(:ofac_sdn, 1), listed(:ofac_sdn, 2)]
      stored(:ofac_sdn, entities)

      expect(doctor(source(entities: entities))).to be_ok
    end
  end

  # Doctor exists for the failure a sync cannot see: the file still parses, the
  # record count is untouched, and the list means something different.
  describe "field fill rates" do
    it "flags a field every record lost, though the record count is unchanged" do
      entities = [listed(:ofac_sdn, 1), listed(:ofac_sdn, 2)]
      stored(:ofac_sdn, entities)
      stripped = entities.map { |entity| listed(:ofac_sdn, entity.source_ref, identifiers: []) }

      report = doctor(source(entities: stripped))

      expect(finding(report, :fill_identifiers))
        .to have_attributes(severity: :error, observed: 0.0, baseline: 1.0,
                            message: "no record carries an identifier any more, 100% did")
    end

    it "leaves the record count alone while it does so" do
      entities = [listed(:ofac_sdn, 1), listed(:ofac_sdn, 2)]
      stored(:ofac_sdn, entities)
      stripped = entities.map { |entity| listed(:ofac_sdn, entity.source_ref, identifiers: []) }

      expect(finding(doctor(source(entities: stripped)), :record_count)).to be_nil
    end

    it "warns about a partial drop rather than erroring" do
      stored(:ofac_sdn, Array.new(4) { |at| listed(:ofac_sdn, at) })
      halved = Array.new(4) { |at| listed(:ofac_sdn, at, **(at < 2 ? { dates_of_birth: [] } : {})) }

      expect(finding(doctor(source(entities: halved)), :fill_dates_of_birth))
        .to have_attributes(severity: :warn, message: /individuals with a date of birth 50% \(was 100%\)/)
    end

    it "says nothing about a movement inside the tolerance" do
      stored(:ofac_sdn, Array.new(20) { |at| listed(:ofac_sdn, at) })
      one_short = Array.new(20) { |at| listed(:ofac_sdn, at, **(at.zero? ? { addresses: [] } : {})) }

      expect(finding(doctor(source(entities: one_short)), :fill_addresses)).to be_nil
    end

    it "reports the same movement when the tolerance is tightened" do
      stored(:ofac_sdn, Array.new(20) { |at| listed(:ofac_sdn, at) })
      one_short = Array.new(20) { |at| listed(:ofac_sdn, at, **(at.zero? ? { addresses: [] } : {})) }

      expect(finding(doctor(source(entities: one_short), tolerance: 0.01), :fill_addresses)).to be_truthy
    end
  end

  describe "record counts" do
    it "warns when a list loses more records than the tolerance allows" do
      stored(:ofac_sdn, Array.new(10) { |at| listed(:ofac_sdn, at) })

      expect(finding(doctor(source(entities: [listed(:ofac_sdn)])), :record_count))
        .to have_attributes(severity: :warn, observed: 1, baseline: 10, message: /down 90%/)
    end

    # A delisting wave and a truncated download look identical from here, and
    # deciding which one it was is not this library's to make.
    it "does not call a lost record count an error" do
      stored(:ofac_sdn, Array.new(10) { |at| listed(:ofac_sdn, at) })

      expect(doctor(source(entities: [listed(:ofac_sdn)])).errors).to be_empty
    end

    it "reports a list that grew as information rather than a problem" do
      stored(:ofac_sdn, [listed(:ofac_sdn, 1)])

      expect(finding(doctor(source(entities: Array.new(4) { |at| listed(:ofac_sdn, at) })), :record_count))
        .to have_attributes(severity: :info, message: /up 300%/)
    end

    it "errors on a list that parsed to nothing at all" do
      stored(:ofac_sdn, [listed(:ofac_sdn)])

      expect(finding(doctor(source(entities: [])), :empty)).to have_attributes(severity: :error)
    end

    # Every fill rate is zero on an empty list, and reporting each of them as
    # its own collapse buries the one finding that matters.
    it "says only that about an empty list" do
      stored(:ofac_sdn, [listed(:ofac_sdn)])

      expect(doctor(source(entities: [])).findings.map(&:check)).to eq([:empty])
    end
  end

  # The crux: a threshold committed per adapter goes stale, and the day
  # somebody widens one to make a build pass is the day it stops being read.
  describe "the baseline" do
    it "compares against the snapshot the last sync stored" do
      stored(:ofac_sdn, [listed(:ofac_sdn, 1, addresses: [])])

      expect(doctor(source(entities: [listed(:ofac_sdn, 1)])).first.baseline.fill[:addresses]).to eq(0.0)
    end

    it "reports a first run against committed floors rather than as a regression" do
      report = doctor(source(entities: [listed(:ofac_sdn)], floors: { record_count: 500 }))

      expect(report.findings.map { |one| [one.check, one.severity, one.compared?] })
        .to eq([[:record_count, :warn, false]])
    end

    it "says nothing about a first run where no floor was declared" do
      expect(doctor(source(entities: [listed(:ofac_sdn)]))).to be_ok
    end

    it "leaves a first run's diagnosis saying it compared with nothing" do
      expect(doctor(source(entities: [listed(:ofac_sdn)])).first).to have_attributes(compared?: false)
    end

    # The half of a profile a stored snapshot cannot supply: what fell out of
    # the parse rather than what is in the list.
    it "takes the parse-time half of the baseline from a report a caller kept" do
      yesterday = doctor(source(entities: [listed(:ofac_sdn)], coverage: FakeCoverage.new(0.97)))
      today = source(entities: [listed(:ofac_sdn)], coverage: FakeCoverage.new(0.71))

      expect(finding(doctor(today, baseline: yesterday), :remarks_coverage))
        .to have_attributes(severity: :warn, baseline: 0.97)
    end

    it "accepts a kept report that has been through JSON" do
      yesterday = doctor(source(entities: [listed(:ofac_sdn)], coverage: FakeCoverage.new(0.97)))
      round_tripped = JSON.parse(JSON.generate(yesterday.to_h))
      today = source(entities: [listed(:ofac_sdn)], coverage: FakeCoverage.new(0.71))

      expect(finding(doctor(today, baseline: round_tripped), :remarks_coverage)).to have_attributes(baseline: 0.97)
    end

    # A profile from three syncs ago would report drift that has already been
    # reviewed, so storage wins wherever the two disagree about the version.
    it "prefers the stored snapshot to a kept profile describing another version" do
      kept = doctor(source(entities: Array.new(9) { |at| listed(:ofac_sdn, at) }))
      stored(:ofac_sdn, [listed(:ofac_sdn, 1)])

      expect(finding(doctor(source(entities: [listed(:ofac_sdn, 1)]), baseline: kept), :record_count)).to be_nil
    end

    it "reports a stored snapshot it could not read as an error of its own" do
      allow(store).to receive(:fetch_snapshot).and_raise(ActiveSanction::Storage::CorruptSnapshot, "truncated")

      expect(finding(doctor(source(entities: [listed(:ofac_sdn)])), :baseline))
        .to have_attributes(severity: :error, message: /could not be read/)
    end
  end

  describe "warnings the parse produced" do
    def warned(message, rows) = Array.new(rows) { ActiveSanction::Parsers::Warning.new(line: 1, message: message) }

    it "counts warnings by class rather than one by one" do
      warnings = (1..4).map { |at| ActiveSanction::Parsers::Warning.new(line: at, message: "row #{at} was skipped") }

      expect(doctor(source(entities: [listed(:ofac_sdn)], warnings: warnings)).first.profile.warnings)
        .to eq({ "row # was skipped" => 4 })
    end

    it "keeps a class that costs a handful of rows informational" do
      entities = Array.new(50) { |at| listed(:ofac_sdn, at) }

      expect(doctor(source(entities: entities, warnings: warned("unknown SDN_Type \"syndicate\"", 1))).first)
        .to be_ok
    end

    # The absolute count is not the signal; a class that was not there last
    # week and is now on a tenth of the file is.
    it "warns about a class that was not there at the last look" do
      yesterday = doctor(source(entities: Array.new(10) { |at| listed(:ofac_sdn, at) }, warnings: []))
      today = source(entities: Array.new(10) { |at| listed(:ofac_sdn, at) },
                     warnings: warned("unknown SDN_Type \"syndicate\"", 9))

      expect(finding(doctor(today, baseline: yesterday), :warnings))
        .to have_attributes(severity: :warn, message: /new since the last sync/)
    end

    it "leaves a class that was already there at that level informational" do
      warnings = warned("unknown SDN_Type \"syndicate\"", 9)
      entities = Array.new(10) { |at| listed(:ofac_sdn, at) }
      yesterday = doctor(source(entities: entities, warnings: warnings))

      expect(doctor(source(entities: entities, warnings: warnings), baseline: yesterday)).to be_ok
    end
  end

  describe "free text the parser did not understand" do
    it "names the shape that cost the most segments" do
      unrecognized = { "Passport No. #####" => 1880, "Member of the" => 3 }
      yesterday = doctor(source(entities: [listed(:ofac_sdn)], coverage: FakeCoverage.new(0.973)))
      today = source(entities: [listed(:ofac_sdn)], coverage: FakeCoverage.new(0.714, unrecognized: unrecognized))

      expect(finding(doctor(today, baseline: yesterday), :remarks_coverage).message)
        .to eq('remarks coverage 71.4% (was 97.3%): "Passport No. #####" x 1,880 unrecognized')
    end

    it "holds a first run to the floor the adapter committed to" do
      today = source(entities: [listed(:ofac_sdn)], coverage: FakeCoverage.new(0.71),
                     floors: { remarks_coverage: 0.90 })

      expect(finding(doctor(today), :remarks_coverage))
        .to have_attributes(severity: :warn, message: /below the floor of 90%/)
    end

    it "says nothing about a source that reads no free text" do
      expect(finding(doctor(source(entities: [listed(:ofac_sdn)])), :remarks_coverage)).to be_nil
    end
  end

  describe "child rows that matched no record" do
    it "reports a handful as information" do
      entities = Array.new(50) { |at| listed(:ofac_sdn, at) }

      expect(finding(doctor(source(entities: entities, orphans: { aliases: 2 })), :orphans))
        .to have_attributes(severity: :info, message: /2 child row\(s\) matched no record: 2 in aliases/)
    end

    it "warns when the join has stopped joining" do
      expect(finding(doctor(source(entities: [listed(:ofac_sdn)], orphans: { aliases: 900 })), :orphans))
        .to have_attributes(severity: :warn)
    end
  end

  # Government endpoints go down, and a UN outage must not stop OFAC being
  # diagnosed.
  describe "per-source isolation" do
    def failing(key = :un_consolidated)
      source(key, error: ActiveSanction::FetchError.new("503 from the publisher", status: 503))
    end

    it "diagnoses the other sources when one cannot be read" do
      report = doctor(failing, source(entities: [listed(:ofac_sdn)]))

      expect(report.map(&:status)).to eq(%i[failed checked])
    end

    it "records the failure as an error finding on that source alone" do
      report = doctor(failing, source(entities: [listed(:ofac_sdn)]))

      expect(report.errors.map { |one| [one.source, one.check] }).to eq([%i[un_consolidated parse]])
    end

    it "keeps the exception for a caller that wants the backtrace" do
      expect(doctor(failing).first.exception).to be_a(ActiveSanction::FetchError)
    end

    it "stamps the source onto an exception raised somewhere that could not know" do
      expect(doctor(failing).first.exception.source_id).to eq(:un_consolidated)
    end

    it "does not raise for a source that could not be read" do
      expect { doctor(failing) }.not_to raise_error
    end
  end

  # Nothing is stored, so a diagnosis can never be the reason a later sync
  # decides a list it has not seen is unchanged.
  describe "leaving no trace" do
    it "writes no snapshot" do
      doctor(source(entities: [listed(:ofac_sdn)]))

      expect(store).to be_empty
    end

    it "builds its adapters over validators that live and die with the run" do
      adapter = described_class.new(sources: [ActiveSanction::Sources::OfacSdn], store: store)
                               .send(:isolate, ActiveSanction::Sources::OfacSdn)

      expect(adapter.fetcher.store).to be_a(ActiveSanction::ValidatorStore::Memory)
    end

    it "gives them no payload cache to write to" do
      adapter = described_class.new(sources: [ActiveSanction::Sources::OfacSdn], store: store)
                               .send(:isolate, ActiveSanction::Sources::OfacSdn)

      expect(adapter.cache).to be_nil
    end
  end

  describe "the run's report" do
    it "exits non-zero on an error" do
      stored(:ofac_sdn, [listed(:ofac_sdn)])

      expect(doctor(source(entities: [])).exit_code).to eq(1)
    end

    it "exits zero on a warning unless it is asked not to" do
      stored(:ofac_sdn, Array.new(10) { |at| listed(:ofac_sdn, at) })
      report = doctor(source(entities: [listed(:ofac_sdn)]))

      expect([report.exit_code, report.exit_code(on: :warn)]).to eq([0, 1])
    end

    it "serializes to something a nightly job can keep" do
      report = doctor(source(entities: [listed(:ofac_sdn)]))

      expect(described_class::Report.from_h(JSON.parse(JSON.generate(report.to_h)))).to eq(report)
    end
  end

  # The committed OFAC fixtures, through fetch, parse and comparison, with
  # nothing stubbed but the government.
  describe "over the real fetch path" do
    def file(name) = File.read("spec/fixtures/ofac_sdn/#{name}")

    def stub_ofac(primary)
      { "SDN.CSV" => primary, "ALT.CSV" => file("ALT.CSV"), "ADD.CSV" => file("ADD.CSV") }.each do |name, body|
        stub_request(:get, "https://sanctionslistservice.ofac.treas.gov/api/download/#{name}")
          .to_return(status: 200, body: body, headers: { "ETag" => "\"#{name}\"" })
      end
    end

    it "diagnoses the list the publisher served" do
      stub_ofac(file("SDN.CSV"))

      expect(doctor(:ofac_sdn).first).to have_attributes(status: :checked, record_count: 7)
    end

    # The failure the declared column width cannot see: a column removed
    # upstream, every row still the right width, every field one place out.
    it "reports a file whose columns have shifted as an error" do
      stub_ofac(file("SDN_SHIFTED.CSV"))

      expect(doctor(:ofac_sdn).errors.map(&:check)).to contain_exactly(:column_ent_num, :column_sdn_type)
    end

    it "names what the shifted column holds instead" do
      stub_ofac(file("SDN_SHIFTED.CSV"))

      expect(finding(doctor(:ofac_sdn), :column_ent_num).message)
        .to include("ent_num numeric on 0% of 6 rows", '"AEROCARIBBEAN AIRLINES"')
    end

    it "parses that file without raising, which is what makes it dangerous" do
      stub_ofac(file("SDN_SHIFTED.CSV"))

      expect(doctor(:ofac_sdn).first).to have_attributes(status: :checked, record_count: 4)
    end

    it "reports the unchanged file's columns as sound" do
      stub_ofac(file("SDN.CSV"))

      expect(doctor(:ofac_sdn).errors).to be_empty
    end

    it "leaves the fetcher's stored validators alone" do
      stub_ofac(file("SDN.CSV"))
      doctor(:ofac_sdn)

      expect(ActiveSanction::Fetcher.new(store: ActiveSanction::ValidatorStore::Memory.new)
                                    .validators(:"ofac_sdn-sdn")).to be_nil
    end
  end
end
