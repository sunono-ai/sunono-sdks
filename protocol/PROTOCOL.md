# Sunono Client Protocol — v1.1

The wire contract between a Sunono chat client (Flutter, React Native, Kotlin, Swift, and the web widget) and the Sunono backend. v1 is what the production web widget speaks. The backend treats every field here as **never-break**: fields may be added, never removed or renamed.

**v1.1** is purely additive. Every v1.1 field is optional, and a client that ignores all of them still works. v1.1 adds: `channel: "app"` on init (§2), the `platform` config parameter, `app` block and `platform_disabled` (§3), structured taps, `client_message_id` and `403 platform_disabled` (§4), `cart_relink` and `order_ids` (§4.1), `remote.extra_lines` (§5.2), `503 image_unavailable` (§9) and `POST /chat/forget` (§11).

Every SDK must pass the fixtures in [`fixtures/`](fixtures/). They are the conformance suite.

## 0. Conventions

- **Base URL.** `https://api.sunono.ai/api` in production. All paths below are relative to it.
- **Shop key.** The shop's publishable key, `pk_…`, is the `{shop}` path segment and the `key` query/body field. It is public and safe to ship in an app.
- **Headers on every request:**
  - `Origin: <appOrigin>`. Native clients only; see §1.
  - `X-Sunono-Client: <sdk>/<version> (<platform>)`, e.g. `sunono-flutter/0.2.0 (ios)`; `<platform>` is `ios` or `android`. Informational.
  - `Authorization: Bearer <token>` on every endpoint that requires it.
- **Money.**
  - Prices arrive as JOD numbers (`price_jod: 12.5`) or integer fils (`total_fils: 16500`, 1 JOD = 1000 fils).
  - Clients format, never compute. Totals come from the server.
  - Display rule: at most 2 decimals, half-up rounded on exact fils (6.849 → 6.85, 2 → 2), Latin digits in every language. Arabic `12.5 د.أ`, English `12.5 JOD`.
- **Unknown data.**
  - Clients **must ignore** unknown SSE event types, unknown live event types, and unknown keys.
  - Clients **must not** fail on a missing optional key.
- **Language.** `ar` or `en`. A turn's `action_data.reply_lang` says which language the bot answered in. When it's absent, the shop is single-locale Arabic.

## 1. Origin and native clients

Browsers set `Origin` themselves. Native apps send a configured **app origin** (an `https://` origin the merchant controls, usually its storefront, e.g. `https://shop.example`):

- The shop's **allowed domains** (dashboard → Widget) must contain it. The chat endpoints refuse a request with no matching Origin once the shop has any allowed domain.
- For Magento cart sync, the shop's **storefront origins** must contain it too, and the cart-binding proof's `origin` must equal it (§8).

The Origin and the allowed domains are an anti-misconfiguration control only. They are not authentication: any non-browser client can send any `Origin`, so never treat them as a secret or a security boundary.

## 2. Identity and token

### `POST /shops/init` (no auth)
Request:

```json
{ "user_id": "<uuid v4, optional>", "channel": "app" }
```

Response:

```json
{ "access_token": "<jwt>", "user_id": "<uuid>", "session_id": "<uuid>", "channel": "app" }
```

- **`channel`** (v1.1, optional). Native SDKs send `"app"` so the server can tell app traffic from web traffic (and apply the per-platform switch, §3). The response echoes it as `channel`. Omitted, it defaults to `web`.

- **The anonymous shopper.** `user_id` is the durable anonymous shopper: cart, orders and history hang off it. The client generates it once (a UUID v4), persists it, and always sends the same one. A missing or invalid id is minted by the server; use the returned value.
- **Token lifetime.** The token lives **15 minutes**. Clients cache it and re-call `/shops/init` with the same `user_id` when a call answers `401`, or `422` without a JSON `error` field (an invalid JWT). Upload's `422 {"error":"image_blocked"}` is not an auth failure.
- **Rate limit.** Init is limited to 5 per minute per IP, so never call it per message.
- `session_id` is informational. The server derives the conversation thread itself from activity (6 hours idle starts a new, empty thread).
- **Logout / "clear chat".** Delete the stored `user_id`; the next init mints a new shopper.

## 3. Shop config

### `GET /widget/config?key={shop}&platform=ios|android` (no auth)
Presentation only. It is cacheable (ETag, max-age 60).

`platform` (v1.1, optional) is a **query parameter**, not a header: native SDKs send `platform=ios` or `platform=android`; the web widget omits it.

```json
{
  "enabled": true,
  "primary_color": "#57227D",
  "header_title_ar": "…", "header_title_en": "…",
  "avatar_url": "https://…" ,
  "welcome_message_ar": "…", "welcome_message_en": "…",
  "default_language": "ar",
  "color_scheme": "light",
  "launcher_position": "bottom-right", "launcher_icon": null,
  "typing_hint": true,
  "app": { "min_sdk_version": "0.3.0" }
}
```

- `{"enabled": false}` is the **kill switch**. Show no chat entry point, and show a neutral "unavailable" state if the chat is already open.
- `{"enabled": false, "reason": "platform_disabled"}` (v1.1) means the shop switched chat off for this platform only. Treat it exactly like the kill switch. Turns sent anyway answer `403 {"error":"platform_disabled"}` (§4).
- `app.min_sdk_version` (v1.1, optional, `x.y.z`) is the oldest SDK version the shop still supports. An SDK older than it should degrade gracefully (for example, show an "update the app" notice) rather than fail.
- `welcome_message_<lang>` is shown only in that language. There is no cross-language fallback: when it is missing, the SDK uses its own default welcome.
- `typing_hint: false` means AI replies are currently off. Show no typing indicator after a send; staff may still answer over the live stream.
- Native SDKs may ignore `primary_color`/`color_scheme`/`launcher_*` in favor of the host theme.

## 4. Sending a message

There are two endpoints. They share the same request body and the same final payload.

### 4.0 `POST /shops/{shop}/chat` — text turns (native clients: always)
Auth: Bearer. Rate limit: 20 per minute.

The response is one JSON object, the same as the `done` frame below without `type`.

The server finishes the turn even if the client disconnects. Both the inbound and the outbound message are saved when the turn ends, and the reply is also published as a live `message.new` (§7). `image_ref` is rejected here (400). No stage events: show a local "thinking" state.

### 4.0b `POST /shops/{shop}/chat/stream` — photo turns, and the web widget

Auth: Bearer. Rate limit: 20 per minute.

Request:

```json
{
  "message": "بدي واقي شمس",
  "lang": "ar",
  "synthetic": false,
  "image_ref": "<from /chat/upload, optional>",
  "client_message_id": "<uuid v4, optional>"
}
```

- **`channel`.** Do not send it on chat requests; the channel comes from the token (`/shops/init`, §2).
- `product_id` (optional) is a card's `public_id`, so a question is scoped to that product.
- `lang` is the UI language hint (`ar`/`en`).
- `synthetic: true` when the client generated the text (a tap on "add to cart", "show more", a starter prompt), so it isn't taken as the shopper's own words.
- **Structured taps** (v1.1, optional). A card tap may also send:
  - `action`: `add_to_cart` or `product_detail`.
  - `action_ref`: the card's `public_id`.
  - `product_sku`: the card's `sku`, when it has one.

  Keep sending the synthetic `message`: it is what the shopper sees in the conversation, and an old server ignores the three fields. See `fixtures/tap_request.json`.
- **`client_message_id`** (v1.1, optional). A UUID v4 the client mints once per message and reuses on every resend of that same message. While the turn is still running, a repeat answers `409 {"error":"turn_in_progress"}`; once it finished, a repeat answers `200` with the identical stored reply and does not run the turn again. This makes a resend safe (§10).

Response: `text/event-stream`. Each frame is `data: <json>\n\n` (no `event:` line). Frames:

| `type` | Payload | Client action |
|---|---|---|
| `stage` | `{"type":"stage","stage":"understand"}` | Show stage label (§4.2). Ignore unknown stages; use the default label. |
| `done` | see §4.1 | Final reply. Exactly one per turn on success. |
| `error` | `{"type":"error","message":"…"}` | Turn failed server-side; show a retry affordance. |

HTTP errors arrive before the stream:
- `401`: re-init and resend once. The request was rejected before processing.
- `403`: origin not allowed, or (v1.1) `{"error":"platform_disabled"}`: this shop turned chat off for app clients (§3). Show the "unavailable" state; don't retry.
- `409`: `{"error":"turn_in_progress"}`, a `client_message_id` whose turn is still running. Wait and resend the same id.
- `404`: unknown shop.
- `429`: rate limited. Show "slow down", don't auto-retry.

### 4.1 `done`

```json
{
  "type": "done",
  "reply": "لقيتلك هدول:",
  "session_id": "…",
  "msg_ref": "<stable id of the stored bot message, may be null>",
  "action_data": { … },
  "paused": true,
  "typing_hint": false,
  "blocked": true
}
```

- `paused`, `typing_hint` and `blocked` are present only when true/false as shown.
- **`paused: true` with an empty `reply`.** A human took over, or AI replies are off. Remove the pending bot bubble and add nothing.
- **`blocked: true`.** The shopper is blocked. Remove the pending bubble silently.
- **`typing_hint: false`.** Stop showing typing indicators from now on, until a later `done` or `assistant.state` says otherwise.
- **Empty `reply` and no `paused`.** Render nothing.
- **Timeout.** A turn that exceeds the server budget yields a normal `done` whose `reply` is a fixed apology and `action_data: null`.
- `msg_ref` is the dedupe key against history and live events (§7).

#### `action_data` — the keys a client reads (all optional)

| Key | Type | Meaning |
|---|---|---|
| `products` | `ProductCard[]` (§5.1) | The page of products shown this turn, in order (max 5). |
| `has_more` | bool | A next page exists. Show a "show more" chip that sends the synthetic message `ورجيني كمان` (ar) / `Show me more` (en). |
| `cart_summary` or `cart` | `Cart` (§5.2) | Authoritative cart snapshot after this turn. Whichever is present wins; absent means unchanged. |
| `cart_sync` | `{"mutated": true}` | The bot changed a synced storefront cart this turn. Tell the host to refresh its cart. |
| `checkout_handoff` | `{"url": "https://…"}` | Synced shop: finish checkout in the host (§6). |
| `order_collect` + `missing_fields`, `known`, `field_notes` | §5.3 | Checkout: collecting delivery details. |
| `order_confirm` / `order_amend` + `details`, `order_total_text`, `vat_text`, `savings_text`, `service_fee_text`, `field_notes` | §5.3 | Checkout read-back (confirm) or edit (amend). |
| `order_placed` + `order` | §5.3 | Order placed in chat. |
| `reply_lang` | `"ar"`/`"en"` | Language of `reply`. Product titles and money in this turn follow it. |
| `cart_relink` | truthy | v1.1. The link to the shopper's storefront cart was dropped. Re-run the cart binding (§8). |
| `order_ids` | `{public_id, number, store_order_id, source}` | v1.1. Ids of an order placed this turn. `source` is `chat` or `storefront`; every key is optional. `number` is the shopper-facing order number. |

The four checkout keys are mutually exclusive per turn. Precedence when reading: `order_placed` > `order_confirm` > `order_amend` > `order_collect`. Every other `action_data` key is internal and must be ignored.

### 4.2 Stage labels

| stage | ar | en |
|---|---|---|
| `understand`, `classify` | بفكر… | Thinking... |
| `search`, `search_rewrite` | بدور على المنتجات… | Searching products... |
| `action`, `extract_cart_items`, `remove_from_cart`, `order_slots` | بنفذ الطلب… | Executing... |
| `generate` | بجهّز الرد… | Generating reply... |
| *(any other)* | بشتغل عليها… | Working on it... |

### 4.3 Reply text

`reply` is plain text with line breaks. URLs inside it are tappable (render LTR).

**Sanitize** (defensive; same as the web widget):
1. Remove every `**`.
2. Remove leading `#…` + spaces on each line.
3. Remove a leading `- ` bullet marker on each line.

**Bubble direction.** Count Arabic-block characters against Latin letters. More Arabic → RTL, otherwise LTR. With neither (digits or emoji only) → the UI's direction.

## 5. Data shapes

### 5.1 ProductCard
Read only these fields. Others may be present and must be ignored.

| Field | Type | Notes |
|---|---|---|
| `public_id` | string | Opaque product id (`prod_…`). Send it back as `product_id` when asking about a product. |
| `sku` | string? | Merchant SKU. Use it to open the product in the host app. Present on catalog cards; may be absent on older history rows. |
| `title_ar`, `title_en` | string? | Pick by `reply_lang`, fall back to the other. |
| `price_jod`, `discount_jod` | number? | `discount_jod` set = sale price (show `price_jod` struck through). |
| `price_from` | number? | Product with options: show «من X» / "From X". |
| `options_summary` | string? | Arabic one-line options summary. |
| `options` | `[{key,name_ar,name_en,values:[{key,ar,en,in_stock,exists}]}]`? | Structured options (build the English line from it). |
| `preselect_line` | `{price_fils,…}`? | A specific variant was named: show its price, not `price_from`. |
| `in_stock` | bool | `false` → "unavailable" badge, no add button. |
| `low_stock_qty` | int? | "Only N left". |
| `has_image`, `img_urls` | bool, string[] | First URL is the card image. |
| `external_url` | string? | Storefront product page (http(s) only; validate). |
| `metadata` | object | Up to 3 string/number chips. |

Card taps:
- **Add.** Send synthetic `ضيف "<title>" للسلة` (ar) / `Add "<title>" to my cart` (en).
- **Details.** Send synthetic `احكيلي أكثر عن "<title>"` / `Tell me more about "<title>"`.
- **Card body.** Hand the product to the host (open the product page).

The title is the reply-language title.

### 5.2 Cart

```json
{
  "items": [
    { "product_id": "prod_…", "name_ar": "…", "name_en": "…", "qty": 1,
      "price_fils": 8000, "subtotal_fils": 8000, "img_urls": ["…"],
      "variant_label": "L / كحلي", "variant_label_en": "L / Navy" }
  ],
  "item_count": 2,
  "total_fils": 16500,
  "stale": true,
  "remote": {
    "extra_lines": [ { "sku": "SKU-X1", "qty": 1, "row_total_fils": 4000 } ]
  }
}
```

- **Badge count.** Sum `qty` over `items`, plus `qty` over `remote.extra_lines`. Fall back to `item_count`, which counts distinct rows, not units.
- **Extra lines** (v1.1). `remote.extra_lines[]` (`{sku, qty, row_total_fils}`) are lines in the shopper's storefront cart that the catalog doesn't know. They count in the badge and in `total_fils`; the client has no name or image for them.
- **Stale cart.** `stale: true` (or no `total_fils`) means the totals are withheld. Show the items only.
- **Line name.** `name` + ` — ` + `variant_label` when present.
- **Empty cart.** `null` or no `items`.

### 5.3 Checkout

**`missing_fields[]` and `known{}`:**
- `missing_fields[]`: `{key, type, label_ar, label_en?, required}`. `type` is one of `text|phone|email|number|choice`.
- `known{}`: `key → value`.
- `field_notes[]`: `{key, note}`.

**`details[]`:** `{key, value, label_ar, label_en?}`.
- The `*_text` totals are server-formatted strings («15.1 دينار»). Render them verbatim; never parse.
- Show `service_fee_text` as «شامل رسوم الخدمة X» / "includes X service fee".
- Show `vat_text` as «شامل X ضريبة» / "includes X VAT".
- Show `savings_text` as «وفّرت» / "You save".

**`order` (placed):**
- `order_number` (string; show unless `"—"`).
- `items[]` (`name_ar`, `name_en`, `variant_label*`, `qty`, `subtotal_fils`).
- `delivery_fee_fils` (null = unknown, 0 = free).
- `total_fils`, `savings_fils`, `service_fee_fils`, `vat_fils`.

The shopper answers the checkout conversationally (free text). The card is a read-back, not a form.

## 6. Commerce modes

The server decides per turn. Clients render whatever arrives.

- **Chat checkout** (shop without storefront cart sync). The cart lives at Sunono. The checkout cards from §5.3 appear, and the order is placed in chat.
- **Host checkout** (storefront cart sync, e.g. Magento):
  - The cart is the shopper's real storefront cart.
  - On `checkout_handoff.url`, show a "Complete order" button that hands checkout to the host. Native host: open its own checkout. Web: navigate to the URL.
  - Refresh the host cart on `cart_sync.mutated` and on live `cart.updated`.

## 7. History and live events

### `GET /shops/{shop}/chat/history?shape=v2` (Bearer; 30 per minute)

```json
{
  "messages": [
    { "role": "user|bot", "sender": "user|bot|staff", "text": "…",
      "products": [ProductCard], "has_more": false, "image": "https://…|null",
      "msg_ref": "…|null", "ts": "2026-10-30T22:23:50+00:00",
      "checkout_handoff": {"url": "…"} }
  ],
  "bot_paused_at": "<iso>|null",
  "cart": Cart|null,
  "cart_linked": false
}
```

- **What it returns.** The current conversation thread (last 50 messages, oldest first). An empty thread is a fresh session.
- **`sender: "staff"`** means a human reply; label it "Store team".
- **`bot_paused_at`** set means a human currently owns the conversation; show the handoff pill.
- **`cart`** is the cart badge state. It may be `stale`.
- **`cart_linked`** means the shopper's cart is a synced storefront cart.
- `image` is relative (`/api/...`) in local development; resolve it against the API origin.

### Live stream
1. `POST /shops/{shop}/chat/subscribe-ticket` (Bearer, body `{}`) → `{"ticket":"…"}`. Single use, valid 60 s.
2. `GET /shops/{shop}/chat/subscribe?ticket=…` → `text/event-stream` with named events: `event: <type>\ndata: <envelope json>\n\n`. The envelope is `{"type": "<type>", "data": {…}, …}`.

| event | `data` | Client action |
|---|---|---|
| `ping` | `{}` | Every ~25 s. Liveness only. |
| `message.new` | `{body_text, ts, msg_ref, client_ref, sent_by, media_stored:{kind,url}}` | Add a bubble unless it's a duplicate. `sent_by: "owner"` is a staff bubble; anything else is a bot bubble. |
| `conversation.paused` | `{bot_paused_at}` | Show the "handed to our team" pill at `bot_paused_at`. |
| `conversation.resumed` | `{}` | Show the "assistant is back" pill. |
| `assistant.state` | `{typing_hint}` | Update typing indicator policy. |
| `cart.updated` | `{cart: Cart|null}` | Synced cart changed on the storefront. Update the badge and tell the host. |

- **No replay.** On every (re)connect, fetch history first, then open the stream.
- **Reconnect.** Back off 2 s, 5 s, then 15 s repeating. A ticket `401`/`422` means re-init the token once.
- **Zombie connection.** No frame for 60 s means the connection is dead; reconnect.
- **Native apps.** Close the stream in the background and reconnect (history first) on resume.

**Dedupe.** A live or history message duplicates an on-screen one when:
- its `msg_ref` equals the on-screen message's `msg_ref`, or
- it has no `msg_ref`, but its text is identical and its `ts` is within 15 s.

The `done` frame and a live `message.new` for the same bot reply share `msg_ref` and may arrive in either order. The result must be exactly one bubble.

### `GET /shops/{shop}/chat/cart` (Bearer)
Returns `{"cart": Cart|null, "linked": bool}`. Synced carts only. Call it on chat open/resume when `cart_linked`.

## 8. Magento cart binding — `POST /widget/cart-binding` (no auth)

```json
{ "key": "pk_…", "user_id": "<uuid>", "proof": { … } | null }
```

- **The proof.** The proof is produced by the merchant's Magento module and signed with the shop's bind secret. Its fields: `v`, `shop_key`, `widget_user_id`, `origin`, `binding_ref` (`snb_…`), `store_code`, `issued_at`, `expires_at` (≤ 300 s after `issued_at`), `nonce` (32 hex), `sig` (64 hex).
- **Origin.** The request's `Origin` header must equal `proof.origin`.
- **Post exactly the 10 proof keys.** `v`, `shop_key`, `widget_user_id`, `origin`, `binding_ref`, `store_code`, `issued_at`, `expires_at`, `nonce`, `sig`, and nothing else. The server rejects a proof with extra keys, for example a GraphQL `__typename`, so build the object from this list rather than forwarding whatever the host returned.
- **Answers:**
  - `{"bound": true|false, "replayed": bool}`
  - `{"bound": false}` when `proof` is null
  - `403 {"error": code}`, where `code` is one of `origin_mismatch`, `origin_not_allowed`, `proof_expired`, `nonce_reused`, …
  - `404 not_available` when the shop has no cart sync.
- **When to bind.** Probe (never creates a cart) when the chat opens or resumes, and after the host's login, logout or cart replacement. Ensure (creates the storefront cart if missing) at most once per open, before the first message.
- **Clock skew.** Get a fresh proof for every attempt and never cache one. Clock skew is tolerated up to 60 s.

## 9. Photos — `POST /shops/{shop}/chat/upload` (Bearer, multipart `image`; 10 per minute)

- **Success:** `200 {"image_ref":"…","url":"…"}`. Then send a message with `image_ref`; a caption is required.
- **Errors:**
  - `413 image_too_large`
  - `400 invalid_image`
  - `422 image_blocked`: moderation refused it
  - `503 image_unavailable` (v1.1): moderation is unavailable right now. Nothing was stored; offer a retry.
  - `403 customer_blocked`
- Resize to ≤ 1600 px on the long edge and JPEG ≈ 0.85 before upload.

## 10. Delivery semantics (mobile)

Without a `client_message_id`, resending can double an action ("add 2"). Native clients send one on every turn (§4.0b); with it, a resend of the same message is safe: `409 turn_in_progress` while the turn runs, then an identical `200` replay. The recovery flow below is the fallback for servers or messages without it.

- **`/chat/stream` (§4.0b) cancels the turn if the client disconnects mid-turn.** Nothing is saved, though cart side effects may already have happened. Native clients use it only for photo turns.
- **Automatic resend is allowed only on `401`/`422`** (re-auth), which are rejected before any work.
- **Any other failure without a response → "recovering":**
  - Re-fetch history at about 4 s, 12 s and 30 s. Both rows of a finished turn appear together.
  - A user row with our text that the screen doesn't account for appears → the turn happened; adopt the server thread. A row is accounted for when its own `msg_ref` is on screen, or when the reply right after it is (`/chat` returns only the bot's `msg_ref`). Never compare device time with server `ts`.
  - A live bot `message.new` arriving meanwhile triggers the check immediately.
  - Still absent after the last check, or history itself fails (offline) → show a retry chip. Only the shopper resends.
- **Any `4xx`** (`429` rate limit or the shop's in-flight cap, `403`, `404`, `400`, `413`, `422` with an `error` code) is rejected before any work. Show a message plus a retry chip.
- **A `5xx`** (e.g. a gateway timeout) can arrive after the turn ran, so treat it as ambiguous and recover.
- **Silence is not an error.** An empty reply that is `paused`/`blocked`/silenced never shows a retry chip.

## 11. Detach the device — `POST /shops/{shop}/chat/forget` (Bearer, body `{}`)

- **Success:** `204`, no body.
- **What it does.** It detaches this device from the shopper: the next `/shops/init` with the same `user_id` starts as a stranger. It is **not deletion**: the carts, orders and conversation stay on the server and the merchant keeps them.
- **When to call it.** On the host's logout or "clear chat", best effort, before discarding the stored `user_id` and token (§2). Ignore a failure.
