# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/parsers"
require "active_sanction/sources"
require "active_sanction/sources/base"

module ActiveSanction
  module Sources
    # The EU Consolidated Financial Sanctions List: every person and entity
    # subject to an EU financial sanction, in one document, as the Financial
    # Sanctions Files (FSF) export.
    #
    #   snapshot = ActiveSanction::Sources[:eu_fsf].new.sync
    #
    # ### One file, one record shape, ten times the size
    #
    #   https://webgate.ec.europa.eu/fsd/fsf/public/files/xmlFullSanctionsList_1_1/content
    #
    #     <export><sanctionEntity>   6,234 records, 25.7 MB
    #
    # An order of magnitude larger than the UN's 2.2 MB or Canada's 2.9 MB, and
    # the first list to actually exercise the streaming interface the XML
    # toolkit was built around. It reads in one pass at roughly 90 MB of
    # resident memory, most of which is the payload itself; nothing here ever
    # holds two records at once.
    #
    # ### The token in the URL
    #
    # The public endpoint takes a `token` query parameter. Omitting it answers
    # 403 and a wrong one answers 500, so it is not optional -- but it is also
    # not a credential: `dG9rZW4tMjAxNw` is base64 for `token-2017`, it is the
    # value the Commission's own public download page has carried since that
    # year, and it is the same string for every caller. It is declared inline
    # rather than configured, the way any other part of a published URL is.
    #
    # If the Commission ever rotates it, no release of this gem is needed:
    #
    #   ActiveSanction::Sources::EuFsf.token = "..."           # or
    #   ActiveSanction::Sources::EuFsf.url :main, "https://..."
    #
    # ### Conditional GET does not work here, and that is the publisher's doing
    #
    # The endpoint serves `Last-Modified` but answers `If-Modified-Since` with
    # 200 and the whole file, and sends no `ETag` and `Cache-Control:
    # no-store`. So every sync of this list downloads 25.7 MB where the other
    # four usually download nothing. The conditional request is still sent --
    # it costs nothing and the day the Commission honours it, it works -- and
    # the snapshot checksum is unchanged when the content is, so a re-download
    # of identical bytes still diffs (#35) to nothing.
    #
    # ### The two traps in this list
    #
    # **No name is the name.** The EU marks no `<nameAlias>` as the official
    # one: all 31,053 carry `strong="true"`, and every other candidate signal
    # is wrong somewhere in the file. Document order files Qusay Hussein's
    # French transliteration ahead of his English name; `nameLanguage` files a
    # Cyrillic spelling of Anatoliy Sidorov's name under `EN`; ordering by
    # `logicalId` picks a non-Latin name for 3,203 of the 5,502 multi-name
    # records. So Record picks one by a stated rule -- see #primary_name -- and
    # what "primary" means for this source is *the first name the EU published
    # that the EU did not itself annotate as an alias*, which is weaker than
    # what it means for OFAC. It costs nothing in score: the scorer takes the
    # best of an entity's names and the kind only reaches the reason line.
    #
    # **Four birth dates are not in the Gregorian calendar.** `calendarType`
    # is `ISLAMIC` on four records, where `year`, `monthOfYear` and
    # `dayOfMonth` hold a Hijri date -- `year="1343"` for a man born in 1964.
    # Read as published those become dates in the fourteenth century, and a
    # fourteenth-century date does not merely fail to match a real one, it
    # *conflicts* with it, and the scorer penalizes the record. Three of the
    # four carry no Gregorian equivalent at all, so they produce no date of
    # birth and the published Hijri date goes to remarks instead.
    #
    # ### What a clean EU result is worth
    #
    # More than a Canadian one and less than an OFAC one. 3,013 identification
    # documents across 6,234 records is real corroborating signal, and 2,764
    # citizenships arrive as ISO codes rather than as prose. What is thin is
    # the alias grading: the EU publishes no quality column, and the 499
    # gradings this adapter does read are prose the Commission happened to put
    # in a `<remark>` -- so most EU aliases arrive ungraded, which the scorer
    # correctly treats as unstated rather than as good.
    #
    # ### What this adapter does not do
    #
    # It does not infer a vessel. `subjectType` publishes only `person` and
    # `enterprise`, and the 41 records carrying an `imo` document are shipping
    # *companies* holding IMO company numbers -- Chongchongang Shipping, Korea
    # Ansan Shipping -- not the ships themselves. Typing those as :vessel on
    # the strength of the document kind would be a guess that hides them from
    # every organization search.
    class EuFsf < Base
      extend T::Sig

      key :eu_fsf
      jurisdiction :eu
      authority "European Commission"
      format :xml

      # Commission Decision 2011/833/EU, which permits reuse of Commission
      # documents provided the source is acknowledged and the reuse does not
      # suggest the Commission endorses it.
      licence_notice "Reusable under Commission Decision 2011/833/EU " \
                     "provided the source is acknowledged and no Commission " \
                     "endorsement is implied. Verified 2026-09-11."
      licence_url "https://eur-lex.europa.eu/eli/dec/2011/833/oj/eng"

      # Split out so #token= can rebuild the URL around a rotated value. See
      # the class comment for why the token is not a credential.
      #
      # @api private
      ENDPOINT = T.let(
        "https://webgate.ec.europa.eu/fsd/fsf/public/files/xmlFullSanctionsList_1_1/content", String
      )

      # @api private
      PUBLIC_TOKEN = T.let("dG9rZW4tMjAxNw", String)

      url :main, "#{ENDPOINT}?token=#{PUBLIC_TOKEN}"

      # @api private
      SANCTION_ENTITY = T.let("sanctionEntity", String)

      # @api private
      LIST = T.let(Parsers::XmlRecords.new(records: SANCTION_ENTITY), Parsers::XmlRecords)

      # The generation timestamp the Commission stamps on the document element,
      # to the millisecond. More precise than the Last-Modified header Base
      # falls back to, and the string the FSF download page itself shows, so it
      # is the one an examiner asking "which version was this screened
      # against" will recognise.
      #
      # @api private
      GENERATED_AT = T.let("generationDate", String)

      # Re-points the list at the same endpoint with a different token, for the
      # day the Commission rotates the one baked in above.
      #
      #   ActiveSanction::Sources::EuFsf.token = "..."
      sig { params(value: T.untyped).returns(String) }
      def self.token=(value)
        url :main, "#{ENDPOINT}?token=#{value}"
      end

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
        @generated_at = reader.root[GENERATED_AT]
        @warnings = reader.warnings + @unmapped
        entities
      end

      sig { override.returns(T.nilable(String)) }
      def source_version = @generated_at || super

      private

      sig { params(reader: Parsers::XmlRecords::Reader).returns(T::Array[Entity]) }
      def build(reader)
        @unmapped = []
        reader.filter_map do |node|
          record = Record.new(node)
          entity = record.entity
          entity.nil? ? note_nameless(node) : entity
        end
      end

      # A record with no name cannot be screened against and is never what the
      # Commission meant to publish. Every one of the 6,234 published today
      # carries at least one `<nameAlias>`; the warning exists so that the day
      # one does not, it is visible rather than absent.
      sig { params(node: Parsers::XmlRecords::Record).returns(NilClass) }
      def note_nameless(node)
        @unmapped << Parsers::Warning.new(
          line: node.line,
          message: "<#{node.name}> #{node["@euReferenceNumber"].inspect} has no name and was skipped"
        )
        nil
      end
    end
  end
end

require "active_sanction/sources/eu_fsf/record"

ActiveSanction::Sources.register(ActiveSanction::Sources::EuFsf)
