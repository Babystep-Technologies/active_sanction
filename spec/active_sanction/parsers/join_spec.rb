# frozen_string_literal: true

RSpec.describe ActiveSanction::Parsers::Join do
  def sdn = ActiveSanction::Parsers::DelimitedTable.new(columns: %i[ent_num name], null: "-0-")
  def alt = ActiveSanction::Parsers::DelimitedTable.new(columns: %i[ent_num alt_num alt_name], null: "-0-")
  def add = ActiveSanction::Parsers::DelimitedTable.new(columns: %i[ent_num add_num city], null: "-0-")

  def primary = sdn.read(%(36,"AEROCARIBBEAN"\n2674,"ABBAS, Abu"\n))
  def aliases = alt.read(%(36,12,"AERO-CARIBBEAN"\n36,13,"AEROCARIBBEAN SA"\n2674,220,"ABBAS, Abu Al"\n))
  def addresses = add.read(%(36,25,"Buenos Aires"\n))

  def join = described_class.new(on: :ent_num, aliases: aliases, addresses: addresses)

  def collect(join_instance = join, rows = primary)
    result = {}
    join_instance.each(rows) { |row, related| result[row[:ent_num]] = related }
    result
  end

  describe "joining" do
    it "attaches every child row that shares the key" do
      expect(collect["36"][:aliases].map { |row| row[:alt_name] })
        .to eq(["AERO-CARIBBEAN", "AEROCARIBBEAN SA"])
    end

    it "keeps the publisher's order, which is the only alias priority OFAC gives" do
      expect(collect["36"][:aliases].map { |row| row[:alt_num] }).to eq(%w[12 13])
    end

    it "hands back an empty Array rather than nil for a child file with no match" do
      expect(collect["2674"][:addresses]).to eq([])
    end

    it "names every child file on every row, so an adapter never has to check" do
      expect(collect["2674"].keys).to eq(%i[aliases addresses])
    end

    it "yields every primary row, including one with no children at all" do
      expect(collect.keys).to eq(%w[36 2674])
    end

    it "returns an Enumerator without a block, so a large join can stay lazy" do
      expect(join.each(primary).lazy.map { |row, _| row[:ent_num] }.first(1)).to eq(["36"])
    end
  end

  describe "orphans" do
    def orphaned = alt.read(%(36,12,"AERO-CARIBBEAN"\n99999,1,"ORPHAN LTD"\n))

    it "counts child rows that match no entity" do
      instance = described_class.new(on: :ent_num, aliases: orphaned)
      collect(instance)
      expect(instance.orphans).to eq(aliases: 1)
    end

    it "reports zero when the files agree, which is the expected state" do
      instance = join
      collect(instance)
      expect(instance.orphans).to eq(aliases: 0, addresses: 0)
    end

    it "does not attach an orphan to some other entity" do
      instance = described_class.new(on: :ent_num, aliases: orphaned)
      expect(collect(instance)["2674"][:aliases]).to eq([])
    end
  end

  describe "warnings" do
    it "gathers them from every file in the join, not just the primary" do
      short = alt.read(%(36,12\n))
      instance = described_class.new(on: :ent_num, aliases: short)
      collect(instance)
      expect(instance.warnings.map(&:message)).to eq(["expected 3 columns, got only 2"])
    end

    it "is empty before the files have been read" do
      expect(join.warnings).to eq([])
    end
  end

  describe "a row missing the join key" do
    it "gets no children rather than being matched to every keyless child" do
      instance = described_class.new(on: :ent_num, aliases: alt.read(%(-0- ,12,"KEYLESS"\n)))
      rows = sdn.read(%(-0- ,"NO KEY"\n))
      instance.each(rows) { |_, related| expect(related[:aliases]).to eq([]) }
    end
  end

  it "refuses a join with nothing to join to" do
    expect { described_class.new(on: :ent_num) }
      .to raise_error(ArgumentError, /at least one child reader/)
  end
end
