# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  class ValidatorStore
    # Validators for the life of one process, and no longer.
    #
    # The default for a caller that builds its own client and does not want a
    # file appearing under a home directory, and what the suite uses so an
    # example never depends on -- or leaves behind -- state on disk. A
    # long-running process that syncs on a schedule still gets the whole
    # benefit of conditional GET from it; only a fresh boot pays for a full
    # download.
    class Memory < ValidatorStore
      extend T::Sig

      sig { params(entries: T::Hash[T.untyped, T.nilable(Validators)]).void }
      def initialize(entries = {})
        @entries = T.let({}, T::Hash[String, Validators])
        @mutex = T.let(Mutex.new, Mutex)
        entries.each { |key, validators| self[key] = validators }
        super()
      end

      private

      sig { override.returns(T::Hash[String, Validators]) }
      attr_reader :entries

      sig do
        override.params(block: T.proc.params(all: T::Hash[String, Validators]).returns(T.untyped))
                .returns(T.untyped)
      end
      def commit(&block)
        @mutex.synchronize { block.call(@entries) }
      end
    end
  end
end
