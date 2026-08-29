# frozen_string_literal: true

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
    # OFAC's ALT.CSV supplies `alt_type` as aka / fka / nka directly, and the
    # distinction matters downstream: a former name (fka) is still a real hit,
    # but ranking it identically to a currently-used one costs precision.
    KINDS = %i[primary aka fka nka].freeze

    # The UN consolidated list grades each alias Good or Low. A Low alias is a
    # weaker signal -- the scorer (#32) penalizes it -- so the grade has to
    # survive parsing rather than being flattened away here. Every other source
    # publishes no grade at all, which is `nil`: unstated, not good.
    QUALITIES = %i[good low].freeze

    # Canonical member order. Snapshot (#8) checksums the serialized form, so
    # #to_h must lay its keys out the same way every time.
    MEMBERS = %i[value kind quality script].freeze

    ENUMS = { kind: KINDS, quality: QUALITIES }.freeze

    attr_reader(*MEMBERS)

    # Rebuilds a name from #to_h output. Accepts string keys and string values
    # for the enum members, so a name that has been through JSON round-trips
    # without a separate coercion step.
    def self.from_h(hash)
      attributes = hash.to_h.transform_keys(&:to_sym)
      unknown = attributes.keys - MEMBERS
      raise ArgumentError, "unknown Name attribute(s): #{unknown.join(", ")}" if unknown.any?

      new(**attributes)
    end

    # `kind` defaults to :primary because that is what a source with no alias
    # data at all means: Canada publishes no aliases, so every Canadian name is
    # a primary one.
    def initialize(value:, kind: :primary, quality: nil, script: nil)
      @value = value!(value)
      @kind = enum!(:kind, kind)
      @quality = quality.nil? ? nil : enum!(:quality, quality)
      # Not validated against an enum: ISO 15924 defines roughly 200 scripts,
      # and a source shipping Cyrillic or Arabic should record that, not raise.
      @script = script.nil? ? nil : script.to_s.downcase.to_sym
      freeze
    end

    def primary? = kind == :primary

    # Every kind except :primary. Reads better at call sites than `!primary?`
    # and keeps the definition of "alias" in one place if a kind is ever added.
    def alias? = !primary?

    # nil quality is not low quality: only the UN grades aliases, so an ungraded
    # name must not be penalized for a field its source never publishes.
    def low_quality? = quality == :low

    def to_h
      { value: value, kind: kind, quality: quality, script: script }
    end

    def to_s = value

    # Class is part of the comparison to keep #== and #hash agreeing, which is
    # what Hash and Set rely on.
    def ==(other)
      other.instance_of?(self.class) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      [self.class, to_h].hash
    end

    def inspect
      "#<#{self.class} #{value.inspect} kind=#{kind.inspect}#{" quality=#{quality.inspect}" if quality}>"
    end

    private

    # Surrounding whitespace is stripped -- the delimited sources are full of it
    # -- but nothing else is touched. Case, diacritics, punctuation and word
    # order are all signal the matcher needs to see as published.
    def value!(value)
      string = value.to_s.strip
      raise ArgumentError, "value is required" if string.empty?

      -string
    end

    # Case is folded before the lookup: the UN writes its grades as Good and
    # Low, OFAC writes its alias types lowercase, and neither adapter should
    # have to remember which. A wrong value still raises.
    def enum!(member, value)
      raise ArgumentError, "#{member} is required" if value.to_s.empty?

      symbol = value.to_s.downcase.to_sym
      permitted = ENUMS.fetch(member)
      return symbol if permitted.include?(symbol)

      raise ArgumentError, "unknown #{member} #{symbol.inspect}, expected one of #{permitted.join(", ")}"
    end
  end
end
