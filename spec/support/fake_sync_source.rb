# frozen_string_literal: true

# A source adapter with the network taken out. It answers #sync with whatever
# it was built with -- entities, nil for "the publisher says nothing has
# changed", or an exception to raise -- so that one example can put four
# sources into four different states at once, which is the whole subject of
# sync orchestration and is not something four real adapters can be made to do.
#
# The real fetch-parse-store path is covered against WebMock and a committed
# fixture in the "over the real fetch path" section of the sync spec; this is
# for the decisions the orchestrator makes above it.
class FakeSyncSource
  # Every `force:` this source was synced with, in order: the first element of
  # `[true, false]` is a run that had nothing stored and so asked in full, and
  # the second is the conditional request that followed it.
  attr_reader :calls

  attr_reader :key, :urls
  attr_accessor :entities, :error

  # `host:` is what the politeness grouping reads, so two sources given the
  # same one stand for two lists from one government file server.
  def initialize(key, entities: nil, error: nil, host: "example.test", &before_sync)
    @key = key
    @entities = entities
    @error = error
    @urls = { main: "https://#{host}/#{key}.csv" }
    @before_sync = before_sync
    @calls = []
  end

  def sync(force: false)
    @calls << force
    @before_sync&.call(self)
    raise error if error
    return nil if entities.nil?

    ActiveSanction::Snapshot.new(source: key, entities: entities)
  end

  # One listed person, named after the source so that a spec can tell which
  # list a stored snapshot came from.
  def self.entity(source, id = 1, name: "NTAGANDA, Bosco")
    ActiveSanction::Entity.new(
      id: "#{source}:#{id}", source: source, type: :individual,
      names: [ActiveSanction::Name.new(value: name)]
    )
  end
end
