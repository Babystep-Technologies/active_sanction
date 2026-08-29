# frozen_string_literal: true

require "json"

RSpec.describe ActiveSanction::PartialDate do
  describe ".parse" do
    # Every row is a value the live lists actually publish, per the issue.
    {
      "1971" => [:year, "1971"],                          # UN <YEAR>1971</YEAR>
      "1972" => [:year, "1972"],                          # Canada, year only
      "1965-04-29" => [:day, "1965-04-29"],               # Canada, full date
      "1972-04" => [:month, "1972-04"],
      "03 May 1938" => [:day, "1938-05-03"],              # OFAC "DOB 03 May 1938"
      "May 1938" => [:month, "1938-05"],
      "May 3, 1938" => [:day, "1938-05-03"],
      "29 Apr. 1972" => [:day, "1972-04-29"],
      "circa 1962" => [:year, "circa 1962"],              # OFAC "DOB circa 1962"
      "c. 1962" => [:year, "circa 1962"],
      "ca 1962" => [:year, "circa 1962"],
      "approximately 1962" => [:year, "circa 1962"],      # UN APPROXIMATELY
      "~1962" => [:year, "circa 1962"],
      "between 1971 and 1973" => [:range, "1971 to 1973"], # UN BETWEEN
      "1971 to 1973" => [:range, "1971 to 1973"],
      "1971-1973" => [:range, "1971 to 1973"],
      "circa 1971 to 1973" => [:range, "circa 1971 to 1973"]
    }.each do |raw, (precision, rendered)|
      it "reads #{raw.inspect} as #{rendered.inspect} at #{precision} precision" do
        parsed = described_class.parse(raw)

        expect([parsed.precision, parsed.to_s]).to eq([precision, rendered])
      end
    end

    it "tolerates surrounding and repeated whitespace" do
      expect(described_class.parse("  03   May 1938 ").to_s).to eq("1938-05-03")
    end

    # The issue is explicit: unparseable input returns nil so a single bad
    # remarks string cannot abort the import of the entity around it.
    ["", "   ", "sometime in the 90s", "1972-02-31", "1972-13", "Smarch 1938", "n/a", nil].each do |raw|
      it "returns nil for #{raw.inspect} rather than raising" do
        expect(described_class.parse(raw)).to be_nil
      end
    end

    it "returns nil for a range that runs backwards" do
      expect(described_class.parse("1973 to 1971")).to be_nil
    end

    it "returns nil for a nested range rather than flattening it" do
      expect(described_class.parse("1971 to 1972 to 1973")).to be_nil
    end

    # A bare dash separates a span only between two four-digit years, or the
    # "-" in an ISO month would read as a span from 1972 to April.
    it "does not mistake an ISO month for a span" do
      expect(described_class.parse("1972-04").precision).to eq(:month)
    end

    it "renders in a form it reads back" do
      round_tripped = ["1971", "1972-04", "1965-04-29", "circa 1962", "1971 to 1973", "circa 1971 to 1973"]
                      .map { |raw| described_class.parse(described_class.parse(raw).to_s).to_s }

      expect(round_tripped).to eq(["1971", "1972-04", "1965-04-29", "circa 1962", "1971 to 1973", "circa 1971 to 1973"])
    end
  end

  describe "#precision" do
    it "covers the documented enum" do
      precisions = [
        described_class.new(year: 1972),
        described_class.new(year: 1972, month: 4),
        described_class.new(year: 1972, month: 4, day: 29),
        described_class.range("1971", "1973")
      ].map(&:precision)

      expect(precisions).to eq(described_class::PRECISIONS)
    end
  end

  describe "#to_range" do
    it "spans the whole year for a year-only date" do
      expect(described_class.new(year: 1972).to_range).to eq(Date.new(1972, 1, 1)..Date.new(1972, 12, 31))
    end

    it "spans the whole month, ending on its real last day" do
      expect(described_class.new(year: 1972, month: 2).to_range).to eq(Date.new(1972, 2, 1)..Date.new(1972, 2, 29))
    end

    it "spans a single day for a full date" do
      expect(described_class.new(year: 1972, month: 4, day: 29).to_range.count).to eq(1)
    end

    it "spans from the start of the first endpoint to the end of the last" do
      expect(described_class.range("1971", "1973").to_range).to eq(Date.new(1971, 1, 1)..Date.new(1973, 12, 31))
    end
  end

  describe "#overlaps? and #conflicts_with?" do
    let(:year_only) { described_class.parse("1972") }

    # Both acceptance criteria from the issue.
    it "does not conflict with a full date inside the same year" do
      expect(year_only.conflicts_with?(described_class.parse("1972-04-29"))).to be(false)
    end

    it "conflicts with a different year" do
      expect(year_only.conflicts_with?(described_class.parse("1980"))).to be(true)
    end

    it "overlaps a full date inside the same year, whichever side asks" do
      full = described_class.parse("1972-04-29")

      expect([year_only.overlaps?(full), full.overlaps?(year_only)]).to eq([true, true])
    end

    it "overlaps a year that a span covers" do
      expect(described_class.parse("between 1971 and 1973").overlaps?(described_class.parse("1972"))).to be(true)
    end

    it "conflicts with a year just outside a span" do
      expect(described_class.parse("between 1971 and 1973").conflicts_with?(described_class.parse("1974"))).to be(true)
    end

    it "does not overlap adjacent days" do
      expect(described_class.parse("1972-04-29").overlaps?(described_class.parse("1972-04-30"))).to be(false)
    end

    # "Circa 1962" and "1963" are the same claim made by two governments off
    # different sources; scoring that as a conflict penalizes a true match.
    it "gives an approximate date a year of slack on each side" do
      circa = described_class.parse("circa 1962")

      expect([circa.overlaps?(described_class.parse("1963")), circa.overlaps?(described_class.parse("1961"))])
        .to eq([true, true])
    end

    it "still conflicts beyond that slack" do
      expect(described_class.parse("circa 1962").conflicts_with?(described_class.parse("1970"))).to be(true)
    end

    it "does not widen the stored date, only the comparison" do
      expect(described_class.parse("circa 1962").to_range).to eq(Date.new(1962, 1, 1)..Date.new(1962, 12, 31))
    end

    # An entity with no DOB contradicts nothing.
    it "treats a missing date as neither an overlap nor a conflict" do
      expect([year_only.overlaps?(nil), year_only.conflicts_with?(nil)]).to eq([false, false])
    end

    it "raises when handed something that is not a date" do
      expect { year_only.overlaps?("1972") }.to raise_error(ArgumentError, /expected a .*PartialDate, got String/)
    end
  end

  describe "construction" do
    it "freezes the date" do
      expect(described_class.new(year: 1972)).to be_frozen
    end

    it "accepts the structured fields the UN and Canada publish" do
      expect(described_class.new(year: 1965, month: 4, day: 29).to_s).to eq("1965-04-29")
    end

    it "carries the UN's APPROXIMATELY flag" do
      expect(described_class.new(year: 1962, approximate: true)).to be_approximate
    end

    it "builds a span from strings, hashes, or dates" do
      spans = [
        described_class.range("1971", described_class.new(year: 1973)),
        described_class.range({ year: 1971 }, { year: 1973 })
      ].map(&:to_s)

      expect(spans).to eq(["1971 to 1973", "1971 to 1973"])
    end

    # Unlike .parse, the constructor is strict: an adapter passing month 13 has
    # a mapping bug, and silently dropping the date would hide it.
    it "raises on an impossible date" do
      expect { described_class.new(year: 1972, month: 2, day: 31) }
        .to raise_error(ArgumentError, /not a real date: "1972-02-31"/)
    end

    it "raises without a year" do
      expect { described_class.new(month: 4) }.to raise_error(ArgumentError, /year is required/)
    end

    it "raises on a day with no month, which would invent a precision" do
      expect { described_class.new(year: 1972, day: 29) }.to raise_error(ArgumentError, /day given without a month/)
    end

    it "raises on a non-numeric field" do
      expect { described_class.new(year: "nineteen") }.to raise_error(ArgumentError, /year is not a number/)
    end

    it "raises on a half-specified span" do
      expect { described_class.new(from: "1971") }.to raise_error(ArgumentError, /needs both from and to/)
    end

    it "raises on a span that runs backwards" do
      expect { described_class.range("1973", "1971") }.to raise_error(ArgumentError, /range runs backwards/)
    end

    it "raises on a span endpoint that is itself a span" do
      expect { described_class.range(described_class.range("1971", "1972"), "1973") }
        .to raise_error(ArgumentError, /cannot itself be a range/)
    end

    it "raises on a span endpoint it cannot read" do
      expect { described_class.range("whenever", "1973") }.to raise_error(ArgumentError, /from is not a date/)
    end

    it "raises when a span is also given a year" do
      expect { described_class.new(year: 1972, from: "1971", to: "1973") }
        .to raise_error(ArgumentError, /carries its year in its endpoints/)
    end
  end

  describe "#to_h" do
    it "lays keys out in canonical member order" do
      expect(described_class.new(year: 1972).to_h.keys).to eq(described_class::MEMBERS)
    end

    it "emits the same keys whatever the precision, so the shape never drifts" do
      expect(described_class.range("1971", "1973").to_h.keys).to eq(described_class::MEMBERS)
    end

    it "serializes a point" do
      expect(described_class.parse("circa 1962").to_h)
        .to eq(year: 1962, month: nil, day: nil, from: nil, to: nil, approximate: true)
    end

    it "nests the endpoints of a span" do
      expect(described_class.range("1971", "1973").to_h[:from])
        .to eq(year: 1971, month: nil, day: nil, from: nil, to: nil, approximate: false)
    end
  end

  describe ".from_h" do
    ["1965-04-29", "1972-04", "circa 1962", "between 1971 and 1973", "circa 1971 to 1973"].each do |raw|
      it "round-trips #{raw.inspect}" do
        date = described_class.parse(raw)

        expect(described_class.from_h(date.to_h)).to eq(date)
      end
    end

    # Storage::FileSystem (#24) persists gzipped JSON, which loses symbol keys.
    it "round-trips a span through JSON, endpoints and all" do
      date = described_class.parse("between 1971 and 1973")

      expect(described_class.from_h(JSON.parse(JSON.generate(date.to_h)))).to eq(date)
    end

    it "rejects unknown attributes rather than dropping them" do
      expect { described_class.from_h(described_class.new(year: 1972).to_h.merge(precision: :year)) }
        .to raise_error(ArgumentError, /unknown PartialDate attribute\(s\): precision/)
    end
  end

  describe "equality" do
    it "compares by value" do
      expect(described_class.new(year: 1972)).to eq(described_class.parse("1972"))
    end

    # Same bounds, different claim: one says "1972", the other "some time
    # between the start and end of 1972".
    it "distinguishes a year from a span covering that year" do
      expect(described_class.new(year: 1972)).not_to eq(described_class.range("1972", "1972"))
    end

    it "distinguishes an approximate date from an exact one" do
      expect(described_class.parse("circa 1962")).not_to eq(described_class.parse("1962"))
    end

    it "hashes equal values alike, so dates can key a Hash or join a Set" do
      expect({ described_class.new(year: 1972) => :hit }[described_class.parse("1972")]).to eq(:hit)
    end
  end

  # Entity (#4) serializes listed_on through #to_h and rebuilds it with .from_h.
  describe "as an Entity member" do
    it "survives an Entity round-trip through JSON" do
      listed_on = described_class.parse("1971")
      entity = ActiveSanction::Entity.new(source: :un, source_ref: "1", type: :individual, listed_on: listed_on)

      expect(ActiveSanction::Entity.from_h(JSON.parse(JSON.generate(entity.to_h))).listed_on).to eq(listed_on)
    end
  end
end
