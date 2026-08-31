# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  # A single name variant attached to an entity. Entities routinely carry more
  # aliases than primary names -- OFAC ships 19,321 primary names against
  # 20,147 aliases -- so an alias is the common case, not the exception.
  #
  #   ActiveSanction::Name.new(
  #     value:   "AERO-CARIBBEAN",
  #     kind:    :aka,
  #     quality: :good,
  #     script:  :latin
  #   )
  #
  # A pure data holder: it stores what the publisher said and nothing more. The
  # normalized and phonetic forms a search actually compares against are built
  # by the normalizer (#26) and the indexer (#31), which need the untouched
  # original to work from.
  #
  # Instances are frozen on construction and compare by value.
  class Name
    extend T::Sig

    # OFAC's ALT.CSV supplies `alt_type` as aka / fka / nka directly, and the
    # distinction matters downstream: a former name (fka) is still a real hit,
    # but ranking it identically to a currently-used one costs precision.
    KINDS = T.let(%i[primary aka fka nka].freeze, T::Array[Symbol])

    # The UN consolidated list grades each alias Good or Low. A Low alias is a
    # weaker signal -- the scorer (#32) penalizes it -- so the grade has to
    # survive parsing rather than being flattened away here. Every other source
    # publishes no grade at all, which is `nil`: unstated, not good.
    QUALITIES = T.let(%i[good low].freeze, T::Array[Symbol])

    # The writing system `value` is published in, which is what tells the
    # normalizer (#26) which transliteration path to take -- a Cyrillic name
    # folded by the Latin rules comes out as noise. Adapters map their source's
    # own vocabulary onto these: OFAC labels some names by language rather than
    # script, so "Farsi" arrives here as :arabic.
    #
    # Closed, so a typo is caught at the boundary instead of quietly minting a
    # script nothing downstream handles. It is sized to what the lists actually
    # publish rather than to all ~200 of ISO 15924; a source shipping one we
    # have not seen is a one-line addition here, which the raised message asks
    # for by name.
    SCRIPTS = T.let(%i[
      latin cyrillic arabic hebrew greek han kana hangul
      thai devanagari bengali tamil myanmar khmer armenian georgian ethiopic syriac
    ].freeze, T::Array[Symbol])

    ENUMS = T.let({ kind: KINDS, quality: QUALITIES, script: SCRIPTS }.freeze, T::Hash[Symbol, T::Array[Symbol]])

    # Canonical member order. Snapshot (#8) checksums the serialized form, so
    # #to_h must lay its keys out the same way every time.
    MEMBERS = T.let(%i[value kind quality script].freeze, T::Array[Symbol])

    # The publisher's own string, stripped of surrounding whitespace and
    # otherwise untouched.
    sig { returns(String) }
    attr_reader :value

    sig { returns(Symbol) }
    attr_reader :kind

    # nil where the source publishes no grade, which is every source but the
    # UN. See #low_quality?: unstated is not low.
    sig { returns(T.nilable(Symbol)) }
    attr_reader :quality

    sig { returns(T.nilable(Symbol)) }
    attr_reader :script

    # Rebuilds a name from #to_h output. Accepts string keys and string values
    # for the enum members, so a name that has been through JSON round-trips
    # without a separate coercion step.
    sig { params(hash: T.untyped).returns(T.attached_class) }
    def self.from_h(hash)
      attributes = hash.to_h.transform_keys(&:to_sym)
      unknown = attributes.keys - MEMBERS
      raise ArgumentError, "unknown Name attribute(s): #{unknown.join(", ")}" if unknown.any?

      # `new(**hash)` past a required keyword parameter is one of the few
      # things Sorbet cannot check statically. #initialize validates what
      # arrives, which is where a bad round-trip is caught.
      T.unsafe(self).new(**attributes)
    end

    # `kind` defaults to :primary because that is what a source with no alias
    # data at all means: Canada publishes no aliases, so every Canadian name is
    # a primary one.
    #
    # Untyped on purpose, and the same choice Entity makes: every one of these
    # is the publisher's text arriving as whatever the parser made of it. The
    # coercions below say what happens to it, in messages written for whoever
    # has to fix the record.
    sig do
      params(value: T.untyped, kind: T.untyped, quality: T.untyped, script: T.untyped).void
    end
    def initialize(value:, kind: :primary, quality: nil, script: nil)
      @value = T.let(value!(value), String)
      @kind = T.let(enum!(:kind, kind), Symbol)
      @quality = T.let(quality.nil? ? nil : enum!(:quality, quality), T.nilable(Symbol))
      @script = T.let(script.nil? ? nil : enum!(:script, script), T.nilable(Symbol))
      freeze
    end

    sig { returns(T::Boolean) }
    def primary? = kind == :primary

    # Every kind except :primary. Reads better at call sites than `!primary?`
    # and keeps the definition of "alias" in one place if a kind is ever added.
    sig { returns(T::Boolean) }
    def alias? = !primary?

    # nil quality is not low quality: only the UN grades aliases, so an ungraded
    # name must not be penalized for a field its source never publishes.
    # Compared by identity because symbols are interned and `quality` is
    # nilable: `nil == :low` is a call on NilClass, which Sorbet will not make.
    sig { returns(T::Boolean) }
    def low_quality? = quality.equal?(:low)

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h
      { value: value, kind: kind, quality: quality, script: script }
    end

    sig { returns(String) }
    def to_s = value

    # Class is part of the comparison to keep #== and #hash agreeing, which is
    # what Hash and Set rely on.
    sig { params(other: T.untyped).returns(T::Boolean) }
    def ==(other)
      return false unless other.instance_of?(self.class)

      to_h == other.to_h
    end
    alias eql? ==

    sig { returns(Integer) }
    def hash
      [self.class, to_h].hash
    end

    sig { returns(String) }
    def inspect
      "#<#{self.class} #{value.inspect} kind=#{kind.inspect}#{" quality=#{quality.inspect}" if quality}>"
    end

    private

    # Surrounding whitespace is stripped -- the delimited sources are full of it
    # -- but nothing else is touched. Case, diacritics, punctuation and word
    # order are all signal the matcher needs to see as published.
    sig { params(value: T.untyped).returns(String) }
    def value!(value)
      string = value.to_s.strip
      raise ArgumentError, "value is required" if string.empty?

      -string
    end

    # Case is folded before the lookup: the UN writes its grades as Good and
    # Low, OFAC writes its alias types lowercase and its scripts capitalized,
    # and no adapter should have to remember which. A wrong value still raises.
    sig { params(member: Symbol, value: T.untyped).returns(Symbol) }
    def enum!(member, value)
      raise ArgumentError, "#{member} is required" if value.to_s.empty?

      symbol = value.to_s.downcase.to_sym
      permitted = ENUMS.fetch(member)
      return symbol if permitted.include?(symbol)

      raise ArgumentError, "unknown #{member} #{symbol.inspect}, expected one of #{permitted.join(", ")}"
    end
  end
end
