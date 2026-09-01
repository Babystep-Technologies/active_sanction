# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  class Normalizer
    class Dictionary
      # One entity type's strip lists, resolved down to the only thing the fold
      # needs: which token sequences to drop, already folded and with the
      # preserved particles taken back out.
      #
      #   stoplist = ActiveSanction::Normalizer::Dictionary.default.stoplist(:organization)
      #   stoplist.reject(%w[public joint stock company gazprom])   # => ["gazprom"]
      #
      # Resolution happens once, when the Dictionary is built, because the
      # alternative is doing it per name: a strip list is a few dozen entries
      # and an index build folds 46,000 names.
      #
      # ### Sequences rather than tokens
      #
      # A dictionary entry is folded by the same Form the names are folded by,
      # and that fold turns punctuation into spaces: `L.L.C.` in the file is
      # three tokens, and so is `L.L.C.` in a name. So an entry is matched as a
      # contiguous sequence rather than as a token, longest first at each
      # position. That the mechanism was forced by punctuation is incidental;
      # what it buys is the phrases that actually matter, since "PUBLIC JOINT
      # STOCK COMPANY GAZPROM" has to reach `gazprom` rather than `public joint
      # stock gazprom`.
      #
      # Folding never joins tokens, so `LLC` is not reachable from an `L.L.C.`
      # entry. The file carries both spellings; this class does not guess.
      #
      # A match is dropped wherever it appears, not only at the end. OFAC
      # writes both "GAZPROM PAO" and "PJSC GAZPROM", and a rule that only
      # looked at the tail would fold one of them and not the other.
      class Stoplist
        extend T::Sig

        sig { returns(Symbol) }
        attr_reader :type

        # Every entry as the token sequence it folds to, deduplicated and
        # sorted so that two dictionaries carrying the same lists in different
        # orders resolve to the same stoplist -- and, through #key, share a
        # normalizer's cache.
        sig { returns(T::Array[T::Array[String]]) }
        attr_reader :entries

        # Identifies these entries within one process, for the fold cache: the
        # folded form of a name depends on the entity type it was folded for
        # and on the dictionary in force, so neither can be left out of a cache
        # key. Content-derived rather than object-derived, so a host that
        # rebuilds an identical dictionary does not invalidate a warm cache.
        sig { returns(String) }
        attr_reader :key

        sig { params(type: Symbol, entries: T::Array[T::Array[String]]).void }
        def initialize(type:, entries:)
          @type = T.let(type, Symbol)
          @entries = T.let(entries.reject(&:empty?).uniq.sort.freeze, T::Array[T::Array[String]])
          @index = T.let(build_index, T::Hash[String, T::Array[T::Array[String]]])
          @key = T.let(-"#{type}:#{@entries.hash.to_s(36)}", String)
          freeze
        end

        sig { returns(T::Boolean) }
        def empty? = entries.empty?

        # `tokens` with every matching sequence removed.
        #
        # The caller decides what an empty result means; Form keeps the
        # unstripped tokens rather than indexing a name that folded away to
        # nothing. See Form#fold.
        sig { params(tokens: T::Array[String]).returns(T::Array[String]) }
        def reject(tokens)
          kept = T.let([], T::Array[String])
          index = 0
          while index < tokens.size
            length = match(tokens, index)
            if length.zero?
              kept << T.must(tokens[index])
              index += 1
            else
              index += length
            end
          end
          kept
        end

        sig { returns(String) }
        def inspect = "#<#{self.class} #{type} #{entries.size} entries>"

        private

        # Candidates by their first token, longest first, so that "public joint
        # stock company" is tried before "company" would be reached and before
        # a shorter entry sharing its first token could win.
        sig { returns(T::Hash[String, T::Array[T::Array[String]]]) }
        def build_index
          entries.group_by { |entry| T.must(entry.first) }
                 .transform_values { |group| group.sort_by { |entry| -entry.size }.freeze }
                 .freeze
        end

        # How many tokens the longest entry starting at `index` covers, or zero
        # when none does.
        sig { params(tokens: T::Array[String], index: Integer).returns(Integer) }
        def match(tokens, index)
          candidates = @index[T.must(tokens[index])]
          return 0 if candidates.nil?

          found = candidates.find { |entry| tokens[index, entry.size] == entry }
          found ? found.size : 0
        end
      end
    end
  end
end
