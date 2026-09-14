# typed: ignore
# frozen_string_literal: true

# How the storage conformance group builds the adapter it is testing.
#
# In a module, and in a file of its own, for two reasons that are both about
# not defining a method twice. A group is free to override `build_store` in the
# customization block it passes to `it_behaves_like` -- which is how an adapter
# that cannot be built by `.new` alone gets held to the contract -- and
# defining a method over one the group already had would warn, since this suite
# runs with Ruby warnings on. Keeping it out of the shared example group's own
# file is the same rule one level up: the conformance spec loads that file
# again inside an RSpec sandbox, and a module reopened there would redefine
# whatever it holds.
#
# Namespaced, because it ships: a bare `StorageAdapterDefaults` at the top
# level would be this gem putting a name into a host's global namespace to
# save itself two words.
module ActiveSanction
  module Testing
    module StorageAdapterDefaults
      def build_store = described_class.new
    end
  end
end
