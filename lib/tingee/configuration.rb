module Tingee
  # Injected credentials — set via Tingee.configure (e.g. from a Rails initializer);
  # this layer never reads any credential store itself.
  class Configuration
    attr_accessor :client_id, :secret_token, :base_url

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
