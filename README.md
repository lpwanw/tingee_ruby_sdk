# tingee_ruby_sdk

Ruby client for the [Tingee](https://tingee.vn) BaaS API (`open-api.tingee.vn`) —
bank account linking, virtual accounts, and payment webhooks for Vietnamese banks.
Official API docs: [developers.tingee.vn/docs/banking](https://developers.tingee.vn/docs/banking/).

- **Pure Ruby, zero runtime dependencies.** `net/http`, `openssl`, `json` only. No
  Rails required (enforced by a boundary test).
- **Built from a live-verified API contract.** Every wrapped endpoint and every
  signing rule in this gem was observed against the production API (2026-07-16),
  not copied from marketing docs. The full observed contract, including Tingee's
  quirks and known bugs, lives in [`docs/tingee-api-reference.md`](docs/tingee-api-reference.md).
- **Only verified endpoints are wrapped** — no speculative "complete SDK".

> **Building the full auto-confirm feature?** Follow
> [`docs/bank-auto-confirm-integration-guide.md`](docs/bank-auto-confirm-integration-guide.md) —
> a complete app-side playbook (data model, link state machine, webhook endpoint,
> payment matching, go-live checklist) distilled from a production integration.
> Written so you can hand the link to an AI coding agent and it knows what to build.

## Installation

```ruby
# Gemfile
gem "tingee_ruby_sdk"
```

Or track the unreleased main branch:

```ruby
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
  # c.shop_id  = 252011  # optional: group every VA under ONE Tingee shop (one shop
                         # per project); unset, Tingee auto-creates a shop per link
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

One `create_va` serves every bank; the bank decides which shape you get back. OTP banks
are below, redirect-authorize banks (VCB/TPB) in the next section.

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

### Bank linking — redirect-authorize banks (VCB, TPB)

Same `create_va`, different bank behavior: pass `app_type: "baas"` + `redirect_url` and
the bank answers with an **authorize link** instead of sending an OTP. There is **no
`confirm_va` step** — the owner approves in the bank's app/web and the result arrives
**asynchronously on your webhook** as `status: "confirm-va-success" | "confirm-va-failed"`
(see [§Webhooks](docs/tingee-api-reference.md#7-webhooks)).

```ruby
# Pass and STORE your own request_id — it's echoed back on the webhook to correlate.
# TPB returns NO confirmId at all, so your request_id is the ONLY correlation key.
data = client.create_va(
  bank_bin:       "970436",              # VCB
  request_id:     my_link_id,
  account_number: "0912323232",
  mobile:         "0987665555",
  app_type:       "baas",
  redirect_url:   "https://yourapp.com/settings/bank",  # where the bank sends them back
  webhook_url:    "https://yourapp.com/webhooks/tingee"
)
data.first["deepLink"] # "vcbpartner://linkPaymentEvent?token=…" — open in VCB Digibank
                       # (TPB answers with "authorizeLink" — an https page)

# Later, on your webhook (verify the signature first — see below):
#   payload["status"] == "confirm-va-success" → payload["vaAccountNumber"] is now linked
```

Banks whose contract collects nothing from you (TPB — the owner picks the account on the
bank's own web) simply omit `account_number`/`account_name`/`identity`/`mobile`; unset
params are never sent.

### Listing linked accounts

```ruby
client.get_va_paging # => {"totalCount"=>1, "items"=>[{"vaAccountNumber"=>"TNG…", "status"=>"active", …}]}
```

### Unlinking

```ruby
# Note Tingee's inconsistency: delete-va takes QUERY params, confirm-delete-va takes a
# JSON BODY. Both identify the bank by its BIN ("970403"). The gem handles the transport.
r = client.delete_va(bank_bin: "970403", va_account_number: "TNG…")
client.confirm_delete_va(bank_bin: "970403", confirm_id: r["confirmId"], otp_number: "111111")
```

> **Do not pass the bank's short CODE (`bankName: "STB"`) to delete-va.** It looks like
> it works — Tingee returns a `confirmId` and the bank really does send an OTP — but the
> session it opens cannot be confirmed: `confirm-delete-va` then fails with
> `"Lỗi hệ thống phương thức xác thực"` (live, 2026-07-17). Since unlinking is the only
> way to stop per-webhook billing, an unlink that silently cannot complete keeps costing
> money.

Bank-shape variations on `delete_va`'s response are the caller's to branch on: OTP banks
return `{confirmId}`, TPB returns an `authorizeLink`, and VCB returns `{}` because it
detaches immediately — nothing left to confirm.

### Transaction history

```ruby
# start_time/end_time are required ("yyyyMMddHHmmss", UTC+7); max 10-day window.
client.get_transactions(start_time: "20260701000000", end_time: "20260710235959")
# => {"totalCount"=>100, "items"=>[{"transactionId"=>…, "amount"=>100000, "type"=>"CREDIT", …}]}

# Optional filters: filter (keyword), skip_count, max_result_count, merchant_id,
# shop_ids, va_account_numbers, bank_bin.
```

Unlinking is also how you stop Tingee's per-webhook billing for an account.

### VietQR payment codes

Mint the payer-facing transfer QR locally — no `img.vietqr.io` round-trip, no API call:

```ruby
memo    = Tingee::VietQR.normalize_description("Thanh toán đơn HD#{invoice.id}")
payload = Tingee::VietQR.payload(
  bank_bin:       link.tingee_bank_bin,
  account_number: link.bank_account_number,  # the REAL account from confirm_va
  amount:         invoice.total,             # whole VND; omit or 0 for an open-amount QR
  description:    memo
)
# => "00020101021138540010A00000072701240006…5802VN6225…6304<CRC>"
```

`amount` is parsed, never coerced: anything that is not a whole non-negative number of
dong raises `Tingee::Error` with code `"QR_INPUT"`. That includes the formatted strings
a form field or CSV will hand you — `"1.234.567"` is rejected rather than silently
becoming a **1 ₫** QR. `Integer`, whole `Float`/`BigDecimal`/`Rational`, and a bare
digit string all work.

The gem returns the **EMVCo payload string, not an image** — QR pixel encoding is
Reed-Solomon plus masking, which would mean a runtime dependency, and this gem has
none. Render it app-side:

```ruby
require "rqrcode"   # add to YOUR Gemfile — deliberately not a dependency of this gem
RQRCode::QRCode.new(payload).as_png(size: 512)
```

> **`description` is ASCII-folded and truncated to 25 chars** (`Thanh toán` → `Thanh toan`),
> because many bank scanners mangle or reject a non-ASCII memo. **Persist the string
> `normalize_description` returns and match your webhook's `description` against that** —
> matching against your original un-normalized text silently misses every payment.
>
> A description that survives normalization as nothing (emoji or symbols only) raises
> `"QR_INPUT"` rather than minting a QR with no reference the matcher could key on.

A plain transfer into the linked real account fires the payment webhook regardless of
which tool minted the QR, so nothing here needs Tingee's (broken) dynamic-QR endpoint.
Ported from [openhoangnc/vietqr](https://github.com/openhoangnc/vietqr) (MIT); the test
suite reproduces that project's fixtures byte-exact.

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
