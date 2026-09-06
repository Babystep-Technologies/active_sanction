# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  class Index
    # The three things a folded name is looked up by.
    #
    #   form = ActiveSanction::Normalizer.call("ABBAS, Abu")
    #
    #   ActiveSanction::Index::Features.tokens(form)    # => ["abbas", "abu"]
    #   ActiveSanction::Index::Features.trigrams(form)  # => [" ab", "abb", "bba", ...]
    #   ActiveSanction::Index::Features.phonetics(form) # => ["APS", "AP"]
    #
    # One module rather than two code paths, because the whole of an index's
    # correctness is that a name is described the same way when it is stored
    # and when it is asked for. A build that padded its trigrams and a query
    # that did not would retrieve nothing at all, and would look exactly like
    # a corpus with no matches in it.
    #
    # ### Why three
    #
    # Each one fails where the next one works, which is the same argument the
    # scorers make and for the same reason -- except that here a miss is
    # final. A name the index does not retrieve is never compared to anything,
    # so this stage is built for recall and the precision is #32's job.
    #
    # **Tokens** are exact and nearly free: one hash lookup finds every name
    # carrying the word. They are what finds `ABBAS, Abu` from `Abu Abbas`,
    # since word order is not a thing a token index has an opinion about.
    # They fail on a typo, on a transliterator's vowel, and on a token
    # boundary drawn differently -- `AEROCARIBBEAN` shares no token at all
    # with `AERO-CARIBBEAN`.
    #
    # **Trigrams** are what covers that. `GAZPROM` and `GAZPRON` share every
    # trigram but two, and a name that lost a letter to a typo keeps almost
    # all of them. They are also the only feature a non-Latin name has that
    # survives a spelling difference, since the phonetic table cannot read it.
    #
    # **Phonetic keys** cover the case neither of the others can: two
    # spellings with few letters in common that are the same name out loud.
    # `QADDAFI` and `GADDAFI` share one trigram of five and no token, and one
    # phonetic key.
    module Features
      extend T::Sig

      # Three characters, which is the size that has to hold two properties at
      # once: short enough that a name keeps most of its trigrams when a
      # letter changes, and long enough that a shared trigram means something.
      # Bigrams of names are close to noise -- `an`, `al` and `ar` are in a
      # third of this corpus -- and quadgrams break too easily on the vowel a
      # transliterator chose.
      SIZE = T.let(3, Integer)

      # Tokens are padded before they are cut up, so that the first and last
      # letters of a word are inside a trigram that says they are first and
      # last. Without it `ABBAS` and `SABBA` are the same bag of trigrams.
      #
      # A space is the padding because a folded token cannot contain one --
      # Normalizer's stage 5 is what guarantees that -- so no padding trigram
      # can collide with one from the middle of a word.
      PAD = T.let(" ", String)

      module_function

      # The distinct tokens of a folded name.
      #
      # Distinct because a posting list is a set: `ALI, Ali Hassan` carries
      # `ali` twice and is not twice as much of a match for it.
      sig { params(form: Normalizer::Form).returns(T::Array[String]).checked(:tests) }
      def tokens(form) = form.tokens.uniq

      # Every character trigram of every token, padded at both ends.
      #
      # Per token rather than across the whole name: a trigram spanning two
      # words would encode the order they were written in, and half of what
      # this index exists to defeat is that order. `abbas abu` and `abu abbas`
      # produce the same trigrams here, as they should.
      sig { params(form: Normalizer::Form).returns(T::Array[String]).checked(:tests) }
      def trigrams(form)
        form.tokens.flat_map { |token| token_trigrams(token) }.uniq
      end

      sig { params(token: String).returns(T::Array[String]).checked(:tests) }
      def token_trigrams(token)
        padded = "#{PAD}#{token}#{PAD}"
        length = padded.length
        # A token of one character is shorter than a trigram once padded, and
        # is indexed as the short string it is rather than not at all.
        return [padded] if length <= SIZE

        # Characters rather than bytes, for the reason Similarity.codepoints
        # gives: a Cyrillic name has to be cut into the same number of pieces
        # a Latin one of the same length is.
        (0..(length - SIZE)).map { |offset| padded[offset, SIZE].to_s }
      end

      # Every Double Metaphone key of every token, both the primary and the
      # alternate -- see Phonetics for why the second one is not optional.
      #
      # A token that produces no key contributes nothing rather than an empty
      # one. An empty key would be a bucket holding every Cyrillic and Arabic
      # name in the corpus, which is the largest and least useful posting list
      # it is possible to build.
      sig { params(form: Normalizer::Form).returns(T::Array[String]).checked(:tests) }
      def phonetics(form)
        form.tokens.flat_map { |token| Phonetics::DoubleMetaphone.call(token) }.uniq
      end
    end
  end
end
