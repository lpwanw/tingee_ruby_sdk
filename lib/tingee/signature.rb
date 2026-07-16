require "openssl"
require "json"

module Tingee
  # HMAC-SHA512 signing, per the official tingee-node SDK and verified live
  # (docs/tingee-api-reference.md §Auth). Outbound requests sign
  # `timestamp + ":" + minified_body`, where a bodyless request signs "{}" (not "")
  # — signing "" returns code 97. Inbound webhooks are verified over the RAW body
  # bytes, not a re-serialization (see #verify).
  module Signature
    module_function

    # yyyyMMddHHmmssSSS in UTC+7. Server rejects >10 min clock drift (error 90).
    def timestamp(now = Time.now)
      now.getlocal("+07:00").strftime("%Y%m%d%H%M%S%L")
    end

    def generate(secret:, timestamp:, body:)
      # `.b`: hash raw bytes (silences the json 3.0 UTF-8/BINARY warning); the
      # digest of ASCII/UTF-8 bytes is unchanged either way.
      OpenSSL::HMAC.hexdigest("SHA512", secret, "#{timestamp}:#{body}".b)
    end

    # Verify an inbound webhook signature. Resolved against a real captured payment
    # webhook (2026-07-16): Tingee signs the RAW body bytes exactly as sent.
    # We hash `raw_body` verbatim — do NOT re-parse/re-serialize. Raw is both correct
    # and immune to Ruby-vs-JS number formatting (a re-serialized whole-number float
    # would render "250000.0" in Ruby vs "250000" in JS and break a valid signature).
    # The caller must pass the body exactly as received (Rails: `request.raw_post`),
    # never a re-encoded body.
    def verify(secret:, timestamp:, raw_body:, signature:)
      secure_compare(generate(secret:, timestamp:, body: raw_body), signature.to_s)
    end

    # Constant-time comparison, hand-rolled so the gem needs no ActiveSupport.
    def secure_compare(left, right)
      return false unless left.bytesize == right.bytesize

      diff = 0
      left.each_byte.with_index { |byte, i| diff |= byte ^ right.getbyte(i) }
      diff.zero?
    end
  end
end
