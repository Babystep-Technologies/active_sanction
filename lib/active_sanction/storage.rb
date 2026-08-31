# frozen_string_literal: true

require "active_sanction/error"

module ActiveSanction
  # Where a synced list lives between the sync that fetched it and the
  # screening run that reads it.
  #
  #   store = ActiveSanction::Storage::Memory.new
  #   store.write_snapshot(ActiveSanction::Sources[:ofac_sdn].new.sync)
  #   store.read_snapshot(:ofac_sdn)   # => Snapshot
  #
  # The namespace holds one interface (Storage::Base), the in-memory
  # implementation of it, and the metadata object a store can answer with
  # without loading a list. The adapters that persist anywhere else -- gzipped
  # JSON on disk (#24), ActiveRecord (#25), whatever a host writes privately --
  # are subclasses of Base and nothing here has to know they exist.
  module Storage
    # A source that has never been synced, or whose snapshot has been deleted,
    # asked for by name. Raised rather than answered with nil wherever a caller
    # named the source itself: screening against a list that turns out not to
    # be there has to fail loudly, because the result of screening against
    # nothing is a clean report.
    class MissingSnapshot < Error; end

    # A stored snapshot that cannot be trusted to be what it says it is: a
    # truncated file, bytes that no longer hash to the checksum recorded beside
    # them, a sidecar that is not JSON, a list filed under one source that
    # claims to be another.
    #
    # Raised rather than repaired, and rather than returning whatever could
    # still be read. A store that hands back the 8,000 records it managed to
    # parse out of 19,015 produces a report that looks exactly like a clean
    # one, which is the most expensive thing this library can get wrong. An
    # operator can always delete the list and re-sync; nobody can recover a
    # screening decision made against a list that was quietly half there.
    class CorruptSnapshot < Error; end

    # A stored snapshot written under a Snapshot::SCHEMA_VERSION this code does
    # not know how to read -- almost always because the directory was written
    # by a newer active_sanction than the one now reading it.
    #
    # Separate from CorruptSnapshot because the file is fine and the fix is
    # different: upgrade the gem, or discard the list and re-sync under this
    # one. It has to be caught before the list is parsed, because a newer
    # schema will usually still deserialize -- into records missing whatever
    # the new version added, with a checksum that verifies, and with no
    # symptom other than names that stop matching.
    class UnsupportedSchema < Error; end
  end
end

require "active_sanction/storage/meta"
require "active_sanction/storage/base"
require "active_sanction/storage/memory"
require "active_sanction/storage/file_system"

# Storage::ActiveRecord (#25) is optional in the strong sense: ActiveRecord is
# not a dependency of this gem and must not become one, so the adapter is
# loaded only where it can be, and the gem is fully usable without it.
#
# Both orders have to work, which is why this is two clauses rather than one.
# A script that requires ActiveRecord itself has already defined the constant
# by the time this file runs, and the first clause loads the adapter now. A
# Rails application loads ActiveSupport long before ActiveRecord::Base -- the
# framework is deliberately lazy about it -- so the second clause books the
# adapter onto the hook Rails runs when Base is finally loaded. An application
# that wants it unconditionally can always require it by name.
if defined?(ActiveRecord::Base)
  require "active_sanction/storage/active_record"
elsif defined?(ActiveSupport) && ActiveSupport.respond_to?(:on_load)
  ActiveSupport.on_load(:active_record) { require "active_sanction/storage/active_record" }
end
