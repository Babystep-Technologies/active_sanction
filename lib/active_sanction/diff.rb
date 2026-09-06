# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"
require "active_sanction/snapshot"
require "active_sanction/sources"
require "active_sanction/storage"
require "active_sanction/storage/meta"
require "active_sanction/diff/change"

module ActiveSanction
  # What changed between two snapshots of one source.
  #
  #   diff = ActiveSanction.diff(:ofac_sdn, from: last_months_snapshot, to: todays_snapshot)
  #
  #   diff.added      # => [Entity], newly listed
  #   diff.removed    # => [Entity], delisted
  #   diff.modified   # => [Diff::Change], amended, with the fields that moved
  #   diff.changed    # => [Entity], what a consuming service should re-screen against
  #   puts diff       # => the summary below
  #
  # ### Why this exists
  #
  # Screening is not a one-time event. A customer cleared last month may be
  # listed today, and the obligation is to notice. Re-running an entire book of
  # business against an entire list every night is how most services answer
  # that, and it is why most services answer it weekly instead. A diff turns
  # the nightly job into "screen everyone against the eleven records that
  # moved", which is a job small enough to run every time a list is synced.
  #
  # Delistings matter as much as listings, and they are the half a re-screen
  # against added records only would miss: a delisting is what lets a customer
  # back through the door, and a service that never notices one goes on
  # blocking somebody the government stopped sanctioning in March.
  #
  # ### It rests on ids being stable
  #
  # The two snapshots are joined by entity id, so an amendment reports as one
  # modification rather than as a delisting and a new listing. That only holds
  # while a record keeps its id between syncs, which is why the adapter
  # conformance group asserts id stability (#16) and why the Canada adapter
  # (#22) hashes a citation *and* a name into a synthetic one. Ids that move
  # would make every sync look like a full replacement, and a diff full of
  # delistings that did not happen is worse than no diff at all.
  #
  # ### A first sync is a baseline, not 19,015 new listings
  #
  # With no previous snapshot there is nothing to compare, and reporting the
  # whole list as `added` would be false: those records were not listed today,
  # they were listed over twenty years and we are only now looking. So a diff
  # with no `from` is a baseline -- `added`, `removed` and `modified` are all
  # empty, `baseline?` is true, and `changed` is empty because the right
  # response to a first sync is a deliberate full screening run rather than one
  # driven by a diff that is really a list.
  #
  # ### Computed here rather than taken from a publisher
  #
  # OFAC serves a delta feed of its own at `/changes/latest`. This does not
  # read it, and the reason is that a diff has to describe the two list
  # versions *we hold*: a publisher's delta describes the change between two
  # versions it chose, and a run that skipped a day, or held a stale list
  # because a fetch failed (#34), is not on either end of it. Cross-checking a
  # computed diff against that feed is worth doing -- it is how a parser
  # regression that quietly drops records gets caught -- but it belongs in the
  # OFAC adapter, as one publisher's answer to a question every source has to
  # answer, rather than in the general shape of a diff.
  #
  # ### The output
  #
  #   ofac_sdn: 19015 -> 19023 records, 12 added, 4 removed, 5 modified (0.1% of the previous list)
  #     + ofac_sdn:41234  IVANOV, Ivan Ivanovich  [SDGT]
  #     - ofac_sdn:2674   ABBAS, Abu  [SDGT]
  #     ~ ofac_sdn:36     names +1, programs +1
  #
  # That is `diff.to_s`, and `#summary` is its first line on its own -- the one
  # a sync wrapper logs. There is no CLI to print either from, #36 being closed
  # as not planned, so the human-readable form is a method on the object and a
  # rake task or a scheduled job prints it. `#to_h` is the machine-readable form
  # of the same thing, JSON-ready and carrying the two snapshots' checksums so a
  # diff says which pair of list versions produced it.
  #
  # There is no `.from_h`: a diff is derived rather than stored, and those two
  # checksums are what makes it reproducible -- keep them and the diff can
  # always be computed again, keep the diff and you have a copy of an answer
  # nobody can check.
  #
  # Instances are frozen on construction and compare by value.
  class Diff
    extend T::Sig

    # How many detail lines #to_s prints before it stops. A real diff between
    # two consecutive syncs is a handful of records; one that is thousands is a
    # parse regression or a publisher who reissued a list under new ids, and
    # neither is improved by dumping all of it into a terminal.
    DETAIL_LIMIT = T.let(20, Integer)

    sig { returns(Symbol) }
    attr_reader :source

    # Newly listed: on the new snapshot, not on the old, sorted by id.
    sig { returns(T::Array[T.untyped]) }
    attr_reader :added

    # Delisted: on the old snapshot, not on the new.
    sig { returns(T::Array[T.untyped]) }
    attr_reader :removed

    # Amended, with the fields that moved. See Diff::Change.
    sig { returns(T::Array[Change]) }
    attr_reader :modified

    # What the old snapshot was: fetched_at, checksum, record_count. Nil for a
    # baseline. The whole snapshot is deliberately not held -- a diff of eleven
    # records would otherwise pin two lists and tens of megabytes of entities
    # in memory for as long as anything holds it.
    sig { returns(T.nilable(Storage::Meta)) }
    attr_reader :from

    # What the new snapshot is, which is what screening runs against now.
    sig { returns(Storage::Meta) }
    attr_reader :to

    # Sugar, and what ActiveSanction.diff calls:
    #
    #   ActiveSanction.diff(:ofac_sdn, from: old, to: new)
    #   ActiveSanction.diff(:ofac_sdn, from: old)   # `to:` is what is stored now
    #   ActiveSanction.diff(from: old, to: new)     # the source comes from the snapshots
    #
    # `to:` defaults to the stored snapshot because that is what a re-screen is
    # about to run against, and it raises rather than defaulting to nothing:
    # diffing against a list that is not there would report every record on it
    # as delisted, which is a clean report for every customer on it.
    sig { params(source: T.untyped, from: T.untyped, to: T.untyped, store: T.untyped).returns(T.attached_class) }
    def self.call(source = nil, from: nil, to: nil, store: nil)
      key = source.nil? ? nil : Sources::Definition.key!(source)
      new(source: key, from: from, to: to || stored!(key, store))
    end

    sig { params(key: T.nilable(Symbol), store: T.untyped).returns(Snapshot) }
    def self.stored!(key, store)
      raise ArgumentError, "diff needs a `to:` snapshot, or a source to read the current one from" if key.nil?

      (store || ActiveSanction.storage).fetch_snapshot(key)
    end
    private_class_method :stored!

    # `from:` is nil for a first sync, which is a baseline rather than a list
    # of additions -- see the class comment. `source:` is optional and is
    # checked against the snapshots rather than trusted, since a diff of the
    # wrong pair of lists reports every record on both as having moved.
    sig { params(to: T.untyped, from: T.untyped, source: T.untyped).void }
    def initialize(to:, from: nil, source: nil)
      current = snapshot!(:to, to)
      previous = from.nil? ? nil : snapshot!(:from, from)
      @source = T.let(source!(source, previous, current), Symbol)
      @from = T.let(previous && Storage::Meta.from_snapshot(previous), T.nilable(Storage::Meta))
      @to = T.let(Storage::Meta.from_snapshot(current), Storage::Meta)
      added, removed, modified = compare(previous, current)
      @added = T.let(added, T::Array[T.untyped])
      @removed = T.let(removed, T::Array[T.untyped])
      @modified = T.let(modified, T::Array[Change])
      freeze
    end

    # No previous snapshot: the source was synced for the first time, and this
    # says what it holds rather than claiming every record on it is new.
    sig { returns(T::Boolean) }
    def baseline? = from.nil?

    sig { returns(T::Boolean) }
    def empty? = added.empty? && removed.empty? && modified.empty?

    sig { returns(T::Boolean) }
    def any? = !empty?

    # Records that moved, in either direction.
    sig { returns(Integer) }
    def size = added.size + removed.size + modified.size

    # What a consuming service should re-screen its book against: the records
    # that are on the list now and were not, or were not the same.
    #
    # Delistings are deliberately not in here -- they are not something to
    # screen *against*, they are records to clear existing alerts on, which is
    # a different job done from `removed`. And nothing here judges a change too
    # small to matter: a corrected passport number and a reworded remark reach
    # the scorer through different paths, and a library that decided on a
    # host's behalf which amendments were worth re-screening would be deciding
    # which sanctions hits it is willing to miss.
    sig { returns(T::Array[T.untyped]) }
    def changed = added + modified.map(&:entity)

    # How much of the previous list moved, as a fraction. The number to alert
    # on: two consecutive syncs of a live sanctions list move a fraction of a
    # percent, so a diff that says a third of the list changed is a parse
    # regression, an id scheme that shifted, or a publisher who reissued the
    # file -- and all three are things to look at before re-screening anybody
    # against the result. Nil for a baseline, and for a previous list that was
    # empty.
    sig { returns(T.nilable(Float)) }
    def churn
      count = from&.record_count
      return nil if count.nil? || count.zero?

      (size.to_f / count).round(6).to_f
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h
      {
        source: source,
        from: from&.to_h,
        to: to.to_h,
        added: added.map(&:to_h),
        removed: removed.map(&:to_h),
        modified: modified.map(&:to_h)
      }
    end

    # The one line at the top of #to_s, and the line worth logging on its own
    # after a sync.
    sig { returns(String) }
    def summary
      return "#{source}: first snapshot, #{to.record_count} records (baseline, nothing to re-screen)" if baseline?
      return "#{source}: #{to.record_count} records, unchanged" if empty?

      "#{source}: #{T.must(from).record_count} -> #{to.record_count} records, #{added.size} added, " \
        "#{removed.size} removed, #{modified.size} modified#{churn_note}"
    end

    # One line per record that moved, marked `+`, `-` or `~`. `limit:` caps how
    # many are returned and adds a line saying how many were not; nil returns
    # every one, which is what a consumer writing a report wants.
    sig { params(limit: T.nilable(Integer)).returns(T::Array[String]) }
    def details(limit: nil)
      lines = added.map { |entity| "  + #{label(entity)}" } +
              removed.map { |entity| "  - #{label(entity)}" } +
              modified.map { |change| "  ~ #{change}" }
      return lines if limit.nil? || lines.size <= limit

      lines.first(limit) + ["  ... and #{lines.size - limit} more"]
    end

    sig { returns(String) }
    def to_s = ([summary] + details(limit: DETAIL_LIMIT)).join("\n")

    sig { params(other: T.untyped).returns(T::Boolean) }
    def ==(other)
      return false unless other.instance_of?(self.class)

      to_h == other.to_h
    end
    alias eql? ==

    sig { returns(Integer) }
    def hash = [self.class, to_h].hash

    sig { returns(String) }
    def inspect = "#<#{self.class} #{source} +#{added.size} -#{removed.size} ~#{modified.size}>"

    private

    # An entity as a summary line names it: its id, the name a hit would be
    # reported under, and the programs it is listed under, which is the field
    # that says what a hit on it means.
    sig { params(entity: T.untyped).returns(String) }
    def label(entity)
      name = entity.primary_name&.value
      programs = entity.programs
      "#{entity.id}  #{name || "(no name)"}#{"  [#{programs.join(", ")}]" if programs.any?}"
    end

    sig { returns(String) }
    def churn_note
      fraction = churn
      fraction.nil? ? "" : " (#{format("%.1f", fraction * 100)}% of the previous list)"
    end

    # The three lists, or three empty ones for a baseline -- which is the whole
    # of what "a first sync is not a list of additions" costs to implement.
    sig { params(previous: T.nilable(Snapshot), current: Snapshot).returns(T::Array[T.untyped]) }
    def compare(previous, current)
      return [[], [], []] if previous.nil?

      before = by_id(previous.entities)
      after = by_id(current.entities)
      [entities(after.keys - before.keys, after),
       entities(before.keys - after.keys, before),
       modifications(before, after)]
    end

    sig { params(ids: T::Array[String], index: T::Hash[String, T.untyped]).returns(T::Array[T.untyped]) }
    def entities(ids, index) = ids.sort.map { |id| index.fetch(id) }

    sig do
      params(before: T::Hash[String, T.untyped], after: T::Hash[String, T.untyped]).returns(T::Array[Change])
    end
    def modifications(before, after)
      (before.keys & after.keys).sort.filter_map { |id| Change.between(before.fetch(id), after.fetch(id)) }
    end

    # By id, and sorted output everywhere below, so that two runs over the same
    # pair of lists produce the same diff whatever order the publisher happened
    # to emit its file in.
    #
    # An id that appears twice in one snapshot keeps its first occurrence: the
    # publisher's own file is what it is, the same rule is applied to both
    # sides, and so a duplicate reads as unchanged rather than as a record that
    # moved. Nothing here can resolve which of the two was meant, and refusing
    # to diff a list that screens perfectly well would be the worse answer.
    sig { params(list: T::Array[T.untyped]).returns(T::Hash[String, T.untyped]) }
    def by_id(list)
      list.each_with_object({}) do |entity, index|
        unless entity.respond_to?(:id) && entity.respond_to?(:to_h)
          raise ArgumentError, "a diff compares entities, got #{entity.class}. A store that hands back " \
                               "half-deserialized records cannot be diffed -- see Storage::Base#read_snapshot"
        end

        index[entity.id] ||= entity
      end
    end

    sig { params(member: Symbol, value: T.untyped).returns(Snapshot) }
    def snapshot!(member, value)
      return value if value.is_a?(Snapshot)

      raise ArgumentError, "#{member} must be an ActiveSanction::Snapshot, got #{value.class}"
    end

    # A diff of two different sources is not a diff, it is every record on both
    # lists reported as having moved -- so the mismatch is refused rather than
    # computed.
    sig { params(named: T.untyped, previous: T.nilable(Snapshot), current: Snapshot).returns(Symbol) }
    def source!(named, previous, current)
      key = current.source
      if previous && previous.source != key
        raise ArgumentError, "cannot diff a #{previous.source} snapshot against a #{key} one"
      end
      return key if named.nil? || named.to_sym == key

      raise ArgumentError, "asked for a #{named} diff, but the snapshots are #{key}"
    end
  end
end
