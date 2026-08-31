# frozen_string_literal: true

RSpec.describe ActiveSanction::Sources::OfacSdn::RemarksParser::Coverage do
  let(:parser) { ActiveSanction::Sources::OfacSdn::RemarksParser }

  def tally(*remarks)
    remarks.each_with_object(described_class.new) { |remark, coverage| coverage.record(parser.new(remark)) }
  end

  it "counts every segment it was shown" do
    expect(tally("DOB 1965; POB Iran", "Gender Male").segments).to eq(3)
  end

  it "counts a segment that produced a value as extracted" do
    expect(tally("DOB 1965; Member of the State Duma")).to have_attributes(extracted: 1, recognized: 1)
  end

  # "We know this citation carries no fields" and "we have never seen this"
  # are different states, and only the second is work.
  it "counts a shape known to be prose as recognized but not extracted" do
    expect(tally("Linked To: YAKUZA")).to have_attributes(extracted: 0, recognized: 1)
  end

  it "reports the share of segments it recognized" do
    expect(tally("DOB 1965; ICTY indictee.").percentage).to eq(50.0)
  end

  it "reports no coverage rather than perfect coverage for a run that read nothing" do
    expect(described_class.new).to have_attributes(ratio: 0.0, percentage: 0.0)
  end

  describe "the unrecognized shapes" do
    it "ranks them by what they cost, which is where a new label shows up first" do
      expect(tally("Member of the Duma", "Member of the Senate", "ICTY indictee.").top(1))
        .to eq([["Member of the", 2]])
    end

    # Without this every one of OFAC's 4,000-odd tax numbers would be its own
    # line and the histogram would be unreadable.
    it "masks digits, so one shape does not become a thousand" do
      expect(tally("Fleet Number 4471 pending", "Fleet Number 9902 pending").top)
        .to eq([["Fleet Number ####", 2]])
    end
  end

  it "says what it found in a form a sync log can print" do
    expect(tally("DOB 1965; ICTY indictee.").to_s)
      .to eq("recognized 1 of 2 segments (50.0%), 1 extracted")
  end

  it "serializes for a report that has to compare two runs" do
    expect(tally("DOB 1965; ICTY indictee.").to_h)
      .to eq(segments: 2, extracted: 1, recognized: 1, ratio: 0.5, unknown: 1)
  end
end
