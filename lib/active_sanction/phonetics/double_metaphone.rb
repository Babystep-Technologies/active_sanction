# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  module Phonetics
    # Double Metaphone, as Lawrence Philips published it. Stage 3c of the
    # matching pipeline.
    #
    #   ActiveSanction::Phonetics::DoubleMetaphone.call("mohammed")  # => ["MHMT"]
    #   ActiveSanction::Phonetics::DoubleMetaphone.call("muhammad")  # => ["MHMT"]
    #   ActiveSanction::Phonetics::DoubleMetaphone.call("jusuf")     # => ["JSF", "ASF"]
    #   ActiveSanction::Phonetics::DoubleMetaphone.call("yusuf")     # => ["ASF"]
    #
    #   DoubleMetaphone.match?("qaddafi", "gaddafi")                 # => true
    #
    # ### One word, not one name
    #
    # Every method here takes a single folded token. A name is keyed token by
    # token, which is what the index (#31) needs -- a bucket per token is what
    # makes a query's tokens findable -- and it is the reason the algorithm's
    # multi-word rules are not exercised here. Philips' table has rules keyed
    # on `VAN `, `VON `, `SAN ` and `MAC C`, and they need the following space
    # to fire; a token handed over on its own never has one. The trade is
    # deliberate: those rules cover a handful of surname prefixes, and keying
    # per token is what the whole stage is for.
    #
    # ### What the two keys are
    #
    # Philips returns a primary and an alternate, and the alternate is the
    # point. It is not a fallback or a fuzzier version of the same key: it is
    # the second way the word is pronounced when a spelling is genuinely
    # ambiguous about its language of origin. `JUSUF` is `JSF` read as
    # English and `ASF` read as Slavic, and `YUSUF` is `ASF` outright. Two
    # names match phonetically when *any* of their keys agree, which is what
    # `match?` does and what an index has to do -- comparing primaries alone
    # would miss exactly the transliteration pairs this stage exists for.
    #
    # `call` returns one key or two: the alternate is dropped when it repeats
    # the primary, so a caller indexing every key never writes the same bucket
    # twice.
    #
    # ### Keys are not truncated
    #
    # Philips' 1990 Metaphone truncated to four characters and the article
    # version of Double Metaphone kept that; the reference C++ raised the cap
    # to 32, which no name reaches. Nothing is truncated here. A caller who
    # wants the classic four-character key takes `key[0, 4]` -- the keys are
    # built left to right, so a prefix of the full key is exactly what a
    # truncating implementation would have produced.
    #
    # The choice matters to the index and not much else: four characters put
    # `GAZPROM` and `GAZPROMBANK` in one bucket, which is good recall and
    # poor precision, and #31 can decide that for itself. Throwing the
    # characters away here would not leave it the choice.
    #
    # ### Latin script only, and it is a mitigation rather than a fix
    #
    # This is a table of English, Germanic, Slavic, Romance and Greek
    # spelling conventions written in the Latin alphabet. Handed anything
    # else it produces no key at all: every character that is not an ASCII
    # letter is skipped, so `путин` and `محمد` come back as `[]` and are not
    # phonetically indexable. That is the same recall limitation Normalizer
    # states about non-Latin script, in the same place in the pipeline, and
    # for the same reason -- these lists publish a romanized name alongside
    # the original, and the romanized one is what an English-language query
    # finds.
    #
    # Within Latin script it is a mitigation for transliteration variance and
    # not a substitute for real transliteration. It collapses `MOHAMMED`,
    # `MUHAMMAD`, `MOHAMAD` and `MOHAMED` onto `MHMT`, and `QADDAFI`,
    # `GADDAFI`, `KADAFI` and `QADHAFI` onto `KTF`, which is the variance
    # these lists actually contain. It also collapses names that are not the
    # same name at all: `HUSSEIN`, `HASSAN` and `HASAN` are one key, and so
    # are `PUTIN`, `PATTON` and `BUTTON`. So a phonetic agreement is a signal
    # the scorer (#32) weighs, never a match on its own. It is deliberately
    # generous, in a pipeline whose other columns are not.
    #
    # And it misses things the other columns catch. `ZAWAHIRI` keys as `SHR`
    # and `ZAWAHRI` as `SR`, because dropping the `I` moves the `H` to where
    # the rules make it silent -- a pair Levenshtein scores 0.85. Neither
    # direction is a defect to be tuned out. Four columns exist because each
    # of them is wrong somewhere the others are right.
    #
    # ### What it costs, and where
    #
    # About 30 us a word without a JIT and 17 with one, which is a whole index
    # build's worth of keys -- 46,000 names, call it 138,000 tokens -- in
    # around four seconds, and a three-token query's worth in under a tenth of
    # a millisecond. The cost lands on the build rather than on the query,
    # which is the right end for it: a key is written once per sync and read
    # on every screening call after it.
    #
    # Most of that is the string slicing the rules are written in, and it
    # stays. Comparing without allocating would mean rewriting a hundred
    # published rules into index arithmetic nobody can check against the
    # source, to save three seconds of a job that runs when a government
    # publishes a file.
    #
    # ### Transcribed, not reimplemented
    #
    # The rules below are a transcription of Philips' reference C++ -- the
    # 2000 C/C++ Users Journal algorithm, in the widely mirrored
    # `double_metaphone.cc` -- kept in its order, with its section comments,
    # so that the two can be read side by side. That is the only way anybody
    # can check this file: the rules are a hundred-odd special cases about
    # spelling that cannot be derived from anything, only compared against
    # the source they came from. The specs compare the output against that
    # implementation's own, over a corpus of several thousand words.
    #
    # Three things in that transcription are deliberate departures, all of
    # them faithful to the C rather than to the ports that are easier to find:
    #
    # 1. A character outside `A-Z` advances one position and contributes
    #    nothing, which is the C's `default:`. Several widely used ports
    #    instead re-apply the previous character's rule, so `putin2` keys as
    #    `PTNN`. Folded names carry digits.
    # 2. The word is padded with spaces, as the C pads it. Rules that look
    #    for a trailing space -- the French `IER ` ending among them -- fire
    #    at the end of a word, which is where they were meant to fire.
    # 3. `-UMB` is read from the character before the `M`, so `dumb` keys as
    #    `TM` rather than `TMP`.
    class DoubleMetaphone
      extend T::Sig

      # What one letter's rule decides: what to append to each key, and how
      # far to move. An empty string appends nothing, which is how the C
      # writes a code that exists on one side only (`primary += ""`).
      Step = T.type_alias { [String, String, Integer] }

      # `Y` is a vowel here. It is in Philips' `IsVowel`, and dropping it
      # would change the initial-vowel rule that `YUSUF` depends on.
      VOWELS = T.let(%w[A E I O U Y].freeze, T::Array[String])

      # The first letter of these pairs is not pronounced: `KNIGHT`, `WRIGHT`,
      # `PSALM`.
      SILENT_STARTERS = T.let(%w[GN KN PN WR PS].freeze, T::Array[String])

      # Five, as the reference pads, and semantic rather than defensive --
      # see the class notes. Every lookahead in the table stays inside it.
      PADDING = T.let("     ", String)

      # A word's phonetic keys: one, or two when the spelling is ambiguous,
      # and none at all when it holds no Latin letters.
      sig { params(word: String).returns(T::Array[String]).checked(:tests) }
      def self.call(word) = new(word).keys

      # Whether two words agree on any key. The cross comparisons are the
      # reason this is a method rather than an `==`: `JUSUF` and `YUSUF` agree
      # on `JUSUF`'s alternate, and a caller comparing primaries would miss it.
      #
      # A word with no keys agrees with nothing, itself included. Two names
      # written in a script this table cannot read are not evidence of
      # anything, and an empty key that matched every other empty key would
      # make every Cyrillic name a phonetic hit against every other one.
      sig { params(left: String, right: String).returns(T::Boolean).checked(:tests) }
      def self.match?(left, right) = call(left).intersect?(call(right))

      # The primary key, or an empty string for a word with no Latin letters.
      sig { returns(String).checked(:tests) }
      attr_reader :primary

      # The second pronunciation, or nil when the word has only one. Nil
      # rather than a repeat of the primary, so that "this word is ambiguous"
      # and "this word is not" are different answers.
      sig { returns(T.nilable(String)).checked(:tests) }
      attr_reader :alternate

      # Every distinct non-empty key, primary first. This is what an index
      # writes and what `match?` intersects.
      sig { returns(T::Array[String]).checked(:tests) }
      attr_reader :keys

      # Encoding happens here, once, and the result is frozen: a key is a
      # pure function of the word, and the same word is keyed thousands of
      # times during an index build.
      #
      # Uppercasing is not a fold. The rule table is written in capitals and
      # this is the alphabet it reads; the fold that decides what a name *is*
      # happened once already, in Normalizer, for both sides of every
      # comparison.
      sig { params(word: String).void.checked(:tests) }
      def initialize(word)
        upper = word.to_s.upcase
        @buffer = T.let("#{upper}#{PADDING}", String)
        @last = T.let(upper.length - 1, Integer)
        @slavo_germanic = T.let(slavo_germanic?(upper), T::Boolean)
        @position = T.let(0, Integer)
        @primary = T.let(+"", String)
        @secondary = T.let(+"", String)
        encode
        @primary = -@primary
        @secondary = -@secondary
        @alternate = T.let(@secondary == @primary ? nil : presence(@secondary), T.nilable(String))
        @keys = T.let([@primary, @secondary].reject(&:empty?).uniq.freeze, T::Array[String])
        freeze
      end

      sig { returns(String) }
      def inspect = "#<#{self.class} #{@keys.inspect}>"

      private

      # The main loop. Philips' runs until both keys reach a length cap; this
      # one runs to the end of the word, for the reason the class notes give.
      sig { void }
      def encode
        skip_silent_start
        while @position <= @last
          primary, secondary, advance = rule
          @primary << primary
          @secondary << secondary
          @position += advance
        end
      end

      # The two things that happen before the first letter is read.
      sig { void }
      def skip_silent_start
        @position += 1 if SILENT_STARTERS.include?(span(0, 2))
        return unless at(0) == "X" # initial 'X' is pronounced 'Z', e.g. 'Xavier'

        @primary << "S"
        @secondary << "S"
        @position += 1
      end

      # `W`, `K`, `CZ` or `WITZ` anywhere in the word. Philips uses this to
      # decide whether a spelling is Slavic or Germanic, which changes what
      # `G`, `J`, `S` and `Z` are worth.
      sig { params(word: String).returns(T::Boolean) }
      def slavo_germanic?(word)
        word.include?("W") || word.include?("K") || word.include?("CZ") || word.include?("WITZ")
      end

      # One character of the buffer, or "" past either end. Philips' `GetAt`
      # returns a NUL there and his `StringAt` refuses a start past the end;
      # both compare false against every rule, which is what "" does here.
      sig { params(index: Integer).returns(String) }
      def at(index) = index.negative? ? "" : @buffer[index].to_s

      sig { params(index: Integer, length: Integer).returns(String) }
      def span(index, length) = index.negative? ? "" : @buffer[index, length].to_s

      sig { params(index: Integer).returns(T::Boolean) }
      def vowel?(index) = VOWELS.include?(at(index))

      sig { params(string: String).returns(T.nilable(String)) }
      def presence(string) = string.empty? ? nil : string

      # The same code on both keys.
      sig { params(code: String, advance: Integer).returns(Step) }
      def both(code, advance) = [code, code, advance]

      # A different code on each -- the ambiguity the second key exists for.
      sig { params(primary: String, secondary: String, advance: Integer).returns(Step) }
      def either(primary, secondary, advance) = [primary, secondary, advance]

      # Move on and say nothing: a silent letter, a space, a digit, or a
      # letter this table cannot read.
      sig { params(advance: Integer).returns(Step) }
      def silent(advance) = ["", "", advance]

      sig { returns(Step) }
      def rule
        case at(@position)
        when "A", "E", "I", "O", "U", "Y" then @position.zero? ? both("A", 1) : silent(1)
        when "B" then both("P", at(@position + 1) == "B" ? 2 : 1)
        when "C" then letter_c
        when "D" then letter_d
        when "F" then both("F", at(@position + 1) == "F" ? 2 : 1)
        when "G" then letter_g
        when "H" then letter_h
        when "J" then letter_j
        when "K" then both("K", at(@position + 1) == "K" ? 2 : 1)
        when "L" then letter_l
        when "M" then letter_m
        when "N" then both("N", at(@position + 1) == "N" ? 2 : 1)
        when "P" then letter_p
        when "Q" then both("K", at(@position + 1) == "Q" ? 2 : 1)
        when "R" then letter_r
        when "S" then letter_s
        when "T" then letter_t
        when "V" then both("F", at(@position + 1) == "V" ? 2 : 1)
        when "W" then letter_w
        when "X" then letter_x
        when "Z" then letter_z
        else silent(1)
        end
      end

      # 'C' -- around a hundred contexts, which is what the algorithm is
      # famous for.
      sig { returns(Step) }
      def letter_c
        return both("K", 2) if germanic_ach?
        return both("S", 2) if @position.zero? && span(@position, 6) == "CAESAR" # 'caesar'
        return both("K", 2) if span(@position, 4) == "CHIA" # italian 'chianti'
        return letter_ch if span(@position, 2) == "CH"
        return either("S", "X", 2) if span(@position, 2) == "CZ" && span(@position - 2, 4) != "WICZ" # 'czerny'
        return both("X", 3) if span(@position + 1, 3) == "CIA" # 'focaccia'
        return letter_cc if span(@position, 2) == "CC" && !(@position == 1 && at(0) == "M") # not 'McClellan'
        return both("K", 2) if %w[CK CG CQ].include?(span(@position, 2))
        return letter_ci if %w[CI CE CY].include?(span(@position, 2))

        both("K", trailing_c_advance)
      end

      # Various germanic, e.g. 'bacher', 'macher'.
      sig { returns(T::Boolean) }
      def germanic_ach?
        @position > 1 && !vowel?(@position - 2) && span(@position - 1, 3) == "ACH" &&
          at(@position + 2) != "I" &&
          (at(@position + 2) != "E" || %w[BACHER MACHER].include?(span(@position - 2, 6)))
      end

      sig { returns(Step) }
      def letter_ch
        return either("K", "X", 2) if @position.positive? && span(@position, 4) == "CHAE" # find 'michael'
        return both("K", 2) if greek_ch? || germanic_ch?
        return both("X", 2) if @position.zero?
        return both("K", 2) if span(0, 2) == "MC" # e.g. 'McHugh'

        either("X", "K", 2)
      end

      # Greek roots, e.g. 'chemistry', 'chorus'.
      sig { returns(T::Boolean) }
      def greek_ch?
        @position.zero? &&
          (%w[HARAC HARIS].include?(span(@position + 1, 5)) ||
            %w[HOR HYM HIA HEM].include?(span(@position + 1, 3))) &&
          span(0, 5) != "CHORE"
      end

      # Germanic, greek, or otherwise 'ch' for 'kh' sound.
      sig { returns(T::Boolean) }
      def germanic_ch?
        ["VAN ", "VON "].include?(span(0, 4)) || span(0, 3) == "SCH" ||
          # 'architect' but not 'arch', 'orchestra', 'orchid'
          %w[ORCHES ARCHIT ORCHID].include?(span(@position - 2, 6)) ||
          %w[T S].include?(at(@position + 2)) ||
          ((%w[A O U E].include?(at(@position - 1)) || @position.zero?) &&
            # e.g. 'wachtler', 'wechsler', but not 'tichner'
            ["L", "R", "N", "M", "B", "H", "F", "V", "W", " "].include?(at(@position + 2)))
      end

      # Double 'C'.
      sig { returns(Step) }
      def letter_cc
        # 'bellocchio' but not 'bacchus'
        return both("K", 2) unless %w[I E H].include?(at(@position + 2)) && span(@position + 2, 2) != "HU"
        # 'accident', 'accede', 'succeed'
        return both("KS", 3) if (@position == 1 && at(0) == "A") || %w[UCCEE UCCES].include?(span(@position - 1, 5))

        both("X", 3) # 'bacci', 'bertucci', other italian
      end

      sig { returns(Step) }
      def letter_ci
        # italian vs. english
        return either("S", "X", 2) if %w[CIO CIE CIA].include?(span(@position, 3))

        both("S", 2)
      end

      sig { returns(Integer) }
      def trailing_c_advance
        return 3 if [" C", " Q", " G"].include?(span(@position + 1, 2)) # 'mac caffrey', 'mac gregor'
        return 2 if %w[C K Q].include?(at(@position + 1)) && !%w[CE CI].include?(span(@position + 1, 2))

        1
      end

      sig { returns(Step) }
      def letter_d
        if span(@position, 2) == "DG"
          return %w[I E Y].include?(at(@position + 2)) ? both("J", 3) : both("TK", 2) # 'edge' / 'edgar'
        end
        return both("T", 2) if %w[DT DD].include?(span(@position, 2))

        both("T", 1)
      end

      sig { returns(Step) }
      def letter_g
        return letter_gh if at(@position + 1) == "H"
        return letter_gn if at(@position + 1) == "N"
        return either("KL", "L", 2) if span(@position + 1, 2) == "LI" && !@slavo_germanic # 'tagliaro'
        return either("K", "J", 2) if initial_soft_g? || soft_ger?
        return italian_g if %w[E I Y].include?(at(@position + 1)) || %w[AGGI OGGI].include?(span(@position - 1, 4))

        both("K", at(@position + 1) == "G" ? 2 : 1)
      end

      sig { returns(Step) }
      def letter_gh
        return both("K", 2) if @position.positive? && !vowel?(@position - 1)
        # 'ghislane', 'ghiradelli'
        return both(at(@position + 2) == "I" ? "J" : "K", 2) if @position.zero?
        # Parker's rule (with some further refinements), e.g. 'hugh'
        return silent(2) if parkers_rule?
        # e.g. 'laugh', 'McLaughlin', 'cough', 'gough', 'rough', 'tough'
        return both("F", 2) if @position > 2 && at(@position - 1) == "U" && %w[C G L R T].include?(at(@position - 3))
        return both("K", 2) if @position.positive? && at(@position - 1) != "I"

        silent(2)
      end

      sig { returns(T::Boolean) }
      def parkers_rule?
        (@position > 1 && %w[B H D].include?(at(@position - 2))) ||
          (@position > 2 && %w[B H D].include?(at(@position - 3))) || # e.g. 'bough'
          (@position > 3 && %w[B H].include?(at(@position - 4))) # e.g. 'broughton'
      end

      sig { returns(Step) }
      def letter_gn
        return either("KN", "N", 2) if @position == 1 && vowel?(0) && !@slavo_germanic
        # not e.g. 'cagney'
        return either("N", "KN", 2) if span(@position + 2, 2) != "EY" && at(@position + 1) != "Y" && !@slavo_germanic

        both("KN", 2)
      end

      # -ges-, -gep-, -gel-, -gie- at beginning.
      sig { returns(T::Boolean) }
      def initial_soft_g?
        @position.zero? &&
          (at(@position + 1) == "Y" ||
            %w[ES EP EB EL EY IB IL IN IE EI ER].include?(span(@position + 1, 2)))
      end

      # -ger-, -gy-.
      sig { returns(T::Boolean) }
      def soft_ger?
        (span(@position + 1, 2) == "ER" || at(@position + 1) == "Y") &&
          !%w[DANGER RANGER MANGER].include?(span(0, 6)) &&
          !%w[E I].include?(at(@position - 1)) &&
          !%w[RGY OGY].include?(span(@position - 1, 3))
      end

      # Italian, e.g. 'biaggi'.
      sig { returns(Step) }
      def italian_g
        # obvious germanic
        return both("K", 2) if ["VAN ", "VON "].include?(span(0, 4)) || span(0, 3) == "SCH" ||
                               span(@position + 1, 2) == "ET"
        # always soft if french ending
        return both("J", 2) if span(@position + 1, 4) == "IER "

        either("J", "K", 2)
      end

      # Only keep 'H' first, or between two vowels. Also takes care of 'HH'.
      sig { returns(Step) }
      def letter_h
        return both("H", 2) if (@position.zero? || vowel?(@position - 1)) && vowel?(@position + 1)

        silent(1)
      end

      sig { returns(Step) }
      def letter_j
        return spanish_j if span(@position, 4) == "JOSE" || span(0, 4) == "SAN " # 'jose', 'san jacinto'

        advance = at(@position + 1) == "J" ? 2 : 1 # it could happen!
        return either("J", "A", advance) if @position.zero? # Yankelovich/Jankelowicz
        # spanish pronunciation of e.g. 'bajador'
        return either("J", "H", advance) if vowel?(@position - 1) && !@slavo_germanic &&
                                            %w[A O].include?(at(@position + 1))
        return either("J", "", advance) if @position == @last
        return both("J", advance) if !%w[L T K S N M B Z].include?(at(@position + 1)) &&
                                     !%w[S K L].include?(at(@position - 1))

        silent(advance)
      end

      sig { returns(Step) }
      def spanish_j
        return both("H", 1) if (@position.zero? && at(@position + 4) == " ") || span(0, 4) == "SAN "

        either("J", "H", 1)
      end

      sig { returns(Step) }
      def letter_l
        return both("L", 1) unless at(@position + 1) == "L"
        # spanish e.g. 'cabrillo', 'gallegos'
        return either("L", "", 2) if spanish_ll?

        both("L", 2)
      end

      sig { returns(T::Boolean) }
      def spanish_ll?
        (@position == @last - 2 && %w[ILLO ILLA ALLE].include?(span(@position - 1, 4))) ||
          ((%w[AS OS].include?(span(@last - 1, 2)) || %w[A O].include?(at(@last))) &&
            span(@position - 1, 4) == "ALLE")
      end

      # 'dumb', 'thumb': the 'B' is silent, so the 'M' consumes it.
      sig { returns(Step) }
      def letter_m
        umb = span(@position - 1, 3) == "UMB" && (@position + 1 == @last || span(@position + 2, 2) == "ER")

        both("M", umb || at(@position + 1) == "M" ? 2 : 1)
      end

      sig { returns(Step) }
      def letter_p
        return both("F", 2) if at(@position + 1) == "H"

        # also account for 'campbell', 'raspberry'
        both("P", %w[P B].include?(at(@position + 1)) ? 2 : 1)
      end

      sig { returns(Step) }
      def letter_r
        advance = at(@position + 1) == "R" ? 2 : 1
        # french e.g. 'rogier', but exclude 'hochmeier'
        french = @position == @last && !@slavo_germanic &&
                 span(@position - 2, 2) == "IE" && !%w[ME MA].include?(span(@position - 4, 2))

        french ? either("", "R", advance) : both("R", advance)
      end

      sig { returns(Step) }
      def letter_s
        return silent(1) if %w[ISL YSL].include?(span(@position - 1, 3)) # 'island', 'isle', 'carlisle'
        return either("X", "S", 1) if @position.zero? && span(@position, 5) == "SUGAR"
        return letter_sh if span(@position, 2) == "SH"
        return italian_s if %w[SIO SIA].include?(span(@position, 3)) || span(@position, 4) == "SIAN"
        # german & anglicisations: 'smith' matches 'schmidt', 'snider' matches 'schneider'
        return either("S", "X", at(@position + 1) == "Z" ? 2 : 1) if germanic_s?
        return letter_sc if span(@position, 2) == "SC"

        trailing_s
      end

      sig { returns(Step) }
      def letter_sh
        # germanic
        return both("S", 2) if %w[HEIM HOEK HOLM HOLZ].include?(span(@position + 1, 4))

        both("X", 2)
      end

      # Italian & armenian.
      sig { returns(Step) }
      def italian_s
        @slavo_germanic ? both("S", 3) : either("S", "X", 3)
      end

      sig { returns(T::Boolean) }
      def germanic_s?
        (@position.zero? && %w[M N L W].include?(at(@position + 1))) || at(@position + 1) == "Z"
      end

      sig { returns(Step) }
      def letter_sc
        return schlesingers_rule if at(@position + 2) == "H"
        return both("S", 3) if %w[I E Y].include?(at(@position + 2))

        both("SK", 3)
      end

      sig { returns(Step) }
      def schlesingers_rule
        # dutch origin, e.g. 'school', 'schooner'
        if %w[OO ER EN UY ED EM].include?(span(@position + 3, 2))
          # 'schermerhorn', 'schenker'
          return %w[ER EN].include?(span(@position + 3, 2)) ? either("X", "SK", 3) : both("SK", 3)
        end
        return either("X", "S", 3) if @position.zero? && !vowel?(3) && at(3) != "W"

        both("X", 3)
      end

      sig { returns(Step) }
      def trailing_s
        advance = %w[S Z].include?(at(@position + 1)) ? 2 : 1
        # french e.g. 'resnais', 'artois'
        french = @position == @last && %w[AI OI].include?(span(@position - 2, 2))

        french ? either("", "S", advance) : both("S", advance)
      end

      sig { returns(Step) }
      def letter_t
        return both("X", 3) if span(@position, 4) == "TION"
        return both("X", 3) if %w[TIA TCH].include?(span(@position, 3))
        return letter_th if span(@position, 2) == "TH" || span(@position, 3) == "TTH"

        both("T", %w[T D].include?(at(@position + 1)) ? 2 : 1)
      end

      sig { returns(Step) }
      def letter_th
        # special case 'thomas', 'thames', or germanic
        return both("T", 2) if %w[OM AM].include?(span(@position + 2, 2)) ||
                               ["VAN ", "VON "].include?(span(0, 4)) || span(0, 3) == "SCH"

        either("0", "T", 2) # yes, zero: the character Philips uses for the 'th' sound
      end

      # 'W' is the one letter whose rules stack: an initial 'WA-' can be
      # scored and then scored again by the ending rule below it, which is
      # why this reads as an accumulator rather than as a chain of returns.
      sig { returns(Step) }
      def letter_w
        return both("R", 2) if span(@position, 2) == "WR"

        primary, secondary = initial_w
        # 'Arnow' should match 'Arnoff'
        return either(primary, "#{secondary}F", 1) if final_w?
        # polish e.g. 'filipowicz'
        return either("#{primary}TS", "#{secondary}FX", 4) if %w[WICZ WITZ].include?(span(@position, 4))

        either(primary, secondary, 1) # else skip it
      end

      sig { returns([String, String]) }
      def initial_w
        return ["", ""] unless @position.zero? && (vowel?(@position + 1) || span(@position, 2) == "WH")
        # 'Wasserman' should match 'Vasserman'; 'Uomo' should match 'Womo'
        return %w[A F] if vowel?(@position + 1)

        %w[A A]
      end

      sig { returns(T::Boolean) }
      def final_w?
        (@position == @last && vowel?(@position - 1)) ||
          %w[EWSKI EWSKY OWSKI OWSKY].include?(span(@position - 1, 5)) ||
          span(0, 3) == "SCH"
      end

      sig { returns(Step) }
      def letter_x
        advance = %w[C X].include?(at(@position + 1)) ? 2 : 1
        # french e.g. 'breaux'
        french = @position == @last &&
                 (%w[IAU EAU].include?(span(@position - 3, 3)) || %w[AU OU].include?(span(@position - 2, 2)))

        french ? silent(advance) : both("KS", advance)
      end

      sig { returns(Step) }
      def letter_z
        return both("J", 2) if at(@position + 1) == "H" # chinese pinyin e.g. 'zhao'

        advance = at(@position + 1) == "Z" ? 2 : 1
        return either("S", "TS", advance) if %w[ZO ZI ZA].include?(span(@position + 1, 2)) ||
                                             (@slavo_germanic && @position.positive? && at(@position - 1) != "T")

        both("S", advance)
      end
    end
  end
end
