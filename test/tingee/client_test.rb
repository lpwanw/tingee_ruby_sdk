require "test_helper"

module Tingee
  class ClientTest < Minitest::Test
    # Fake config so tests never need real credentials.
    FakeConfig = Data.define(:client_id, :secret_token, :base_url, :shop_id) do
      def validate! = nil
    end

    FakeRes = Struct.new(:code, :body)

    # Transport-level fake: canned responses in call order, requests recorded.
    class FakeClient < Client
      attr_reader :requests

      def initialize(*responses, shop_id: nil)
        super(FakeConfig.new(client_id: "cid", secret_token: "sec", base_url: "https://open-api.tingee.vn", shop_id:))
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
      config = FakeConfig.new(client_id: "cid", secret_token: "sec", base_url: "https://open-api.tingee.vn", shop_id: nil)
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

    def test_create_va_carries_the_configured_shop_id_omits_it_when_unset
      c = FakeClient.new(FakeRes.new("200", '{"code":"00","message":"Success","data":{"confirmId":"123"}}'), shop_id: 252011)
      c.create_va(bank_bin: "970403", account_number: "0011", account_name: "LE PHUONG TAY",
        identity: "012345678901", mobile: "0393203261", webhook_url: "https://example.com/webhooks/tingee")
      assert_equal 252011, JSON.parse(c.requests.first[:body])["shopId"]

      c = FakeClient.new(FakeRes.new("200", '{"code":"00","message":"Success","data":{"confirmId":"123"}}'))
      c.create_va(bank_bin: "970403", account_number: "0011", account_name: "LE PHUONG TAY",
        identity: "012345678901", mobile: "0393203261", webhook_url: "https://example.com/webhooks/tingee")
      refute JSON.parse(c.requests.first[:body]).key?("shopId")
    end

    def test_create_va_explicit_shop_id_wins_over_the_configured_default
      c = FakeClient.new(FakeRes.new("200", '{"code":"00","message":"Success","data":{"confirmId":"123"}}'), shop_id: 252011)
      c.create_va(bank_bin: "970436", webhook_url: "https://example.com/webhooks/tingee", shop_id: 999)
      assert_equal 999, JSON.parse(c.requests.first[:body])["shopId"]
    end

    # Redirect-authorize bank (VCB): appType "baas" + redirectUrl make create-va answer
    # with a deepLink instead of sending an OTP; the result arrives on the webhook.
    def test_create_va_sends_the_redirect_authorize_fields_and_returns_the_deep_link
      c = FakeClient.new(FakeRes.new("200",
        '{"code":"00","message":"Success","data":[{"confirmId":"r1","deepLink":"vcbpartner://x"}]}'))
      data = c.create_va(bank_bin: "970436", account_number: "0912323232", mobile: "0987665555",
        webhook_url: "https://example.com/webhooks/tingee", app_type: "baas",
        redirect_url: "https://example.com/settings/bank", request_id: "req-1")

      body = JSON.parse(c.requests.first[:body])
      assert_equal "baas", body["appType"]
      assert_equal "https://example.com/settings/bank", body["redirectUrl"]
      assert_equal "req-1", body["requestId"]
      assert_equal "970436", body["bankBin"]
      assert_equal [ { "confirmId" => "r1", "deepLink" => "vcbpartner://x" } ], data
    end

    # No-account-field bank (TPB): the owner picks the account on the bank's own web,
    # so none of the account/identity params exist in its contract — they must be
    # absent from the payload, not sent as nulls.
    def test_create_va_omits_every_account_field_the_caller_did_not_supply
      c = FakeClient.new(FakeRes.new("200", '{"code":"00","message":"Success","data":[{"authorizeLink":"https://tpb/x"}]}'))
      c.create_va(bank_bin: "970423", webhook_url: "https://example.com/webhooks/tingee",
        app_type: "baas", redirect_url: "https://example.com/settings/bank", request_id: "req-2")

      assert_equal({
        "accountType" => "personal-account", "bankBin" => "970423",
        "isNotifyAccountNumber" => false, "webhookUrl" => "https://example.com/webhooks/tingee",
        "appType" => "baas", "redirectUrl" => "https://example.com/settings/bank",
        "requestId" => "req-2"
      }, JSON.parse(c.requests.first[:body]))
    end

    # An OTP bank never gets the redirect-authorize params it has no contract for.
    def test_create_va_omits_redirect_authorize_fields_for_a_plain_otp_bank
      c = FakeClient.new(FakeRes.new("200", '{"code":"00","message":"Success","data":{"confirmId":"123"}}'))
      c.create_va(bank_bin: "970403", account_number: "0011", account_name: "LE PHUONG TAY",
        identity: "012345678901", mobile: "0393203261", webhook_url: "https://example.com/webhooks/tingee")

      body = JSON.parse(c.requests.first[:body])
      refute body.key?("appType")
      refute body.key?("redirectUrl")
      refute body.key?("requestId")
    end

    def test_create_va_includes_optional_merchant_and_va_prefix_fields_when_given
      c = FakeClient.new(FakeRes.new("200", '{"code":"00","message":"Success","data":[]}'))
      c.create_va(bank_bin: "970436", webhook_url: "https://app/hook",
        merchant_id: 140998, merchant_name: "Cửa hàng số 1", merchant_address: "Hà Nội",
        va_prefix: "PRE", va_suffix: "SUF")

      body = JSON.parse(c.requests.first[:body])
      assert_equal 140998, body["merchantId"]
      assert_equal "Cửa hàng số 1", body["merchantName"]
      assert_equal "Hà Nội", body["merchantAddress"]
      assert_equal "PRE", body["vaPrefix"]
      assert_equal "SUF", body["vaSuffix"]
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

    # bankBin, NOT bankName: the bankName variant also returns a confirmId and fires the
    # bank's OTP, but the session it opens cannot be confirmed — confirm-delete-va then
    # 400s with "Lỗi hệ thống phương thức xác thực" (live, 2026-07-17).
    def test_delete_va_sends_bank_bin_and_va_account_number_as_query_params_not_the_body
      c = FakeClient.new(FakeRes.new("200", '{"code":"00","message":"Success","data":{"confirmId":"789"}}'))
      data = c.delete_va(bank_bin: "970403", va_account_number: "TNG1")

      assert_equal "789", data["confirmId"]
      uri = URI(c.requests.first[:uri])
      assert_equal({ "bankBin" => "970403", "vaAccountNumber" => "TNG1" }, URI.decode_www_form(uri.query).to_h)
      assert_equal "{}", c.requests.first[:body] # bodyless signing convention still applies
    end

    def test_confirm_delete_va_sends_bank_bin_confirm_id_and_otp_number_in_the_body
      c = FakeClient.new(FakeRes.new("200", '{"code":"00","message":"Success","data":null}'))
      c.confirm_delete_va(bank_bin: "970403", confirm_id: "789", otp_number: "222222")

      body = JSON.parse(c.requests.first[:body])
      assert_equal({ "bankBin" => "970403", "confirmId" => "789", "otpNumber" => "222222" }, body)
    end

    def test_get_transactions_sends_only_the_required_time_window_when_no_filters_given
      c = FakeClient.new(FakeRes.new("200", '{"code":"00","message":"Success","data":{"totalCount":0,"items":[]}}'))
      c.get_transactions(start_time: "20260701000000", end_time: "20260710235959")

      body = JSON.parse(c.requests.first[:body])
      assert_equal({ "startTime" => "20260701000000", "endTime" => "20260710235959" }, body)
    end

    def test_get_transactions_includes_optional_filters_and_arrays_when_given
      c = FakeClient.new(FakeRes.new("200", '{"code":"00","message":"Success","data":{"totalCount":0,"items":[]}}'))
      c.get_transactions(start_time: "20260701000000", end_time: "20260710235959",
                         filter: "abc", skip_count: 0, max_result_count: 20,
                         va_account_numbers: "TNG1", bank_bin: "970403")

      body = JSON.parse(c.requests.first[:body])
      assert_equal({
        "startTime" => "20260701000000", "endTime" => "20260710235959",
        "filter" => "abc", "skipCount" => 0, "maxResultCount" => 20,
        "vaAccountNumbers" => [ "TNG1" ], "bankBin" => "970403"
      }, body)
    end

  end
end
