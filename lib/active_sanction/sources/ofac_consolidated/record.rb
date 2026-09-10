# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/sources/ofac"

module ActiveSanction
  module Sources
    class OfacConsolidated < Ofac
      # A consolidated row, read exactly as an SDN row is, plus the one thing
      # the SDN list does not have to say: which of OFAC's six non-SDN lists
      # this record is on.
      #
      # The attribution is derived from the programs rather than stored beside
      # them, so that it stays derivable from a stored Entity long after this
      # object is gone -- see OfacConsolidated.lists. What the record adds is
      # the human-readable form, appended to remarks ahead of the other
      # source fields because it is the first thing an examiner looking at a
      # hit needs to know.
      #
      # @api private
      class Record < Ofac::Record
        extend T::Sig

        sig { returns(T::Array[Symbol]) }
        def lists = OfacConsolidated.lists(programs)

        sig { returns(T::Array[String]) }
        def list_names = lists.map { |list| OfacConsolidated::NAMES.fetch(list) }

        sig { override.returns(T::Array[T.untyped]) }
        def remark_fields = [["List", list_names]] + super
      end
    end
  end
end
