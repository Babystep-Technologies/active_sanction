# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/sources"
require "active_sanction/sources/ofac"

module ActiveSanction
  module Sources
    # OFAC's Consolidated (non-SDN) list: everything the US sanctions that is
    # not a Specially Designated National.
    #
    #   snapshot = ActiveSanction::Sources[:ofac_consolidated].new.sync
    #
    # It is small -- 481 entities against the SDN list's 19,321 -- and it is
    # screened anyway, because being on it still carries real legal weight. A
    # Chinese semiconductor firm on the CMIC list cannot be invested in; a
    # Russian bank on the SSI list can be transacted with but not lent to
    # beyond a tenor the directive sets. Neither is a blocking sanction, and
    # both are prohibitions a compliance team has to act on.
    #
    # ### One file, several lists
    #
    # OFAC ships the non-SDN lists as one set of three CSVs in the same shape
    # as the SDN files -- the reading is Ofac's, and this adapter adds no
    # parsing of its own -- but the rows in it belong to six different lists:
    #
    #   Sectoral Sanctions Identifications (SSI)   the Russia/Ukraine directives
    #   Non-SDN CMIC                               Chinese military-industrial firms
    #   Non-SDN Palestinian Legislative Council    NS-PLC
    #   Non-SDN Menu-Based Sanctions (NS-MBS)      HKAA, CAATSA, EO 14024 directives
    #   CAPTA                                      foreign financial institutions
    #   FSE                                        foreign sanctions evaders
    #
    # A hit on CMIC and a hit on NS-PLC are different findings with different
    # consequences, so which one a record is on has to survive the parse.
    # #lists answers it for any entity this adapter produced:
    #
    #   ActiveSanction::Sources::OfacConsolidated.lists(entity)   # => [:cmic]
    #   ActiveSanction::Sources::OfacConsolidated.names(entity)   # => ["Non-SDN CMIC List"]
    #
    # It is a function of `entity.programs`, which is a canonical Entity member
    # -- so it keeps working on a record that has been stored, serialized and
    # read back, with no per-source column anywhere downstream. The names are
    # also appended to `remarks` behind the `[source fields]` marker, which is
    # where a compliance report reads them from.
    #
    # ### Why the programs and not a column
    #
    # There is no list column. CONS_PRIM.CSV has the same twelve columns as
    # SDN.CSV, and the only thing in it that names a list is the program code
    # -- `CMIC-EO13959`, `NS-PLC`, `HKAA`. OFAC states the membership
    # explicitly in CONS_ADVANCED.XML, a 4.5 MB re-publication of the same 481
    # records, and downloading the list twice to read one attribute off the
    # second copy is a poor trade. So the program code is what LISTS maps.
    #
    # Checked against that XML's own attribution, the mapping is exact for 478
    # of the 481 published records. The three it is not are all the same
    # ambiguity, and SHARED is where it lives.
    class OfacConsolidated < Ofac
      extend T::Sig

      key :ofac_consolidated

      url :prim, "https://sanctionslistservice.ofac.treas.gov/api/download/CONS_PRIM.CSV"
      url :alt, "https://sanctionslistservice.ofac.treas.gov/api/download/CONS_ALT.CSV"
      url :add, "https://sanctionslistservice.ofac.treas.gov/api/download/CONS_ADD.CSV"

      # Ofac declares 0.90, calibrated on the SDN file, where RemarksParser
      # reads about 97% of the segments. This list reads at 80.3%, and it is
      # not a parse that has gone wrong: the CMIC rows publish a vocabulary the
      # SDN file has no equivalent of -- `Effective Date (CMIC)`,
      # `Listing Date (CMIC)`, `Purchase/Sales For Divestment`, `HKAA
      # Section 5`, an equity ticker -- none of which is a name, a date of
      # birth, a nationality or a document number, so none of it is anything
      # this parser has a home for.
      #
      # Inheriting the SDN's floor made every first `ActiveSanction.doctor` run
      # against a deployment with no stored snapshot warn about this list
      # forever, with no fix available to whoever read the warning. 0.75 sits
      # the same distance below what the file does as 0.90 does for the SDN,
      # and it is a floor rather than a target: it exists for the run with
      # nothing to compare against, and is not consulted once there is a
      # snapshot or a committed baseline. Found by the canary (#69) on its
      # first run against the published lists.
      floor :remarks_coverage, 0.75

      # The sub-lists, spelled the way OFAC's own `/sanctions-lists` endpoint
      # spells them -- which is what a report has to print beside a hit.
      NAMES = T.let({
        ssi: "Sectoral Sanctions Identifications List",
        cmic: "Non-SDN CMIC List",
        ns_plc: "Non-SDN Palestinian Legislative Council List",
        ns_mbs: "Non-SDN Menu-Based Sanctions List",
        capta: "CAPTA List",
        fse: "FSE List"
      }.freeze, T::Hash[Symbol, String])

      # Program code to sub-list, for every program that names exactly one.
      #
      # A program absent from here is not an error: `SDGT` appears on three
      # consolidated rows because those people are on the SDN list as well, and
      # it says nothing about which non-SDN list they are on. FSE-IR and FSE-SY
      # are carried because the FSE list is one OFAC still publishes and can
      # refill, though nothing is on it today.
      LISTS = T.let({
        "UKRAINE-EO13662" => :ssi,
        "UKRAINE-EO13685" => :ssi,
        "VENEZUELA-EO13850" => :ssi,
        "IRAN-CON-ARMS-EO" => :ssi,
        "CMIC-EO13959" => :cmic,
        "NS-PLC" => :ns_plc,
        "HKAA" => :ns_mbs,
        "CAATSA - RUSSIA" => :ns_mbs,
        "BURMA-EO14014" => :ns_mbs,
        "ILLICIT-DRUGS-EO14059" => :ns_mbs,
        "561-Related" => :capta,
        "CAPTA" => :capta,
        "FSE-IR" => :fse,
        "FSE-SY" => :fse
      }.freeze, T::Hash[String, Symbol])

      # The one program OFAC uses for two lists, and the rule that reads it.
      #
      # EO 14024 is the Russia authority behind both the SSI directives and
      # several menu-based determinations, so `RUSSIA-EO14024` alone means
      # NS-MBS -- the Central Bank of Russia, the Ministry of Finance -- while
      # `RUSSIA-EO14024` beside a program that is unambiguously SSI means the
      # entity is on SSI under both authorities. That reads 92 of the 95 rows
      # carrying it the way OFAC's own XML does.
      #
      # The three it does not are Gazprom, Transneft and Rosselkhozbank, which
      # are on SSI *and* NS-MBS and come out marked SSI only. It is the safer
      # direction of the two errors -- the record is still returned, still
      # matched, still flagged as a non-SDN sanctions hit, and the program code
      # OFAC published is on the entity verbatim for anyone who needs to look
      # closer -- but it is an error, and nothing in the CSVs distinguishes
      # those three from the 89 rows carrying the identical program pair.
      SHARED = T.let(
        { "RUSSIA-EO14024" => { with: :ssi, alone: :ns_mbs } }.freeze,
        T::Hash[String, T::Hash[Symbol, Symbol]]
      )

      # Which sub-lists a record is on, as an Array of the keys NAMES uses.
      # Takes an Entity, or the programs themselves.
      #
      #   OfacConsolidated.lists(entity)                             # => [:ssi]
      #   OfacConsolidated.lists(%w[UKRAINE-EO13662 RUSSIA-EO14024])  # => [:ssi]
      #   OfacConsolidated.lists(%w[RUSSIA-EO14024])                  # => [:ns_mbs]
      #
      # Empty for a record whose programs name no list this adapter knows,
      # which is what #parse warns about.
      sig { params(programs: T.untyped).returns(T::Array[Symbol]) }
      def self.lists(programs)
        codes = programs.respond_to?(:programs) ? programs.programs : Array(programs)
        certain = codes.filter_map { |code| LISTS[code] }.uniq
        shared = codes.filter_map { |code| SHARED[code] }
                      .map { |rule| certain.include?(rule[:with]) ? rule[:with] : rule[:alone] }
        (certain + shared).uniq
      end

      # The same answer as OFAC spells it, which is what goes in a report.
      sig { params(programs: T.untyped).returns(T::Array[String]) }
      def self.names(programs) = lists(programs).map { |list| NAMES.fetch(list) }

      private

      sig { override.returns(T.untyped) }
      def record_class = Record

      # A row whose programs name no sub-list is the signal that OFAC has
      # added an authority: the entity is still returned, with its programs
      # intact, but nothing downstream can say which list it puts it on until
      # LISTS learns the code. Every other adapter's drift shows up as a
      # parse warning, and so does this.
      sig { override.params(record: T.untyped).void }
      def note(record)
        super
        note_unattributed(record) if record.lists.empty?
      end

      sig { params(record: T.untyped).void }
      def note_unattributed(record)
        @unmapped << Parsers::Warning.new(
          line: record.row.line,
          message: "row #{record.row[:ent_num].inspect} carries no program naming a consolidated sub-list " \
                   "(#{record.programs.join(", ")}); it is on none this adapter knows"
        )
      end
    end
  end
end

require "active_sanction/sources/ofac_consolidated/record"

ActiveSanction::Sources.register(ActiveSanction::Sources::OfacConsolidated)
