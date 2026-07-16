require "test_helper"

module Tingee
  class SignatureTest < Minitest::Test
    # Known-good triple captured live from GET /v1/get-banks (2026-07-16). Runs only
    # when TINGEE_SECRET_TOKEN is set (the matching secret); regenerate the triple
    # with a live get-banks call if the secret rotates.
    KNOWN_TS   = "20260716155928753".freeze
    KNOWN_BODY = "{}".freeze
    KNOWN_SIG  = "93a3031c8e3a26ede4d4d684cad1f69a459acbfc24deb87a39ed918a6b70f909537105e8f7c491f59932ff9401c5499c8d92a02e6709a8310ddc947255ab4de4".freeze

    def test_generate_reproduces_a_real_captured_signature
      secret = ENV["TINGEE_SECRET_TOKEN"]
      skip "TINGEE_SECRET_TOKEN not set in this env" unless secret

      assert_equal KNOWN_SIG, Signature.generate(secret:, timestamp: KNOWN_TS, body: KNOWN_BODY)
    end

    def test_a_bodyless_request_signs_braces_not_empty_string
      # code-97 regression guard: signing "" instead of "{}" is rejected by Tingee
      refute_equal Signature.generate(secret: "s", timestamp: "t", body: "{}"),
        Signature.generate(secret: "s", timestamp: "t", body: "")
    end

    def test_verify_round_trips_the_raw_body
      raw = '{"transactionCode":"T1","amount":250000}'
      sig = Signature.generate(secret: "shh", timestamp: KNOWN_TS, body: raw)

      assert Signature.verify(secret: "shh", timestamp: KNOWN_TS, raw_body: raw, signature: sig)
    end

    def test_verify_hashes_raw_bytes_not_a_reserialized_body
      # Real webhooks are signed over the raw body (verified live 2026-07-16). This
      # body has a space JSON.generate would strip — signing raw must still verify,
      # and a re-serialized approach would have produced a different signature.
      raw = '{"amount": 2000}'
      raw_sig = Signature.generate(secret: "shh", timestamp: "t", body: raw)

      assert Signature.verify(secret: "shh", timestamp: "t", raw_body: raw, signature: raw_sig)
      refute_equal raw_sig, Signature.generate(secret: "shh", timestamp: "t", body: '{"amount":2000}')
    end

    def test_verify_rejects_a_tampered_body
      sig = Signature.generate(secret: "shh", timestamp: "t", body: JSON.generate({ "amount" => 1 }))
      refute Signature.verify(secret: "shh", timestamp: "t", raw_body: '{"amount":999}', signature: sig)
    end

    def test_verify_rejects_a_wrong_secret
      raw = '{"amount":1}'
      sig = Signature.generate(secret: "right", timestamp: "t", body: raw)
      refute Signature.verify(secret: "wrong", timestamp: "t", raw_body: raw, signature: sig)
    end

    def test_secure_compare_is_length_and_content_safe
      refute Signature.secure_compare("abc", "ab")
      refute Signature.secure_compare("abc", "abd")
      assert Signature.secure_compare("abc", "abc")
    end

    def test_timestamp_is_17_digits
      assert_match(/\A\d{17}\z/, Signature.timestamp)
    end
  end
end
