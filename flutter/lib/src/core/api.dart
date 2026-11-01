import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:http/http.dart' as http;

import 'models.dart';
import 'sse.dart';

const sdkVersion = '0.1.0-dev.1';

/// The server answered with an error status (PROTOCOL §4, §8, §9).
class SunonoHttpException implements Exception {
  SunonoHttpException(this.status, [this.code]);
  final int status;

  /// The JSON `error` field when the body had one (e.g. `image_too_large`).
  final String? code;

  /// 401, or 422 without an `error` field: the token is stale, re-init.
  bool get isAuth => status == 401 || (status == 422 && code == null);

  /// 403 `platform_disabled` (v1.1): the shop turned chat off for app clients.
  bool get isPlatformDisabled => status == 403 && code == 'platform_disabled';

  /// 409 `turn_in_progress` (v1.1): that `client_message_id`'s turn is still running.
  bool get isTurnInProgress => status == 409 && code == 'turn_in_progress';

  @override
  String toString() => 'SunonoHttpException($status${code == null ? '' : ', $code'})';
}

typedef InitResult = ({String token, String userId});

/// `ios`, `android` or `other`: what the client header and `/widget/config` report.
String detectPlatform() => switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'ios',
      TargetPlatform.android => 'android',
      _ => 'other',
    };

const _proofKeys = [
  'v', 'shop_key', 'widget_user_id', 'origin', 'binding_ref', 'store_code', 'issued_at', 'expires_at', 'nonce', 'sig' //
];

const _localHosts = {'localhost', '127.0.0.1', '10.0.2.2'};

/// Thin HTTP client for protocol v1. Stateless: tokens are passed in.
class SunonoApi {
  /// [apiBase] must be https (plain http only for localhost, 127.0.0.1 and
  /// the Android emulator's 10.0.2.2), else [ArgumentError]. Every request
  /// gives up after [requestTimeout]; a `/chat` turn after [turnTimeout].
  SunonoApi({
    required this.shopKey,
    required this.apiBase,
    this.appOrigin,
    http.Client Function()? clientFactory,
    this.turnTimeout = const Duration(seconds: 90),
    this.requestTimeout = const Duration(seconds: 15),
    String? platform,
  })  : platform = platform ?? detectPlatform(),
        _newClient = clientFactory ?? http.Client.new {
    final u = Uri.tryParse(apiBase);
    if (u == null || !(u.scheme == 'https' || (u.scheme == 'http' && _localHosts.contains(u.host)))) {
      throw ArgumentError.value(apiBase, 'apiBase', 'must be https (http only for localhost, 127.0.0.1, 10.0.2.2)');
    }
    _client = _newClient();
  }

  final Duration turnTimeout;
  final Duration requestTimeout;

  /// `ios` / `android` / `other`.
  final String platform;

  final String shopKey;

  /// e.g. `https://api.sunono.ai/api` (no trailing slash).
  final String apiBase;

  /// Sent as `Origin` (PROTOCOL §1). Null on web, where the browser sets it.
  final String? appOrigin;
  final http.Client Function() _newClient;
  late final http.Client _client;

  /// The API's origin, for resolving relative media URLs.
  String get apiOrigin => Uri.parse(apiBase).origin;

  String get _shop => '$apiBase/shops/${Uri.encodeComponent(shopKey)}';

  Map<String, String> _headers({String? token, bool json = false}) => {
        if (appOrigin != null) 'Origin': appOrigin!,
        'X-Sunono-Client': 'sunono-flutter/$sdkVersion ($platform)',
        if (token != null) 'Authorization': 'Bearer $token',
        if (json) 'Content-Type': 'application/json',
      };

  Future<Object?> _decode(http.Response r) async {
    Object? body;
    try {
      // Always UTF-8: Flask sends `application/json` without a charset, and
      // `Response.body` would fall back to Latin-1 and garble Arabic.
      body = r.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    } on FormatException {
      body = null;
    }
    if (r.statusCode >= 400) {
      final code = body is Map && body['error'] is String ? body['error'] as String : null;
      throw SunonoHttpException(r.statusCode, code);
    }
    return body;
  }

  Map<String, dynamic> _obj(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

  Future<InitResult> init(String? userId) async {
    final r = await _client
        .post(Uri.parse('$apiBase/shops/init'),
            headers: _headers(json: true), body: jsonEncode({if (userId != null) 'user_id': userId, 'channel': 'app'}))
        .timeout(requestTimeout);
    final j = _obj(await _decode(r));
    return (token: '${j['access_token']}', userId: '${j['user_id']}');
  }

  Future<ShopConfig> config() async {
    final r = await _client
        .get(Uri.parse('$apiBase/widget/config?key=${Uri.encodeComponent(shopKey)}&platform=$platform'),
            headers: _headers())
        .timeout(requestTimeout);
    return ShopConfig.fromJson(_obj(await _decode(r)));
  }

  /// [productId] (a card's public id) wins over [productSku]; [tap] is the
  /// structured card tap `(action, action_ref)` (PROTOCOL §4).
  Map<String, Object?> _turnBody(String text, String lang, bool synthetic, String? productId, String? productSku,
          ({String action, String ref})? tap, String? imageRef, String? clientMessageId) =>
      {
        'message': text,
        'lang': lang,
        'synthetic': synthetic,
        if (tap != null) 'action': tap.action,
        if (tap != null) 'action_ref': tap.ref,
        if (productId != null) 'product_id': productId else if (productSku != null) 'product_sku': productSku,
        if (clientMessageId != null) 'client_message_id': clientMessageId,
        if (imageRef != null) 'image_ref': imageRef,
      };

  /// Text turn (PROTOCOL §4.0): completes server-side even if we disconnect.
  /// [clientMessageId] makes a resend of the same message safe (§4).
  Future<TurnResult> chat(String token, String text,
      {required String lang,
      bool synthetic = false,
      String? productId,
      String? productSku,
      ({String action, String ref})? tap,
      String? clientMessageId}) async {
    final r = await _client
        .post(Uri.parse('$_shop/chat'),
            headers: _headers(token: token, json: true),
            body: jsonEncode(_turnBody(text, lang, synthetic, productId, productSku, tap, null, clientMessageId)))
        .timeout(turnTimeout);
    return TurnResult.fromJson(_obj(await _decode(r)));
  }

  /// Streamed turn (PROTOCOL §4.0b), used for photo turns. HTTP errors throw
  /// before the first frame.
  Stream<SseFrame> chatStream(String token, String text,
      {required String lang,
      bool synthetic = false,
      String? productId,
      String? productSku,
      ({String action, String ref})? tap,
      String? imageRef,
      String? clientMessageId}) async* {
    final req = http.Request('POST', Uri.parse('$_shop/chat/stream'))
      ..headers.addAll(_headers(token: token, json: true))
      ..body = jsonEncode(_turnBody(text, lang, synthetic, productId, productSku, tap, imageRef, clientMessageId));
    final res = await _client.send(req).timeout(turnTimeout);
    if (res.statusCode >= 400) {
      await _decode(await http.Response.fromStream(res).timeout(requestTimeout));
    }
    // The turn timeout is also the longest silence tolerated between frames.
    yield* parseSse(res.stream).timeout(turnTimeout);
  }

  Future<History> history(String token) async {
    final r = await _client
        .get(Uri.parse('$_shop/chat/history?shape=v2'), headers: _headers(token: token))
        .timeout(requestTimeout);
    return History.fromJson(await _decode(r), apiOrigin: apiOrigin);
  }

  Future<({Cart? cart, bool linked})> cart(String token) async {
    final r = await _client.get(Uri.parse('$_shop/chat/cart'), headers: _headers(token: token)).timeout(requestTimeout);
    final j = _obj(await _decode(r));
    return (cart: Cart.fromJson(j['cart']), linked: j['linked'] == true);
  }

  Future<String> subscribeTicket(String token) async {
    final r = await _client
        .post(Uri.parse('$_shop/chat/subscribe-ticket'), headers: _headers(token: token, json: true), body: '{}')
        .timeout(requestTimeout);
    return '${_obj(await _decode(r))['ticket']}';
  }

  /// Opens the live stream on its own connection; [close] it to disconnect.
  Future<({Stream<SseFrame> frames, void Function() close})> subscribe(String ticket) async {
    final client = _newClient();
    try {
      final req = http.Request('GET', Uri.parse('$_shop/chat/subscribe?ticket=${Uri.encodeComponent(ticket)}'))
        ..headers.addAll(_headers());
      // Only the connect is bounded: the stream is long-lived (ping watchdog).
      final res = await client.send(req).timeout(requestTimeout);
      if (res.statusCode >= 400) {
        await _decode(await http.Response.fromStream(res).timeout(requestTimeout));
      }
      return (frames: parseSse(res.stream), close: client.close);
    } catch (_) {
      client.close();
      rethrow;
    }
  }

  /// Photo upload (PROTOCOL §9). Returns the `image_ref` for the next turn.
  Future<String> upload(String token, List<int> bytes, {String filename = 'photo.jpg'}) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_shop/chat/upload'))
      ..headers.addAll(_headers(token: token))
      ..files.add(http.MultipartFile.fromBytes('image', bytes, filename: filename));
    // Both phases are bounded: the send (a photo on a slow link legitimately
    // outlasts [requestTimeout], so it gets [turnTimeout]) and the reply body.
    final sent = await _client.send(req).timeout(turnTimeout);
    final r = await http.Response.fromStream(sent).timeout(requestTimeout);
    return '${_obj(await _decode(r))['image_ref']}';
  }

  /// Magento cart binding (PROTOCOL §8). True when the cart is now bound.
  /// Only the ten protocol keys of [proof] are sent: a bridge may hand back a
  /// wider map (e.g. a GraphQL `__typename`), and the server must not see it.
  Future<bool> bindCart(String userId, Map<String, dynamic>? proof) async {
    final clean = proof == null
        ? null
        : {
            for (final k in _proofKeys)
              if (proof.containsKey(k)) k: proof[k],
          };
    final r = await _client
        .post(Uri.parse('$apiBase/widget/cart-binding'),
            headers: _headers(json: true), body: jsonEncode({'key': shopKey, 'user_id': userId, 'proof': clean}))
        .timeout(requestTimeout);
    return _obj(await _decode(r))['bound'] == true;
  }

  void close() => _client.close();
}
