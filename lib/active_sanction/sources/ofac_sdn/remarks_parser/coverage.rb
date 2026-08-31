# frozen_string_literal: true

module ActiveSanction
  module Sources
    class OfacSdn < Base
      class RemarksParser
        # How much of OFAC's free text the parser understood, accumulated over
        # a whole sync.
        #
        #   coverage = source.remarks_coverage
        #   coverage.percentage   # => 93.4
        #   coverage.to_s         # => "recognized 82943 of 88827 segments (93.4%), 41216 extracted"
        #   coverage.top(3)
        #   # => [["Member of the", 615], ["ICTY indictee.", 45], ["all offices worldwide.", 43]]
        #
        # ### Why a number and not a pass/fail
        #
        # RemarksParser is heuristic against text a government writes for
        # people, and OFAC changes how it writes things without telling
        # anybody. The failure that matters is not a crash -- nothing here
        # raises, and an unread segment is still in the remark -- it is the
        # quiet one, where a re-spelled label stops producing passports for six
        # months and no one notices because the import still succeeds.
        #
        # A percentage recorded on every sync makes that visible: it moves when
        # the file's vocabulary moves. #top is what turns the movement into
        # work, since the shapes that suddenly appear in the unrecognized
        # histogram are the new spellings, ranked by how many records they cost.
        #
        # `recognized` counts a segment matched as prose as well as one that
        # produced a value, because "we know this citation carries no fields"
        # and "we have never seen this" are different states and only the
        # second is actionable. `extracted` counts the second kind alone.
        class Coverage
          # A shape, not a segment: enough leading words to recognize the
          # pattern, with digits masked so that 4,000 distinct tax numbers
          # collapse into one line rather than flooding the histogram.
          SHAPE_WORDS = 3

          attr_reader :segments, :extracted, :recognized, :unknown

          def initialize
            @segments = 0
            @extracted = 0
            @recognized = 0
            @unknown = Hash.new(0)
          end

          # Folds one parsed remark in. Returns self, so a caller can chain it
          # into a fold over the file.
          def record(parsed)
            @segments += parsed.segments.size
            @extracted += parsed.extracted.size
            @recognized += parsed.extracted.size + parsed.prose.size
            parsed.unrecognized.each { |segment| @unknown[shape(segment)] += 1 }
            self
          end

          # 0.0 for an empty run rather than a division by zero: a sync that
          # read no remarks has no coverage to report, and neither perfect nor
          # nil is an honest way to say so.
          def ratio = segments.zero? ? 0.0 : recognized.fdiv(segments)

          def percentage = (ratio * 100).round(1)

          # The unrecognized shapes that cost the most segments, which is where
          # a new label shows up first.
          def top(count = 10) = unknown.sort_by { |shape, tally| [-tally, shape] }.first(count)

          def to_h
            { segments: segments, extracted: extracted, recognized: recognized,
              ratio: ratio, unknown: unknown.size }
          end

          def to_s
            "recognized #{recognized} of #{segments} segments (#{percentage}%), #{extracted} extracted"
          end

          def inspect = "#<#{self.class} #{self}>"

          private

          def shape(segment)
            -segment.split(/\s+/).first(SHAPE_WORDS).join(" ").gsub(/\d/, "#")
          end
        end
      end
    end
  end
end
