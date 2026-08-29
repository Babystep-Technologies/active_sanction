# frozen_string_literal: true

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
      def initialize(entries = {})
        @entries = {}
        @mutex = Mutex.new
        entries.each { |key, validators| self[key] = validators }
        super()
      end

      private

      attr_reader :entries

      def commit
        @mutex.synchronize { yield @entries }
      end
    end
  end
end
