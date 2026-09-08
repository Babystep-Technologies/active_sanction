# frozen_string_literal: true

RSpec.describe ActiveSanction::Doctor::Diagnosis do
  def finding(severity, check = :record_count, message = "12,433 records, was 19,015")
    ActiveSanction::Doctor::Finding.new(source: :ofac_sdn, severity: severity, check: check, message: message)
  end

  def profile(records = 3)
    ActiveSanction::Doctor::Profile.new(source: :ofac_sdn, record_count: records)
  end

  def diagnosis(**overrides)
    described_class.new(source: :ofac_sdn, status: :checked, **overrides)
  end

  describe ".new" do
    it "refuses a status that is neither of the two" do
      expect { diagnosis(status: :unchanged) }
        .to raise_error(ActiveSanction::InvalidArgument, /checked, failed/)
    end

    it "freezes on construction" do
      expect(diagnosis).to be_frozen
    end
  end

  describe "how a source came out" do
    it "is ok when nothing rose above info" do
      expect(diagnosis(findings: [finding(:info)])).to be_ok
    end

    it "is not ok on a warning" do
      expect(diagnosis(findings: [finding(:warn)])).not_to be_ok
    end

    it "reports the most serious severity it found" do
      expect(diagnosis(findings: [finding(:info), finding(:error), finding(:warn)]).severity).to eq(:error)
    end

    it "has no severity when it found nothing" do
      expect(diagnosis.severity).to be_nil
    end

    it "sorts its findings into the three severities" do
      one = diagnosis(findings: [finding(:info), finding(:error), finding(:warn)])

      expect([one.errors.size, one.warnings.size, one.infos.size]).to eq([1, 1, 1])
    end
  end

  # A source that could not be fetched is not a source in good health, but nor
  # is it one anything here can say a thing about.
  describe "a source that could not be read" do
    def failed
      diagnosis(status: :failed, error: ActiveSanction::FetchError.new("503 from the publisher", status: 503))
    end

    it "keeps the exception for a caller that wants the backtrace" do
      expect(failed.exception).to be_a(ActiveSanction::FetchError)
    end

    it "prints the failure on one line" do
      expect(failed.error).to eq("ActiveSanction::FetchError: 503 from the publisher")
    end

    it "measured nothing" do
      expect(failed).to have_attributes(profile: nil, record_count: 0)
    end
  end

  # The difference between "nothing changed" and "this is the first look".
  describe "whether it compared with anything" do
    it "has compared when a baseline was found" do
      expect(diagnosis(baseline: profile)).to be_compared
    end

    it "has not when there was none" do
      expect(diagnosis(profile: profile)).not_to be_compared
    end
  end

  describe "printing" do
    it "labels a clean source OK" do
      expect(diagnosis.headline).to eq("ofac_sdn  OK")
    end

    it "labels a source by the worst thing found on it, and says how many" do
      expect(diagnosis(findings: [finding(:warn), finding(:info, :orphans, "2 orphans")]).headline)
        .to eq("ofac_sdn  WARN  2 findings")
    end

    it "pads the source name to the width the whole run needs" do
      expect(diagnosis.headline(15)).to eq("ofac_sdn         OK")
    end

    it "prints its findings under its heading" do
      expect(diagnosis(findings: [finding(:warn)]).to_s)
        .to eq("ofac_sdn  WARN  1 finding\n  warn   12,433 records, was 19,015")
    end
  end

  describe "serialization" do
    it "rebuilds from its own hash" do
      original = diagnosis(findings: [finding(:warn)], profile: profile, baseline: profile(9), duration: 1.5)

      expect(described_class.from_h(original.to_h)).to eq(original)
    end

    # A backtrace is not something to put in a metrics pipeline; the class and
    # the message are what an alert is written against.
    it "keeps the failure's class and message but not the exception" do
      original = diagnosis(status: :failed, error: ActiveSanction::FetchError.new("gone", status: 404))
      rebuilt = described_class.from_h(JSON.parse(JSON.generate(original.to_h)))

      expect(rebuilt).to have_attributes(error: original.error, exception: nil)
    end
  end
end
