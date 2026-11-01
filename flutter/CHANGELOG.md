## 0.2.0

Protocol v1.1 (additive). Breaking changes first.

### Breaking

- `Sunono.init(locale:)` defaults to `null` (was `'ar'`): the chat follows the shop's `default_language` until the host sets one. `SunonoChatController(lang:)` is `String?` to match.
- `Sunono.init(storage:)` is **required**. Pass a `SunonoStorage` over secure storage; `MemoryStorage` starts a new shopper on every launch and is for tests and demos.
- `SunonoIntent` and `SunonoEvent` are no longer `sealed` (now `abstract`), so new intents and events (like `OpenOrderIntent`) never break host code again. A `switch` **expression** over either type without a `_` / default arm no longer compiles; `switch` **statements** still compile. End every host switch with `default: return false;` (intents) or `default: break;` (events).
- `CartChangedEvent` gained `fromSync`: `true` when the storefront cart itself changed. The event now also fires for every change of lines, totals and store-side items, not only the count.
- The live connection is lifecycle-based: it keeps running while the app is in the foreground, even with the chat hidden, and stops in the background. Headless hosts (your own UI, `open()` without `attach()`) must call `suspend()` / `resume()` from their app lifecycle.
- `SunonoChatController.send(..., image:)` is removed. Use `attachPhoto(image)` (uploads at once), then `send(text)`; `retryPhoto()` and `removePhoto()` manage the preview, and `photo` exposes the state.
- The default checkout hand-off label is now «كمّل الطلب بالموقع» / "Complete order on the site". Pass `nativeCheckout: true` to `Sunono.init` when your `CheckoutIntent` opens a native checkout; the label is then «كمّل الطلب» / "Complete your order".
- `controller.openCart()` returns a `Future` (handled by `OpenCartIntent` when the cart is linked, otherwise the assistant shows the cart) and `controller.checkout()` returns `bool`. Unhandled checkout, URL and store-order intents report `ErrorEvent(UnhandledIntent)`.
- `SunonoApi` refuses a non-https `apiBaseUrl` (plain http only for `localhost`, `127.0.0.1` and `10.0.2.2`).
- The cart bar's "+N" now matches the web widget (every unit but the featured one).
- The shop welcome message no longer falls back across languages; `Sunono.init(starterPrompts:)` overrides the starter chips.

### Added

- `OpenOrderIntent` (with an "Order details" chip on placed and tracked orders), `Sunono.open(productSku:)`.
- `Sunono.cartCount` and `Sunono.unread` listenables for tab badges; `Sunono.refreshCart()`.
- `controller.send(text, withPhoto: false)` sends text without taking the composer's photo (used by `Sunono.open(initialMessage:)`).
- Theme fallback from the dashboard (brand color, light/dark scheme, avatar) when no `theme` is passed; `SunonoTheme.fromConfig`. Brand colors are contrast-checked for text and buttons.
- Remote kill switch (`enabled: false`, `platform_disabled`) and a minimum SDK version from the shop config, each with an "unavailable" / "update the app" state.
- `Sunono.reset()` also asks the server to detach this device (`/chat/forget`), in the background and retried on the next open. It unlinks the device from the shopper's data; it does not delete it.
- Photos upload as soon as they are picked, with progress, inline errors and Retry (JPEG, PNG, WebP up to 5 MB).
- Product cards match the web widget: sale and price-from badges, `-X%`, preselected variant, option chips, stock states, a details button.
- Thread parity: welcome and starter chips, timestamps, pause/resume pills in the right place, de-duplicated live messages, safe link handling, an image lightbox.
- Checkout and order cards match the web widget; structured taps (add to cart, product detail) are sent to the server; `client_message_id` makes sends idempotent (a retry never double-places).
- Polite screen-reader announcements for arriving replies; `autofocus` option for the chat input.
- README: intents table, host-allowlisted `OpenUrlIntent` example, secure-storage example, "Data collected" table for App Store / Play, cart-sync guide.

### Fixed
- Stopping the live connection (app pause, `reset()`) no longer leaks an uncaught async error into the host's crash reporter.
- The cart binding follows the server (history, `/chat/cart`, relink); older responses never overwrite a newer cart.
- Request timeouts (15 s; 90 s for a turn), SSE line and frame size caps, a 300-message bound, history merge beyond the cap.
- A reset clears local state at once and never reconnects the previous shopper, even if secure-storage deletion fails or hangs.
- A turn or upload in flight across `reset()` is never re-sent as the new shopper (after a 401), and a reset during loading or while disabled re-opens the chat.
- Secure storage that fails or hangs no longer stops the chat: the shopper id is kept in memory for the session and an `ErrorEvent` is reported.
- `Sunono.open(initialMessage:)` never takes, or waits on, a photo in the composer.
- Accessibility: Send reports when it is disabled, links in bubbles are links, the remove-photo and Add buttons have 48 dp targets, and the header subtitle ellipsizes at large text.
- Product and chat images are decoded at display size.

### Notes

- Supports Flutter 3.27 and later. `SemanticsService.announce` and `TickerMode.of` are deprecated from Flutter 3.35 but still present; the SDK keeps them (with a lint ignore) until the floor moves.

## 0.1.0-dev.1

- First preview: `SunonoChatView`, `Sunono.open`, headless `SunonoChatController`.
- Protocol v1 client: text turns over `/chat`, photo turns over `/chat/stream`, live updates, history merge, mobile-safe delivery (never auto-resends an ambiguous message).
- Magento cart binding through `SunonoCartBridge`; navigation intents; analytics, cart and error events.
- Arabic-first UI: RTL, Latin digits, reduce motion, large-text safe.
