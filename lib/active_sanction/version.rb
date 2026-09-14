# typed: strict
# frozen_string_literal: true

module ActiveSanction
  # The gem version, and what CHANGELOG.md is about. Moves under SemVer for a
  # new source adapter, a storage fix or a documentation release -- none of
  # which change what a name scores. MATCHER_VERSION, below, is the one that
  # answers that question.
  VERSION = "1.1.0"

  # Which matching pipeline scored a decision, stamped onto every MatchResult
  # and bumped whenever a change to the normalizer, the index, the similarity
  # algorithms or the scorer could move a score.
  #
  # Deliberately not VERSION. The gem version moves for a new source adapter,
  # a storage fix, a documentation release -- none of which change what a name
  # scores -- and an auditor asking "would this screening come out the same
  # today?" needs the answer to that question rather than a release number
  # that also answers several others. Its companions on the record are the
  # weights and the snapshot checksum; between the three, a past decision is
  # re-derivable.
  MATCHER_VERSION = "1"
end
