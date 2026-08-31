# frozen_string_literal: true

require "active_sanction/entity"
require "active_sanction/name"
require "active_sanction/address"
require "active_sanction/identifier"
require "active_sanction/sources/remarks"

module ActiveSanction
  module Sources
    class OfacSdn < Base
      # One joined OFAC record -- a row of SDN.CSV plus the ALT and ADD rows
      # that share its `ent_num` -- turned into an Entity.
      #
      # Separate from the adapter because they are two jobs: the adapter says
      # what the list is and where it lives, and this says what OFAC's columns
      # mean. The mapping is where all the judgment sits, so it is worth being
      # able to read it on its own.
      class Record
        # OFAC's `SDN_Type` as published, and what each maps to. Blank is the
        # one that matters: 9,923 of 19,321 rows leave it empty and every one
        # of them is an organization. Defaulting blank to "unknown" would
        # mis-type the largest group in the list.
        TYPES = { "individual" => :individual, "vessel" => :vessel, "aircraft" => :aircraft }.freeze

        # ALT.CSV's `alt_type`, which OFAC publishes as exactly these three.
        ALIAS_KINDS = { "aka" => :aka, "fka" => :fka, "nka" => :nka }.freeze

        # Multiple programs arrive in one field separated by `] [`:
        # `"IRAQ2] [IRGC] [SDGT"` is three sanctions programs, not one.
        PROGRAM_SEPARATOR = /\]\s*\[/

        # Columns OFAC publishes outside its Remarks field that the canonical
        # model has no home for. Appended to remarks rather than dropped: a
        # vessel's flag and owner are real screening signal, and losing them to
        # keep a schema tidy is the wrong trade.
        COLUMNS_IN_REMARKS = {
          title: "Title", vessel_type: "Vessel type", tonnage: "Tonnage",
          gross_registered_tonnage: "GRT", vessel_flag: "Vessel flag", vessel_owner: "Vessel owner"
        }.freeze

        attr_reader :row, :aliases, :addresses

        def initialize(row:, aliases: [], addresses: [])
          @row = row
          @aliases = aliases
          @addresses = addresses
        end

        # The entity, or nil for a row with no name -- which cannot be screened
        # against and is never what OFAC meant to publish.
        def entity
          return nil if row.null?(:sdn_name)

          Entity.new(source: :ofac_sdn, source_ref: row[:ent_num], type: type,
                     names: names, addresses: places, identifiers: identifiers,
                     programs: programs, remarks: remarks)
        end

        def type
          published = row[:sdn_type]
          return :organization if published.nil?

          TYPES.fetch(published.downcase, :organization)
        end

        # True when OFAC published a type this adapter does not know. Worth
        # surfacing rather than silently absorbing: a new value here means the
        # list grew a category, and everything in it is currently being called
        # an organization.
        def unknown_type?
          published = row[:sdn_type]
          !published.nil? && !TYPES.key?(published.downcase)
        end

        # The primary name first, then every alias in the order OFAC filed it.
        # `alt_num` ordering is the closest thing these aliases have to a
        # priority, so it is preserved rather than sorted away.
        def names
          [Name.new(value: row[:sdn_name], kind: :primary)] + alias_names
        end

        def places
          addresses.filter_map { |address| place(address) }
        end

        # A vessel's call sign is a registered, near-unique string, which makes
        # it far more like a document number than like a name -- and an
        # Identifier is matchable where a line of remarks is not. Filed as
        # :other because it is not any of the document kinds the model names.
        def identifiers
          return [] if row.null?(:call_sign)

          [Identifier.new(kind: :other, value: row[:call_sign], note: "call sign")]
        rescue ArgumentError
          []
        end

        def programs
          return [] if row.null?(:program)

          row[:program].split(PROGRAM_SEPARATOR).map { |program| program.strip.delete("[]") }.reject(&:empty?)
        end

        # OFAC's remark verbatim, then the columns that have nowhere else to
        # go, behind the marker that makes them trivial to strip again.
        def remarks
          Remarks.build(row[:remarks], COLUMNS_IN_REMARKS.map { |column, label| [label, row[column]] })
        end

        private

        def alias_names
          aliases.filter_map do |alt|
            next nil if alt.null?(:alt_name)

            Name.new(value: alt[:alt_name], kind: ALIAS_KINDS.fetch(alt.fetch(:alt_type).to_s.downcase, :aka))
          end
        end

        # ADD.CSV combines city, state, province and postal code into one
        # column, so "London EC3N 1DY" arrives undivided. It is filed under
        # `city` whole rather than split on a guess: a rule that turns
        # "London EC3N 1DY" into a city and a postcode also turns "Dubai" into
        # a city and turns half of Latin America into nonsense.
        # 3,211 of ADD.CSV's 25,078 rows carry an `ent_num` and an `add_num`
        # and then nothing at all -- no street, no city, no country, no
        # remark. They are dropped rather than kept as empty addresses, which
        # is why a full sync yields ~21.9k addresses from ~25.1k rows. An
        # Address that locates nothing cannot be screened on and would only
        # inflate the count.
        def place(address)
          Address.new(street: address[:address], city: address[:city_state_province_postal_code],
                      country: address[:country], note: address[:add_remarks])
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
