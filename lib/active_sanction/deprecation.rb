# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  # How this library says that something it still supports is going away.
  #
  #   ActiveSanction::Deprecation.warn(
  #     "ActiveSanction.screen(name:)",
  #     replacement: "ActiveSanction.screen(Query.new(...))",
  #     since: "1.4.0"
  #   )
  #   # => active_sanction: ActiveSanction.screen(name:) is deprecated since
  #   #    1.4.0 and will be removed in 1.6.0. Use
  #   #    ActiveSanction.screen(Query.new(...)) instead.
  #   #    Called from app/jobs/screen_job.rb:31
  #
  # The rules that message is stating are in `docs/api_stability.md`: a
  # deprecated thing keeps working for one full minor release after the one
  # that deprecated it, and the removal version is computed from `since`
  # rather than chosen, so nobody has to remember the policy to apply it.
  #
  # ### Ruby's own switch, rather than one of ours
  #
  # This routes through `Kernel#warn` with `category: :deprecated`, so a host
  # silences it with `Warning[:deprecated] = false` -- the same line that
  # silences every other deprecation in their process, and the line they
  # already have if they run a quiet suite. A `config.deprecation_mode` of our
  # own would be one more thing to discover, and it would not be the thing
  # already sitting in their `spec_helper`.
  #
  # Ruby's default for that switch is off outside verbose mode. That is
  # deliberate on Ruby's part and it is kept: the audience for a deprecation
  # is a developer running `ruby -w`, a test suite or a CI build, and a
  # warning a production process cannot act on is a log line nobody reads.
  #
  # ### Once per call site, not once per call
  #
  # A deprecated method called while looping over 19,000 records would
  # otherwise write 19,000 identical lines. The first call from each source
  # location warns and the rest are silent. `reset!` clears that memory, which
  # is what a spec asserting a deprecation needs and what nothing else should
  # touch.
  module Deprecation
    extend T::Sig

    # Deprecations overlap for one full minor release. Something deprecated in
    # 1.4.0 goes on working through all of 1.5.x and may be removed in 1.6.0,
    # so an application upgrading one minor at a time always meets the warning
    # at least one release before the breakage.
    #
    # @api private
    OVERLAP_MINORS = 2

    # Frames to walk past when working out who called a deprecated thing. Two
    # of these would lie: this file is never the answer, and neither is the
    # rest of `lib/` -- a deprecated method's own body is the frame directly
    # beneath the warning, and reporting it would point every deprecation at
    # this library rather than at the line a host has to change.
    #
    # sorbet-runtime is the third, and it is why this is a list rather than a
    # `caller_locations(1, 1)`. Every signed method is called through a
    # validation wrapper, so the immediate caller of anything in `lib/` is
    # Sorbet's `call_validation.rb` -- and that wrapper *moves* once Sorbet
    # swaps in its fast path, so a call site read naively is not even stable
    # between two calls from the same line, which silently defeats the
    # per-site memory above.
    #
    # @api private
    INTERNAL_PATHS = T.let(
      [File.expand_path("..", __dir__),
       Gem.loaded_specs["sorbet-runtime"]&.full_gem_path].compact.freeze,
      T::Array[String]
    )

    @seen = T.let({}, T::Hash[String, TrueClass])
    @mutex = T.let(Mutex.new, Mutex)

    class << self
      extend T::Sig

      # @param subject [String] what is deprecated, written the way a caller
      #   writes it -- a method signature, a constant, a configuration setting.
      # @param since [String] the released version that deprecated it.
      # @param replacement [String, nil] what to use instead. Nil says there is
      #   nothing to move to, which is worth saying out loud rather than
      #   leaving somebody to search for one that does not exist.
      # @param removal [String, nil] the version it may be removed in.
      #   Computed from `since` when omitted, which is the case that should be
      #   normal -- a hand-written removal version is a policy exception, and
      #   an exception is worth having to type.
      # @return [void]
      sig do
        params(subject: String, since: String, replacement: T.nilable(String),
               removal: T.nilable(String)).void
      end
      def warn(subject, since:, replacement: nil, removal: nil)
        return unless Warning[:deprecated]

        site = call_site
        return unless first_time?("#{subject}@#{site}")

        Kernel.warn(message(subject, since, replacement, removal, site), category: :deprecated)
      end

      # The version something deprecated in `since` may be removed in: the
      # minor after the next one. A patch release never removes anything, so
      # the patch component is dropped rather than carried forward.
      #
      # @param since [String] the version that deprecated it
      # @return [String] the earliest version it may be removed in
      sig { params(since: String).returns(String) }
      def removal_for(since)
        major, minor = since.split(".").first(2).map(&:to_i)
        "#{major}.#{T.must(minor) + OVERLAP_MINORS}.0"
      end

      # Forget which call sites have already warned. For a spec that asserts a
      # deprecation fires; nothing in a running application should call it.
      #
      # @return [void]
      sig { void }
      def reset!
        @mutex.synchronize { @seen.clear }
      end

      private

      # The first frame outside this library, which is the line a host would
      # have to change. Says so plainly rather than naming a frame it does not
      # believe.
      sig { returns(String) }
      def call_site
        caller_locations(2, 32)&.each do |location|
          path = location.path
          # Evaluated code has no path, and is not a line anybody can edit.
          next if path.nil?
          next if INTERNAL_PATHS.any? { |internal| path.start_with?(internal) }

          return "#{path}:#{location.lineno}"
        end
        "an unknown location"
      end

      sig { params(key: String).returns(T::Boolean) }
      def first_time?(key)
        @mutex.synchronize do
          next false if @seen.key?(key)

          @seen[key] = true
        end
      end

      sig do
        params(subject: String, since: String, replacement: T.nilable(String),
               removal: T.nilable(String), site: String).returns(String)
      end
      def message(subject, since, replacement, removal, site)
        parts = ["active_sanction: #{subject} is deprecated since #{since} " \
                 "and will be removed in #{removal || removal_for(since)}."]
        parts << "Use #{replacement} instead." if replacement
        parts << "Called from #{site}"
        parts.join(" ")
      end
    end
  end
end
