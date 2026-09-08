# frozen_string_literal: true

# A source adapter with the network taken out, for the decisions the doctor
# makes above the fetch. It answers #retrieve and #snapshot with whatever it
# was built with, so one example can put a list into a state -- every record
# suddenly missing its identifiers, a warning class that was not there last
# week -- that no real adapter can be talked into on demand.
#
# It exposes the diagnostic readers a real adapter exposes, and only the ones
# it was asked for: Profile decides what it can measure by asking the adapter
# what it responds to, so a fake that always answered #remarks_coverage would
# make it impossible to test a source that reads no free text.
#
# The real fetch-parse path is covered against WebMock and the committed OFAC
# fixtures in the "over the real fetch path" section of the doctor spec.
class FakeDoctorSource
  attr_reader :key, :urls, :floors
  attr_accessor :entities, :error

  # `payload:` is what #retrieve hands back; nothing here reads it, but the
  # doctor passes it on to #column_tallies, so it is worth being real.
  def initialize(key, entities: [], error: nil, warnings: nil, orphans: nil, coverage: nil,
                 columns: [], floors: {}, payload: "bytes")
    @key = key
    @entities = entities
    @error = error
    @columns = columns
    @floors = floors
    @payload = payload
    @urls = { main: "https://#{key}.test/list.csv" }
    expose(warnings, orphans, coverage)
  end

  def retrieve(force: false)
    @forced = force
    raise error if error

    { main: @payload }
  end

  # Whether the doctor asked for the bytes unconditionally, which it must:
  # a diagnosis of a list the publisher answered 304 for is a diagnosis of a
  # parse that did not happen.
  def forced? = @forced

  def snapshot(_payloads = nil) = ActiveSanction::Snapshot.new(source: key, entities: entities)

  def column_tallies(_payloads) = @columns

  # A listed person carrying every field a fill rate is measured over, so that
  # an example can take one away and watch the doctor notice.
  def self.entity(source, id = 1, **without)
    fields = {
      names: [ActiveSanction::Name.new(value: "PUTIN, Vladimir Vladimirovich"),
              ActiveSanction::Name.new(value: "PUTIN, Vladimir", kind: :aka)],
      addresses: [ActiveSanction::Address.new(country: "RU")],
      identifiers: [ActiveSanction::Identifier.new(kind: :passport, value: "51NO#{id}")],
      dates_of_birth: [ActiveSanction::PartialDate.new(year: 1952, month: 10, day: 7)],
      nationalities: ["RU"], programs: ["UKRAINE-EO14024"], remarks: "Born in Leningrad"
    }
    ActiveSanction::Entity.new(id: "#{source}:#{id}", source: source, source_ref: id.to_s,
                               type: :individual, **fields.merge(without))
  end

  private

  # Only the readers this source was asked for -- see the class comment.
  def expose(warnings, orphans, coverage)
    define_singleton_method(:warnings) { warnings } unless warnings.nil?
    define_singleton_method(:orphans) { orphans } unless orphans.nil?
    return if coverage.nil?

    define_singleton_method(:remarks_coverage) { coverage }
  end
end

# What a RemarksParser::Coverage looks like to Profile, without a parse behind
# it: a ratio and the shapes that cost it.
class FakeCoverage
  attr_reader :segments, :ratio

  def initialize(ratio, unrecognized: {}, segments: 100)
    @ratio = ratio
    @segments = segments
    @unrecognized = unrecognized
  end

  def top(count = 10) = @unrecognized.sort_by { |shape, tally| [-tally, shape] }.first(count)
end
