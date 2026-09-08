# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/entity"
require "active_sanction/normalizer/form"
require "active_sanction/normalizer/dictionary/stoplist"

module ActiveSanction
  class Normalizer
    # The token lists the fold applies per entity type, and the one list that
    # overrides them.
    #
    #   dictionary = ActiveSanction::Normalizer::Dictionary.default
    #   dictionary.stoplist(:organization).reject(%w[rosneft oil company])  # => ["rosneft", "oil"]
    #   dictionary.stoplist(:individual).reject(%w[hajji abdallah])         # => ["abdallah"]
    #
    # Stage 1b of the matching pipeline. Form settles what a name looks like;
    # this settles which of its tokens carry no identifying information --
    # `LTD` on a company, `SHAYKH` on a person -- so that "Rosneft Oil Company"
    # and "Rosneft" can score as the near-identical pair they are.
    #
    # ### Contextual, because the same token means different things
    #
    # Legal forms are stripped from organizations and honorifics from
    # individuals, and neither is stripped from the other or from a vessel or
    # an aircraft. This is not tidiness. `CO` is a legal form in "Bank of
    # Kunlun Co Ltd" and the first syllable of a great many personal names;
    # `AS` is a Norwegian company and an English word. Applying a list to the
    # type it was written for is what keeps it from being a source of false
    # matches everywhere else. A caller that does not know the type says so by
    # passing none, and gets the fold and nothing else.
    #
    # ### The preserve list wins
    #
    # Whatever the strip lists say, no entry containing a particle from
    # particles.txt is applied. `bin`, `abu`, `al` and `abd` look like noise to
    # a stopword filter and are structural parts of the names they appear in;
    # dropping them turns "Osama bin Laden" into a different name rather than a
    # shorter one. The collision is real and shipped: `AL` is in
    # organization_stopwords.txt and never strips anything, which is what the
    # rule is for and what the suite holds it to.
    #
    # ### Data files, not constants
    #
    # The lists live in `lib/active_sanction/normalizer/dictionaries/*.txt`,
    # one entry per line with `#` comments, because what belongs on them is
    # settled by reading government lists rather than by reading this code --
    # and a contributor adding `OYJ` should be sending a one-line diff, not
    # editing a Ruby array.
    #
    # Entries are written as a publisher writes them (`L.L.C.`, not `l l c`)
    # and folded by the same Form the names are folded by, so a file never
    # spells the casing, the accents or the marks: one `LTD` covers `Ltd`,
    # `ltd.` and `LTD`. An entry that folds to several tokens is matched as a
    # contiguous phrase, which is what lets `L.L.C.` reach a name a publisher
    # wrote as `L L C` -- see Stoplist.
    #
    # What folding does not do is join tokens, so `LLC` and `L.L.C.` are one
    # token and three and the file carries both. That is the one thing a
    # contributor has to know when adding an abbreviation.
    #
    # ### Extending it
    #
    # A host adds to the shipped lists with a Hash, or replaces them wholesale
    # by building a Dictionary of its own:
    #
    #   ActiveSanction.configure do |c|
    #     c.normalizer_dictionary = { legal_forms: %w[OYJ TBK], particles: %w[ben] }
    #   end
    #
    # Instances are frozen on construction and compare by value.
    class Dictionary
      extend T::Sig

      # Where the shipped lists are, and the file name of each: `legal_forms`
      # is `dictionaries/legal_forms.txt`.
      DIRECTORY = T.let(File.expand_path("dictionaries", __dir__), String)

      LISTS = T.let(%i[legal_forms honorifics organization_stopwords particles].freeze, T::Array[Symbol])

      # Which lists are stripped from which entity type. A type absent here --
      # `vessel`, `aircraft` -- is folded and left alone: a ship's name is not
      # a company's, and the tokens that would be dropped from one carry
      # meaning in the other.
      STRIPPED = T.let({
        individual: %i[honorifics].freeze,
        organization: %i[legal_forms organization_stopwords].freeze
      }.freeze, T::Hash[Symbol, T::Array[Symbol]])

      sig { returns(T::Array[String]) }
      attr_reader :legal_forms

      sig { returns(T::Array[String]) }
      attr_reader :honorifics

      sig { returns(T::Array[String]) }
      attr_reader :organization_stopwords

      # The entries no strip list may touch. See the class comment.
      sig { returns(T::Array[String]) }
      attr_reader :particles

      # Every keyword is required, because a Dictionary built by hand is a
      # replacement for the shipped one and a replacement that forgot to carry
      # the particles over would strip `al` out of several hundred SDN names
      # without saying anything. `Dictionary.default.merge(...)` is the way to
      # add to the lists rather than replace them.
      sig do
        params(legal_forms: T.untyped, honorifics: T.untyped, organization_stopwords: T.untyped,
               particles: T.untyped).void
      end
      def initialize(legal_forms:, honorifics:, organization_stopwords:, particles:)
        @legal_forms = T.let(entries(legal_forms), T::Array[String])
        @honorifics = T.let(entries(honorifics), T::Array[String])
        @organization_stopwords = T.let(entries(organization_stopwords), T::Array[String])
        @particles = T.let(entries(particles), T::Array[String])
        @stoplists = T.let(build_stoplists, T::Hash[Symbol, Stoplist])
        freeze
      end

      # What is stripped from a name of this type, or nil when nothing is --
      # an unknown type, a type no list applies to, or a host that emptied the
      # lists that did. Nil is the fold's fast path, not a degraded one.
      sig { params(type: T.nilable(Symbol)).returns(T.nilable(Stoplist)) }
      def stoplist(type)
        return nil if type.nil?

        unless Entity::TYPES.include?(type)
          raise InvalidArgument,
                "unknown entity type #{type.inspect}; expected one of #{Entity::TYPES.join(", ")} or nil"
        end

        stoplist = @stoplists[type]
        stoplist unless stoplist.nil? || stoplist.empty?
      end

      # This dictionary's lists with more entries added. Duplicates are
      # dropped, so merging a list a file already carries is a no-op rather
      # than an error.
      sig do
        params(legal_forms: T.untyped, honorifics: T.untyped, organization_stopwords: T.untyped,
               particles: T.untyped).returns(Dictionary)
      end
      def merge(legal_forms: nil, honorifics: nil, organization_stopwords: nil, particles: nil)
        self.class.new(
          legal_forms: @legal_forms + entries(legal_forms),
          honorifics: @honorifics + entries(honorifics),
          organization_stopwords: @organization_stopwords + entries(organization_stopwords),
          particles: @particles + entries(particles)
        )
      end

      sig { returns(T::Hash[Symbol, T::Array[String]]) }
      def to_h = LISTS.to_h { |list| [list, T.unsafe(public_send(list))] }

      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.instance_of?(self.class)

        to_h == other.to_h
      end
      alias eql? ==

      sig { returns(Integer) }
      def hash = [self.class, to_h].hash

      sig { returns(String) }
      def inspect = "#<#{self.class} #{to_h.map { |list, values| "#{list}=#{values.size}" }.join(" ")}>"

      class << self
        extend T::Sig

        # The shipped lists. Built at load rather than memoized on first use,
        # so nothing has to synchronize reading four files; the constant behind
        # it is private because this is the way to reach it.
        sig { returns(Dictionary) }
        def default = DEFAULT

        # Reads `<directory>/<list>.txt` for each of LISTS. Public because it
        # is how a host ships its own set of files rather than a Ruby literal,
        # and how the suite builds a dictionary it can vary.
        sig { params(directory: String).returns(Dictionary) }
        def from_files(directory = DIRECTORY)
          # `new(**hash)` past required keyword parameters is one of the few
          # things Sorbet cannot check statically. The keys are LISTS itself.
          T.unsafe(self).new(**LISTS.to_h { |list| [list, read(File.join(directory, "#{list}.txt"))] })
        end

        # One entry per line; blank lines and `#` comments ignored. Comments
        # are whole-line only -- no entry contains a `#`, and a rule that
        # stripped from the middle would be a rule to remember when one does.
        sig { params(path: String).returns(T::Array[String]) }
        def read(path)
          File.readlines(path, chomp: true).map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
        end
      end

      private

      # Entries as written, deduplicated, with the blanks a hand-edited file
      # collects dropped. A single string is accepted as a list of one, since
      # `c.normalizer_dictionary = { legal_forms: "OYJ" }` is what a host will
      # write for one entry.
      sig { params(value: T.untyped).returns(T::Array[String]) }
      def entries(value)
        Array(value).map { |entry| -entry.to_s.strip }.reject(&:empty?).uniq.freeze
      end

      # Resolves each type's lists once: fold every entry, drop the ones the
      # preserve list protects, hand the rest to a Stoplist. Once, rather than
      # per name, because an index build folds 46,000 of them.
      sig { returns(T::Hash[Symbol, Stoplist]) }
      def build_stoplists
        preserved = @particles.flat_map { |entry| fold(entry) }
        STRIPPED.to_h do |type, lists|
          sequences = lists.flat_map { |list| T.unsafe(public_send(list)) }
                           .map { |entry| fold(entry) }
                           .reject { |sequence| sequence.any? { |token| preserved.include?(token) } }
          [type, Stoplist.new(type: type, entries: sequences)]
        end.freeze
      end

      # The same fold the names get. A dictionary folded any other way is a
      # dictionary that matches tokens the fold never produces.
      sig { params(entry: String).returns(T::Array[String]) }
      def fold(entry) = Form.new(entry).tokens

      # Last, because building it runs #initialize, which calls every private
      # method below.
      DEFAULT = T.let(from_files, Dictionary)
      private_constant :DEFAULT
    end
  end
end
