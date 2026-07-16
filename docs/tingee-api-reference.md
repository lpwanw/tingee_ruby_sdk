# Tingee BaaS — verified API reference

Everything here was **observed against the live production API (2026-07-16)**, not
copied from Tingee's website. Claims marked `NOT OBSERVED` are unverified. This is
the contract `Tingee::Client` and `Tingee::Signature` are built against.

Redaction: account numbers → last 4, no identity/CCCD, no mobile numbers, no
client_id/secret_token, no payer PII from memos.

## 0. Auth & signing (OBSERVED)

- Base URL (prod): `https://open-api.tingee.vn`
- Headers on every request: `x-client-id`, `x-request-timestamp`
  (`yyyyMMddHHmmssSSS`, **UTC+7**), `x-signature`, `Content-Type: application/json`.
- Signature: `HMAC_SHA512(secret_token, x-request-timestamp + ":" + JSON.stringify(body))`, **hex** digest.
- **`body` is `payload || {}`** — a no-body GET signs the string `"{}"`, NOT empty.
  Signing `""` returns `code 97 Invalid signature`. Confirmed against the official
  `tingee-node` SDK (`src/signature/signer.ts`, `src/client/http.ts`:
  `generateSignature(secretKey, timestamp, body || {})`) and a live `get-banks`
  call. The wire request still omits the body on GET; only the SIGNED string is `"{}"`.
- Timestamp window: ±10 min of server clock (else error `90`).

Known-good triple from a live `get-banks` GET (the ENV-gated signature test asserts
this; the secret is not stored here):

```
timestamp: 20260716155928753
body:      {}
signature: 93a3031c8e3a26ede4d4d684cad1f69a459acbfc24deb87a39ed918a6b70f909537105e8f7c491f59932ff9401c5499c8d92a02e6709a8310ddc947255ab4de4
```

Ruby encoding note: `OpenSSL::HMAC.hexdigest` on a UTF-8 message warns
"UTF-8 string passed as BINARY" under json 3.0 — the gem `.b`-forces the signing
string to bytes. The digest of ASCII/UTF-8 bytes is unchanged either way.

## Response envelope

All endpoints return `{code, message, data}`; `code == "00"` is success and the
gem unwraps and returns `data`. **Exception: `get-banks` returns a bare JSON
array** — the array IS the success payload.

## 1. get-banks — supported banks (LIVE)

`GET /v1/get-banks`. Row shape:
`{code, name, bin, shortName, urlLogo, termsAndConditions:{url, urlVA}}`.

**Tingee supports 14 real banks (+ NEXTPAY mPOS).** Napas BIN → Tingee code:

| Bank | Napas BIN | Tingee code | Notes |
|---|---|---|---|
| Vietcombank | 970436 | VCB | |
| VietinBank | 970415 | CTG | |
| BIDV | 970418 | BIDV | |
| MB Bank | 970422 | MBB | |
| ACB | 970416 | ACB | needs register-notify (extra OTP round) |
| OCB | 970448 | OCB | |
| VPBank | 970432 | VPB | |
| Sacombank | 970403 | STB | |
| VIB | 970441 | VIB | |
| TPBank | 970423 | TPB | authorizeLink flow |
| MSB | 970426 | MSB | |
| PGBank | 970430 | PGB | |
| Shinhan | 970424 | SHINHAN | |
| Co-opBank | 970446 | COB | |

**Canonical supported code list** (leaked by a `create-bank-link-session` 400 on
`allowedBanks`): `OCB, BIDV, MBB, ACB, VPB, PGB, VIB, STB, CTG, VCB, AGRIBANK,
SHINHAN, COB, MSB, NEXTPAY, TPB`. Note `AGRIBANK` is accepted here but was NOT
returned by `get-banks` — Agribank is supported (via bank-link) despite the
get-banks gap.

**❌ NOT supported** (verified absent from both get-banks and allowedBanks):
**Techcombank (TCB)** — the one large bank genuinely unsupported — plus SHB,
HDBank, Eximbank, SeABank, NamABank, SCB, LPBank, VietABank, ABBANK, BacABank,
PVcomBank, NCB, VietCapitalBank, SaigonBank, BaoVietBank, VietBank, GPBank,
Oceanbank/MBV.

## 2. create-bank-link-session — hosted SDK flow (LIVE)

`POST /v1/create-bank-link-session` with an **empty body** → `code 00`,
`data` = SDK URL string.

- **No `merchantId` / sub-merchant provisioning needed** for the default merchant —
  credentials resolve to a merchant directly. Pass `merchantId` only for a
  sub-merchant.
- URL returned points at prod (`https://bank-link.tingee.vn?token=…&s=…`) when the
  configured base is prod. Linking there links a real account.
- The token is base64 JSON: `{merchantId, type, timestamp, clientId}` — clientId is
  the public id (not the secret).
- Optional params: `redirectUrl`, `allowedBanks` (array of Tingee codes),
  `bankName`, `shopId`.

**Known Tingee bug (2026-07-16, escalated):** the hosted SDK JS crashes on some
banks with `TypeError: e.confirmId.startsWith is not a function` after the user
links. It's their frontend bug — the SDK internally calls `create-va` (it holds a
`confirmId`) and mishandles it. Fallback: the raw create-va chain below, which is
fully verified.

## 3. Manual link chain — create-va → confirm-va (LIVE, works end-to-end)

Bypasses the hosted SDK. Verified flow (Sacombank, real account):

1. `POST /v1/create-va`
   `{accountType:"personal-account", bankBin, accountNumber, accountName,
   identity (CCCD), mobile, isNotifyAccountNumber, webhookUrl}`
   → `data: {confirmId, otpMethod}`.
   - **`mobile` must be domestic `0`-prefixed** (`09…`); `84…` →
     `400 mobile must be a valid phone number`.
   - STB returns `otpMethod:"SmartOTP"` (bank-app OTP, not SMS). No `authorizeLink`
     (that's TPBank only).
   - **`isNotifyAccountNumber: false` is the verified-working mode**: a real VietQR
     transfer to the linked real account fired the payment webhook on a
     notify=false link. notify=true ("watch the real account") MAY also work but
     was never confirmed to fire on a plain transfer.
2. `POST /v1/confirm-va` `{bankBin, confirmId, otpNumber}`
   → `data: {bankName, accountType, accountNumber, vaAccountNumber, shopId}`.
   - Bank-side OTP verification **can take minutes** — run in a background job with
     a raised read timeout, not a web request.
   - STB needs NO register-notify — confirm-va alone activates. **Only ACB needs
     the extra step** (§4).
3. `get-va-paging` then shows the link:
   `{bankName, bankBin, accountType, accountName, accountNumber:"xxxx…119",
   vaAccountNumber:"TNG60716171228", status:"active", creationTime, shopId}`.

### The two account numbers (critical)

confirm-va returns BOTH:

- `accountNumber` — the **real** bank account. Money lands here; this is what a
  customer transfers to and what a QR should show.
- `vaAccountNumber` — `TNG` + timestamp digits, a **Tingee-internal routing
  handle**, NOT a transferable account. Store it as your unique routing key for
  webhooks.

Also store `bankBin` and `shopId` from the response if you need them later
(`delete-va` needs the bank's short CODE, resolvable from get-banks by BIN).

## 4. register-notify — ACB only (LIVE contract)

`POST /v1/register-notify` `{vaAccountNumber, bankBin}` → `data: {confirmId}` —
run once right after confirm-va succeeds, then
`POST /v1/confirm-register-notify` `{bankBin, confirmId, otpNumber}` with the
second OTP.

## 5. get-va-paging (LIVE)

`POST /v1/get-va-paging` (optional `{merchantId}`) → `data: {totalCount, items}`.

## 6. Unlink — delete-va → confirm-delete-va (LIVE)

Tingee is inconsistent between these two — verified live:

- `POST /v1/delete-va` — params ride the **QUERY STRING** (not the JSON body):
  `?bankName=STB&vaAccountNumber=TNG…`. `bankName` is Tingee's short bank **CODE**
  (e.g. `"STB"`), NOT the BIN. The bodyless-signing convention still applies (the
  signed string is `"{}"`). → `data: {confirmId}`.
- `POST /v1/confirm-delete-va` — params ride the **BODY**:
  `{bankName, confirmId, otpNumber}`.

Unlinking is also how per-webhook billing stops for an account (see §9).

## 7. Webhooks

### Payment callback (LIVE, real captured payload)

```json
{"clientId":"…","transactionCode":"<acct>/FT26197KVBJB","amount":2000,
 "content":"hello FT26197646813469","bank":"STB","bankBin":"970403",
 "accountNumber":"<real acct>","vaAccountNumber":"TNG60716173559",
 "transactionDate":"20260716174026","additionalData":[]}
```

Field semantics (all confirmed real):

- idempotency key → `transactionCode` (`<accountNumber>/FT<ref>`, unique per txn)
- amount → `amount` — **integer**, no decimals observed
- memo → `content` (payer text; the bank may append its FT ref)
- routing → `vaAccountNumber` (unique per link) or `accountNumber` (real);
  `bankBin` IS present
- `transactionDate` — `yyyyMMddHHmmss`
- `additionalData: []` — empty for a plain transfer; a billId-bound dynamic QR may
  populate it

**A plain bank transfer (any VietQR / manual transfer into the real account) fires
the webhook** — no Tingee-minted QR required. Verified with a real transfer.

### Signature verification (LIVE — raw bytes, resolved 2026-07-16)

Tingee signs the **RAW body bytes exactly as sent**:
`x-signature = HMAC_SHA512(secret, x-request-timestamp + ":" + raw_body)`.

A genuine payment callback's signature was reproduced from the raw body verbatim.
Do NOT re-parse/re-serialize — hash raw. (The official `tingee-node` SDK's
`verifyWebhookSignature` re-serializes via `JSON.stringify(JSON.parse(body))`;
against the real webhook, raw bytes are what verified. Raw is also immune to
Ruby-vs-JS number formatting: a re-serialized whole-number float would render
`250000.0` in Ruby vs `250000` in JS and break a valid signature.)
Rails: pass `request.raw_post` verbatim to `Tingee::Signature.verify`.

### Connection-test ping (LIVE)

Tingee's dashboard "test webhook" sends
`{"event":"ping","message":"Tingee Webhook Connection Test","timestamp":<ms>}`
with **NO `x-signature` / `x-request-timestamp` headers — the ping is UNSIGNED**.
Your endpoint must short-circuit on `event == "ping"` (or "only verify when the
signature header is present") and 200-ack, else the dashboard's connection test
shows failure.

### Ack & retry contract

- Success ack: `{"code":"00","message":"Success"}` at HTTP 200 — Tingee stops
  retrying on it. Always ack replays too (idempotency on `transactionCode`).
- Retry interval/count on failure: Tingee's docs conflict (1 min vs 5 min) —
  `NOT OBSERVED` precisely.
- Whether `"02"` (already-processed) is honored for replays: `NOT OBSERVED`.

### Registering the webhook

In the Tingee dashboard, register your webhook URL with auth =
**API Credentials** (HMAC) — not the static API-key option — so callbacks carry
`x-signature`/`x-request-timestamp`.

## 8. Error codes

| Code | Meaning |
|---|---|
| `00` | Success |
| `90` | Timestamp outside the ±10 min window |
| `91` | Timeout |
| `97` | Invalid signature (including the signed-`""`-instead-of-`"{}"` mistake) |
| `1001`–`1076` | Business errors (undocumented series, codes kept raw) |

The gem raises `Tingee::Error` with the raw code preserved; transport failures are
normalized to code `"NETWORK"`, non-JSON gateway/WAF pages to `"HTTP_<status>"`.

## 9. Operational notes

- **Billing is per delivered webhook** (check Tingee's current pricing).
  Delivered ≠ matched — unroutable webhooks still bill. Whether retries
  bill: `NOT OBSERVED` (ask support).
- Disabling your own feature flags does NOT stop the meter — **only unlinking
  (`delete-va` chain) stops webhook billing** for an account.
- Post-unlink webhook behavior (do they fully stop?): `NOT OBSERVED`.
- `vaAccountNumber` uniqueness scope (global vs bank-scoped): `NOT OBSERVED`.
- Outgoing-transfer callbacks (does a debit fire a webhook too?): `NOT OBSERVED` —
  determines whether the per-webhook cost covers only customer payments or all
  balance changes.

## 10. Known Tingee bugs (escalated 2026-07-16, off this gem's critical path)

- `/v1/generate-dynamic-qr` returns
  `500 "Field 'accountNumber' doesn't have a default value"` for a valid documented
  request (their dashboard mints the same QR fine). Not wrapped by this gem —
  plain transfers fire the webhook, so dynamic QRs aren't needed for payment
  confirmation.
- Hosted bank-link JS SDK crashes
  `TypeError: e.confirmId.startsWith is not a function` (§2). Workaround: the raw
  create-va chain (§3).
