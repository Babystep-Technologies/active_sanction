# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/country"
require "active_sanction/scorer/reason"

module ActiveSanction
  module Scorer
    # What the record says about a subject other than their name, and what
    # each agreement and each contradiction is worth.
    #
    #   ActiveSanction::Scorer::Adjustments.call(subject, entity)
    #   # => [#<Reason +40.0 identifier: passport AB123456 matches>,
    #   #     #<Reason  -8.0 nationality: query RU vs listed EG>]
    #
    # Stage 4b, and the part that separates a usable screening tool from a
    # name-similarity toy. A name score alone puts thousands of people on a
    # list of a few hundred, because a quarter of the individuals on these
    # lists share a handful of given names and every one of them scores in the
    # seventies against every other. The passport number, the date of birth
    # and the nationality are what tell those apart, and they are the fields a
    # compliance officer already has in a customer record.
    #
    # ### Absent is not conflict, and it is the rule everything here obeys
    #
    # Most records lack most identifiers. Canada publishes no aliases and
    # frequently no date of birth; OFAC's dates are prose in a remarks field
    # and are missing wherever the sentence did not parse; the UN grades what
    # it has and says nothing about what it does not. So every adjustment
    # below fires only when *both* sides carry the field, and a field missing
    # on either side produces no Reason at all -- not a small penalty, not a
    # zero-valued reason.
    #
    # Treating absence as disagreement would penalize exactly the sparser
    # lists, which means systematically under-scoring the jurisdictions that
    # publish least and hiding real hits behind a threshold. It is the
    # quietest way to build a screening tool that does not screen, and it is
    # why this is stated as a rule rather than left to each branch.
    #
    # The same rule governs a country nobody can resolve. A nationality of
    # `Ruritania` is not a contradiction of `Egypt`; it is a string this
    # library does not recognize, and the difference between those two is a
    # penalty applied to a match that was correct. See Country.
    #
    # ### The three signals, and why they are worth what they are
    #
    # **A document number is the only near-decisive field on a sanctions
    # record.** Two people share a name; they do not share a passport number.
    # It is the one place where agreement outranks everything the name said,
    # which is what a boost of 40 points on a 100-point scale means: a name in
    # the fifties plus the right passport clears any threshold this library
    # would ship.
    #
    # **A date of birth is strong evidence in both directions.** An exact full
    # date agreeing is worth a real boost; a genuine conflict -- two dates
    # that cannot describe the same person -- is worth more against, because
    # sharing a birthday with a listed person is a coincidence a few thousand
    # people have and not having theirs is not. `PartialDate#overlaps?` is
    # what decides which of the three cases a pair is in, and it is exact
    # whatever precision either side carries: a year-only record does not
    # conflict with a full date inside it, it agrees with it, weakly.
    #
    # **Nationality moves the score least.** People hold two passports, lists
    # record the country a person was born in as readily as the one they are a
    # citizen of, and the field is published as prose. It is real evidence and
    # it is the softest of the three.
    #
    # ### Order is fixed, because an explanation is read
    #
    # Identifier, then date of birth, then nationality: strongest evidence
    # first, so a reviewer reading an explanation downwards meets the reason
    # the score is what it is before meeting the ones that adjusted it. The
    # order is also what makes a score reproducible to the last decimal --
    # see Scorer on why the sum has to be taken the same way every time.
    #
    # @api private
    module Adjustments
      extend T::Sig

      # Below this many alphanumerics, a "document number" is not a document
      # number. Nothing a government issues is three characters long, and an
      # exact match on a short string is the one way a 40-point boost could
      # land on a coincidence -- a remarks parser that read `Passport 12` out
      # of a half-formed sentence would otherwise make two unrelated records
      # decisive for each other.
      MINIMUM_IDENTIFIER_LENGTH = T.let(4, Integer)

      module_function

      # Every adjustment both sides carry the evidence for, strongest first.
      # An empty array is the ordinary answer for a record that publishes a
      # name and nothing else.
      sig do
        params(subject: Subject, entity: Entity, weights: Weights)
          .returns(T::Array[Reason]).checked(:tests)
      end
      def call(subject, entity, weights = Weights.default)
        [identifier(subject, entity, weights), dob(subject, entity, weights),
         nationality(subject, entity, weights)].compact
      end

      # The first document number both sides carry, in the order the caller
      # and the publisher listed them. First rather than best: there is no
      # "better" exact match on a document number, and iterating in a fixed
      # order is what makes the explanation identical on every run.
      sig { params(subject: Subject, entity: Entity, weights: Weights).returns(T.nilable(Reason)).checked(:tests) }
      def identifier(subject, entity, weights)
        subject.identifiers.each do |mine|
          next if mine.normalized_value.length < MINIMUM_IDENTIFIER_LENGTH

          theirs = entity.identifiers.find { |listed| same_document?(mine, listed) }
          next if theirs.nil?

          return Reason.new(factor: :identifier, contribution: weights.identifier_match,
                            detail: document_detail(mine, theirs))
        end
        nil
      end

      # Exact, overlapping, or contradictory -- in that order, over every
      # pairing of the dates the two sides carry. Both plural: the UN
      # publishes more than one date of birth for 140 of its individuals
      # because several governments reported several dates, and any of them
      # matching is a match. A conflict therefore means *no* pairing overlaps,
      # which is the only reading that does not turn an honestly uncertain
      # record into a penalty.
      sig { params(subject: Subject, entity: Entity, weights: Weights).returns(T.nilable(Reason)).checked(:tests) }
      def dob(subject, entity, weights)
        mine = subject.dates_of_birth
        theirs = entity.dates_of_birth
        return nil if mine.empty? || theirs.empty?

        agreement(mine.product(theirs), weights) ||
          dob_reason(:dob_conflict, "#{mine.join(", ")} conflicts with listed #{theirs.join(", ")}", weights)
      end

      # The best of the pairings, or nil when none of them agree at all --
      # which is what makes the caller above a conflict.
      sig do
        params(pairs: T::Array[T::Array[PartialDate]], weights: Weights)
          .returns(T.nilable(Reason)).checked(:tests)
      end
      def agreement(pairs, weights)
        exact = pairs.find { |left, right| same_day?(T.must(left), T.must(right)) }
        return dob_reason(:dob_exact, "#{exact.first} matches", weights) if exact

        overlap = pairs.find { |left, right| T.must(left).overlaps?(right) }
        return nil if overlap.nil?

        dob_reason(:dob_overlap, "#{overlap.first} overlaps listed #{overlap.last}", weights)
      end

      # Agreement, or a contradiction both sides are precise enough to make.
      #
      # A country is compared as the alpha-2 code it resolves to, falling back
      # to its folded string so that two publishers writing the same
      # unrecognized value still agree. A *conflict* needs more: every value
      # on both sides has to have resolved, because "these two strings are not
      # equal" is not evidence that two countries are different.
      sig { params(subject: Subject, entity: Entity, weights: Weights).returns(T.nilable(Reason)).checked(:tests) }
      def nationality(subject, entity, weights)
        listed = entity.nationalities
        return nil if subject.nationalities.empty? || listed.empty?

        mine = keys(subject.nationalities)
        theirs = keys(listed)
        shared = mine & theirs
        if shared.any?
          return Reason.new(factor: :nationality, contribution: weights.nationality_match,
                            detail: "#{shared.join(", ")} matches")
        end
        return nil unless subject.countries? && resolved?(listed)

        Reason.new(factor: :nationality, contribution: weights.nationality_conflict,
                   detail: "query #{mine.join(", ")} vs listed #{theirs.join(", ")}")
      end

      # Kind, number and country all have to be compatible, and two of the
      # three treat "unstated" as compatible rather than as different.
      #
      # `:other` is the kind OFAC's remarks produce for a number its sentence
      # did not classify, so requiring the kinds to be equal would throw away
      # most of the document numbers this library extracts. Country is the
      # opposite case and is why Identifier's own equality carries it: two
      # passports with the same number from different countries are different
      # documents, so a country stated on both sides and disagreeing is a
      # mismatch -- while a country stated on neither, or on one, is not.
      sig { params(mine: Identifier, theirs: Identifier).returns(T::Boolean).checked(:tests) }
      def same_document?(mine, theirs)
        return false unless mine.normalized_value == theirs.normalized_value
        return false unless mine.kind == theirs.kind || mine.kind == :other || theirs.kind == :other

        same_country?(mine.country, theirs.country)
      end

      sig { params(mine: T.nilable(String), theirs: T.nilable(String)).returns(T::Boolean).checked(:tests) }
      def same_country?(mine, theirs)
        return true if mine.nil? || theirs.nil?

        key(mine) == key(theirs)
      end

      # A full date on both sides, neither hedged with a "circa", naming the
      # same day. Anything less precise is an overlap: `1948` and `1948-12-10`
      # agree, and saying they match exactly would claim a precision the
      # publisher did not.
      sig { params(mine: PartialDate, theirs: PartialDate).returns(T::Boolean).checked(:tests) }
      def same_day?(mine, theirs)
        mine.precision == :day && theirs.precision == :day &&
          !mine.approximate? && !theirs.approximate? && mine.first_date == theirs.first_date
      end

      sig { params(weight: Symbol, detail: String, weights: Weights).returns(Reason).checked(:tests) }
      def dob_reason(weight, detail, weights)
        Reason.new(factor: :dob, detail: "date of birth #{detail}", contribution: weights.fetch(weight))
      end

      sig { params(mine: Identifier, theirs: Identifier).returns(String).checked(:tests) }
      def document_detail(mine, theirs)
        kind = mine.kind == :other ? theirs.kind : mine.kind
        return "#{kind} #{mine.value} matches" if mine.value == theirs.value

        "#{kind} #{mine.value} matches listed #{theirs.value}"
      end

      # The alpha-2 code, or the folded string when the table does not know
      # the value. Never nil, so agreement can be found on a spelling neither
      # side could resolve.
      sig { params(value: String).returns(String).checked(:tests) }
      def key(value) = Country.code(value) || Country.fold(value)

      sig { params(values: T::Array[String]).returns(T::Array[String]).checked(:tests) }
      def keys(values) = values.map { |value| key(value) }.uniq

      sig { params(values: T::Array[String]).returns(T::Boolean).checked(:tests) }
      def resolved?(values) = values.all? { |value| Country.code(value) }
    end
  end
end
