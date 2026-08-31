# frozen_string_literal: true

require "active_sanction/entity"
require "active_sanction/name"
require "active_sanction/address"
require "active_sanction/identifier"
require "active_sanction/sources/remarks"
require "active_sanction/sources/ofac/remarks_parser"

module ActiveSanction
  module Sources
    class Ofac < Base
      # One joined OFAC record -- a row of the primary file plus the ALT and
      # ADD rows that share its `ent_num` -- turned into an Entity.
      #
      # Separate from the adapter because they are two jobs: the adapter says
      # what the list is and where it lives, and this says what OFAC's columns
      # mean. The mapping is where all the judgment sits, so it is worth being
      # able to read it on its own.
      #
      # Shared by both OFAC adapters, because SDN.CSV and CONS_PRIM.CSV are
      # the same twelve columns with the same conventions -- the same is true
      # of ALT and ADD -- and the only thing that differs between them is
      # which list a row is on. `source` is passed in rather than hard-coded
      # for that reason, and #remark_fields is the hook a subclass overrides
      # to record anything its own list publishes on top.
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

        # A name matches one already on the record when the letters and digits
        # agree; OFAC's own punctuation does not have to. 24 of the 4,349
        # inline aliases repeat an ALT.CSV row, and the rest are names the list
        # publishes nowhere else.
        INSIGNIFICANT = /[^[:alnum:]]+/

        attr_reader :row, :source, :aliases, :addresses

        def initialize(row:, source:, aliases: [], addresses: [])
          @row = row
          @source = source
          @aliases = aliases
          @addresses = addresses
        end

        # The entity, or nil for a row with no name -- which cannot be screened
        # against and is never what OFAC meant to publish.
        def entity
          return nil if row.null?(:sdn_name)

          Entity.new(source: source, source_ref: row[:ent_num], type: type,
                     names: names, addresses: places, identifiers: identifiers,
                     programs: programs, remarks: remarks, **from_remarks)
        end

        # The members no OFAC column feeds. De-duplicated because one entity's
        # remark can report the same nationality twice -- "nationality Iran;
        # alt. nationality Iran" -- and a record that claims one thing twice
        # is not a record that claims it more strongly.
        def from_remarks
          { dates_of_birth: parsed_remarks.dates_of_birth.uniq,
            nationalities: parsed_remarks.nationalities.uniq }
        end

        # OFAC's free text, read for the fields it has no columns for. Exposed
        # rather than kept private because the adapter folds every record's
        # into one coverage figure, which is how drift in a heuristic parser
        # gets noticed at all.
        def parsed_remarks
          @parsed_remarks ||= RemarksParser.new(row[:remarks])
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
        # priority, so it is preserved rather than sorted away. Last come the
        # aliases that appear only inside the remark -- 4,325 names that are in
        # no other column of any of the three files.
        def names
          published = [Name.new(value: row[:sdn_name], kind: :primary)] + alias_names
          published + new_names(published, parsed_remarks.aliases)
        end

        def places
          addresses.filter_map { |address| place(address) }
        end

        # The call sign, then every document number the remark named. Compared
        # through Identifier's own equality, which already treats `AB-123 456`
        # and `ab123456` as one document, so a number OFAC wrote twice does not
        # become two.
        def identifiers
          (call_sign + parsed_remarks.identifiers).uniq
        end

        # A vessel's call sign is a registered, near-unique string, which makes
        # it far more like a document number than like a name -- and an
        # Identifier is matchable where a line of remarks is not. Filed as
        # :other because it is not any of the document kinds the model names.
        def call_sign
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
          Remarks.build(row[:remarks], remark_fields)
        end

        # The label/value pairs appended behind the marker. A subclass reading
        # a list that publishes something more -- which sub-list of the
        # consolidated file a row is on -- prepends to this rather than
        # rewriting #remarks.
        def remark_fields
          COLUMNS_IN_REMARKS.map { |column, label| [label, row[column]] }
        end

        private

        def new_names(published, candidates)
          seen = published.map { |name| key(name) }
          candidates.reject { |name| seen.include?(key(name)) }
        end

        def key(name) = name.value.upcase.gsub(INSIGNIFICANT, "")

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
