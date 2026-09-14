# typed: strict
# frozen_string_literal: true

require "pathname"
require "sorbet-runtime"

require "active_sanction"

module ActiveSanction
  # The conformance groups, shipped, so that an adapter written outside this
  # repository can prove it conforms.
  #
  #   # spec/spec_helper.rb, in your application
  #   require "active_sanction/testing"
  #
  #   # spec/internal_watchlist_spec.rb
  #   RSpec.describe MyCompany::InternalWatchlist do
  #     it_behaves_like "a sanction source", fixture: "internal_watchlist/list.csv"
  #   end
  #
  #   RSpec.describe MyCompany::PostgresStore do
  #     it_behaves_like "a storage adapter" do
  #       def build_store = described_class.new(url: ENV.fetch("DATABASE_URL"))
  #     end
  #   end
  #
  # Two groups: **"a sanction source"** for a Sources::Base subclass, and
  # **"a storage adapter"** for a Storage::Base implementation. Each is
  # documented at the top of its own file.
  #
  # ### Why this is in `lib/` and not in `spec/`
  #
  # `docs/api_stability.md` names Sources::Base, Storage::Base and
  # ValidatorStore as the three extension points carrying the strongest
  # guarantee, and says of these groups that they "are the executable
  # statement of what they require. An adapter that passes them today passes
  # them for the life of the major version."
  #
  # That promise is addressed to people who install this gem, and until this
  # file existed it was kept only for adapters living in this repository:
  # `spec/` is excluded from the package, so the executable statement shipped
  # nowhere and the guarantee was a paragraph again for everyone it was
  # written for. A conformance suite that its audience cannot run is a
  # conformance suite in name.
  #
  # ### Requiring it is opt-in, and costs a host nothing
  #
  # `require "active_sanction"` does not load this, and nothing under `lib/`
  # requires it. It is loaded by a suite that asked for it, needs RSpec
  # already loaded, and says so rather than failing somewhere stranger if it
  # is not.
  #
  # ### What they do not do
  #
  # Neither group knows anything about *your* list. They are the floor: that
  # an adapter declares what it must, produces Entities of the right shape,
  # gives every record a stable id, and reports what it could not read. Only a
  # spec that knows which of your fixture's records is a vessel can check that
  # you read it correctly, and you still write that one.
  module Testing
    extend T::Sig

    # Where "a sanction source" looks for the fixture a group names, relative
    # to the working directory a suite runs from. `spec/fixtures` is where
    # RSpec projects put them, which makes the default right for most callers
    # and the setting below right for the rest.
    DEFAULT_FIXTURE_ROOT = T.let("spec/fixtures", String)

    class << self
      extend T::Sig

      # Where fixture paths are resolved from. Set it when a project keeps
      # them somewhere other than `spec/fixtures`:
      #
      #   ActiveSanction::Testing.fixture_root = "test/data/sanctions"
      #
      # Relative to the working directory, which for a suite is the project
      # root. An absolute path passed to `fixture:` ignores this entirely.
      sig { params(value: T.untyped).void }
      def fixture_root=(value)
        @fixture_root = T.let(value&.to_s, T.nilable(String))
      end

      sig { returns(String) }
      def fixture_root
        @fixture_root ||= T.let(nil, T.nilable(String))
        File.expand_path(@fixture_root || DEFAULT_FIXTURE_ROOT, Dir.pwd)
      end

      # One fixture, as an absolute path. An absolute path is returned as it
      # stands, so a project that generates a fixture into a temporary
      # directory can name it directly.
      #
      # Missing files are refused here rather than at `File.binread`, because
      # a conformance run against a fixture that is not there should say which
      # fixture and where it looked -- the two facts needed to fix it.
      sig { params(path: T.untyped).returns(String) }
      def fixture_path(path)
        name = path.to_s
        resolved = Pathname.new(name).absolute? ? name : File.expand_path(name, fixture_root)
        return resolved if File.file?(resolved)

        raise ArgumentError,
              "no fixture at #{resolved}. Paths are resolved under #{fixture_root} -- " \
              "set ActiveSanction::Testing.fixture_root if yours live somewhere else."
      end
    end
  end
end

unless defined?(RSpec)
  raise LoadError,
        "active_sanction/testing defines RSpec shared example groups, and RSpec is not loaded. " \
        "Require it from your spec_helper, after rspec itself."
end

require "active_sanction/testing/storage_adapter_defaults"
require "active_sanction/testing/sanction_source"
require "active_sanction/testing/storage_adapter"
