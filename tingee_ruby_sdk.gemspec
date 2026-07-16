require_relative "lib/tingee/version"

Gem::Specification.new do |spec|
  spec.name    = "tingee_ruby_sdk"
  spec.version = Tingee::VERSION
  spec.authors = ["lpwanw"]
  spec.email   = ["lp.wanw@gmail.com"]

  spec.summary     = "Ruby client for the Tingee BaaS API — bank linking, virtual accounts, payment webhooks"
  spec.description = "Pure-Ruby, zero-dependency client for Tingee (open-api.tingee.vn): " \
                     "HMAC-SHA512 request signing, bank-link sessions, the manual " \
                     "create-va/confirm-va OTP chain, unlink, and raw-body webhook " \
                     "signature verification. Built from a live-verified API contract."
  spec.homepage = "https://github.com/lpwanw/tingee_ruby_sdk"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "docs/*.md", "README.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"
end
