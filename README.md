# tingee_ruby_sdk

Ruby client for the [Tingee](https://tingee.vn) BaaS API (`open-api.tingee.vn`) —
bank account linking, virtual accounts, and payment webhooks for Vietnamese banks.

- **Pure Ruby, zero runtime dependencies.** `net/http`, `openssl`, `json` only. No
  Rails required (enforced by a boundary test).
- **Built from a live-verified API contract.** Every wrapped endpoint and every
  signing rule in this gem was observed against the production API (2026-07-16),
  not copied from marketing docs. The full observed contract, including Tingee's
  quirks and known bugs, lives in [`docs/tingee-api-reference.md`](docs/tingee-api-reference.md).
- **Only verified endpoints are wrapped** — no speculative "complete SDK".

## Installation

Not published to RubyGems yet — install from GitHub:

```ruby
# Gemfile
gem "tingee_ruby_sdk", github: "lpwanw/tingee_ruby_sdk"
```

Or from a local checkout:

```ruby
gem "tingee_ruby_sdk", path: "../tingee_ruby_sdk"
```

## Configuration

Credentials are injected — the gem never reads any credential store itself:

```ruby
# e.g. config/initializers/tingee.rb in a Rails app
Tingee.configure do |c|
  c.client_id    = ENV["TINGEE_CLIENT_ID"]      # or Rails credentials, etc.
  c.secret_token = ENV["TINGEE_SECRET_TOKEN"]
  # c.base_url = "https://open-api.tingee.vn"   # default (production)
end
```

Validation happens when a client is built, not at load time — a credential-less
environment still boots. A missing credential raises `Tingee::Error` with code
`"CONFIG"`.

## Usage

### Client basics

```ruby
client = Tingee::Client.new                     # uses Tingee.config, 90s read timeout
slow   = Tingee::Client.new(read_timeout: 300)  # for background jobs (OTP confirm can take minutes)
```

All methods return the unwrapped `data` payload on success (`code "00"`), or raise
`Tingee::Error` (see [Error handling](#error-handling)).

### Supported banks

```ruby
client.get_banks
# => bare array (NOT the usual envelope): [{"code"=>"VCB", "name"=>..., "bin"=>"970436", ...}, ...]
```

14 real banks are supported; notably **Techcombank (TCB) is NOT supported**. Full
verified bank/BIN table in the [API reference](docs/tingee-api-reference.md#1-get-banks--supported-banks).

### Bank linking — hosted SDK flow

```ruby
url = client.create_bank_link_session(redirect_url: "https://yourapp.com/settings/bank")
# => "https://bank-link.tingee.vn?token=…" — redirect the user there
```

An empty payload works for the default merchant; pass `merchant_id:` only for a
sub-merchant. Note: Tingee's hosted JS SDK had a live crash bug at verification
time (`confirmId.startsWith`) — the manual chain below is the verified fallback.

### Bank linking — manual API chain (verified end-to-end)

```ruby
# 1. Start the link — the bank sends/pushes an OTP to `mobile`
data = client.create_va(
  bank_bin:       "970403",             # Napas BIN (STB/Sacombank here)
  account_number: "0400…",
  account_name:   "NGUYEN VAN A",
  identity:       "0123456789…",        # CCCD — do not persist
  mobile:         "09xxxxxxxx",         # MUST be domestic 0-prefixed; "84…" is rejected
  webhook_url:    "https://yourapp.com/webhooks/tingee"
)
data # => {"confirmId"=>"…", "otpMethod"=>"SmartOTP"}

# 2. Finish with the bank's OTP (can take minutes bank-side — use a background job)
link = client.confirm_va(bank_bin: "970403", confirm_id: data["confirmId"], otp_number: "123456")
link["accountNumber"]   # the REAL bank account — money lands here, show this on QRs
link["vaAccountNumber"] # "TNG…" — Tingee-internal ROUTING KEY, store it to route webhooks

# 3. ACB only: one extra OTP round
r = client.register_notify(bank_bin: "970416", va_account_number: link["vaAccountNumber"])
client.confirm_register_notify(bank_bin: "970416", confirm_id: r["confirmId"], otp_number: "654321")
```

### Listing linked accounts

```ruby
client.get_va_paging # => {"totalCount"=>1, "items"=>[{"vaAccountNumber"=>"TNG…", "status"=>"active", …}]}
```

### Unlinking

```ruby
# Note Tingee's inconsistency: delete-va takes QUERY params and the bank's short
# CODE ("STB"), not the BIN; confirm-delete-va takes a JSON BODY. The gem handles it.
r = client.delete_va(bank_name: "STB", va_account_number: "TNG…")
client.confirm_delete_va(bank_name: "STB", confirm_id: r["confirmId"], otp_number: "111111")
```

Unlinking is also how you stop Tingee's per-webhook billing for an account.

## Webhook verification

Tingee signs webhooks with `HMAC_SHA512(secret, timestamp + ":" + raw_body)` over
the **raw body bytes exactly as sent** (verified against a real captured payment
webhook). Pass the body verbatim — never re-parse/re-serialize it:

```ruby
Tingee::Signature.verify(
  secret:    Tingee.config.secret_token,
  timestamp: request_headers["x-request-timestamp"],
  raw_body:  raw_request_body,   # Rails: request.raw_post — verbatim!
  signature: request_headers["x-signature"]
) # => true/false (constant-time comparison)
```

### Rails controller example

```ruby
class Webhooks::TingeeController < ActionController::Base
  skip_forgery_protection

  ACK = { code: "00", message: "Success" }.freeze

  def create
    raw = request.raw_post
    payload = JSON.parse(raw) rescue nil
    return render(json: ACK) if payload.nil?

    # Dashboard connection test: unsigned {"event":"ping"} — ack it or the
    # dashboard's test shows failure. Don't verify, don't process.
    return render(json: ACK) if payload["event"] == "ping"

    unless Tingee::Signature.verify(
      secret: Tingee.config.secret_token,
      timestamp: request.headers["x-request-timestamp"],
      raw_body: raw,
      signature: request.headers["x-signature"]
    )
      return head(:unauthorized)
    end

    # payload: {"transactionCode", "amount" (integer), "content" (memo),
    #           "accountNumber", "vaAccountNumber", "bankBin", "transactionDate", …}
    # Route on vaAccountNumber (unique per link), idempotency-key on transactionCode.
    render json: ACK # always ack so Tingee stops retrying
  end
end
```

Payment-callback field semantics are documented in the
[API reference §Webhooks](docs/tingee-api-reference.md#7-webhooks).

## Error handling

Every failure raises `Tingee::Error` with the raw Tingee code preserved:

```ruby
begin
  client.confirm_va(bank_bin:, confirm_id:, otp_number:)
rescue Tingee::Error => e
  e.code    # "97" (bad signature), "90" (timestamp drift), "1001".."1076" (business),
            # "HTTP_502" (non-JSON gateway page), "NETWORK" (transport), "CONFIG"
  e.message # "Tingee error 97: Invalid signature"
end
```

Transport failures (timeouts, DNS, TLS) are normalized to code `"NETWORK"` so
callers handle one error type.

## Signing rules (the things that will bite you)

- Signature = `HMAC_SHA512(secret, timestamp + ":" + minified_json_body)`, hex digest.
- Timestamp header format `yyyyMMddHHmmssSSS` in **UTC+7**; >10 min drift → error `90`.
- A bodyless request (e.g. GET) still signs the string `"{}"` — signing `""` → error `97`.
- Webhooks verify over **raw bytes**, outbound requests sign the minified body.

All handled by the gem; listed here so you don't fight them when debugging.

## Testing

```bash
bundle install
bundle exec rake test
```

### Poking the live API

Rails apps: `bin/rails console` (with the initializer set) — `Tingee::Client.new.get_banks`.
Without Rails:

```bash
TINGEE_CLIENT_ID=… TINGEE_SECRET_TOKEN=… bin/console
> client = Tingee::Client.new
> client.get_banks
```

One test reproduces a real captured signature and only runs when
`TINGEE_SECRET_TOKEN` is set; it is skipped otherwise.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
