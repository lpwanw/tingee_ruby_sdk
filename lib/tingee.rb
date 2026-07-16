# Ruby client for the Tingee BaaS API (https://open-api.tingee.vn) — bank account
# linking, virtual accounts, and payment webhooks. Pure Ruby, zero runtime
# dependencies, no Rails required (guarded by test/tingee/rails_free_boundary_test.rb).
#
# The observed API contract lives in docs/tingee-api-reference.md (signing recipe,
# envelope shapes, error codes — all verified against the live API 2026-07-16).
# Credentials are INJECTED via Tingee.configure; this library never reads any
# credential store itself.
require_relative "tingee/version"
require_relative "tingee/error"
require_relative "tingee/configuration"
require_relative "tingee/signature"
require_relative "tingee/client"

module Tingee
  class << self
    def configure
      yield config
      config
    end

    def config
      @config ||= Configuration.new
    end

    # test seam — swap in a fake config, reset between examples
    attr_writer :config
  end
end
