# frozen_string_literal: true

RSpec.describe ActiveSanction::Diff::Change do
  def name(value, kind: :primary) = ActiveSanction::Name.new(value: value, kind: kind)

  def entity(**overrides)
    ActiveSanction::Entity.new(
      source: :ofac_sdn, source_ref: "2674", type: :individual,
      names: [name("ABBAS, Abu")], programs: ["SDGT"],
      **overrides
    )
  end

  def change(**overrides) = described_class.between(entity, entity(**overrides))

  describe ".between" do
    it "is nil when the two versions say the same thing" do
      expect(described_class.between(entity, entity)).to be_nil
    end

    it "reports only the fields that moved" do
      expect(change(programs: %w[SDGT SDNTK]).fields).to eq(%i[programs])
    end

    # A field the canonical record gains has to be compared without anybody
    # remembering to add it here -- a diff that silently stops reporting a
    # field is how an amendment goes unnoticed.
    it "covers every member of the canonical record except the id it joined on" do
      expect(described_class::FIELDS).to eq(ActiveSanction::Entity::MEMBERS - %i[id])
    end
  end

  describe "a collection field" do
    it "reports what the new list has and the old did not" do
      amended = change(names: [name("ABBAS, Abu"), name("ZAYDAN, Muhammad", kind: :nka)])

      expect(amended[:names][:added].map(&:value)).to eq(["ZAYDAN, Muhammad"])
    end

    it "reports what the old list had and the new does not" do
      expect(change(programs: [])[:programs]).to eq(added: [], removed: ["SDGT"])
    end

    # A publisher re-emitting the same aliases in a different order has not
    # amended the record, and saying it has costs somebody a review.
    it "is not moved by a reordering" do
      published = entity(names: [name("ABBAS, Abu"), name("ZAYDAN, Muhammad", kind: :nka)])
      reordered = entity(names: [name("ZAYDAN, Muhammad", kind: :nka), name("ABBAS, Abu")])

      expect(described_class.between(published, reordered)).to be_nil
    end
  end

  describe "a scalar field" do
    it "reports the value on each side" do
      expect(change(type: :vessel)[:type]).to eq(from: :individual, to: :vessel)
    end

    it "reports a value the old list did not carry at all" do
      expect(change(remarks: "Linked To: PALESTINE LIBERATION FRONT")[:remarks][:from]).to be_nil
    end
  end

  describe "#to_s" do
    it "counts what moved in each collection" do
      amended = change(names: [name("ZAYDAN, Muhammad")], programs: %w[SDGT SDNTK])

      expect(amended.to_s).to eq("ofac_sdn:2674  names +1 -1, programs +1")
    end

    it "prints both sides of a scalar" do
      expect(change(type: :vessel).summary).to eq("type individual -> vessel")
    end

    it "names a value the old list did not carry rather than printing nothing" do
      expect(change(listed_on: ActiveSanction::PartialDate.new(year: 2011, month: 5, day: 16)).summary)
        .to eq("listed_on (none) -> 2011-05-16")
    end

    # Remarks are prose and run to paragraphs; the line answers which field
    # moved, not what the whole of the new text says.
    it "truncates prose" do
      expect(change(remarks: "a" * 200).summary).to eq("remarks (none) -> #{"a" * 40}...")
    end
  end

  describe "#to_h" do
    it "serializes value objects the way a snapshot serializes them" do
      amended = change(names: [name("ABBAS, Abu"), name("ZAYDAN, Muhammad", kind: :nka)])

      expect(amended.to_h[:changes][:names][:added]).to eq([name("ZAYDAN, Muhammad", kind: :nka).to_h])
    end

    it "carries both versions of the record, so a consumer need not hold the snapshots" do
      expect(change(type: :vessel).to_h[:previous]).to eq(entity.to_h)
    end
  end

  it "is frozen" do
    expect(change(type: :vessel)).to be_frozen
  end
end
