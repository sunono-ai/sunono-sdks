import 'dart:typed_data';

import 'package:flutter/widgets.dart' show IconData, VoidCallback;

import 'models.dart';

/// An outlined chip under the latest reply (and on an empty thread): tapping
/// it sends [message] as a synthetic turn, or runs [action] instead when set
/// (e.g. open your offers screen). [icon] null = text only.
class SunonoQuickReply {
  const SunonoQuickReply(this.label, this.icon, this.message, {this.action});
  final String label;
  final IconData? icon;
  final String message;
  final VoidCallback? action;
}

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

  /// False when the same photo would fail the same way (too large, unreadable,
  /// refused, photos unavailable, customer blocked): only a different photo or
  /// plain text helps, and a typed send then goes out without the photo.
  bool get retryable => !const {
        'image_too_large',
        'invalid_image',
        'image_blocked',
        'image_unavailable',
        'customer_blocked'
      }.contains(code);
}

/// The host's microphone (e.g. the `record` plugin). The SDK draws the
/// recording bar (timer, level meter, cancel, send), caps a note at 60 s and
/// stops on app pause, reset and dispose.
abstract interface class SunonoVoiceRecorder {
  /// Ask for microphone permission if needed and start recording. false =
  /// denied or busy: the SDK shows the "allow the microphone" hint.
  Future<bool> start();

  /// 0..1 input level, about 10 Hz, while recording. An empty stream is fine
  /// (flat bars). Read once per recording, right after [start] returns true.
  Stream<double> get levels;

  /// Stop and return the note: AAC in m4a, mono, ≤ 64 kbps recommended (a
  /// full 60 s is then about 0.5 MB; the cap is 1.5 MB). null = nothing was
  /// recorded.
  Future<SunonoAudio?> stop();

  /// Stop and throw the recording away.
  Future<void> cancel();
}

/// A recorded voice note.
class SunonoAudio {
  const SunonoAudio(this.bytes, {required this.mimeType, required this.duration});
  final Uint8List bytes;

  /// e.g. `audio/mp4` (m4a), `audio/aac`, `audio/ogg`, `audio/webm`, `audio/wav`.
  /// The server judges the bytes; this only names the upload.
  final String mimeType;
  final Duration duration;
}

/// Plays voice notes (e.g. `just_audio`). Optional: without one, voice
/// bubbles show their duration and transcript only.
abstract interface class SunonoAudioPlayer {
  /// Play the shopper's own note from [bytes] (just recorded) or [url]
  /// (restored history, an mp3), stopping anything playing.
  Future<void> play({Uint8List? bytes, String? url});
  Future<void> stop();

  /// The playback position of the current note.
  Stream<Duration> get position;

  /// true while a note plays; false when it ends or stops.
  Stream<bool> get playing;
}

/// The voice note being recorded or sent (`SunonoChatController.voice`).
sealed class VoiceState {
  const VoiceState();
}

/// Not recording.
class VoiceIdle extends VoiceState {
  const VoiceIdle();
}

/// Recording for [elapsed]; [level] is the latest input level (0..1) and
/// [levels] the most recent ones, oldest first (at most 12).
class VoiceRecording extends VoiceState {
  const VoiceRecording(this.elapsed, this.level, [this.levels = const []]);
  final Duration elapsed;
  final double level;
  final List<double> levels;
}

/// The note is uploading; [progress] is 0..1 of the request body sent.
class VoiceUploading extends VoiceState {
  const VoiceUploading(this.progress);
  final double progress;
}

/// The note never left the device: [code] is `mic_denied` (the recorder
/// said no), `voice_failed` (it threw), `voice_too_short` (under 1 s) or
/// `audio_too_large` (over 1.5 MB) or `audio_too_long` (over 60 s). The next recording or send clears it.
/// Server refusals after upload show on the message instead (`errorCode`).
class VoiceFailed extends VoiceState {
  const VoiceFailed(this.code);
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
