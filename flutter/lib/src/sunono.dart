import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'core/api.dart';
import 'core/controller.dart';
import 'core/host.dart';
import 'ui/chat_view.dart';
import 'ui/header.dart';
import 'ui/theme.dart';

/// The one-line integration. Call [init] in `main()` (no network happens
/// there), put [SunonoChatView] in a screen or call [open] for a sheet.
abstract final class Sunono {
  static SunonoChatController? _controller;
  static Future<SunonoImage?> Function()? _pickImage;
  static SunonoTheme? _theme;

  /// Set up the SDK.
  ///
  /// - [shopKey]: the shop's publishable key (`pk_…`).
  /// - [appOrigin]: an https origin listed in the shop's allowed domains
  ///   (and cart-sync storefront origins), usually your storefront, e.g.
  ///   `https://shop.example`. Sent as `Origin`, since apps have none.
  /// - [storage]: persists the anonymous shopper id (use secure storage).
  ///   Required: without a persistent one every cold start is a new shopper.
  /// - [cartBridge]: Magento cart sync proofs, if your shop uses it.
  /// - [nativeCheckout]: true when [onIntent] opens your own checkout screen
  ///   for [CheckoutIntent]; the handoff button then reads «كمّل الطلب» /
  ///   "Complete your order" instead of «…بالموقع» / "…on the site".
  /// - [pickImage]: enables photo messages.
  /// - [voiceRecorder]: enables voice notes (the mic shows while the input is
  ///   empty). Tap to record, tap send (auto-sends at 60 s) or ✕. Implement it
  ///   with any recorder plugin; the SDK ships no native code.
  /// - [audioPlayer]: plays voice bubbles; without one they show the duration
  ///   and transcript only.
  /// - [onOpenSettings]: opens your app's settings, offered when the recorder
  ///   reports the microphone permission denied.
  /// - [quickReplies]: the chips under the latest reply and on an empty
  ///   thread, per language, e.g.
  ///   `{'en': [SunonoQuickReply('Gift ideas', Icons.redeem, 'Any gift ideas?')]}`;
  ///   at most 3, `[]` shows none. Defaults: "Browse offers" and "Talk to our team".
  /// - [starterPrompts]: deprecated, use [quickReplies]; text-only chips on
  ///   the empty thread only, per language, where [quickReplies] has none.
  /// - [locale]: `ar` / `en`; null follows the shop's `default_language`.
  /// - [theme]: null follows the shop's dashboard color over your Material theme.
  /// - [onIntent]: route product/cart/checkout taps; return true if handled.
  static SunonoChatController init({
    required String shopKey,
    String? appOrigin,
    String apiBaseUrl = 'https://api.sunono.ai/api',
    String? locale,
    required SunonoStorage storage,
    SunonoCartBridge? cartBridge,
    bool nativeCheckout = false,
    Future<SunonoImage?> Function()? pickImage,
    SunonoVoiceRecorder? voiceRecorder,
    SunonoAudioPlayer? audioPlayer,
    VoidCallback? onOpenSettings,
    bool Function(SunonoIntent intent)? onIntent,
    Map<String, List<String>>? starterPrompts,
    Map<String, List<SunonoQuickReply>>? quickReplies,
    SunonoTheme? theme,
    http.Client Function()? httpClientFactory,
  }) {
    _controller?.dispose();
    _pickImage = pickImage;
    _theme = theme;
    return _controller = SunonoChatController(
      api: SunonoApi(
        shopKey: shopKey,
        apiBase: apiBaseUrl.replaceFirst(RegExp(r'/+$'), ''),
        appOrigin: appOrigin,
        clientFactory: httpClientFactory,
      ),
      storage: storage,
      lang: locale,
      cartBridge: cartBridge,
      nativeCheckout: nativeCheckout,
      onIntent: onIntent,
      starterPrompts: starterPrompts,
      quickReplies: quickReplies,
      voiceRecorder: voiceRecorder,
      audioPlayer: audioPlayer,
      onOpenSettings: onOpenSettings,
    );
  }

  static SunonoChatController get controller =>
      _controller ?? (throw StateError('Call Sunono.init(...) before using Sunono.'));

  /// Cart changes, analytics and non-fatal errors.
  static Stream<SunonoEvent> get events => controller.events;

  /// Items in the shopper's cart, for your cart badge.
  static ValueListenable<int> get cartCount => controller.cartCount;

  /// Assistant and staff messages the shopper hasn't seen, for a Chat tab badge.
  static ValueListenable<int> get unread => controller.unread;

  /// Follow the app's language at runtime (`ar` / `en`).
  static void setLocale(String locale) => controller.lang = locale;

  /// Logout / account switch: forget this shopper's chat and cart link.
  /// Clears everything local at once; the server-side detach runs in the background.
  static Future<void> reset() => controller.reset();

  /// After login, logout or a cart replacement (e.g. `mergeCarts`).
  static Future<void> refreshCartBinding() => controller.refreshCartBinding();

  /// Pull the latest cart, e.g. when the host's cart screen opens.
  static Future<void> refreshCart() => controller.refreshCart();

  /// The chat as a full-height bottom sheet, e.g. from a product page:
  /// `Sunono.open(context, initialMessage: 'متوفر بمقاس 42؟')`.
  static Future<void> open(BuildContext context,
      {String? initialMessage, String? productId, String? productSku, SunonoTheme? theme, bool autofocus = false}) {
    final c = controller;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: FractionallySizedBox(
          heightFactor: 0.92,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            child: Material(
              child: SunonoChatView(
                controller: c,
                theme: theme ?? _theme,
                pickImage: _pickImage,
                initialMessage: initialMessage,
                productId: productId,
                productSku: productSku,
                autofocus: autofocus,
                onClose: () => Navigator.of(ctx).pop(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The chat screen with the facade's photo picker and theme wired in.
  /// [onBack] shows the header's back button (pop your route); [menuItems]
  /// add to its ⋮ menu; [welcomeTitle]/[welcomeSubtitle] replace the welcome
  /// card's copy per language.
  static Widget view(
          {SunonoTheme? theme,
          bool showHeader = true,
          bool autofocus = false,
          VoidCallback? onBack,
          List<SunonoMenuItem> menuItems = const [],
          Map<String, String>? welcomeTitle,
          Map<String, String>? welcomeSubtitle}) =>
      SunonoChatView(
        controller: controller,
        theme: theme ?? _theme,
        pickImage: _pickImage,
        showHeader: showHeader,
        autofocus: autofocus,
        onBack: onBack,
        menuItems: menuItems,
        welcomeTitle: welcomeTitle,
        welcomeSubtitle: welcomeSubtitle,
      );
}
