# typed: ignore
# frozen_string_literal: true

# The contract every source adapter must satisfy, written once.
#
# Loaded by `require "active_sanction/testing"` -- see ActiveSanction::Testing,
# which is where the entry point and the fixture root are documented.
#
#   RSpec.describe ActiveSanction::Sources::CanadaSema do
#     it_behaves_like "a sanction source", fixture: "canada_sema/sema.xml"
#   end
#
# A list its publisher splits across several files names each one, under the
# keys the adapter declared its URLs with:
#
#   it_behaves_like "a sanction source",
#                   fixture: { sdn: "ofac_sdn/SDN.CSV", alt: "ofac_sdn/ALT.CSV", add: "ofac_sdn/ADD.CSV" }
#
# Paths are relative to `spec/fixtures` -- or to whatever
# `ActiveSanction::Testing.fixture_root` names, and an absolute path is taken
# as it stands. The bytes reach #parse exactly as they were committed --
# undecoded, so an adapter reading the Windows-1252 OFAC serves is held to
# doing its own decoding rather than to being handed a String somebody already
# fixed up.
#
# ### What this is for
#
# Everything downstream of an adapter -- storage, the diff between two syncs,
# the index, the matcher, the report an examiner reads -- is written against
# Entity and never against a list. That only holds if every adapter really
# does produce the same shape, and "the same shape" is otherwise a paragraph
# in a design document that each new adapter re-interprets. Here it is
# executable, so adding a jurisdiction is a checklist rather than an open
# research question.
#
# ### What it does not do
#
# It does not check that the adapter read its list *correctly*. Nothing here
# knows that OFAC writes `-0-` for null, that the UN means two different
# things by QUALITY, or which of the fixture's records is a vessel. Only a
# spec that knows what is in the fixture can check that, so every adapter
# still writes its own; this group is the floor, not the ceiling.
#
# ### Options
#
#   fixture:  required. A path under the fixture root, or a Hash of one path
#             per declared URL. Real published records, not invented ones --
#             a conformance run against a fixture somebody wrote to pass it
#             proves nothing about the list.
#
#   remarks:  pass `remarks: false` for a list that publishes no free text of
#             its own at all, so the check that the publisher's own words
#             survive into `remarks` is skipped. Every list at launch does
#             publish some, which is why the default is to require it: a
#             remark quietly dropped is how a place of birth or a passport
#             number stops reaching #19.
RSpec.shared_examples "a sanction source" do |options = {}|
  publishes_remarks = options.fetch(:remarks, true)

  # Read through a `let` rather than closed over directly, so that a group
  # that forgot to name a fixture says so when an example asks for one rather
  # than while the suite is still loading.
  let(:fixture) do
    options.fetch(:fixture) do
      raise ArgumentError, %(pass the fixture to parse: it_behaves_like "a sanction source", fixture: "list.xml")
    end
  end

  let(:source) { described_class.new }
  let(:payload) { fixture_payload(fixture) { |bytes| bytes } }
  let(:records) { source.parse(payload) }

  # Fixture bytes in the shape this adapter's #parse takes: the bytes
  # themselves for a source declaring one file, a Hash keyed by declaration
  # name for one declaring several. The same rule Base applies before calling
  # #parse, so an adapter is exercised here exactly as `sync` exercises it.
  def fixture_payload(paths)
    bytes = named_fixtures(paths).to_h { |name, path| [name, yield(File.binread(fixture_path(path)))] }
    described_class.multi_url? ? bytes : bytes.values.first
  end

  # One fixture path per declared file. A source declaring one file may name it
  # as a bare path, which is what reading a fixture off disk looks like.
  def named_fixtures(paths)
    files = paths.is_a?(Hash) ? paths : { described_class.urls.keys.first => paths }
    missing = described_class.urls.keys - files.keys
    raise ArgumentError, "no fixture given for the #{missing.join(", ")} file(s) this source declares" if missing.any?

    files
  end

  # Resolved through Testing rather than relative to this file, which is what
  # lets the group work for a project whose fixtures are its own. See
  # ActiveSanction::Testing.fixture_root.
  def fixture_path(path) = ActiveSanction::Testing.fixture_path(path)

  # Every date any entity carries, wherever the model puts them.
  def entity_dates(entities)
    entities.flat_map do |entity|
      [entity.listed_on, *entity.dates_of_birth,
       *entity.identifiers.flat_map { |identifier| [identifier.issued_on, identifier.expires_on] }]
    end.compact
  end

  # The serialized records half the bytes produce, or the marker that reading
  # them raised -- which is the other acceptable answer, and never equal to a
  # complete parse.
  def parsed_truncated(paths)
    truncated = fixture_payload(paths) { |bytes| bytes[0, bytes.bytesize / 2] }
    described_class.new.parse(truncated).map(&:to_h)
  rescue ActiveSanction::Error
    :raised
  end

  describe "what it declares" do
    it "declares a key, which is the name the list answers to everywhere" do
      expect(described_class.key.to_s).to match(ActiveSanction::Sources::Definition::KEY_PATTERN)
    end

    it "declares the jurisdiction behind the list" do
      expect(described_class.jurisdiction).to be_a(Symbol)
    end

    it "declares the authority a compliance report has to print beside a hit" do
      expect(described_class.authority).to be_a(String)
    end

    it "declares at least one URL to fetch the list from" do
      expect(described_class.urls).not_to be_empty
    end

    # An adapter whose file is required but which never registers is invisible:
    # `config.sources` cannot name it and `sync` will not run it, and nothing
    # says so out loud.
    it "registers itself, so requiring its file is enough to reach it" do
      expect(ActiveSanction::Sources[described_class.key]).to eq(described_class)
    end
  end

  describe "what #parse returns" do
    it "builds at least one record from the fixture" do
      expect(records).not_to be_empty
    end

    it "returns Entities and nothing else" do
      expect(records).to all(be_an(ActiveSanction::Entity))
    end

    it "stamps every entity with this adapter's own key" do
      expect(records.map(&:source).uniq).to eq([described_class.key])
    end

    it "gives every entity an id" do
      expect(records.map(&:id)).to all(match(/\S/))
    end

    # A record with no name cannot be screened against, so it is not a record.
    it "gives every entity at least one name" do
      expect(records.reject { |record| record.names.any? }).to be_empty
    end

    # Types are the matcher's coarsest filter: a search for a person that can
    # rank a ship is the failure this closes. Entity refuses anything else on
    # construction, so this fails only for something that is not an Entity.
    it "types every entity as one of the four canonical types" do
      expect(records.map(&:type).uniq - ActiveSanction::Entity::TYPES).to be_empty
    end

    # Two records under one id are one record to storage, and the second
    # silently replaces the first.
    it "gives no two entities the same id" do
      expect(records.map(&:id).tally.select { |_id, count| count > 1 }).to be_empty
    end
  end

  # #35 diffs two syncs by comparing records under their ids. An id that moves
  # because a Hash iterated differently, or because a counter was involved,
  # reports the whole list as removed and re-added -- and a diff that says
  # everything changed says nothing at all.
  describe "reading the same bytes twice" do
    it "produces the same ids" do
      expect(described_class.new.parse(payload).map(&:id)).to eq(records.map(&:id))
    end

    it "produces the same records, in the same order" do
      expect(described_class.new.parse(payload).map(&:to_h)).to eq(records.map(&:to_h))
    end
  end

  describe "the canonical model it produces" do
    # A date left as the publisher's string cannot be compared with one from
    # another list, and PartialDate exists because none of these lists agree on
    # how precise a date of birth is. Entity does not coerce, so an adapter
    # that forgets is caught here rather than in the scorer.
    it "publishes every date as a PartialDate, never as the string it was written as" do
      expect(entity_dates(records)).to all(be_a(ActiveSanction::PartialDate))
    end

    # What storage (#24) does to every record on the way to disk and back.
    it "round-trips every entity through the serialized form" do
      expect(records.map { |record| ActiveSanction::Entity.from_h(record.to_h) }).to eq(records)
    end

    if publishes_remarks
      # The publisher's own prose is where the fields the canonical model has
      # no home for still live -- OFAC's dates of birth and passport numbers
      # are nowhere else -- so an adapter that drops it loses data no later
      # issue can get back.
      it "keeps the publisher's own text in remarks" do
        expect(records.filter_map { |record| ActiveSanction::Sources::Remarks.published(record.remarks) })
          .not_to be_empty
      end
    end
  end

  describe "a payload that is not the list" do
    # No sanctions list has ever been empty, so an empty payload is a failed
    # download, a moved URL or an outage -- never a day on which nobody is
    # sanctioned. Returning [] lets a sync succeed at screening against
    # nothing, which is the most expensive way this library can fail.
    it "refuses an empty payload rather than reporting a list with nobody on it" do
      expect { described_class.new.parse(fixture_payload(fixture) { "" }) }
        .to raise_error(ActiveSanction::Error)
    end

    # A truncated download may still be worth salvaging -- the XML toolkit
    # keeps the records it read before the break and warns -- so what is
    # required is not that it raises, only that half a list never comes back
    # looking exactly like the whole one.
    it "does not report a truncated document as though it were the whole list" do
      expect(parsed_truncated(fixture)).not_to eq(records.map(&:to_h))
    end
  end
end
