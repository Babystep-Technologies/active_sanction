# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "active_sanction/error"
require "active_sanction/version"
require "active_sanction/configuration"
require "active_sanction/name"
require "active_sanction/address"
require "active_sanction/identifier"
require "active_sanction/partial_date"
require "active_sanction/entity"
require "active_sanction/snapshot"
require "active_sanction/http_client"
require "active_sanction/validators"
require "active_sanction/validator_store"
require "active_sanction/fetcher"
require "active_sanction/payload_cache"
require "active_sanction/parsers"
require "active_sanction/sources"
require "active_sanction/storage"
require "active_sanction/normalizer"
require "active_sanction/similarity"
require "active_sanction/phonetics"
require "active_sanction/sources/ofac_sdn"
require "active_sanction/sources/ofac_consolidated"
require "active_sanction/sources/un_consolidated"
require "active_sanction/sources/canada_sema"

module ActiveSanction
  class << self
    extend T::Sig

    # Library-wide settings. Reading this before anything is configured builds
    # the defaults, so nothing has to remember to initialize it.
    sig { returns(Configuration) }
    def config
      @config ||= T.let(Configuration.new, T.nilable(Configuration))
    end

    # The one entry point an application is expected to call at boot:
    #
    #   ActiveSanction.configure do |c|
    #     c.user_agent = "my-app/1.0 (compliance@example.com)"
    #   end
    sig { params(block: T.proc.params(config: Configuration).void).returns(Configuration) }
    def configure(&block)
      block.call(config)
      config
    end

    # Mostly for tests, which need each example to start from the defaults
    # rather than from whatever the last one set.
    sig { returns(Configuration) }
    def reset_configuration!
      @config = T.let(nil, T.nilable(Configuration))
      config
    end
  end
end
