# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"
require "active_sanction/match_result"
require "active_sanction/subject"

module ActiveSanction
  class Rescreen
    # One subject, one record, and what moved between two list versions.
    #
    #   alert.subject_id      # => "cust_1"
    #   alert.change          # => :newly_listed
    #   alert.result          # => MatchResult, scored against the record as it is now
    #   alert.previous_result # => nil -- there was no such record before
    #   alert.score           # => 94.1
    #   alert.previous_score  # => nil
    #
    #   puts alert
    #   # => cust_1  newly listed  un_consolidated:6908021  BOSCO TAGANDA  94.1
    #
    # ### The two sides, and why either may be missing
    #
    # An alert is a *change*, so it is two screening results rather than one:
    # `previous_result` is what this subject scored against the record as the
    # old list had it, and `result` is what it scores against the record as
    # the new list has it. A newly listed record has no previous side. A
    # delisted one has no current side. Everything else has both, and the pair
    # is what lets an alert say a subject moved from 71 to 94 rather than
    # merely that it now matches -- which is the difference between an analyst
    # reading a record and an analyst reading a change to one.
    #
    # Both are full MatchResults, each stamped with the checksum of the list
    # version it was scored against, so an alert is defensible the same way a
    # screening decision is: the explanation is on it, and it adds up.
    # `#evidence` is the side the alert was raised on, for a caller that wants
    # the record and does not care which list version described it.
    #
    # The side that did *not* clear is scored again without a cutoff, so its
    # result may sit below the threshold its own query names -- which is
    # exactly what a subject moving into or out of range looks like, and is
    # the whole reason the score is carried rather than only the fact of a
    # match.
    #
    # ### What `change` says, and what it does not
    #
    # It is about **this subject's match**, not about the record's paperwork:
    #
    # - `:newly_listed` -- the subject did not reach the threshold against
    #   this record before and does now. Usually because the record is new;
    #   also because an existing record gained the alias, the identifier or
    #   the date of birth that brought the subject over the line, which is the
    #   same event for a compliance team and is why it is not filed
    #   separately.
    # - `:delisted` -- it did reach the threshold before and does not now.
    #   Usually because the record was withdrawn; also because an amendment
    #   moved it out of range. This is the half of a rescreen that a run
    #   against new records only would miss, and it is the half that lets a
    #   customer back through the door.
    # - `:details_changed` -- it matched before, it matches now, and the
    #   record moved underneath it. The score may be identical: a program
    #   added or an address corrected changes what a hit *means* without
    #   changing what it scores, and deciding that such a change is too small
    #   to report would be deciding which sanctions hits a host is willing to
    #   miss.
    #
    # Which of those two routes into `:newly_listed` and `:delisted` a given
    # alert took is not guesswork -- `#fields` is empty when the record itself
    # arrived or left, and names the fields that moved when it was amended.
    #
    # ### Both snapshot ids, on every alert
    #
    # A MatchResult cites the one list version it was scored against, and an
    # alert is about two. So it carries both: `previous_snapshot_id` and
    # `snapshot_id` are the checksums the diff was computed over, which is
    # what makes an alert reproducible under audit -- keep the pair and the
    # whole run can be derived again, from lists that can be identified rather
    # than from a copy of an answer nobody can check.
    #
    # Instances are frozen on construction and compare by value.
    class Alert
      extend T::Sig

      # What happened to this subject's match. See the class comment.
      CHANGES = T.let(%i[newly_listed delisted details_changed].freeze, T::Array[Symbol])

      # @api private
      MEMBERS = T.let(
        %i[subject change fields result previous_result snapshot_id previous_snapshot_id].freeze,
        T::Array[Symbol]
      )

      # The book entry this alert is about, as the caller supplied it.
      sig { returns(Subject) }
      attr_reader :subject

      sig { returns(Symbol) }
      attr_reader :change

      # The fields of the record that moved, in Entity's member order, or an
      # empty array when the record was added or withdrawn whole. See
      # Diff::Change.
      sig { returns(T::Array[Symbol]) }
      attr_reader :fields

      # Scored against the record as the new list has it, or nil when the new
      # list does not have it.
      sig { returns(T.nilable(MatchResult)) }
      attr_reader :result

      # Scored against the record as the old list had it, or nil when the old
      # list did not have it.
      sig { returns(T.nilable(MatchResult)) }
      attr_reader :previous_result

      # The checksum of the list version this run screened against.
      sig { returns(String) }
      attr_reader :snapshot_id

      # The checksum of the list version it was compared with.
      sig { returns(String) }
      attr_reader :previous_snapshot_id

      # Rebuilds an alert from #to_h output, accepting string keys so one
      # survives the round-trip through JSON and back out of whatever a host
      # stored it in.
      sig { params(hash: T.untyped).returns(T.attached_class) }
      def self.from_h(hash)
        attributes = hash.to_h.transform_keys(&:to_sym)
        unknown = attributes.keys - MEMBERS
        raise InvalidArgument, "unknown Alert attribute(s): #{unknown.join(", ")}" if unknown.any?

        T.unsafe(self).new(**attributes,
                           subject: build(Subject, attributes[:subject]),
                           result: build(MatchResult, attributes[:result]),
                           previous_result: build(MatchResult, attributes[:previous_result]))
      end

      # A value that is already the object passes through, so from_h is safe
      # to call on a half-deserialized hash.
      sig { params(klass: T.untyped, value: T.untyped).returns(T.untyped) }
      def self.build(klass, value) = value.is_a?(Hash) ? klass.from_h(value) : value
      private_class_method :build

      sig do
        params(subject: T.untyped, change: T.untyped, snapshot_id: T.untyped, previous_snapshot_id: T.untyped,
               result: T.untyped, previous_result: T.untyped, fields: T.untyped).void
      end
      def initialize(subject:, change:, snapshot_id:, previous_snapshot_id:, result: nil, previous_result: nil,
                     fields: [])
        @subject = T.let(instance!(:subject, Subject, subject), Subject)
        @change = T.let(change!(change), Symbol)
        @result = T.let(result!(:result, result), T.nilable(MatchResult))
        @previous_result = T.let(result!(:previous_result, previous_result), T.nilable(MatchResult))
        sides!
        @fields = T.let(Array(fields).map(&:to_sym).freeze, T::Array[Symbol])
        @snapshot_id = T.let(string!(:snapshot_id, snapshot_id), String)
        @previous_snapshot_id = T.let(string!(:previous_snapshot_id, previous_snapshot_id), String)
        freeze
      end

      # The caller's own id for the subject, which is what an alert is joined
      # back to a book of business by.
      sig { returns(String) }
      def subject_id = subject.id

      # The side the alert was raised on: the current one, or the previous one
      # for a delisting, which is the version that actually matched. It is
      # what `#entity` and `#matched_name` read, so an alert describes the
      # record the way it looked when it crossed the threshold.
      #
      # Never nil: an alert with neither side is not a change, and is refused
      # at construction.
      sig { returns(MatchResult) }
      def evidence = T.must(delisted? ? previous_result || result : result || previous_result)

      # The record this alert is about, as the surviving side has it.
      sig { returns(Entity) }
      def entity = evidence.entity

      sig { returns(String) }
      def entity_id = entity.id

      # The spelling that produced the score, as its publisher wrote it. See
      # MatchResult#matched_name.
      sig { returns(Name) }
      def matched_name = evidence.matched_name

      sig { returns(Symbol) }
      def source = entity.source

      # What the subject scores against the record now, or nil if the record
      # is no longer on the list.
      sig { returns(T.nilable(Float)) }
      def score = result&.score

      # What it scored against the record before, or nil if the record was
      # not on the previous list.
      sig { returns(T.nilable(Float)) }
      def previous_score = previous_result&.score

      # The threshold this subject was screened at, which is half of what
      # makes the change mean anything: the same pair of scores is a new
      # listing at 75 and nothing at all at 95.
      sig { returns(Float) }
      def threshold = evidence.threshold

      # When the run that produced this alert happened. One instant for a
      # whole run -- see Rescreen.
      sig { returns(Time) }
      def screened_at = evidence.screened_at

      sig { returns(T::Boolean) }
      def newly_listed? = change == :newly_listed

      sig { returns(T::Boolean) }
      def delisted? = change == :delisted

      sig { returns(T::Boolean) }
      def details_changed? = change == :details_changed

      # The documented shape. Every value is a String, a Float, an Integer, an
      # Array or a Hash of the same, so `JSON.generate(alert.to_h)` needs
      # nothing from this library and `Alert.from_h(JSON.parse(json))` rebuilds
      # exactly this object.
      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h
        {
          subject: subject.to_h,
          change: change,
          fields: fields,
          result: result&.to_h,
          previous_result: previous_result&.to_h,
          snapshot_id: snapshot_id,
          previous_snapshot_id: previous_snapshot_id
        }
      end

      # One line, for the summary a human reads:
      #
      #   cust_1  newly listed  un_consolidated:6908021  BOSCO TAGANDA  94.1 (was 71.0)
      sig { returns(String) }
      def to_s
        "#{subject_id}  #{change.to_s.tr("_", " ")}  #{entity_id}  #{evidence.matched_name.value}  #{movement}"
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
      def inspect = "#<#{self.class} #{self}>"

      private

      # What the score did, which is the sentence an analyst reads first. A
      # side that does not exist prints as the listing event it was.
      sig { returns(String) }
      def movement
        return "#{previous_score} -> delisted" if result.nil?
        return score.to_s if previous_result.nil?
        return "#{score} (unchanged)" if score == previous_score

        "#{previous_score} -> #{score}"
      end

      sig { params(member: Symbol, klass: T.untyped, value: T.untyped).returns(T.untyped) }
      def instance!(member, klass, value)
        return value if value.is_a?(klass)

        raise InvalidArgument, "#{member} must be an #{klass}, got #{value.class}"
      end

      sig { params(member: Symbol, value: T.untyped).returns(T.nilable(MatchResult)) }
      def result!(member, value) = value.nil? ? nil : instance!(member, MatchResult, value)

      # An alert with neither side is not a change: nothing was scored, and
      # there is no record for it to be about.
      sig { void }
      def sides!
        return unless result.nil? && previous_result.nil?

        raise InvalidArgument,
              "an alert needs a result on at least one side of the change -- one that scored against neither " \
              "list version is not a change, and cannot say what it is about"
      end

      sig { params(value: T.untyped).returns(Symbol) }
      def change!(value)
        symbol = value.to_s.to_sym
        return symbol if CHANGES.include?(symbol)

        raise InvalidArgument, "unknown change #{value.inspect}, expected one of #{CHANGES.join(", ")}"
      end

      sig { params(member: Symbol, value: T.untyped).returns(String) }
      def string!(member, value)
        string = value.to_s.strip
        raise InvalidArgument, "#{member} is required -- an alert cites both list versions it compared" if string.empty?

        -string
      end
    end
  end
end
