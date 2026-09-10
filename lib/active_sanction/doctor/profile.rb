# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"
require "active_sanction/entity"

module ActiveSanction
  class Doctor
    # What one parse of one list measured, in numbers small enough to keep.
    #
    #   profile = Doctor::Profile.measure(snapshot, adapter: source)
    #
    #   profile.record_count          # => 19015
    #   profile.cohorts[:individual]  # => 11704
    #   profile.fill[:identifiers]    # => 0.341
    #   profile.remarks_coverage      # => 0.973
    #   profile.warnings              # => { "unknown SDN_Type \"syndicate\"" => 41 }
    #
    # This is the thing a diagnosis compares. A snapshot is tens of megabytes
    # and a profile of it is a few hundred bytes, so a host that wants to watch
    # a fill rate over ninety days keeps ninety of these and no lists at all.
    #
    # ### Fill rates are the check that catches a clean parse of a changed file
    #
    # Record counts do not move when a publisher renames an element. Fill rates
    # do: 19,321 entities carrying zero passports looks exactly like 19,321
    # carrying 23,429 if the only thing anyone counts is records, and the first
    # one screens a passport number against nothing. Measuring the share of
    # records that carry each field is what turns that from invisible into a
    # number that halved.
    #
    # ### Each field is measured over the records that could have one
    #
    # A date of birth is measured over individuals, because an organization
    # never has one and including them would make the rate a function of how
    # many companies a designation round happened to name. Everything else is
    # measured over every record: an address, an identifier or a program is
    # something any kind of listed party can carry, and a list where the
    # organizations lost their registration numbers is the same failure as one
    # where the people lost their passports.
    #
    # ### Half of a profile survives a stored snapshot, and half does not
    #
    # Everything derived from the entities -- counts, fill rates -- can be
    # recomputed from a snapshot that was stored months ago, which is what
    # makes the last sync usable as a baseline for free. Everything that falls
    # out of the parse itself -- warnings, orphaned child rows, how much of
    # OFAC's free text was understood, the column tallies -- exists only while
    # the parse is running and is nil in a profile rebuilt from storage. A
    # caller that wants those compared too keeps the profile: see
    # Doctor#baseline.
    #
    # Instances are frozen on construction and compare by value.
    class Profile
      extend T::Sig

      # Which records each field's fill rate is measured over. `:all` is every
      # record in the list; a type name is that type alone. See the class
      # comment.
      #
      # @api private
      FIELDS = T.let({
        names: :all,
        aliases: :all,
        addresses: :all,
        identifiers: :all,
        programs: :all,
        remarks: :all,
        dates_of_birth: :individual,
        nationalities: :individual
      }.freeze, T::Hash[Symbol, Symbol])

      # How a field's fill rate reads in a sentence: "individuals with a date
      # of birth 12% (was 61%)".
      #
      # @api private
      COHORT_NAMES = T.let({ all: "records", individual: "individuals", organization: "organizations",
                             vessel: "vessels", aircraft: "aircraft" }.freeze, T::Hash[Symbol, String])

      # The longest a shaped warning is kept at. A malformed row is frequently
      # malformed because it is enormous, and the complaint about it carries a
      # snippet.
      #
      # @api private
      SHAPE_LENGTH = T.let(100, Integer)

      # Unrecognized free-text shapes kept per profile. Enough to name what
      # changed; not a histogram of a whole file.
      #
      # @api private
      TOP_UNRECOGNIZED = T.let(5, Integer)

      # @api private
      MEMBERS = T.let(%i[
        source record_count checksum cohorts fill warnings orphans remarks_coverage
        unrecognized columns
      ].freeze, T::Array[Symbol])

      sig { returns(Symbol) }
      attr_reader :source

      sig { returns(Integer) }
      attr_reader :record_count

      # The checksum of the snapshot this was measured over, so a stored
      # profile can say which list version it describes.
      sig { returns(T.nilable(String)) }
      attr_reader :checksum

      # How many records of each type, plus `:all`.
      sig { returns(T::Hash[Symbol, Integer]) }
      attr_reader :cohorts

      # Field name to the share of its cohort carrying at least one, 0.0 to 1.0.
      sig { returns(T::Hash[Symbol, Float]) }
      attr_reader :fill

      # Shaped parser warning to how many rows carried it. nil in a profile
      # rebuilt from a stored snapshot -- see the class comment.
      sig { returns(T.nilable(T::Hash[String, Integer])) }
      attr_reader :warnings

      # Child rows that matched no entity, by file. A nonzero count means the
      # publisher's files were downloaded at different moments, or that the key
      # they join on has moved.
      sig { returns(T.nilable(T::Hash[Symbol, Integer])) }
      attr_reader :orphans

      # The share of the publisher's free text the adapter understood, for a
      # source that reads any. nil for one that does not, and for a profile
      # rebuilt from storage.
      sig { returns(T.nilable(Float)) }
      attr_reader :remarks_coverage

      # The free-text shapes the parser did not recognize, to how many segments
      # each cost -- what turns a coverage drop into the label that caused it.
      sig { returns(T.nilable(T::Hash[String, Integer])) }
      attr_reader :unrecognized

      # Positional column assertions, as Parsers::ColumnShape::Tally#to_h wrote
      # them. Empty for a source whose file names its own columns.
      sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
      attr_reader :columns

      # Measures a parsed snapshot, and everything the adapter that parsed it
      # is willing to say about the parse. `adapter` is optional: without one
      # this is the entity-derived half, which is exactly what a stored
      # snapshot can supply.
      sig { params(snapshot: T.untyped, adapter: T.untyped, columns: T.untyped).returns(T.attached_class) }
      def self.measure(snapshot, adapter: nil, columns: nil)
        entities = snapshot.entities
        new(source: snapshot.source, record_count: snapshot.record_count, checksum: snapshot.checksum,
            cohorts: count_cohorts(entities), fill: measure_fill(entities),
            warnings: shape_warnings(adapter), orphans: count_orphans(adapter),
            remarks_coverage: coverage_of(adapter), unrecognized: unrecognized_of(adapter),
            columns: (columns || []).map(&:to_h))
      end

      sig { params(hash: T.untyped).returns(T.attached_class) }
      def self.from_h(hash)
        attributes = hash.to_h.transform_keys(&:to_sym)
        unknown = attributes.keys - MEMBERS
        raise InvalidArgument, "unknown Doctor::Profile attribute(s): #{unknown.join(", ")}" if unknown.any?

        T.unsafe(self).new(**attributes)
      end

      # How many records of each type there are, and how many there are.
      sig { params(entities: T::Array[T.untyped]).returns(T::Hash[Symbol, Integer]) }
      def self.count_cohorts(entities)
        counts = Entity::TYPES.to_h { |type| [type, 0] }
        entities.each { |entity| counts[entity.type] = counts.fetch(entity.type, 0) + 1 }
        counts.merge(all: entities.size)
      end
      private_class_method :count_cohorts

      # One pass over the list, tallying every field against the cohort it is
      # measured over. Fields whose cohort is empty are left out rather than
      # recorded as zero -- a list with no individuals on it has no date of
      # birth rate, and calling that 0% would report a regression the first
      # time one was listed.
      sig { params(entities: T::Array[T.untyped]).returns(T::Hash[Symbol, Float]) }
      def self.measure_fill(entities)
        filled = T.let(Hash.new(0), T::Hash[Symbol, Integer])
        sizes = T.let(Hash.new(0), T::Hash[Symbol, Integer])
        entities.each { |entity| tally_fields(entity, filled, sizes) }
        sizes.reject { |_field, size| size.zero? }
             .to_h { |field, size| [field, filled.fetch(field, 0).fdiv(size).round(4).to_f] }
      end
      private_class_method :measure_fill

      sig do
        params(entity: T.untyped, filled: T::Hash[Symbol, Integer], sizes: T::Hash[Symbol, Integer]).void
      end
      def self.tally_fields(entity, filled, sizes)
        FIELDS.each do |field, cohort|
          next unless cohort == :all || entity.type == cohort

          sizes[field] = sizes.fetch(field, 0) + 1
          filled[field] = filled.fetch(field, 0) + 1 if present?(entity, field)
        end
      end
      private_class_method :tally_fields

      # Whether one record carries the field at all. `aliases` is the names
      # beyond the primary one, which is its own signal: a list that stopped
      # publishing alternate spellings still has a name on every record and is
      # far harder to match against.
      sig { params(entity: T.untyped, field: Symbol).returns(T::Boolean) }
      def self.present?(entity, field)
        case field
        when :aliases then entity.names.any? { |name| !name.primary? }
        when :remarks then !entity.remarks.nil? && !entity.remarks.empty?
        else entity.public_send(field).any?
        end
      end
      private_class_method :present?

      sig { params(adapter: T.untyped).returns(T.nilable(T::Hash[String, Integer])) }
      def self.shape_warnings(adapter)
        return nil unless adapter.respond_to?(:warnings)

        adapter.warnings.each_with_object(T.let(Hash.new(0), T::Hash[String, Integer])) do |warning, shapes|
          key = shape(warning.respond_to?(:message) ? warning.message : warning.to_s)
          shapes[key] = shapes.fetch(key, 0) + 1
        end
      end
      private_class_method :shape_warnings

      sig { params(adapter: T.untyped).returns(T.nilable(T::Hash[Symbol, Integer])) }
      def self.count_orphans(adapter)
        return nil unless adapter.respond_to?(:orphans)

        # An adapter reports orphans as the rows themselves; a count is
        # accepted too, and `rows.size` cannot be asked of an Integer -- it
        # answers with how many bytes wide it is.
        adapter.orphans.to_h { |file, rows| [file.to_sym, rows.is_a?(Integer) ? rows : rows.to_a.size] }
      end
      private_class_method :count_orphans

      sig { params(adapter: T.untyped).returns(T.nilable(Float)) }
      def self.coverage_of(adapter)
        return nil unless adapter.respond_to?(:remarks_coverage)

        coverage = adapter.remarks_coverage
        coverage.segments.zero? ? nil : coverage.ratio.round(4)
      end
      private_class_method :coverage_of

      sig { params(adapter: T.untyped).returns(T.nilable(T::Hash[String, Integer])) }
      def self.unrecognized_of(adapter)
        return nil unless adapter.respond_to?(:remarks_coverage)

        adapter.remarks_coverage.top(TOP_UNRECOGNIZED).to_h
      end
      private_class_method :unrecognized_of

      # A warning's class, rather than the warning: the message with its digits
      # masked, so "row 4711 has no SDN_Name" and "row 4712 has no SDN_Name"
      # are one complaint counted twice rather than two complaints.
      #
      # Masking rather than truncating, because what distinguishes one class
      # of warning from another on these lists is usually the value the
      # publisher put in a field -- `unknown SDN_Type "syndicate"` is a
      # different thing to notice from `unknown SDN_Type "trust"` -- while what
      # makes two warnings the same complaint is that only their row numbers
      # and identifiers differ.
      sig { params(message: String).returns(String) }
      def self.shape(message)
        masked = message.gsub(/\d/, "#").gsub(/\s+/, " ").strip
        -(masked.length > SHAPE_LENGTH ? "#{masked[0, SHAPE_LENGTH]}..." : masked)
      end

      sig do
        params(source: T.untyped, record_count: T.untyped, checksum: T.untyped, cohorts: T.untyped,
               fill: T.untyped, warnings: T.untyped, orphans: T.untyped, remarks_coverage: T.untyped,
               unrecognized: T.untyped, columns: T.untyped).void
      end
      def initialize(source:, record_count:, checksum: nil, cohorts: {}, fill: {}, warnings: nil,
                     orphans: nil, remarks_coverage: nil, unrecognized: nil, columns: [])
        @source = T.let(symbol!(:source, source), Symbol)
        @record_count = T.let(Integer(record_count), Integer)
        @checksum = T.let(string_or_nil(checksum), T.nilable(String))
        @cohorts = T.let(counts!(cohorts), T::Hash[Symbol, Integer])
        @fill = T.let(ratios!(fill), T::Hash[Symbol, Float])
        @warnings = T.let(warnings.nil? ? nil : tally!(warnings), T.nilable(T::Hash[String, Integer]))
        @orphans = T.let(orphans.nil? ? nil : counts!(orphans), T.nilable(T::Hash[Symbol, Integer]))
        @remarks_coverage = T.let(remarks_coverage.nil? ? nil : Float(remarks_coverage), T.nilable(Float))
        @unrecognized = T.let(unrecognized.nil? ? nil : tally!(unrecognized), T.nilable(T::Hash[String, Integer]))
        @columns = T.let(columns!(columns), T::Array[T::Hash[Symbol, T.untyped]])
        freeze
      end

      # How many records the field's rate was measured over, for a message that
      # says "12% of 11,704 individuals" rather than "12%".
      sig { params(field: Symbol).returns(Integer) }
      def cohort_size(field) = cohorts.fetch(FIELDS.fetch(field, :all), 0)

      # What to call the records a field was measured over: "individuals",
      # "records".
      sig { params(field: Symbol).returns(String) }
      def cohort_name(field)
        cohort = FIELDS.fetch(field, :all)
        COHORT_NAMES.fetch(cohort, cohort.to_s)
      end

      # Warning classes this parse produced, most rows first.
      sig { params(count: Integer).returns(T::Array[T.untyped]) }
      def top_warnings(count = 5)
        (warnings || {}).sort_by { |shape, rows| [-rows, shape] }.first(count)
      end

      # The unrecognized free-text shape that cost the most, as `[shape, count]`
      # -- what a coverage finding names as the likely cause.
      sig { returns(T.nilable(T::Array[T.untyped])) }
      def worst_unrecognized
        (unrecognized || {}).max_by { |shape, count| [count, shape] }
      end

      sig { returns(Integer) }
      def warning_count = (warnings || {}).values.sum

      sig { returns(Integer) }
      def orphan_count = (orphans || {}).values.sum

      sig { returns(T::Boolean) }
      def empty? = record_count.zero?

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h
        { source: source, record_count: record_count, checksum: checksum, cohorts: cohorts, fill: fill,
          warnings: warnings, orphans: orphans, remarks_coverage: remarks_coverage,
          unrecognized: unrecognized, columns: columns }
      end

      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.instance_of?(self.class)

        to_h == other.to_h
      end
      alias eql? ==

      sig { returns(Integer) }
      def hash = [self.class, to_h].hash

      sig { returns(String) }
      def inspect = "#<#{self.class} #{source} #{record_count} records #{fill.size} fill rate(s)>"

      private

      sig { params(member: Symbol, value: T.untyped).returns(Symbol) }
      def symbol!(member, value)
        raise InvalidArgument, "#{member} is required" if value.nil? || value.to_s.empty?

        value.to_sym
      end

      sig { params(value: T.untyped).returns(T.nilable(String)) }
      def string_or_nil(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : -string
      end

      sig { params(value: T.untyped).returns(T::Hash[Symbol, Integer]) }
      def counts!(value) = value.to_h { |name, count| [name.to_sym, Integer(count)] }.freeze

      sig { params(value: T.untyped).returns(T::Hash[String, Integer]) }
      def tally!(value) = value.to_h { |name, count| [-name.to_s, Integer(count)] }.freeze

      sig { params(value: T.untyped).returns(T::Hash[Symbol, Float]) }
      def ratios!(value) = value.to_h { |name, ratio| [name.to_sym, Float(ratio)] }.freeze

      sig { params(value: T.untyped).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
      def columns!(value)
        Array(value).map { |column| column.to_h.transform_keys(&:to_sym).freeze }.freeze
      end
    end
  end
end
