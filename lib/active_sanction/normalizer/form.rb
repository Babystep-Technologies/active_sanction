# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/normalizer/dictionary/stoplist"

module ActiveSanction
  class Normalizer
    # A name in both of the forms a screening decision needs: the string the
    # publisher wrote, and the folded string a comparison actually runs
    # against.
    #
    #   form = ActiveSanction::Normalizer.call("O'Brien, Seán")
    #   form.original   # => "O'Brien, Seán"
    #   form.value      # => "o brien sean"
    #   form.tokens     # => ["o", "brien", "sean"]
    #
    #   org = ActiveSanction::Normalizer.call("Rosneft Oil Company", type: :organization)
    #   org.value       # => "rosneft oil"
    #   org.type        # => :organization
    #
    # Both halves travel together because both are needed at different ends of
    # the same query. The scorers (#28, #29) compare `value`; the index (#31)
    # keys on `tokens`; and what a compliance user reads in a hit is
    # `original`, in the government's own capitalization and punctuation. A
    # report that quotes the folded string instead is quoting this library
    # rather than the list, which is not something anyone can take to an
    # examiner.
    #
    # Instances are frozen on construction and compare by value.
    #
    # ### The pipeline
    #
    # Five stages, applied in this order to indexed names and query names
    # alike -- see Normalizer for why that sameness is the whole point -- and
    # a sixth that runs only for a caller who said what kind of entity the
    # name belongs to:
    #
    # 1. **Unicode NFKD.** Decomposes `é` into `e` + combining acute, and folds
    #    the compatibility forms a publisher's export tooling emits: full-width
    #    `ＡＢＣ` becomes `ABC`, `Ⅳ` becomes `IV`, `①` becomes `1`, and the
    #    no-break spaces scattered through the delimited lists become ordinary
    #    ones.
    # 2. **Strip combining marks.** What stage 1 separated is dropped, so
    #    `Bélarus` is `belarus` and `Müller` is `muller`. Arabic gets the same
    #    treatment for free and wants it: the harakat are optional in writing,
    #    so one publisher's `مُحَمَّد` and another's `محمد` have to fold together, and
    #    `أ` decomposes to a bare alef rather than staying a third spelling of
    #    the same first letter.
    # 3. **Casefold**, Unicode-aware: `String#downcase(:fold)` rather than
    #    `String#downcase`, which is what turns `Straße` into `strasse` instead
    #    of leaving a `ß` that no query will ever be typed with.
    # 3b. **Transliterate the letters NFKD cannot help with** -- see
    #    TRANSLITERATIONS.
    # 4. **Punctuation to spaces**, not to nothing: `Al-Qaida` is `al qaida`
    #    and `O'Brien` is `o brien`. Splitting is the conservative direction.
    #    A hyphen and a space are written interchangeably across these lists,
    #    so joining `Al-Qaida` into `alqaida` would make it unreachable from
    #    the `al qaida` a caller types, while splitting it leaves both sides as
    #    the same two tokens for the token ratios (#29) to work on.
    # 5. **Collapse whitespace and strip**, which is what `tokens` is: the
    #    folded string split on whitespace, with `value` its single-spaced
    #    join.
    # 6. **Drop the tokens that carry no identifying information**, given a
    #    Stoplist: `LTD` and `COMPANY` from an organization, `SHAYKH` from a
    #    person, nothing at all from either without one. Stage 6 is the only
    #    one that depends on something outside the string, which is why it
    #    arrives as an argument -- see Dictionary for what is on the lists and
    #    for the particles they may never touch.
    #
    #    A name that folds away entirely keeps its unstripped tokens. An
    #    organization called "The Company" is a poor name to screen on and a
    #    worse one to index as the empty string, which matches everything or
    #    nothing depending on which scorer sees it first.
    #
    # ### What it deliberately does not do
    #
    # **Non-Latin script is not transliterated.** Cyrillic, Arabic, Han, Kana
    # and Hangul come out of here casefolded and stripped of marks, in their
    # own script. `Путин` does not become `putin`, so a Cyrillic name matches a
    # Cyrillic query and nothing else. That is a real recall limitation, and it
    # is stated rather than papered over.
    #
    # What makes it survivable is that these lists publish a non-Latin name as
    # an additional variant rather than instead of a Latin one -- the UN's
    # ORIGINAL_SCRIPT aliases and Canada's Cyrillic ones both sit on records
    # that carry a romanized name too, which is the one an English-language
    # query finds. Romanization itself is a per-script problem with several
    # competing standards for Cyrillic alone, and guessing at it costs
    # precision everywhere, so v1 does not. Double Metaphone (#30) covers the
    # case this actually leaves open, which is one name romanized two ways.
    #
    # One consequence worth knowing: NFKD decomposes Hangul syllables into
    # jamo, so `김정은` folds to its letters rather than its syllable blocks.
    # Nothing downstream cares -- both sides of a comparison are folded the
    # same way -- but the value is not the string a Korean reader would type.
    class Form
      extend T::Sig

      # Nonspacing and enclosing marks: the diacritics stage 1 separated from
      # their letters. Spacing marks (`Mc`) are deliberately left alone --
      # those are the Indic vowel signs, which are letters in every sense that
      # matters here, and dropping them would fold `का` and `कि` onto the same
      # consonant.
      #
      # @api private
      MARKS = T.let(/[\p{Mn}\p{Me}]/, Regexp)

      # The Latin letters NFKD leaves untouched, because they are letters in
      # their own right rather than a letter wearing a mark: nothing decomposes
      # `ø` into an `o`. Without this table `Bjørn` and `Bjorn` are two
      # different names, which is the same false negative diacritic stripping
      # exists to prevent -- it just happens to affect Scandinavian, Polish,
      # Turkish, Icelandic, Vietnamese and Azerbaijani names rather than French
      # ones.
      #
      # Applied after casefolding, so the table only has to carry lowercase
      # keys. `ß` is absent because casefolding already turns it into `ss`.
      #
      # @api private
      TRANSLITERATIONS = T.let(
        {
          "æ" => "ae", "œ" => "oe", "ø" => "o", "ð" => "d", "þ" => "th",
          "đ" => "d", "ħ" => "h", "ı" => "i", "ł" => "l", "ŀ" => "l",
          "ŋ" => "n", "ŧ" => "t", "ĸ" => "k", "ə" => "e"
        }.freeze,
        T::Hash[String, String]
      )

      # @api private
      TRANSLITERABLE = T.let(Regexp.union(TRANSLITERATIONS.keys), Regexp)

      # Everything that is not a letter, a digit or whitespace, which covers
      # the punctuation and the symbols in one rule and needs no list of
      # dashes and quotation marks to be kept in step with reality.
      #
      # Plus the characters Unicode calls letters and a transliterator uses as
      # punctuation: the spacing modifier letters, U+02B0 to U+02FF (`ʻ ʼ ʹ ʾ
      # ʿ`), and the two glottal stop letters (`ʔ ʕ`). The UN list writes
      # `Sanʻa` and `Qurʼan` with these where OFAC writes a plain apostrophe or
      # nothing at all, and a mark that survives here is a token no query will
      # ever be typed with.
      #
      # @api private
      PUNCTUATION = T.let(/[^[:alnum:][:space:]]|[ʔʕʰ-˿]/, Regexp)

      # The publisher's string, untouched. This is what a hit is reported in.
      sig { returns(String).checked(:tests) }
      attr_reader :original

      # The folded form: lowercase, unmarked, punctuation-free, single-spaced.
      # Empty when the original carried nothing a comparison can use -- see
      # #empty?.
      sig { returns(String).checked(:tests) }
      attr_reader :value

      # `value` split on whitespace. Frozen, and the array the token ratios
      # (#29) and the inverted index (#31) read rather than splitting again per
      # comparison.
      sig { returns(T::Array[String]).checked(:tests) }
      attr_reader :tokens

      # The entity type this name was folded for, or nil when the caller did
      # not say. It is what decides stage 6, and it travels with the form
      # because two folds of the same string under different types are two
      # different answers -- which is also why `value` is part of #==.
      sig { returns(T.nilable(Symbol)).checked(:tests) }
      attr_reader :type

      # Untyped for the reason the rest of the model is: what arrives here is a
      # publisher's text as whatever the parser made of it. Anything that
      # responds to `to_s` works, which includes Name -- `Name#to_s` is its
      # value -- so an indexer can hand over the object it already has.
      #
      # `stoplist` is stage 6, and comes from a Dictionary rather than from
      # here: which tokens carry no information is a property of the entity
      # type and of the lists in force, neither of which the string knows.
      #
      # Building a Form directly skips the cache; Normalizer.call is the entry
      # point everything in the library goes through, and the one that resolves
      # a type into the stoplist for it.
      sig { params(original: T.untyped, stoplist: T.nilable(Dictionary::Stoplist)).void.checked(:tests) }
      def initialize(original, stoplist: nil)
        @original = T.let(-original.to_s, String)
        @type = T.let(stoplist&.type, T.nilable(Symbol))
        @tokens = T.let(fold(@original, stoplist), T::Array[String])
        @value = T.let(-@tokens.join(" "), String)
        freeze
      end

      # True when nothing survived the fold: a name of `"---"`, of punctuation,
      # of an emoji, or of whitespace alone. It happens in real data, and it
      # matters because such a name cannot be indexed and cannot be scored --
      # every comparison against it is meaningless rather than merely bad. The
      # index (#31) skips these; the alternative is a record that matches
      # everything or nothing depending on which scorer sees it first.
      sig { returns(T::Boolean).checked(:tests) }
      def empty? = value.empty?

      sig { returns(String).checked(:tests) }
      def to_s = value

      # Class is part of the comparison to keep #== and #hash agreeing, which
      # is what Hash and Set rely on -- and the index is built out of both.
      #
      # Two forms are equal when they came from the same original and folded
      # to the same value. The second half is not redundant now that stage 6
      # exists: `value` is a pure function of the original *and* the stoplist,
      # so "Rosneft Oil Company" folded as an organization and the same string
      # folded as nothing in particular are two different answers rather than
      # one.
      #
      # Note that this makes two differently-written names that fold to the
      # same string unequal *as forms* while comparing as identical *for
      # matching*, which is the distinction the whole pipeline rests on.
      sig { params(other: T.untyped).returns(T::Boolean).checked(:tests) }
      def ==(other)
        return false unless other.instance_of?(self.class)

        original == other.original && value == other.value
      end
      alias eql? ==

      sig { returns(Integer).checked(:tests) }
      def hash
        [self.class, original, value].hash
      end

      sig { returns(String) }
      def inspect
        "#<#{self.class} #{original.inspect} => #{value.inspect}>"
      end

      private

      # The stages, in the order they have to run in: marks cannot be stripped
      # before NFKD has separated them, the transliteration table only carries
      # the lowercase keys casefolding produces, and the stoplist is written in
      # the tokens the first five stages produce.
      #
      # Stripping every token is treated as stripping none. A name of nothing
      # but legal forms is rare and real -- an organization called "The
      # Company", a vessel whose only alias is its owner's suffix -- and the
      # empty string is the one fold that cannot be scored at all.
      sig do
        params(string: String, stoplist: T.nilable(Dictionary::Stoplist))
          .returns(T::Array[String]).checked(:tests)
      end
      def fold(string, stoplist)
        decomposed = utf8(string).unicode_normalize(:nfkd).gsub(MARKS, "")
        folded = decomposed.downcase(:fold).gsub(TRANSLITERABLE, TRANSLITERATIONS)
        # `&:-@` is String#-@, the deduplicating freeze: 46,000 names share
        # a few thousand distinct tokens between them, and the index holds
        # onto every one of them.
        tokens = folded.gsub(PUNCTUATION, " ").split.map(&:-@).freeze
        return tokens if stoplist.nil?

        kept = stoplist.reject(tokens)
        kept.empty? ? tokens : kept.freeze
      end

      # `unicode_normalize` raises on a string that is not valid UTF-8, and one
      # record's stray byte is not worth failing an entire index build over --
      # a list that will not build is a list nobody is screened against. The
      # bad bytes become U+FFFD, which stage 4 turns into a space.
      #
      # Only the folded form is repaired. `original` keeps whatever arrived,
      # because the point of keeping it is to show a compliance user exactly
      # what the publisher's file said.
      sig { params(string: String).returns(String).checked(:tests) }
      def utf8(string)
        return string if string.encoding == Encoding::UTF_8 && string.valid_encoding?

        string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end
    end
  end
end
