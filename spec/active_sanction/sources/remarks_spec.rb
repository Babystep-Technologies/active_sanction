# frozen_string_literal: true

RSpec.describe ActiveSanction::Sources::Remarks do
  describe ".build" do
    it "returns the publisher's text unchanged when there is nothing to append" do
      expect(described_class.build("Registered in Panama")).to eq("Registered in Panama")
    end

    it "appends a field behind the marker" do
      expect(described_class.build("Registered in Panama", [["Vessel flag", "Panama"]]))
        .to eq("Registered in Panama [source fields] Vessel flag: Panama")
    end

    it "leaves out a field the record did not fill in" do
      expect(described_class.build("x", [["Title", nil], ["Tonnage", "  "], ["GRT", "8000"]]))
        .to eq("x [source fields] GRT: 8000")
    end

    it "joins a field a publisher listed several times" do
      expect(described_class.build(nil, [["Designation", %w[Colonel Commander]]]))
        .to eq("[source fields] Designation: Colonel, Commander")
    end

    it "is nil when the publisher wrote nothing and there was nothing to append" do
      expect(described_class.build("   ")).to be_nil
    end
  end

  describe ".published" do
    it "strips everything the adapter appended" do
      remark = described_class.build("Registered in Panama", [%w[Tonnage 8000]])

      expect(described_class.published(remark)).to eq("Registered in Panama")
    end

    it "leaves a remark with nothing appended untouched" do
      expect(described_class.published("Registered in Panama")).to eq("Registered in Panama")
    end

    # The case a per-adapter implementation gets wrong. With no marker emitted
    # when the publisher's own text is blank, everything the adapter appended
    # reads back as though the publisher had written it -- and #19's remarks
    # parser would then read a vessel's tonnage looking for a date of birth.
    it "is nil when every word in the remark was put there by an adapter" do
      remark = described_class.build(nil, [["Vessel flag", "Panama"]])

      expect(described_class.published(remark)).to be_nil
    end

    it "is nil for a record with no remark at all" do
      expect(described_class.published(nil)).to be_nil
    end
  end

  # The two adapters reach it the same way, through Base, so a caller does not
  # have to know which list a remark came from before it can strip one.
  describe "as every adapter inherits it" do
    it "is available on each source under one name" do
      remark = described_class.build("published text", [%w[Gender Male]])

      expect([ActiveSanction::Sources::OfacSdn.published_remarks(remark),
              ActiveSanction::Sources::UnConsolidated.published_remarks(remark)])
        .to eq(["published text", "published text"])
    end
  end
end
