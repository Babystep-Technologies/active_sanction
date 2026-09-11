# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/parsers"
require "active_sanction/sources"
require "active_sanction/sources/base"

module ActiveSanction
  module Sources
    # The UK Sanctions List: every designation made under the Sanctions and
    # Anti-Money Laundering Act 2018, published by the Foreign, Commonwealth
    # and Development Office.
    #
    #   snapshot = ActiveSanction::Sources[:uk_sanctions_list].new.sync
    #
    # ### This is not the OFSI Consolidated List, and that is deliberate
    #
    # The list this adapter was scoped against -- OFSI's Consolidated List of
    # Asset Freeze Targets, `ConList.csv` -- was retired on 28 January 2026,
    # when the UK moved every sanctions designation onto one list. Its gov.uk
    # page is marked withdrawn, and the FCDO's own transition guidance says the
    # Consolidated List "is no longer being updated".
    #
    # The blob it was served from still answers 200. That is the trap: an
    # adapter reading it would look healthy on every sync, download a real
    # file, produce real entities and screen a book of business against a list
    # that stopped moving in January. A stale list that reports itself fresh is
    # the most expensive way this library can fail, so the UK adapter reads the
    # list the UK actually publishes.
    #
    # OFSI Group IDs are not lost in the move: the FCDO carries the historic
    # one on every designation made before 28 January 2026, and this adapter
    # keeps it in `remarks` so a hit can still be reconciled against an OFSI
    # licence application or a suspected-breach report. Designations made since
    # carry a `UniqueID` and nothing else, which is why the Unique ID is what
    # `source_ref` is built from.
    #
    # ### Seven formats, and why this one
    #
    #   https://sanctionslist.fcdo.gov.uk/docs/UK-Sanctions-List.xml
    #
    #     <Designations><Designation>    6,334 records, 21.8 MB
    #
    # The FCDO publishes the same list seven ways, and two of them are
    # machine-readable at this size: the XML above and a CSV added in January
    # to match the format OFSI's readers had been built against. The CSV is
    # 49.9 MB and 58,424 rows for the same 6,334 designations, because it is a
    # full cartesian product of every repeating group -- one record in it,
    # `INU0075`, occupies 3,780 rows, being 10 names x 7 addresses x 3 phone
    # numbers x 2 websites x 9 subsidiaries. Reading it means grouping 58,424
    # rows and then de-duplicating each dimension back out of the product,
    # which is recoverable but is reconstruction rather than parsing. The XML
    # states the same structure directly, in 44% of the bytes, against a
    # published XSD, and it carries a field the CSV has no column for at all.
    #
    # ### Conditional GET works here
    #
    # Unlike the EU's endpoint, this one serves both an ETag and a
    # Last-Modified and honours both: a sync against an unchanged list answers
    # 304 and downloads nothing. Verified against the live endpoint. So the
    # usual run of this source costs one request, and the 21.8 MB is paid only
    # on the days the FCDO republishes.
    #
    # ### The two traps in this list
    #
    # **A date component the FCDO does not know is spelled out, not omitted.**
    # `dd/mm/1962` is a year-only birth date, `dd/07/1978` is a month, and
    # `00/00/1975` is one more spelling of the same thing. 824 of the 3,788
    # published birth dates -- 22% -- carry a placeholder, and every one of
    # them reads as nil through an ordinary date parser. See PublishedDate.
    #
    # **The publisher's own script labels disagree with its own strings.**
    # `NonLatinScriptType` is stated on 2,057 of the 3,856 non-Latin names and
    # agrees with the characters on 2,054 of them -- but three names labelled
    # `Cyrillic` are Latin transliterations (`OAO "STUPINSKAYA
    # METALLURGICHESKAYA KOMPANIYA"`), and 185 names filed under
    # `<NonLatinName>` contain no non-Latin character at all. So `script` is
    # left unstated on every name here, which is the same call the UN and EU
    # adapters make for the same reason: which script a string is in is a
    # question about its characters, and the normalizer is where that gets
    # answered. The FCDO's label and language are kept in `remarks`.
    #
    # ### What a clean UK result is worth
    #
    # More than an EU one. The FCDO marks its own primary name -- every one of
    # the 6,334 records carries exactly one `NameType` of `Primary Name`, six
    # carry two, and none carries none -- so this adapter never has to guess
    # which spelling is the official one, which is the judgment the EU adapter
    # is stuck making. Alias grading is published as a field rather than as
    # prose, on 2,073 names. Against that, nationality arrives as prose
    # ("Russia", "North Korea"), the way the UN publishes it, and is resolved
    # by Country at scoring time rather than here.
    #
    # ### What this adapter does not do
    #
    # It does not read `<CryptoWalletAddresses>` or
    # `<HullIdentificationNumbers>`. The XSD defines both and the FCDO populates
    # neither on any of the 6,334 records published today, and a mapping
    # written against zero records is a guess that gets discovered to be wrong
    # by a user rather than by a test. They are the first things to add when
    # either field appears.
    #
    # It does not parse `PassportAdditionalInformation`, which is a sentence
    # ("Afghanistan passport number P04581926, issued on 7 August 2024, issued
    # in Kandahar, Afghanistan (expires 7 August 2034)") carrying an issuing
    # country and two dates that Identifier has members for. Reading it is the
    # same job OFAC's RemarksParser does and wants the same treatment --
    # a measured coverage figure -- rather than a regex added here in passing.
    # The sentence is kept verbatim on the identifier's note.
    class UkSanctionsList < Base
      extend T::Sig

      key :uk_sanctions_list
      jurisdiction :uk
      authority "Foreign, Commonwealth and Development Office"
      format :xml

      # Crown copyright under the Open Government Licence v3.0, which is the
      # most permissive of the seven: reuse for any purpose, commercial
      # included, on an attribution condition.
      licence_notice "Crown copyright, reusable under the Open Government " \
                     "Licence v3.0 with attribution. Verified 2026-09-11."
      licence_url "https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/"

      # Static since January 2026, and the FCDO says so out loud: the URL for
      # each format stays the same however many times the list is refreshed.
      url :main, "https://sanctionslist.fcdo.gov.uk/docs/UK-Sanctions-List.xml"

      # @api private
      DESIGNATION = T.let("Designation", String)

      # The FCDO's own generation date, which it publishes as an element
      # sibling of the records rather than as an attribute of the document.
      # Named as a record so that the one pass over the payload reads it on the
      # way past -- it is the first child of `<Designations>` -- instead of the
      # adapter parsing 21.8 MB twice to answer which version this was.
      #
      # @api private
      GENERATED_AT = T.let("DateGenerated", String)

      # @api private
      LIST = T.let(Parsers::XmlRecords.new(records: [DESIGNATION, GENERATED_AT]), Parsers::XmlRecords)

      # Records that could not be used, and fields that could not be read.
      # Read after #parse; sync orchestration (#34) reports them.
      sig { returns(T::Array[Parsers::Warning]) }
      attr_reader :warnings

      sig { params(args: T.untyped, options: T.untyped).void }
      def initialize(*args, **options)
        super
        @warnings = T.let([], T::Array[Parsers::Warning])
        @unmapped = T.let([], T::Array[Parsers::Warning])
        @generated_at = T.let(nil, T.nilable(String))
      end

      sig { override.params(raw: T.untyped).returns(T::Array[Entity]) }
      def parse(raw)
        reader = LIST.read(raw)
        entities = build(reader)
        @warnings = reader.warnings + @unmapped
        entities
      end

      # `07/09/2026` -- the date the FCDO stamps on the document and shows on
      # its own download page, which is the string an examiner asking which
      # version a decision was made against will recognise. Falls back to
      # Last-Modified for a payload handed straight to #snapshot.
      sig { override.returns(T.nilable(String)) }
      def source_version = @generated_at || super

      private

      sig { params(reader: Parsers::XmlRecords::Reader).returns(T::Array[Entity]) }
      def build(reader)
        @unmapped = []
        @generated_at = nil
        reader.filter_map do |node|
          # `filter_map` keeps a truthy block value, so the generation date has
          # to be captured and then explicitly not returned as a record.
          if node.name == GENERATED_AT
            @generated_at ||= node.text
            next nil
          end

          record = Record.new(node)
          entity = record.entity
          entity.nil? ? note_nameless(node) : entity
        end
      end

      # A record with no name cannot be screened against and is never what the
      # FCDO meant to publish. Every one of the 6,334 published today carries a
      # name; 26 `<Name>` elements are empty of every part, which Record drops
      # on their own. The warning exists so that the day a whole designation
      # arrives nameless, it is visible rather than absent.
      sig { params(node: Parsers::XmlRecords::Record).returns(NilClass) }
      def note_nameless(node)
        @unmapped << Parsers::Warning.new(
          line: node.line,
          message: "<#{node.name}> #{node["UniqueID"].inspect} has no name and was skipped"
        )
        nil
      end
    end
  end
end

require "active_sanction/sources/uk_sanctions_list/published_date"
require "active_sanction/sources/uk_sanctions_list/record"

ActiveSanction::Sources.register(ActiveSanction::Sources::UkSanctionsList)
