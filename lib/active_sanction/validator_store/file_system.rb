# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "fileutils"
require "json"

module ActiveSanction
  class ValidatorStore
    # Validators in one small JSON file, so a sync that runs from cron gets a
    # 304 on its second run rather than on its second run within one process.
    #
    #   ActiveSanction::ValidatorStore::FileSystem.new
    #   # => ~/.cache/active_sanction/validators.json
    #
    # JSON, indented, keyed by the caller's key: this file is the first thing
    # somebody opens when a sync is downloading more than it should, and it is
    # a few hundred bytes even with every source in it. It is also the file the
    # acceptance criterion is about -- deleting it forces a full re-download,
    # and nothing else is lost with it, because validators are an optimization
    # and never the record of what a list contained.
    #
    # Entries are re-read on every access rather than memoized. The file is
    # tiny, and a cache that has to be reloaded to see another process's write
    # is a cache that lies to a sync running beside a CLI command.
    #
    # Writes go to a temporary sibling and are renamed into place, so an
    # interrupted write leaves the previous file rather than a truncated one.
    # Two processes writing at once still resolve last-writer-wins: the cost is
    # one avoidable download, which is the right trade for not putting a lock
    # file in a user's cache directory.
    class FileSystem < ValidatorStore
      extend T::Sig

      DEFAULT_FILENAME = T.let("validators.json", String)

      sig { returns(String) }
      attr_reader :path

      sig { params(path: T.untyped).void }
      def initialize(path: nil)
        @path = T.let(
          ::File.expand_path((path || ::File.join(ActiveSanction.config.cache_dir, DEFAULT_FILENAME)).to_s), String
        )
        super()
      end

      sig { override.returns(String) }
      def inspect = "#<#{self.class} #{path} #{size} entr#{size == 1 ? "y" : "ies"}>"

      private

      sig { override.returns(T::Hash[String, Validators]) }
      def entries
        raw = read
        raw.to_h { |key, attributes| [key, Validators.from_h(attributes)] }
      rescue ArgumentError, TypeError => e
        raise CorruptStore, "#{path} does not hold validators (#{e.message}). Delete it to re-download in full."
      end

      sig do
        override.params(block: T.proc.params(all: T::Hash[String, Validators]).returns(T.untyped))
                .returns(T.untyped)
      end
      def commit(&block)
        all = entries
        result = block.call(all)
        write(all)
        result
      end

      # A missing file is an empty store, not an error: it is what a first run
      # sees, and what deleting the file leaves behind.
      sig { returns(T::Hash[String, T.untyped]) }
      def read
        return {} unless ::File.exist?(path)

        contents = ::File.read(path, encoding: Encoding::UTF_8)
        return {} if contents.strip.empty?

        parsed = JSON.parse(contents)
        raise CorruptStore, "#{path} is not a JSON object of validators. Delete it to re-download in full." unless
          parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError => e
        raise CorruptStore, "#{path} is not valid JSON (#{e.message}). Delete it to re-download in full."
      end

      sig { params(all: T::Hash[String, Validators]).void }
      def write(all)
        FileUtils.mkdir_p(::File.dirname(path))
        temporary = T.let("#{path}.#{Process.pid}.tmp", T.nilable(String))
        ::File.write(T.must(temporary), "#{JSON.pretty_generate(all.transform_values(&:to_h))}\n")
        ::File.rename(T.must(temporary), path)
      ensure
        FileUtils.rm_f(temporary) if temporary
      end
    end
  end
end
