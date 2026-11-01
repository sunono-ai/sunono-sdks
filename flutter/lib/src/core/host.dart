import 'dart:typed_data';

import 'models.dart';

/// Persists the anonymous shopper id across launches. Pass one backed by
/// secure storage (e.g. `flutter_secure_storage`); [MemoryStorage] forgets it
/// on every cold start, which starts a new shopper each launch.
abstract interface class SunonoStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class MemoryStorage implements SunonoStorage {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// Bridges the host's storefront cart (Magento cart sync, PROTOCOL §8).
/// Each call returns a FRESH signed proof from the merchant's backend, or
/// null when there is nothing to bind. Never cache proofs (they expire in
/// at most 5 minutes and are single use).
abstract interface class SunonoCartBridge {
  /// Proof for the shopper's existing cart, without creating one.
  Future<Map<String, dynamic>?> probe(String userId);

  /// Proof for the shopper's cart, creating an empty one first if needed.
  Future<Map<String, dynamic>?> ensureBind(String userId);
}

/// A photo the host picked (already resized: ≤ 1600 px, JPEG ~0.85).
class SunonoImage {
  const SunonoImage(this.bytes, {this.filename = 'photo.jpg'});
  final Uint8List bytes;
  final String filename;
}

/// Where the composer's attached photo is (`SunonoChatController.photo`).
sealed class PhotoState {
  const PhotoState();
}

/// No photo attached.
class PhotoIdle extends PhotoState {
  const PhotoIdle();
}

/// Uploading; [progress] is 0..1 of the request body handed to the network.
class PhotoUploading extends PhotoState {
  const PhotoUploading(this.progress);
  final double progress;
}

/// Uploaded; the next message carries [ref] (the `image_ref`).
class PhotoReady extends PhotoState {
  const PhotoReady(this.ref);
  final String ref;
}

/// The upload was refused or failed. [code] is the server's `error`
/// (`image_too_large`, `invalid_image`, `image_blocked`, `image_unavailable`,
/// …), `rate_limited`, or `offline`. `retryPhoto` re-uploads.
class PhotoFailed extends PhotoState {
  const PhotoFailed(this.code);
  final String code;
}

/// Navigation the assistant hands back to the host app.
///
/// Not sealed: new intents can be added in a minor release, so a host's
/// `switch` should end with `default: return false;`.
abstract class SunonoIntent {
  const SunonoIntent();
}

/// Open a product page. Route by [sku] when present; [url] is the storefront page.
class OpenProductIntent extends SunonoIntent {
  const OpenProductIntent({required this.productId, this.sku, this.url, required this.title});
  final String productId;
  final String? sku;
  final String? url;
  final String title;
}

class OpenCartIntent extends SunonoIntent {
  const OpenCartIntent();
}

/// Finish checkout in the host. [url] is the web checkout, a fallback only:
/// a native app should open its own checkout screen.
class CheckoutIntent extends SunonoIntent {
  const CheckoutIntent({this.url});
  final String? url;
}

class OpenUrlIntent extends SunonoIntent {
  const OpenUrlIntent(this.url);
  final String url;
}

/// Open the host's screen for an order the assistant placed or reported on.
/// Every field is optional; route by [storeOrderId] or [number] for a
/// storefront order. [source] is `chat` (placed in the assistant) or
/// `storefront`. Return false for a `chat` order and the assistant answers
/// with the order's status instead.
class OpenOrderIntent extends SunonoIntent {
  const OpenOrderIntent({this.number, this.storeOrderId, this.publicId, this.source});
  final String? number;
  final String? storeOrderId;
  final String? publicId;
  final String? source;
}

/// Things the host may want to react to. Not sealed: end a `switch` with a default.
abstract class SunonoEvent {
  const SunonoEvent();
}

/// The shopper's cart changed (identity or count). [cart] is the latest snapshot.
class CartChangedEvent extends SunonoEvent {
  const CartChangedEvent(this.cart, {this.fromSync = false});
  final Cart? cart;

  /// The storefront cart itself changed (the bot added or removed in the
  /// store, a live update arrived, or a pull returned a different linked
  /// cart). Hosts with a storefront cart refresh theirs when this is true;
  /// badge-only hosts can just read `cart.count`.
  final bool fromSync;
}

/// Analytics hook: `assistant_opened`, `assistant_message_sent`,
/// `assistant_product_tapped`, `assistant_checkout_tapped`, ….
class AnalyticsEvent extends SunonoEvent {
  const AnalyticsEvent(this.name, [this.params = const {}]);
  final String name;
  final Map<String, Object?> params;
}

/// A non-fatal SDK error (network, cart binding, …) for the host's crash/log tool.
class ErrorEvent extends SunonoEvent {
  const ErrorEvent(this.error, [this.stackTrace]);
  final Object error;
  final StackTrace? stackTrace;
}

/// Reported through [ErrorEvent] when an intent has no handler and the SDK has
/// no fallback of its own (open URL, checkout, a storefront order).
class UnhandledIntent implements Exception {
  const UnhandledIntent(this.intent);
  final SunonoIntent intent;

  @override
  String toString() => 'UnhandledIntent(${intent.runtimeType})';
}
