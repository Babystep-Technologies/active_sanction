# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "digest"

module ActiveSanction
  module Sources
    class CanadaSema < Base
      # The identity Canada does not publish, derived so that the same record
      # in two syncs is the same record.
      #
      #   SourceRef.for(country: "Russia / Russie", schedule: "1, Part 1",
      #                 item: "1114", name: "Kirill Alekseevich MORDASHOV")
      #
      # ### Why anything has to be derived at all
      #
      # Global Affairs publishes no id. What it publishes is a citation --
      # which regulation, which schedule, which item -- and #35 diffs two syncs
      # by comparing records under their ids, so without one every sync reports
      # the entire list as removed and re-added, and a diff that says
      # everything changed says nothing at all.
      #
      # ### What goes into it, and the one part that is not obvious
      #
      # The citation alone -- country, schedule, item -- is already unique
      # across all 5,690 published records, so on the face of it the name is
      # redundant. It is in the hash anyway, because of what happens when a
      # schedule is amended.
      #
      # Item numbers are positions in a list, not identifiers: delete item 5
      # from a schedule and everything after it moves up one. Hashing the
      # citation alone would then hand item 6's old id to the person who used
      # to be item 7, and the diff would report that one person quietly changed
      # their name -- which is the same shape as a correction and reads as one.
      # With the name in the hash, that amendment reports as a removal and an
      # addition, which is noisier and true.
      #
      # The cost runs the other way: correcting a typo in a published name
      # re-ids that record, so a spelling fix reads as one person leaving and
      # another arriving. Churn in a diff is a nuisance; one id covering two
      # different people is a screening failure, so the trade goes this way.
      #
      # ### Stability
      #
      # The digest is taken over the normalized parts joined by a separator
      # that cannot occur in any of them, so an id depends on nothing but the
      # record's own bytes -- not on iteration order, not on position in the
      # file, not on the run. Changing NORMALIZE, SEPARATOR or LENGTH re-ids
      # every Canadian record ever stored, which makes each of them a versioned
      # decision rather than a cleanup.
      module SourceRef
        extend T::Sig

        # Case and the publisher's stray padding are noise: `Venezuela ` and
        # `1, Part 1 ` are published both with and without their trailing
        # space, and a record must not change id when a space does. Nothing
        # further is folded -- not punctuation, not diacritics -- because every
        # additional fold is another way for two genuinely different records to
        # collide into one id.
        NORMALIZE = T.let(/[[:space:]]+/, Regexp)

        # A NUL cannot appear in XML character data at all, so no two different
        # sets of field values can be re-parenthesized into each other:
        # ("a", "bc") and ("ab", "c") hash apart.
        SEPARATOR = T.let("\u0000", String)

        # 64 bits of SHA-256. Across 5,690 records the chance of any collision
        # at all is about one in a trillion, and an id this length stays
        # readable in a log line and in the report that quotes it.
        LENGTH = T.let(16, Integer)

        module_function

        sig { params(country: T.untyped, schedule: T.untyped, item: T.untyped, name: T.untyped).returns(String) }
        def for(country:, schedule:, item:, name:)
          parts = [country, schedule, item, name].map { |part| normalize(part) }
          -T.must(Digest::SHA256.hexdigest(parts.join(SEPARATOR))[0, LENGTH])
        end

        sig { params(value: T.untyped).returns(String) }
        def normalize(value) = value.to_s.split(NORMALIZE).join(" ").downcase
      end
    end
  end
end
