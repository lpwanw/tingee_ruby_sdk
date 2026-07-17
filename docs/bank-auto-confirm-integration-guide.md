# Bank auto-confirm integration guide

A step-by-step playbook for wiring `tingee_ruby_sdk` into an app so customer bank
transfers automatically confirm payments. Written to be handed to an AI coding
agent or a developer with zero prior context — follow it top to bottom.

Distilled from a production Rails integration (multi-tenant invoicing app,
2026-07). Rails examples throughout, but every rule is framework-agnostic; the
Rails-specific parts are marked. API-level facts live in
[`tingee-api-reference.md`](tingee-api-reference.md) (official docs:
[developers.tingee.vn/docs/banking](https://developers.tingee.vn/docs/banking/)) —
this file is the app-side architecture.

## What you're building

1. **Link**: a business owner links their Vietnamese bank account to Tingee
   (OTP-verified). You store a routing key.
2. **Receive**: any plain bank transfer into that account (VietQR, manual
   transfer — no Tingee QR needed) fires a signed webhook to your app.
3. **Match**: your app routes the webhook to the right account/tenant, matches it
   to an open invoice/order (memo + exact amount), and marks it paid.
4. **Unlink**: reverses the link — also the ONLY way to stop Tingee's
   per-webhook billing (every delivered webhook bills, matched or not).

## 0. Prerequisites

- Tingee merchant account with API credentials (`client_id`, `secret_token`).
- In the Tingee dashboard: register your webhook URL
  (`https://yourapp.com/webhooks/tingee`) with auth = **API Credentials** (HMAC),
  NOT the static API-key option.
- The gem: `gem "tingee_ruby_sdk", github: "lpwanw/tingee_ruby_sdk"`.
- Know your supported-bank story: **Techcombank is NOT supported** (see the API
  reference §1 for the full list). Hide/explain the link button for unsupported
  banks.

## 1. Configure credentials

Inject at boot; never let the gem read a credential store. Missing credentials
must not fail boot — `Tingee::Client.new` raises only when actually used.

```ruby
# config/initializers/tingee.rb (Rails)
Rails.application.config.to_prepare do
  creds = Rails.application.credentials.tingee
  next unless creds

  Tingee.configure do |c|
    c.client_id    = creds[:client_id]
    c.secret_token = creds[:secret_token]
    c.base_url     = creds[:base_url] if creds[:base_url] # default is prod
  end
end
```

`to_prepare` (not a bare initializer body) so the config survives dev reloads.

## 2. Data model

Three pieces of state. Adapt names to your domain (`organizations` below = your
tenant/account model).

### 2a. On the linked account (organization)

| Column | Source | Purpose |
|---|---|---|
| `tingee_va_account_number` (string, **unique index**, nullable) | `confirm_va` → `vaAccountNumber` (`TNG…`) | THE routing key — webhooks route on it. Not a real account. |
| `bank_account_number` | `confirm_va` → `accountNumber` | The REAL account — what QRs show, where money lands. |
| `tingee_bank_bin`, `tingee_shop_id` | `confirm_va` response | Needed for unlink / support. |
| `tingee_linked_at` (datetime) | you | Link state + audit. |
| `bank_auto_confirm_enabled` (boolean, default **false**) | you | Feature gate — launches OFF, flipped per account. |

Make the routing-key uniqueness a **partial unique DB index**
(`WHERE tingee_va_account_number IS NOT NULL`) plus a model validation — the same
bank account must never link to two of your tenants.

`linked?` = `tingee_va_account_number.present?`.

### 2b. In-flight link/unlink flow (one row per account)

The link is a two-step OTP conversation and the slow step runs in a background
job — so the pending state must live in the **DB, not the session** (a job can't
touch a session). One table, unique per account:

```
tingee_link_requests:
  organization_id (unique index)
  step        confirm_va | confirm_register_notify | start_delete_va | confirm_delete_va
  status      otp | verifying | failed
  bank_code, bank_bin
  confirm_id  (from Tingee; survives a wrong OTP — retrying is legitimate)
  account_name (confirm-va doesn't echo it; carry the typed value)
  error_message
```

**Never store** the customer's CCCD (`identity`), `mobile`, or the OTP — they are
create-va call inputs only.

### 2c. Webhook log (metering + idempotency, NOT a ledger)

```
tingee_webhooks:
  organization_id   (nullable! unroutable webhooks still count — they still bill)
  transaction_code  (UNIQUE DB index — this IS the idempotency mechanism)
  amount            (integer)
  memo_invoice_id   (extracted from memo, e.g. /HD(\d+)/i — never store the raw memo: payer PII)
  matched_invoice_id (nullable)
  received_at, processed_at
```

Idempotency via the DB unique index on `transaction_code` (race-safe), not a
model validation — a replay raises the DB's duplicate error, which the webhook
controller rescues and acks. `processed_at` distinguishes "processed, no match"
from "job never ran" — your match-rate metric depends on that.

## 3. The link flow

Two paths exist. **Use the manual API chain** — Tingee's hosted JS SDK
(`create_bank_link_session`) had a live crash bug at verification time; the raw
chain is the verified-in-production path.

### The state machine

```
create_va (sync, fast — bank sends OTP)          → step: confirm_va,   status: otp
owner submits OTP                                → status: verifying, enqueue job
job: confirm_va (SLOW — minutes at the bank)     → success: apply link, destroy request
                                                 → ACB only: register_notify → step: confirm_register_notify, status: otp (second OTP)
job failure, confirm_id present (wrong OTP/blip) → status: otp (retry legitimate)
job failure, no confirm_id                       → status: failed (terminal, only cancel)
```

Rules learned in production:

- **`confirm_va` MUST run in a background job with a raised read timeout**
  (`Tingee::Client.new(read_timeout: 300)`): bank-side SmartOTP verification
  routinely exceeds 90s and will 504 any synchronous request path.
- `create_va` can stay synchronous — it only initiates the bank's OTP send (fast).
- `mobile` must be domestic `0`-prefixed (`09…`), never `84…`.
- **No automatic retry on the confirm job**: the OTP is consumed by the first
  attempt; a retry can never succeed. Failures land on the record for the owner.
- **ACB is special**: after `confirm_va` succeeds, call `register_notify` — a
  second OTP round via `confirm_register_notify`. Call register_notify BEFORE
  persisting the link locally: a link whose notify registration failed never
  receives webhooks and silently breaks auto-confirm. On success, apply the link
  and flip the request to the second OTP step in one transaction.
- **Routing-key collision** (same bank account, second tenant): the unique index
  rejects `apply_link!` even though Tingee-side confirm succeeded. Mark the
  request `failed` with a clear message.
- **Double-submit guard**: flip `otp → verifying` under a row lock; only the
  transition enqueues the job. Enqueue AFTER the lock's transaction commits.
- **Stale-replay guard**: while a request is `verifying`, a job owns it —
  a back-button form replay must not destroy/recreate it. Redirect instead.
- **Cancel** is allowed from ANY status (it's the escape hatch for a dead job);
  the confirm job must tolerate the record vanishing (`find_by → return if nil`).
- Persist from `confirm_va`'s response: real `accountNumber` → what your QR
  shows; `vaAccountNumber` → routing key; plus `bankBin`, `shopId`.

### UI pattern (Rails)

Settings page renders from the `tingee_link_request` state (form → OTP input →
verifying spinner → failed/cancel) and live-updates via Turbo broadcasts on the
record's `after_update_commit` / `after_destroy_commit` — the owner can leave the
page while the bank verifies. Any live-update mechanism (polling included) works;
the point is: the page follows the DB record.

## 4. The webhook endpoint

Public, no auth/tenancy — the tenant is resolved FROM the payload. Order matters:

```ruby
class Webhooks::TingeeController < ActionController::Base
  skip_forgery_protection
  ACK = { code: "00", message: "Success" }.freeze

  def create
    raw = request.raw_post
    payload = JSON.parse(raw) rescue nil
    return render(json: ACK) if payload.nil?                 # unparseable — ack, ignore

    return render(json: ACK) if payload["event"] == "ping"   # 1. unsigned dashboard test — ack or their UI shows failure

    unless Tingee::Signature.verify(                          # 2. HMAC over RAW bytes — raw_post verbatim, never re-encode
      secret: Tingee.config.secret_token,
      timestamp: request.headers["x-request-timestamp"],
      raw_body: raw,
      signature: request.headers["x-signature"]
    )
      return head(:unauthorized)
    end

    record(payload)                                           # 3. log + route + enqueue
    render json: ACK                                          # 4. ALWAYS ack success — Tingee stops retrying
  rescue ActiveRecord::RecordNotUnique
    render json: ACK                                          # replay — already recorded, safe no-op
  end

  private

  def record(payload)
    # nil-guard the routing key: a blank vaAccountNumber must route to NO tenant,
    # not accidentally match every unlinked tenant's nil column.
    va = payload["vaAccountNumber"].presence
    org = va && Organization.find_by(tingee_va_account_number: va)
    webhook = TingeeWebhook.create!(
      organization: org,
      transaction_code: payload["transactionCode"],
      amount: payload["amount"].to_i,
      memo_invoice_id: payload["content"].to_s[/HD(\d+)/i, 1]&.to_i,
      received_at: Time.current
    )
    Tingee::PaymentJob.perform_later(webhook.id)
  end
end
```

Route: `post "/webhooks/tingee"`. Non-negotiables:

- **Verify raw bytes** (`request.raw_post`) — re-parsing/re-serializing breaks
  valid signatures.
- **Ack the unsigned ping** before verification.
- **Record + ack fast, match in a job.** You ack before matching, and Tingee
  never resends an acked transaction — so the matching job MUST retry on
  transient failure (`retry_on StandardError, attempts: 5`) or a hiccup silently
  loses the payment. Matching is idempotent against a still-open invoice, so
  retries are safe.
- Log EVERY webhook, routable or not — each one bills.

## 5. Payment matching

App-side policy (deliberately not in the gem). The safe-by-construction rules:

- **Memo convention**: your checkout/QR embeds a marker (`HD<invoice_id>`);
  extract with a permissive regex — banks append their own reference text.
- **All must hold**: feature flag enabled for the tenant, invoice still
  open/draft, **exact amount match**, invoice belongs to the routed tenant
  (run the matcher inside the tenant scope so cross-tenant attribution is
  impossible by construction).
- **Re-check open + exact amount UNDER a row lock, and pay in the same lock** —
  a concurrent edit to the invoice between check and pay could settle it for a
  total that no longer equals what was transferred.
- **Any miss is safe**: fall through to your existing manual confirm path and
  stamp `processed_at`. Narrow rules, safe misses — never guess.
- Optional but valuable: a **self-test transfer** path — the settings page shows
  a QR with a special memo; the matcher recognizes it, stamps
  `tingee_test_verified_at`, and the page celebrates. Proves the whole pipe
  end-to-end per account before real money relies on it.

## 6. Unlink

Mirror of linking, same state machine and job (`start_delete_va` →
`confirm_delete_va` with OTP):

- `delete_va` is slow too (it triggers the bank-side detach + OTP send) — run it
  in the job, show the verifying spinner until the OTP form appears.
- `delete_va` takes the bank's short **CODE** (`"STB"`), not the BIN — keep a
  BIN→code map from `get_banks`. But `confirm_delete_va` is the opposite: it keys
  the bank by **BIN** (`"970403"`), and passing the code is ignored (Tingee then
  fails with `"Lỗi hệ thống phương thức xác thực"`, seen live 2026-07-17).
- On confirmed unlink: clear all `tingee_*` fields AND the test-verified stamp
  (a re-link needs fresh proof).
- **Business rule**: disabling your feature flag does NOT stop Tingee's meter —
  offer a "disable" that flags off AND unlinks in one action.

## 7. Go-live checklist

- [ ] Credentials in prod; boot succeeds without them in other envs.
- [ ] Webhook URL registered in the Tingee dashboard (API Credentials/HMAC auth);
      dashboard "test webhook" returns success (the unsigned ping path works).
- [ ] `curl -X POST https://yourapp.com/webhooks/tingee -d '{}'` →
      `{"code":"00","message":"Success"}`.
- [ ] Feature flag default-false for every account; enable per pilot account.
- [ ] Per pilot account, real end-to-end proof: link a supported bank → transfer
      the exact total with the memo marker → invoice auto-pays with no manual
      refresh; wrong amount does NOT auto-pay; manual confirm still works.
- [ ] Monitoring: webhooks vs matched per account (match rate),
      `organization_id IS NULL` rows (unroutable = linking problem, still
      billed), `processed_at IS NULL` older than a few minutes (stranded job —
      re-enqueue; manual confirm is the safety net).
- [ ] Rollback story: flag off stops auto-pay instantly; unlink stops billing;
      manual confirm untouched throughout — the feature degrades to the old
      behavior, never worse.

## 8. Gotchas index (hard-won, don't relearn)

| # | Gotcha |
|---|---|
| 1 | `confirm_va`/`delete_va` take minutes at the bank — background job + `read_timeout: 300`, never a web request. |
| 2 | OTP is consumed on first attempt — no auto-retry on confirm jobs. |
| 3 | Webhook HMAC is over RAW bytes — `request.raw_post` verbatim. |
| 4 | Dashboard ping is UNSIGNED — ack it before verifying. |
| 5 | Ack-before-match means the match job MUST retry — Tingee never resends an acked txn. |
| 6 | Idempotency = DB unique index on `transactionCode`, rescue the duplicate error with an ack. |
| 7 | Blank `vaAccountNumber` must route nowhere — guard the nil-column lookup. |
| 8 | `delete_va`: query-string params + bank CODE not BIN (the gem handles the transport; you supply the code). |
| 9 | ACB needs `register_notify` (second OTP) — register BEFORE persisting the link. |
| 10 | `mobile` domestic `0`-prefix; never persist identity/mobile/OTP; never store raw memos (PII). |
| 11 | Exact-amount re-check under the invoice row lock. |
| 12 | Unlink is the only way to stop per-webhook billing. |
| 13 | Techcombank unsupported — handle in UI, not as an error surprise. |
