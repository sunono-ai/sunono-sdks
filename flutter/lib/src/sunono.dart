import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'core/api.dart';
import 'core/controller.dart';
import 'core/host.dart';
import 'ui/chat_view.dart';
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
  /// - [pickImage]: enables photo messages.
  /// - [starterPrompts]: replaces the empty-thread starter chips per language,
  ///   e.g. `{'ar': ['شو في جديد؟'], 'en': ["What's new?"]}`; `[]` shows none.
  /// - [onIntent]: route product/cart/checkout taps; return true if handled.
  static SunonoChatController init({
    required String shopKey,
    String? appOrigin,
    String apiBaseUrl = 'https://api.sunono.ai/api',
    String locale = 'ar',
    required SunonoStorage storage,
    SunonoCartBridge? cartBridge,
    Future<SunonoImage?> Function()? pickImage,
    bool Function(SunonoIntent intent)? onIntent,
    Map<String, List<String>>? starterPrompts,
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
      onIntent: onIntent,
      starterPrompts: starterPrompts,
    );
  }

  static SunonoChatController get controller =>
      _controller ?? (throw StateError('Call Sunono.init(...) before using Sunono.'));

  /// Cart changes, analytics and non-fatal errors.
  static Stream<SunonoEvent> get events => controller.events;

  /// Follow the app's language at runtime (`ar` / `en`).
  static void setLocale(String locale) => controller.lang = locale;

  /// Logout / account switch: forget this shopper's chat and cart link.
  static Future<void> reset() => controller.reset();

  /// After login, logout or a cart replacement (e.g. `mergeCarts`).
  static Future<void> refreshCartBinding() => controller.refreshCartBinding();

  /// The chat as a full-height bottom sheet, e.g. from a product page:
  /// `Sunono.open(context, initialMessage: 'متوفر بمقاس 42؟')`.
  static Future<void> open(BuildContext context,
      {String? initialMessage, String? productId, String? productSku, SunonoTheme? theme}) {
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
                onClose: () => Navigator.of(ctx).pop(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The chat screen with the facade's photo picker and theme wired in.
  static Widget view({SunonoTheme? theme, bool showHeader = true}) => SunonoChatView(
        controller: controller,
        theme: theme ?? _theme,
        pickImage: _pickImage,
        showHeader: showHeader,
      );
}
