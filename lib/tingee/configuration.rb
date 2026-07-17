module Tingee
  # Injected credentials — set via Tingee.configure (e.g. from a Rails initializer);
  # this layer never reads any credential store itself.
  class Configuration
    # shop_id: every VA this app creates is grouped under one Tingee shop
    # (one shop per project). Optional: nil sends no shopId and Tingee
    # auto-creates a throwaway shop per link.
    attr_accessor :client_id, :secret_token, :base_url, :shop_id

    def initialize
      @base_url = "https://open-api.tingee.vn"
    end

    # Called when a client is built, not at load — a credential-less env still boots.
    def validate!
      return if client_id && secret_token

      raise Error.new("CONFIG", "Missing Tingee credentials (client_id, secret_token) — set them via Tingee.configure")
    end
  end
end
