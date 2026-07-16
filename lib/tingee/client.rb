require "net/http"
require "json"
require "uri"

module Tingee
  # HTTP + endpoint methods. Only live-verified endpoints are wrapped — no
  # speculative "complete SDK". Responses use a uniform {code, message, data}
  # envelope EXCEPT get-banks, which returns a bare array (verified live).
  class Client
    # read_timeout: web requests keep the 90s default (stay under your proxy's
    # response timeout); background jobs should pass a larger value — bank-side
    # OTP verification on confirm_va can take minutes.
    def initialize(config = Tingee.config, read_timeout: 90)
      @config = config
      @read_timeout = read_timeout
      @config.validate!
    end

    # GET /v1/get-banks — returns the bare bank array (the supported-bank/BIN map).
    def get_banks
      get("/v1/get-banks")
    end

    # POST /v1/create-bank-link-session — returns the SDK URL string (data). No
    # merchant_id is needed for the default merchant; pass one only for a sub-merchant.
    def create_bank_link_session(merchant_id: nil, redirect_url: nil, allowed_banks: nil, bank_name: nil, shop_id: nil)
      payload = { type: "bank-link" }
      payload[:merchantId]   = merchant_id          if merchant_id
      payload[:redirectUrl]  = redirect_url         if redirect_url
      payload[:allowedBanks] = Array(allowed_banks) if allowed_banks
      payload[:bankName]     = bank_name            if bank_name
      payload[:shopId]       = shop_id              if shop_id
      post("/v1/create-bank-link-session", payload)
    end

    # POST /v1/get-va-paging — returns {totalCount, items} of linked virtual accounts.
    def get_va_paging(merchant_id: nil)
      payload = {}
      payload[:merchantId] = merchant_id if merchant_id
      post("/v1/get-va-paging", payload)
    end

    # POST /v1/create-va — starts a manual bank link (the raw API chain, usable when
    # Tingee's hosted JS SDK is unavailable or broken — docs/tingee-api-reference.md
    # §create-va, live-verified). The bank then sends/pushes an OTP to `mobile`.
    # Returns {confirmId, otpMethod}. `identity`/`mobile` should never be persisted
    # by the caller.
    #
    # is_notify_account_number: FALSE is the DEFAULT because it is the mode proved
    # end-to-end — a real VietQR transfer to the linked real account fired the webhook
    # on a notify=false link (2026-07-16). notify=true is documented as "watch the real
    # account" and MAY also work, but was never confirmed to fire on a plain transfer;
    # do not switch the default to true without a real-transfer test on a true link.
    def create_va(bank_bin:, account_number:, account_name:, identity:, mobile:, webhook_url:,
                   account_type: "personal-account", is_notify_account_number: false)
      post("/v1/create-va", {
        accountType: account_type, bankBin: bank_bin,
        accountNumber: account_number, accountName: account_name,
        identity: identity, mobile: mobile,
        isNotifyAccountNumber: is_notify_account_number,
        webhookUrl: webhook_url
      })
    end

    # POST /v1/confirm-va — finishes the link with the bank's OTP. Returns
    # {bankName, accountType, accountNumber (real), vaAccountNumber (routing key), shopId}.
    def confirm_va(bank_bin:, confirm_id:, otp_number:)
      post("/v1/confirm-va", { bankBin: bank_bin, confirmId: confirm_id, otpNumber: otp_number })
    end

    # POST /v1/register-notify — ACB only, run once right after confirm_va succeeds.
    # Returns {confirmId} for a second OTP round (see #confirm_register_notify).
    def register_notify(bank_bin:, va_account_number:)
      post("/v1/register-notify", { vaAccountNumber: va_account_number, bankBin: bank_bin })
    end

    def confirm_register_notify(bank_bin:, confirm_id:, otp_number:)
      post("/v1/confirm-register-notify", { bankBin: bank_bin, confirmId: confirm_id, otpNumber: otp_number })
    end

    # POST /v1/delete-va — starts an unlink. Params ride the QUERY STRING (not the
    # JSON body) and identify the bank by `bankName` (Tingee's short bank CODE, e.g.
    # "STB") — NOT bankBin. Verified live 2026-07-16; Tingee is inconsistent here
    # (confirm-delete-va below takes the body instead). Returns {confirmId}.
    def delete_va(bank_name:, va_account_number:)
      request(:post, "/v1/delete-va", query: { bankName: bank_name, vaAccountNumber: va_account_number })
    end

    # POST /v1/confirm-delete-va — finishes the unlink with the bank's OTP. Params
    # ride the BODY this time (unlike delete_va's query string above).
    def confirm_delete_va(bank_name:, confirm_id:, otp_number:)
      post("/v1/confirm-delete-va", { bankName: bank_name, confirmId: confirm_id, otpNumber: otp_number })
    end

    private

    def get(path)        = request(:get, path)
    def post(path, body) = request(:post, path, body)

    def request(method, path, payload = nil, query: nil)
      signed_body = JSON.generate(payload || {}) # bodyless request signs "{}", not ""
      ts  = Signature.timestamp
      sig = Signature.generate(secret: @config.secret_token, timestamp: ts, body: signed_body)
      uri = URI.join(@config.base_url, path)
      uri.query = URI.encode_www_form(query) if query # delete-va reads query params, not the body

      req = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri)
      req["Content-Type"]        = "application/json"
      req["x-client-id"]         = @config.client_id
      req["x-request-timestamp"] = ts
      req["x-signature"]         = sig
      req.body = signed_body unless method == :get

      parse(perform(uri, req))
    end

    # Transport seam — tests override with canned responses (see client_test.rb).
    def perform(uri, req)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = @read_timeout
      http.request(req)
    rescue Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
      # Normalize transport failures to Tingee::Error so callers handle one error type —
      # a bare timeout mid-link would otherwise crash the caller and strand the flow.
      raise Error.new("NETWORK", e.message)
    end

    def parse(res)
      body = res.body.to_s.empty? ? nil : JSON.parse(res.body)
      return body if body.is_a?(Array) # get-banks: a bare array IS the success payload

      raise Error.new("HTTP_#{res.code}", res.body.to_s) unless body.is_a?(Hash)
      raise Error.new(body["code"], body["message"]) unless body["code"] == "00"

      body["data"]
    rescue JSON::ParserError
      # A gateway/WAF error page (non-JSON) — surface as Tingee::Error, not a raw parse crash.
      raise Error.new("HTTP_#{res.code}", res.body.to_s)
    end
  end
end
