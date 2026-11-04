## 0.3.0

Protocol v1.2 (additive). A flat chat design, history that restores every card, checkout through your app's cart page, and voice notes. Breaking changes first.

### Breaking

- **Checkout opens your cart page.** With a v1.2 server, the assistant never checks out in an app: it never collects delivery details, reads the order back, asks for a code or places the order. When the shopper wants to check out, the reply carries an «افتح السلة» / "Open cart" button, which sends `OpenCartIntent`. If you decline it and set `nativeCheckout`, the SDK sends `CheckoutIntent()` with a `null` url. Otherwise it reports `ErrorEvent(UnhandledIntent(OpenCartIntent))` and the sheet stays open. Handle `OpenCartIntent`.
- `controller.openCart()` (the cart bar) now always tries `OpenCartIntent` first, linked or not. The assistant shows the cart in the chat only when you decline it.
- **Add without a linked cart opens the product.** The bot adds only to a linked storefront cart. While the shopper isn't linked (no `cartBridge`, or its bind failed), a card's **Add** sends `OpenProductIntent`. If you decline it, the SDK asks the assistant about the product; it never sends an add. After the server reports an unlinked cart (`app_cart_unlinked`), the next Add opens the product too.
- `ChatMessage.handoffUrl` is now a read-only getter over the new `ChatMessage.handoff`. Assign `handoff` instead. The `handoffUrl:` constructor parameter still works but is deprecated.
- **Quick replies replace the starter chips.** The defaults are now «شو العروض؟» / "Browse offers" and «احكي مع الفريق» / "Talk to our team". They show on the empty thread and also under the newest assistant reply (at most 3) while the chat is idle. `starterPrompts` still works, but only on the empty thread, and only where `quickReplies` has nothing for that language. Pass `quickReplies: {'ar': [], 'en': []}` to show no chips.
- **New header.** It has a 44 dp avatar (the shop's `avatar_url`, else a monogram), the title, and a status row: «متصل • جاهزين نساعدك» / "Online • Here to help", «فريق المتجر معك» while staff have the chat, or «غير متاح هلّق» / "Unavailable right now". The leading button is now a back button: it calls `onBack` in `Sunono.view` and closes the `Sunono.open` sheet. A ⋮ menu has the built-in "Talk to our team" and your `menuItems`.
- **Photos.** The photo button is now a `+` that opens an attach sheet with one row, «صورة» / "Photo". `pickImage` runs after the shopper picks that row.
- **Flat theme defaults.** No gradients, glows or shadows. The bubble and card `radius` default is now 18 (was 20), and the bubble tail corner is 4. Default `muted` is `#6E6B78`, `success` is `#06774F` and `danger` is `#C02048`, so they reach 4.5:1 on the chat background. Text on a brand color can now be black when neither white nor near-black reaches 4.5:1. The user bubble is lifted toward white or black when the brand color is below 3:1 against the page. `SunonoTheme.fromMaterial` now takes the header and bot bubbles from `surfaceContainerLowest` (light) or `surfaceContainerHigh` (dark), and its `primaryText` and `muted` are now contrast-adjusted. If you pinned goldens of the chat, regenerate them.

### Deprecated (removed in 1.0)

- `PresenceOrb`. The header and typing row no longer use it.
- `SunonoTheme.brandGradient` and `SunonoTheme.glow`.
- `Sunono.init(starterPrompts:)` and `SunonoChatController(starterPrompts:)`. Use `quickReplies`.
- `ChatMessage(handoffUrl:)`. Use `handoff`.

### Added

- **Voice notes**, through your own recorder. The SDK still ships no native code.
  - `Sunono.init(voiceRecorder:, audioPlayer:, onOpenSettings:)`, and the same on `SunonoChatController`.
  - New types: `SunonoVoiceRecorder` (`start`, `levels`, `stop`, `cancel`), `SunonoAudio` and the optional `SunonoAudioPlayer`. The README has a host implementation with `record` and `just_audio`.
  - Tap to record. A recording bar shows the timer, levels, cancel and send. The server transcribes the note, and the bubble shows «سمعناك: …» / "We heard: …".
  - Limits: a note is 1–60 s and at most 1.5 MB (it auto-sends at 60 s). Record AAC in m4a, mono, at 64 kbps or less.
  - Error codes, each with Arabic and English copy: `mic_denied`, `voice_failed`, `voice_too_short`, `audio_too_large`, `audio_too_long`, `audio_unclear`, `invalid_audio`, `audio_unavailable`, `voice_busy` and `voice_unavailable`. `voice_unavailable` hides the mic until the next `Sunono.init`. Retry appears only where it can help, because each upload is a paid transcription.
  - A recording is cancelled, and playback stopped, when the shopper leaves the chat, the app goes to the background, and on `reset()`, the kill switch and dispose.
  - Headless: `controller.voice` (`VoiceIdle | VoiceRecording | VoiceUploading | VoiceFailed`), `startVoice()`, `stopVoice()` (sends), `cancelVoice()`, `recording`, `canRecord`, `voiceAvailable`, `toggleVoicePlayback(message)`, `stopVoicePlayback()`, `playingVoice`, and `ChatMessage.isVoice`, `audioUrl`, `localAudio`, `audioDuration`, `retryable`.
- `SunonoQuickReply(label, icon, message, {action})` and `Sunono.init(quickReplies:)`, per language. `action` runs your callback instead of sending.
- `Sunono.view(onBack:, menuItems:, welcomeTitle:, welcomeSubtitle:)` and `SunonoMenuItem`. A welcome card sits at the top of the thread, and a short thread starts under the header.
- **History restores every card**, the same as live: checkout read-backs, the placed order with its "Order details" chip, the hand-off button, order ids, the reply language and voice notes. This needs a v1.2 server.
- Bubbles: avatars beside each group of assistant messages, a date pill per day («اليوم» / "Today", «مبارح» / "Yesterday"), times, and ✓✓ once a message is delivered. A failed send is marked on the shopper's bubble. Long-press a bubble, or use the screen-reader action, to copy it. New API: `ChatMessage.delivered` and `controller.isSending(message)`.
- `CheckoutHandoff` (`({String? url, String target})`), `ChatMessage.handoff`, `controller.checkout(url, target: 'cart' | 'checkout')` and `controller.addOpensProduct`.
- `SunonoTheme.flat(primary:, dark:)` and new tokens, each derived unless you pass it: `chatBackground`, `headerBackground`, `botBubble`, `userBubble`, `onUserBubble`, `outline`, `online` and `chipOutline`. Read-only tokens: `controlOutline`, `datePill`, `onDatePill` and `isDark`. Also `fontFamilyFallback`, which `fromMaterial` takes from your text theme.
- Composer: Shift+Enter inserts a new line on a hardware keyboard; Enter still sends.
- Conformance fixtures for protocol v1.2: `turn_handoff_cart.json`, `turn_app_cart_unlinked.json`, `upload_audio.json` and `history_app.json`.

### Fixed

- Phone numbers, prices, quantities and order numbers keep their order inside Arabic text (bubbles, product and checkout cards, the cart bar).
- Contrast: dark-mode success, danger and field borders; light success, danger and the date pill; the Add and hand-off buttons on light and very dark brand colors.
- Every new control has a 48 dp target and a screen-reader label in the UI language, and the chat fits at 200% text on a 320 dp phone.
- A site checkout url that is not https no longer shows the hand-off button.

### Notes

- With a v1.1 server, the SDK still works, but checkout stays in chat as in 0.2, history restores text and cards only, and voice uploads fail with an error.

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
