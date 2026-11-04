# sunono

The Sunono AI shopping assistant for Flutter apps. It ships as a ready chat screen that searches your catalog, fills the cart, runs checkout and tracks orders, in Ammani Arabic or English. Product, cart and checkout taps are handed back to your app's own screens.

- Pure Dart, one dependency (`http`), no native code. Works with Swift Package Manager-only iOS projects and AGP 9.
- Arabic-first: RTL, Latin digits, mixed-direction text.
- Honors reduce-motion and large text.
- Drop-in screen (`Sunono.view()`), a bottom sheet (`Sunono.open(context)`), or headless (`SunonoChatController`) if you want to build your own UI.

## Install

```sh
flutter pub add sunono
```

## Set up

1. **Get your shop key** (`pk_live_…`) from the Sunono dashboard.
2. **Add your app origin to Allowed domains** (Dashboard → Widget). Apps have no browser `Origin`, so the SDK sends the one you configure. Use an https origin you own, usually your storefront (e.g. `https://your-store.example`).
3. **Initialize it in `main()`.** No network happens here.

```dart
void main() {
  Sunono.init(
    shopKey: 'pk_live_…',
    appOrigin: 'https://your-store.example',
    locale: 'ar',                       // omit for the shop's default; follow your app: Sunono.setLocale('en')
    storage: MySecureStorage(),         // required: persists the anonymous shopper (see below)
    nativeCheckout: true,               // CheckoutIntent opens your own checkout screen
    onIntent: (intent) {
      switch (intent) {
        case OpenProductIntent(:final sku): router.push('/products/$sku');
        case OpenCartIntent(): router.push('/cart');
        case CheckoutIntent(): router.push('/checkout');
        case OpenUrlIntent(:final url):
          final u = Uri.parse(url);
          if (u.scheme == 'https' && myHosts.contains(u.host)) {
            launchUrl(u);                // your own domains only
          } else {
            showConfirmDialog(u);        // anything else: ask the shopper first
          }
        case OpenOrderIntent(:final storeOrderId?): router.push('/orders/$storeOrderId');
        default: return false;          // intents added in later versions
      }
      return true;
    },
  );
  runApp(const MyApp());
}
```

4. **Show it**, as a tab or route, or as a sheet from a product page:

```dart
// As a tab or route:
Sunono.view(theme: SunonoTheme.fromMaterial(Theme.of(context), accent: brandGold));

// As a sheet:
Sunono.open(context, initialMessage: 'Is this available in size 42?');
```

Without a `theme`, the chat uses the dashboard's brand color and light/dark scheme over your Material theme, and the header shows the shop's avatar. Pass `autofocus: true` to raise the keyboard when the chat opens (off by default, so a Chat tab doesn't pop it).

## Intents

The assistant hands navigation back to your app through `onIntent`. Return `true` when you handled it, `false` (or `default: return false;`) to let the SDK fall back.

| Intent | When | If you return `false` / don't handle it |
|---|---|---|
| `OpenProductIntent(productId, sku, url, title)` | The shopper taps a product card, or taps **Add** while no storefront cart is linked (no `cartBridge`, or its bind failed: the assistant only adds to a linked cart) | The assistant answers with the product's details in the chat |
| `OpenCartIntent` | The shopper taps the cart bar, or «افتح السلة» / "Open cart" when the assistant hands checkout to your cart page | Cart bar: the assistant shows the cart in the chat. Open cart: a `CheckoutIntent()` (no URL) when `nativeCheckout`, otherwise an `ErrorEvent(UnhandledIntent)` and the sheet stays |
| `CheckoutIntent(url)` | The shopper taps a site checkout hand-off button, or you declined Open cart with `nativeCheckout` (then `url` is null) | Nothing opens; an `ErrorEvent(UnhandledIntent)` is emitted and the sheet stays |
| `OpenUrlIntent(url)` | The shopper taps a link in a reply (https links only) | Nothing opens; an `ErrorEvent(UnhandledIntent)` is emitted |
| `OpenOrderIntent(number, storeOrderId, publicId, source)` | The shopper taps "Order details" on a placed or tracked order | For a chat order, the assistant answers with the order's status; otherwise an `ErrorEvent(UnhandledIntent)` is emitted |

`SunonoIntent` and `SunonoEvent` are not `sealed`: new intents and events are added in minor releases, so end every `switch` with a default. Never pass an `OpenUrlIntent` URL straight to `launchUrl`; check the host as shown above.

## Badges

```dart
ValueListenableBuilder<int>(
  valueListenable: Sunono.unread,       // or Sunono.cartCount
  builder: (_, n, __) => Badge.count(count: n, isLabelVisible: n > 0, child: const Icon(Icons.chat_outlined)),
);
```

`unread` counts assistant and staff messages that arrive while no chat view is on screen (a hidden tab or a covered route counts as off screen) and clears when one shows. The live connection keeps running while the app is in the foreground, even with the chat hidden, and stops in the background. If you drive `SunonoChatController` headless (your own UI, `open()` without `attach()`), call `suspend()` / `resume()` from your app lifecycle yourself.

## Storage

The SDK identifies the shopper with an anonymous id that should survive app restarts, so the cart and chat history come back. `storage` is required. Implement `SunonoStorage` over secure storage (`MemoryStorage` is for tests and demos: it starts a new shopper on every launch):

```dart
class MySecureStorage implements SunonoStorage {
  // flutter_secure_storage: the id stays on this device, readable after the first unlock.
  final _s = const FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  @override Future<String?> read(String k) => _s.read(key: k);
  @override Future<void> write(String k, String v) => _s.write(key: k, value: v);
  @override Future<void> delete(String k) => _s.delete(key: k);
}
```

On **logout or account switch**, call `Sunono.reset()` so the next person never sees the previous chat or cart. Everything local is cleared at once; the server is then asked, in the background, to detach this device (retried on the next open if it fails). `reset()` **unlinks** this device from the shopper's data; it does not delete that data (see [Data collected](#data-collected-and-privacy)).

## Events

```dart
Sunono.events.listen((e) {
  switch (e) {
    case CartChangedEvent(:final fromSync): if (fromSync) cartController.refresh(); // see Cart sync
    case AnalyticsEvent(:final name, :final params): analytics.log(name, params);
    case ErrorEvent(:final error, :final stackTrace): crashReporter.record(error, stackTrace);
    default: break;                                   // events added in later versions
  }
});
```

## Storefront cart sync (Magento)

If your shop uses Sunono's Magento cart sync, the bot fills the shopper's real storefront cart:

1. Implement `SunonoCartBridge`. Each call asks your backend for a **fresh** signed binding proof for the current guest or customer cart. `ensureBind` creates the cart first if there is none.
2. The proof's `origin` must equal your `appOrigin`, and the shop's cart-sync storefront origins must list it.
3. Call `Sunono.refreshCartBinding()` after login, logout or a cart merge. If the server reports that the cart was replaced (a relink), the SDK drops its binding and binds again on the next turn, so a stale cart is never written to.
4. React to `CartChangedEvent(:final fromSync)`. `fromSync == true` means the **storefront** cart changed (the bot added or removed an item, a live update arrived, or a pull returned a different linked cart): refresh your own cart screen. It is `false` for a badge-only change. Call `Sunono.refreshCart()` to pull the latest cart yourself, e.g. when your cart screen opens.

Checkout then hands off to your app (`CheckoutIntent`) instead of the chat. Set `nativeCheckout: true` when your handler opens a native checkout screen; the button then reads «كمّل الطلب» / "Complete your order" instead of the default «كمّل الطلب بالموقع» / "Complete order on the site".

## Photos

Pass `pickImage` to `Sunono.init` to show the photo button. Return a JPEG resized to at most 1600 px (e.g. `image_picker` with `maxWidth: 1600, imageQuality: 85`). Add the camera and photo-library permission strings to your app.

The photo uploads as soon as it is picked, with a progress ring on the preview; JPEG, PNG and WebP up to 5 MB are accepted. Errors (too large, unreadable, refused, photos unavailable, offline) show under the preview with a Retry where it can help, and a caption is required to send. Headless: `controller.attachPhoto(image)`, `controller.photo` (`PhotoIdle | PhotoUploading | PhotoReady | PhotoFailed`), `retryPhoto()`, `removePhoto()`; `send(text)` carries a ready photo.

## Data collected and privacy

Use this table for your App Store privacy label and Google Play Data Safety form.

| Data | When | Purpose |
|---|---|---|
| Anonymous user ID | Always (stored in your `SunonoStorage`) | Keeps the shopper's chat and cart between launches |
| Messages | Always | Answering the shopper |
| Photos | Only when the shopper attaches one (`pickImage`) | Finding similar products |
| Name, phone, address, email | Only for shops that run checkout or order tracking in the chat | Placing, delivering and tracking the order |
| Purchase history | Orders placed through the assistant | Order tracking, reordering |

This data is processed by Sunono and its subprocessors: AI model providers, message-safety checking, SMS for one-time codes (when the shop enables it) and cloud storage for photos. See [Sunono's privacy policy](https://dashboard.sunono.ai/privacy-policy) for the current list. It is linked to the anonymous ID, not to an account of yours, unless the shopper types identifying details into the chat. The SDK collects no advertising ID and no device identifiers, and does no tracking across apps.

**Deletion.** `Sunono.reset()` unlinks this device from the shopper's data (logout); it does **not** delete it. A shopper who wants their data deleted asks the shop or Sunono support (support@sunono.ai).

- **App Store guideline 5.1.2(i).** The shopper's messages are sent to third-party AI services. Disclose this in your privacy policy and tell the shopper before first use (e.g. a line above the chat entry point), and get consent where your policy or law requires it.
- **Jordan's Personal Data Protection Law (PDPL).** Name, phone and address are personal data. Collect them only for checkout, state the purposes in your privacy policy, and route access and deletion requests to the shop or Sunono support.

## Notes

- Prices are shown exactly as the store sends them (Latin digits, up to 2 decimals).
- iOS and Android are the targets. On Flutter **web**, leave `appOrigin` null (browsers set `Origin` themselves and refuse a custom one).
- `apiBaseUrl` must be https (plain http only for `localhost`, `127.0.0.1` and the Android emulator's `10.0.2.2`).
- `{"enabled": false}` in the shop's widget settings is a remote kill switch: the view shows an "unavailable" state.
- Protocol and conformance fixtures: [`protocol/`](https://github.com/sunono-ai/sunono-sdks/tree/main/protocol).

## License

Apache-2.0. "Sunono" and its logo are trademarks and are not licensed.
