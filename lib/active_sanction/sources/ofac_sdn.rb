# frozen_string_literal: true

require "active_sanction/sources"
require "active_sanction/sources/ofac"

module ActiveSanction
  module Sources
    # The US Specially Designated Nationals list: the largest and most
    # frequently screened sanctions list there is, and the one whose format
    # dictates most of what the parsing toolkits have to handle.
    #
    #   snapshot = ActiveSanction::Sources[:ofac_sdn].new.sync
    #
    # ### Three files, one list
    #
    # OFAC publishes the SDN list as three headerless CSVs joined on `ent_num`:
    #
    #   SDN.CSV   19,321 rows   primary names, type, programs, remarks
    #   ALT.CSV   20,147 rows   aliases -- more of them than there are entities
    #   ADD.CSV   25,078 rows   addresses
    #
    # Each is fetched and cached independently by Base, because they change
    # independently; the join happens in Ofac#parse, which the consolidated
    # list uses too -- the two files are the same twelve columns and are read
    # by the same code.
    #
    # What is left here is the declaration: which list this is, and where its
    # three files live. Everything else, including the free-text remarks
    # parsing that gives the list its secondary identifiers, is in Ofac.
    class OfacSdn < Ofac
      key :ofac_sdn

      url :sdn, "https://sanctionslistservice.ofac.treas.gov/api/download/SDN.CSV"
      url :alt, "https://sanctionslistservice.ofac.treas.gov/api/download/ALT.CSV"
      url :add, "https://sanctionslistservice.ofac.treas.gov/api/download/ADD.CSV"
    end
  end
end

ActiveSanction::Sources.register(ActiveSanction::Sources::OfacSdn)
