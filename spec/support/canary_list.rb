# frozen_string_literal: true

require_relative "fake_doctor_source"

# A registerable source class for the canary's own specs, wrapping the fake the
# doctor's specs already use.
#
# The canary resolves a source through the registry rather than being handed an
# adapter, so what its run needs is a *class* -- and one the doctor is willing
# to isolate, which means an `initialize` taking the three keywords
# `Sources::Base` takes. They are accepted and ignored here: the point of the
# fake is that nothing fetches.
#
# Deliberately not registered on load, for the reason ContractExampleSource
# gives: the registry is global and lives for the whole process, so the examples
# that need it register it and hand the key back afterwards.
class CanaryList < FakeDoctorSource
  class << self
    # What the next adapter built from this class parses into: the keywords
    # FakeDoctorSource takes.
    attr_writer :plan

    def key = :canary_list

    def plan = @plan || {}
  end

  def initialize(fetcher: nil, cache: nil, logger: nil, **options)
    _ = [fetcher, cache, logger]
    super(self.class.key, **self.class.plan.merge(options))
  end
end
