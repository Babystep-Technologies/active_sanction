# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  # Turns a candidate into an explainable score. Stage 4 of the matching
  # pipeline, and the component that decides whether this library is
  # trustworthy.
  #
  #   subject = ActiveSanction::Scorer::Subject.new(
  #     name: "Abu Abbas", type: :individual, dates_of_birth: "1948", nationalities: %w[RU]
  #   )
  #
  #   result = ActiveSanction::Scorer.call(subject, entity)
  #   result.score        # => 87.4
  #   result.name.value   # => "ABBAS, Abu"
  #   result.explanation
  #   # => [#<Reason +91.2 name: matched primary name 'ABBAS, Abu'>,
  #   #     #<Reason  +6.0 dob: date of birth 1948 overlaps listed 1948-12-10>,
  #   #     #<Reason -12.0 nationality: query RU vs listed EG>]
  #
  #   ActiveSanction::Scorer.call(subject, index.candidates("Abu Abbas").first)
  #
  # Everything upstream narrows: the normalizer (#26) makes two names
  # comparable, the index (#31) says which are worth comparing, and Similarity
  # (#28, #29) and Phonetics (#30) each answer one question about a pair. This
  # stage is the only one that says *how much a match is worth*, and the only
  # one whose output a person has to act on.
  #
  # ### An entity's score is the best of its names
  #
  # Matching any single alias is a hit. OFAC ships 20,147 aliases against
  # 19,321 primary names and the UN publishes as many as a dozen spellings of
  # one person, so a score that averaged over an entity's names would punish
  # the records that describe themselves most thoroughly -- and a score that
  # only read the primary name would miss most of what these lists are for.
  #
  # So every name is scored and the best one wins, and the winner is on the
  # Result: a report has to be able to say which spelling produced the hit.
  #
  # The low-quality penalty is applied *before* the maximum rather than to the
  # winner afterwards, which is the difference between two readings of the
  # same rule. The UN grades some aliases `Low`, meaning the Committee itself
  # is unsure the person is known by that name; a good name scoring 85 should
  # beat a low-quality one scoring 90, and it only does if the penalty is part
  # of what the maximum is taken over.
  #
  # A former name (`fka`) is not penalized. It is a name the person really
  # used, and a screening tool that discounted it would be discounting exactly
  # the alias someone changes their name to escape.
  #
  # ### An entity of the wrong type is not scored at all
  #
  # A subject that says `:individual` is never compared to a vessel, whatever
  # the names look like. `NORTHERN STAR` is a ship and a person and the
  # difference is not a matter of degree -- there is no score at which a
  # compliance officer wants a ship in a list of people -- so this is a filter
  # and not a penalty, and `call` returns nil.
  #
  # Vessels and aircraft are ~10% of the SDN list and carry name-like strings,
  # which is why Entity has the types at all. A subject that gives no type is
  # asking a different question and is scored against everything.
  #
  # ### Deterministic, to the last decimal
  #
  # The same subject and the same entity produce the same score and the same
  # explanation on every run, in every process. That is not a nicety: a
  # screening decision is re-derived during an audit months later, and a score
  # that moved by a tenth because a Hash iterated differently is a decision
  # nobody can defend.
  #
  # What that costs is small and worth naming, because each piece of it is a
  # place the property could be lost. Names are scored in the order the
  # publisher listed them and ties go to the first, so an entity carrying the
  # same spelling twice does not depend on which copy was seen first. The
  # adjustments run in a fixed order -- see Adjustments -- and each picks its
  # pairing by iteration order rather than by anything sorted on a Float.
  # Rounding happens once, in Reason, and the score is the sum of the rounded
  # contributions rather than the rounded sum.
  #
  # ### `threshold:` is how a screening call fits in its budget
  #
  # This stage is nearly all of what a screening call costs -- a few hundred
  # candidates, four string algorithms and a phonetic pass on each -- and
  # scoring them exactly costs about 46 ms under YJIT where scoring them to a
  # threshold of 75 costs about 16. The difference is not an approximation:
  # everything a threshold turns off is a comparison whose result could not
  # have changed the answer, and a result at or above the cutoff is exactly
  # the result the same call without one returns. See NameScore for the
  # arithmetic and `rake benchmark:scorer` for the sweep.
  #
  # So the caller in front of this should always pass one. A matcher that
  # screens without a threshold spends three times its budget computing exact
  # scores for candidates it is about to discard.
  #
  # It is applied to the whole score rather than to the name, which matters:
  # a subject carrying the right passport number needs forty points less of a
  # name than one carrying nothing, and a threshold applied to the name alone
  # would drop exactly the hits the identifiers exist to find.
  #
  # ### Weights
  #
  # Every number this stage uses is in Weights, with a default and the reason
  # for it. A host that disagrees passes its own, per call or in
  # configuration:
  #
  #   ActiveSanction.configure { |c| c.scorer_weights = { dob_conflict: -20.0 } }
  #
  # Changing them changes what a past decision would score today, so a stored
  # decision records the weights it was made under -- which is #33's job, and
  # the reason this stage takes them as an argument rather than reading a
  # global halfway down a call stack.
  module Scorer
    extend T::Sig
    extend T::Helpers

    # Called as `Scorer.threshold!`, which is where `raise` comes from.
    requires_ancestor { Kernel }

    # The scale everything here works in. Similarity is 0..1; the conversion
    # happens once, in NameScore.
    SCALE = T.let(100.0, Float)

    module_function

    # The best score this entity can make against this subject, or nil when
    # there is nothing to score: an entity of the wrong type, or one whose
    # every name folds away to nothing.
    #
    # Takes an Entity or an Index::Candidate, since the caller in front of
    # this holds candidates and the caller in a console holds entities.
    #
    # `weights:` defaults to the configured set. It is read once per call
    # rather than per name, so a configuration changed mid-call cannot produce
    # a score that is half one set of weights and half another.
    #
    # `threshold:` is on the same 0..100 scale as the score. A result at or
    # above it is exactly the result the same call without one returns; below
    # it, nil. See the note on cost below for what it buys and why the caller
    # in front of this should always pass one.
    sig do
      params(subject: Subject, candidate: T.untyped, weights: T.untyped, threshold: Numeric)
        .returns(T.nilable(Result)).checked(:tests)
    end
    def call(subject, candidate, weights: nil, threshold: 0.0)
      entity = candidate.is_a?(Entity) ? candidate : candidate.entity
      return nil unless comparable?(subject, entity)

      settings = Weights.build(weights || ActiveSanction.config.scorer_weights)
      cutoff = threshold!(threshold)
      # The secondary identifiers first, though they are reported second: they
      # cost no string comparison, and what they come to is what the name has
      # to beat. A subject carrying the right passport number needs 40 points
      # less of a name than one carrying nothing.
      adjustments = Adjustments.call(subject, entity, settings)
      best = best_name(subject, entity, settings, floor(cutoff, adjustments))
      return nil if best.nil?

      name, form, reasons = best
      result = Result.new(entity: entity, name: name, form: form,
                          explanation: bounded(reasons + adjustments))
      result.score < cutoff ? nil : result
    end

    # The least a name can score and still leave the entity able to reach the
    # cutoff, given what the identifiers already came to.
    #
    # A cutoff of nothing is nothing, and the guard is not cosmetic: a stack
    # of penalties can put a total below zero, where the floor clamps it back
    # up, so `cutoff - adjustments` would demand a name score of 47 to reach a
    # threshold of 0 and quietly return no result at all.
    sig { params(cutoff: Float, adjustments: T::Array[Reason]).returns(Float).checked(:tests) }
    def floor(cutoff, adjustments)
      return 0.0 unless cutoff.positive?

      [cutoff - adjustments.sum(&:contribution), 0.0].max
    end

    # A threshold as a Float, or a QueryError.
    #
    # This is the boundary where the library changes units: everything below
    # this stage is a similarity on a 0..1 scale and everything above it is a
    # percentage. Similarity checks for the mistake in one direction -- an 85
    # arriving where 0.85 was meant, which would reject every pair and read as
    # "nothing matched" -- and this checks the other, an argument outside
    # 0..100 at all.
    #
    # What it deliberately cannot catch is a `0.75` meant as three-quarters,
    # because 0.75 is a legitimate threshold and there is no way to tell the
    # two apart. That mistake is the survivable one: a threshold far too low
    # returns everything the index found rather than nothing, which is noisy
    # and visible. It is the opposite error that hides a hit.
    sig { params(threshold: Numeric).returns(Float).checked(:tests) }
    def threshold!(threshold)
      cutoff = threshold.to_f
      return cutoff if cutoff.between?(0.0, SCALE)

      raise QueryError,
            "threshold must be between 0 and 100, got #{threshold.inspect} -- " \
            "a screening score is a percentage, not a similarity on a 0..1 scale"
    end

    # Whether this entity is the kind of thing the subject asked about. A
    # subject with no type asks about everything.
    sig { params(subject: Subject, entity: Entity).returns(T::Boolean).checked(:tests) }
    def comparable?(subject, entity) = subject.type.nil? || subject.type == entity.type

    # One of an entity's names, as far as this stage takes it: the published
    # name, its folded form, and the reasons that name produced.
    Scored = T.type_alias { [Name, Normalizer::Form, T::Array[Reason]] }

    # Whichever of the entity's names scores highest once its own quality
    # penalty is applied, or nil when none of them survives the fold or
    # reaches the threshold.
    #
    # Each name is scored against the best one found so far as well as against
    # the caller's threshold, since only the best is going to be reported. On
    # an entity with a dozen aliases that is most of the work skipped: the
    # second name only has to be compared closely enough to establish that it
    # does not beat the first.
    #
    # Equal is not better, so a tie stays with the name the publisher listed
    # first -- see the note on determinism above.
    sig do
      params(subject: Subject, entity: Entity, weights: Weights, threshold: Float)
        .returns(T.nilable(Scored)).checked(:tests)
    end
    def best_name(subject, entity, weights, threshold)
      best = T.let(nil, T.nilable(Scored))
      highest = T.let(-Float::INFINITY, Float)
      entity.names.each do |name|
        # A name that folds away to nothing cannot be compared -- see
        # Normalizer::Form#empty?, and Index, which skips the same names.
        form = Normalizer.call(name, type: entity.type)
        next if form.empty?

        penalty = name.low_quality? ? weights.low_quality_alias : 0.0
        cutoff = [threshold, highest].max - penalty
        score = NameScore.call(subject.form, form, weights, threshold: cutoff.clamp(0.0, SCALE))
        # A zero under a real cutoff means "could not reach it", not "scored
        # nothing" -- and the two have to be told apart before the comparison
        # below, which would otherwise take a name that was never measured.
        next if score.zero? && cutoff.positive?
        next unless score + penalty > highest

        highest = score + penalty
        best = [name, form, reasons(name, score, penalty)]
      end
      best
    end

    # What one name is worth: the blended similarity, and the penalty for a
    # name its own publisher graded unreliable.
    sig do
      params(name: Name, score: Float, penalty: Float).returns(T::Array[Reason]).checked(:tests)
    end
    def reasons(name, score, penalty)
      reasons = [Reason.new(factor: :name, detail: matched(name), contribution: score)]
      return reasons if penalty.zero?

      reasons << Reason.new(factor: :alias_quality, contribution: penalty,
                            detail: "#{name.value.inspect} is graded a low-quality alias by its publisher")
    end

    sig { params(name: Name).returns(String).checked(:tests) }
    def matched(name)
      kind = name.primary? ? "primary name" : "alias"
      suffix = name.primary? ? "" : " (#{name.kind})"
      "matched #{kind} #{name.value.inspect}#{suffix}"
    end

    # Keeps the score inside 0..100 without letting the explanation stop
    # explaining it. A cap that silently swallowed 12 points would leave a
    # reviewer adding a column of figures that does not reach the number
    # printed above it, so the correction is itself a reason.
    #
    # It fires rarely -- a decisive identifier boost on an already-strong name
    # is the usual way -- and when it does, the fact that a score reached its
    # ceiling with points to spare is worth seeing.
    sig { params(reasons: T::Array[Reason]).returns(T::Array[Reason]).checked(:tests) }
    def bounded(reasons)
      total = reasons.sum(&:contribution).round(Reason::PRECISION)
      capped = total.clamp(0.0, SCALE)
      return reasons if capped == total

      reasons + [Reason.new(factor: :clamp, contribution: capped - total,
                            detail: "#{total.round(Reason::PRECISION)} #{capped.zero? ? "raised" : "capped"} " \
                                    "to #{capped}")]
    end
  end
end

require "active_sanction/scorer/weights"
require "active_sanction/scorer/reason"
require "active_sanction/scorer/subject"
require "active_sanction/scorer/name_score"
require "active_sanction/scorer/adjustments"
require "active_sanction/scorer/result"
