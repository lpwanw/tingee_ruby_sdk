require "test_helper"

module Tingee
  class ClientTest < Minitest::Test
    # Fake config so tests never need real credentials.
    FakeConfig = Data.define(:client_id, :secret_token, :base_url) do
      def validate! = nil
    end

    FakeRes = Struct.new(:code, :body)

    # Transport-level fake: canned responses in call order, requests recorded.
    class FakeClient < Client
      attr_reader :requests

      def initialize(*responses)
        super(FakeConfig.new(client_id: "cid", secret_token: "sec", base_url: "https://open-api.tingee.vn"))
        @responses = responses
        @requests = []
      end

      private

      def perform(uri, req)
        @requests << { uri: uri.to_s, method: req.method, body: req.body, headers: req.to_hash }
        @responses.shift or raise "unexpected extra request to #{uri}"
      end
    end

    def test_get_banks_returns_the_bare_array_no_envelope
      c = FakeClient.new(FakeRes.new("200", '[{"code":"VCB","bin":"970436"}]'))
      assert_equal [ { "code" => "VCB", "bin" => "970436" } ], c.get_banks
    end

    def test_every_request_carries_the_three_auth_headers_signature_is_sha512_hex
      c = FakeClient.new(FakeRes.new("200", "[]"))
      c.get_banks
      h = c.requests.first[:headers]

      assert_equal "cid", h["x-client-id"].first
      assert_match(/\A\d{17}\z/, h["x-request-timestamp"].first)
      assert_equal 128, h["x-signature"].first.length
    end

    def test_get_signs_but_sends_no_body
      c = FakeClient.new(FakeRes.new("200", "[]"))
      c.get_banks
      assert_nil c.requests.first[:body]
    end

    def test_post_sends_the_minified_signed_body
      c = FakeClient.new(FakeRes.new("200", '{"code":"00","message":"Success","data":"url"}'))
      c.create_bank_link_session
      assert_equal '{"type":"bank-link"}', c.requests.first[:body]
    end

    def test_unwraps_the_data_envelope_on_success
      c = FakeClient.new(FakeRes.new("200", '{"code":"00","message":"Success","data":{"totalCount":0,"items":[]}}'))
      assert_equal({ "totalCount" => 0, "items" => [] }, c.get_va_paging)
    end

    def test_create_bank_link_session_returns_the_sdk_url_string
      c = FakeClient.new(FakeRes.new("200", '{"code":"00","message":"Success","data":"https://bank-link.tingee.vn?token=x"}'))
      assert_equal "https://bank-link.tingee.vn?token=x", c.create_bank_link_session
    end

    def test_raises_tingee_error_carrying_the_raw_code_on_a_non_00_response
      c = FakeClient.new(FakeRes.new("200", '{"code":"97","message":"Invalid signature","data":null}'))
      err = assert_raises(Tingee::Error) { c.get_va_paging }
      assert_equal "97", err.code
    end

    def test_a_non_json_error_body_raises_tingee_error_not_a_raw_parse_crash
      c = FakeClient.new(FakeRes.new("502", "<html>Bad Gateway</html>"))
      err = assert_raises(Tingee::Error) { c.get_va_paging }
      assert_equal "HTTP_502", err.code
    end

    def test_read_timeout_is_overridable_per_client_web_default_stays_90
      config = FakeConfig.new(client_id: "cid", secret_token: "sec", base_url: "https://open-api.tingee.vn")
      assert_equal 90, Client.new(config).instance_variable_get(:@read_timeout)
      assert_equal 300, Client.new(config, read_timeout: 300).instance_variable_get(:@read_timeout)
    end

    def test_missing_credentials_raise_the_config_error
      err = assert_raises(Tingee::Error) do
        Client.new(Configuration.new) # no client_id/secret_token set
      end
      assert_equal "CONFIG", err.code
      assert_match(/credentials/, err.message)
    end

    # --- manual bank-link chain (create-va → confirm-va, + register-notify) ------

    def test_create_va_posts_the_va_watch_payload_and_returns_confirm_id_and_otp_method
      c = FakeClient.new(FakeRes.new("200", '{"code":"00","message":"Success","data":{"confirmId":"123","otpMethod":"SmartOTP"}}'))
      data = c.create_va(bank_bin: "970403", account_number: "0011", account_name: "LE PHUONG TAY",
        identity: "012345678901", mobile: "0393203261", webhook_url: "https://example.com/webhooks/tingee")

      assert_equal({ "confirmId" => "123", "otpMethod" => "SmartOTP" }, data)
      body = JSON.parse(c.requests.first[:body])
      assert_equal "970403", body["bankBin"]
      assert_equal false, body["isNotifyAccountNumber"] # verified-working mode (real transfer fired the webhook)
      assert_equal "0393203261", body["mobile"] # domestic 0-prefixed, never 84-prefixed
    end

    def test_confirm_va_sends_the_otp_and_returns_the_real_account_and_routing_key
      c = FakeClient.new(FakeRes.new("200",
        '{"code":"00","message":"Success","data":{"bankName":"STB","accountNumber":"040072649119","vaAccountNumber":"TNG1","shopId":251809}}'))
      data = c.confirm_va(bank_bin: "970403", confirm_id: "123", otp_number: "999999")

      assert_equal "040072649119", data["accountNumber"]
      assert_equal "TNG1", data["vaAccountNumber"]
      body = JSON.parse(c.requests.first[:body])
      assert_equal({ "bankBin" => "970403", "confirmId" => "123", "otpNumber" => "999999" }, body)
    end

    def test_register_notify_and_confirm_register_notify_acb_extra_round
      c = FakeClient.new(
        FakeRes.new("200", '{"code":"00","message":"Success","data":{"confirmId":"456"}}'),
        FakeRes.new("200", '{"code":"00","message":"Success","data":null}')
      )
      data = c.register_notify(bank_bin: "970416", va_account_number: "TNG1")
      assert_equal "456", data["confirmId"]

      c.confirm_register_notify(bank_bin: "970416", confirm_id: "456", otp_number: "111111")
      body = JSON.parse(c.requests.last[:body])
      assert_equal({ "bankBin" => "970416", "confirmId" => "456", "otpNumber" => "111111" }, body)
    end

    # --- unlink chain (delete-va = query params, confirm-delete-va = body) -------

    def test_delete_va_sends_bank_name_and_va_account_number_as_query_params_not_the_body
      c = FakeClient.new(FakeRes.new("200", '{"code":"00","message":"Success","data":{"confirmId":"789"}}'))
      data = c.delete_va(bank_name: "STB", va_account_number: "TNG1")

      assert_equal "789", data["confirmId"]
      uri = URI(c.requests.first[:uri])
      assert_equal({ "bankName" => "STB", "vaAccountNumber" => "TNG1" }, URI.decode_www_form(uri.query).to_h)
      assert_equal "{}", c.requests.first[:body] # bodyless signing convention still applies
    end

    def test_confirm_delete_va_sends_bank_name_confirm_id_and_otp_number_in_the_body
      c = FakeClient.new(FakeRes.new("200", '{"code":"00","message":"Success","data":null}'))
      c.confirm_delete_va(bank_name: "STB", confirm_id: "789", otp_number: "222222")

      body = JSON.parse(c.requests.first[:body])
      assert_equal({ "bankName" => "STB", "confirmId" => "789", "otpNumber" => "222222" }, body)
    end
  end
end
