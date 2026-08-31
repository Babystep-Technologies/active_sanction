# frozen_string_literal: true

# A whole source adapter -- five declarations, a #parse, and a fixture of three
# records under spec/fixtures/contract_example -- written so that the adapter
# conformance contract can itself be tested.
#
# It has to be a fake list. A real adapter cannot be made to break the contract
# without editing the adapter, and a spec that edits the thing it is measuring
# measures nothing; the deliberately broken sources in
# spec/active_sanction/sources/conformance_spec.rb are this class with one rule
# taken out apiece.
#
# It is deliberately not registered here. The registry is global and lives for
# the whole process, so the examples that need this source in it register it
# and hand the key back when they are done.
class ContractExampleSource < ActiveSanction::Sources::Base
  key :contract_example
  jurisdiction :xx
  authority "Contract Example Authority"
  format :csv
  url :main, "https://example.test/contract.csv"

  TABLE = ActiveSanction::Parsers::DelimitedTable.new(columns: %i[ref name type listed_on remarks])

  def parse(raw) = TABLE.read(raw).map { |row| entity(row) }

  def entity(row)
    ActiveSanction::Entity.new(
      source: key, source_ref: row[:ref], type: row[:type],
      names: [ActiveSanction::Name.new(value: row[:name])],
      listed_on: ActiveSanction::PartialDate.parse(row[:listed_on]), remarks: row[:remarks]
    )
  end

  # One field of a built entity replaced and everything else left alone, so
  # that a broken subclass breaks exactly the rule it is named for. A source
  # failing three examples would prove nothing about which of them was watching.
  def rebuild(entity, **changes) = ActiveSanction::Entity.from_h(entity.to_h.merge(changes))
end
