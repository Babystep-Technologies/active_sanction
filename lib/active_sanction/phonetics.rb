# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  # What a name sounds like, as a key two spellings of it can share. Stage 3c
  # of the matching pipeline.
  #
  #   ActiveSanction::Phonetics::DoubleMetaphone.call("qaddafi")   # => ["KTF"]
  #   ActiveSanction::Phonetics::DoubleMetaphone.call("gaddafi")   # => ["KTF"]
  #
  # ### Why this is not in Similarity
  #
  # Because a key is not a score. Everything in Similarity answers "how close
  # are these two names" with a number between 0 and 1, and the whole of that
  # module's contract -- symmetric, never rounded, `threshold:` as an
  # optimization, a `ceiling` that may never come in under a real score --
  # is about keeping four such numbers comparable enough to blend.
  #
  # This stage answers a different question and gives a different kind of
  # answer: it turns one name into the handful of strings that stand for how
  # it sounds. Two names either share one of those strings or they do not.
  # That is what makes it useful in the two places it is used --
  #
  # - the inverted index (#31) keys on it, so that a query for `GADDAFI`
  #   reaches a record spelled `QADHAFI` at all, which no amount of comparing
  #   would help with if the record is never fetched; and
  # - the scorer (#32) reads it as a bonus on a pair it is already comparing.
  #
  # -- and it is also why it cannot be blended with the other four. A shared
  # key is evidence, at the strength #32 decides. It is never a match on its
  # own: `HSN` is the key for `HUSSEIN`, and equally for `HASSAN`.
  module Phonetics
  end
end

require "active_sanction/phonetics/double_metaphone"
