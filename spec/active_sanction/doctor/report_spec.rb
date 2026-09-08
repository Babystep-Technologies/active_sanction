# frozen_string_literal: true

RSpec.describe ActiveSanction::Doctor::Report do
  def finding(source, severity, check = :record_count, message = "12,433 records, was 19,015")
    ActiveSanction::Doctor::Finding.new(source: source, severity: severity, check: check, message: message)
  end

  def diagnosis(source, findings = [], **overrides)
    ActiveSanction::Doctor::Diagnosis.new(
      source: source, status: :checked, findings: findings, **overrides
    )
  end

  def report(*diagnoses, duration: 18.42)
    described_class.new(diagnoses: diagnoses, started_at: Time.utc(2026, 9, 7), duration: duration)
  end

  describe "reading the run" do
    it "answers with one source's diagnosis" do
      expect(report(diagnosis(:ofac_sdn), diagnosis(:un_consolidated))[:un_consolidated].source)
        .to eq(:un_consolidated)
    end

    # A caller asking about a source the run did not cover is asking a question
    # with an answer.
    it "answers nil for a source the run did not cover" do
      expect(report(diagnosis(:ofac_sdn))[:eu_fsf]).to be_nil
    end

    it "is enumerable over its diagnoses" do
      expect(report(diagnosis(:ofac_sdn), diagnosis(:eu_fsf)).map(&:source)).to eq(%i[ofac_sdn eu_fsf])
    end
  end

  describe "findings across every source" do
    def mixed
      report(diagnosis(:ofac_sdn, [finding(:ofac_sdn, :info, :orphans, "2 orphans"), finding(:ofac_sdn, :warn)]),
             diagnosis(:eu_fsf, [finding(:eu_fsf, :error, :empty, "parsed to no records at all")]))
    end

    it "puts the most serious first" do
      expect(mixed.findings.map(&:severity)).to eq(%i[error warn info])
    end

    it "sorts them into the three severities" do
      expect([mixed.errors.size, mixed.warnings.size, mixed.infos.size]).to eq([1, 1, 1])
    end

    it "names the sources with something worth reading about them" do
      expect(mixed.unhealthy.map(&:source)).to eq(%i[ofac_sdn eu_fsf])
    end

    it "is not ok while any of them is above info" do
      expect(mixed).not_to be_ok
    end

    it "is ok when nothing anywhere rose above info" do
      expect(report(diagnosis(:ofac_sdn, [finding(:ofac_sdn, :info, :orphans, "2 orphans")]))).to be_ok
    end
  end

  # A list that cannot be read is not a matter of taste; whether drift should
  # stop a deployment is.
  describe "#exit_code" do
    it "is 1 on an error" do
      expect(report(diagnosis(:eu_fsf, [finding(:eu_fsf, :error, :empty, "empty")])).exit_code).to eq(1)
    end

    it "is 0 on a warning by default" do
      expect(report(diagnosis(:ofac_sdn, [finding(:ofac_sdn, :warn)])).exit_code).to eq(0)
    end

    it "is 1 on a warning for a caller that asks for it" do
      expect(report(diagnosis(:ofac_sdn, [finding(:ofac_sdn, :warn)])).exit_code(on: :warn)).to eq(1)
    end

    it "is 0 for a clean run" do
      expect(report(diagnosis(:ofac_sdn)).exit_code(on: :info)).to eq(0)
    end
  end

  describe "printing" do
    it "summarizes a clean run" do
      expect(report(diagnosis(:ofac_sdn)).summary).to eq("1 source in 18.42s: all healthy")
    end

    it "counts the sources with findings and the ones it could not read" do
      run = report(diagnosis(:ofac_sdn, [finding(:ofac_sdn, :warn)]),
                   diagnosis(:eu_fsf, [finding(:eu_fsf, :error, :parse, "could not be read")], status: :failed))

      expect(run.summary).to eq("2 sources in 18.42s: 2 with findings, 1 unreadable")
    end

    it "prints a source per block, aligned, with its findings under it" do
      run = report(diagnosis(:ofac_sdn, [finding(:ofac_sdn, :warn)]), diagnosis(:un_consolidated))

      expect(run.to_s.lines.map(&:chomp)).to eq(
        ["2 sources in 18.42s: 1 with findings",
         "ofac_sdn         WARN  1 finding",
         "  warn   12,433 records, was 19,015",
         "un_consolidated  OK"]
      )
    end
  end

  # What a nightly job keeps so the next run has last night's warning classes
  # to compare against.
  describe "#profiles" do
    it "hands back what each source measured, keyed by source" do
      measured = ActiveSanction::Doctor::Profile.new(source: :ofac_sdn, record_count: 3)

      expect(report(diagnosis(:ofac_sdn, [], profile: measured)).profiles).to eq({ ofac_sdn: measured })
    end

    it "leaves out a source that measured nothing" do
      expect(report(diagnosis(:eu_fsf, [], status: :failed)).profiles).to be_empty
    end
  end

  describe "serialization" do
    it "rebuilds from its own hash" do
      original = report(diagnosis(:ofac_sdn, [finding(:ofac_sdn, :warn)]))

      expect(described_class.from_h(original.to_h)).to eq(original)
    end

    it "survives the trip through JSON" do
      original = report(diagnosis(:ofac_sdn, [finding(:ofac_sdn, :warn)]), diagnosis(:eu_fsf))

      expect(described_class.from_h(JSON.parse(JSON.generate(original.to_h)))).to eq(original)
    end

    it "refuses a hash carrying an attribute it does not have" do
      expect { described_class.from_h({ diagnoses: [], findings: [] }) }
        .to raise_error(ActiveSanction::InvalidArgument, /findings/)
    end
  end
end
