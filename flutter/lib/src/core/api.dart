import 'dart:async';
import 'dart:convert';

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

  @override
  String toString() => 'SunonoHttpException($status${code == null ? '' : ', $code'})';
}

typedef InitResult = ({String token, String userId});

/// Thin HTTP client for protocol v1. Stateless: tokens are passed in.
class SunonoApi {
  SunonoApi({
    required this.shopKey,
    required this.apiBase,
    this.appOrigin,
    http.Client Function()? clientFactory,
  }) : _newClient = clientFactory ?? http.Client.new {
    _client = _newClient();
  }

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
        'X-Sunono-Client': 'sunono-flutter/$sdkVersion',
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
    final r = await _client.post(Uri.parse('$apiBase/shops/init'),
        headers: _headers(json: true), body: jsonEncode({if (userId != null) 'user_id': userId}));
    final j = _obj(await _decode(r));
    return (token: '${j['access_token']}', userId: '${j['user_id']}');
  }

  Future<ShopConfig> config() async {
    final r =
        await _client.get(Uri.parse('$apiBase/widget/config?key=${Uri.encodeComponent(shopKey)}'), headers: _headers());
    return ShopConfig.fromJson(_obj(await _decode(r)));
  }

  Map<String, Object?> _turnBody(String text, String lang, bool synthetic, String? productId, String? imageRef) => {
        'message': text,
        'lang': lang,
        'synthetic': synthetic,
        if (productId != null) 'product_id': productId,
        if (imageRef != null) 'image_ref': imageRef,
      };

  /// Text turn (PROTOCOL §4.0): completes server-side even if we disconnect.
  Future<TurnResult> chat(String token, String text,
      {required String lang, bool synthetic = false, String? productId}) async {
    final r = await _client.post(Uri.parse('$_shop/chat'),
        headers: _headers(token: token, json: true),
        body: jsonEncode(_turnBody(text, lang, synthetic, productId, null)));
    return TurnResult.fromJson(_obj(await _decode(r)));
  }

  /// Streamed turn (PROTOCOL §4.0b), used for photo turns. HTTP errors throw
  /// before the first frame.
  Stream<SseFrame> chatStream(String token, String text,
      {required String lang, bool synthetic = false, String? productId, String? imageRef}) async* {
    final req = http.Request('POST', Uri.parse('$_shop/chat/stream'))
      ..headers.addAll(_headers(token: token, json: true))
      ..body = jsonEncode(_turnBody(text, lang, synthetic, productId, imageRef));
    final res = await _client.send(req);
    if (res.statusCode >= 400) {
      await _decode(await http.Response.fromStream(res));
    }
    yield* parseSse(res.stream);
  }

  Future<History> history(String token) async {
    final r = await _client.get(Uri.parse('$_shop/chat/history?shape=v2'), headers: _headers(token: token));
    return History.fromJson(await _decode(r), apiOrigin: apiOrigin);
  }

  Future<({Cart? cart, bool linked})> cart(String token) async {
    final r = await _client.get(Uri.parse('$_shop/chat/cart'), headers: _headers(token: token));
    final j = _obj(await _decode(r));
    return (cart: Cart.fromJson(j['cart']), linked: j['linked'] == true);
  }

  Future<String> subscribeTicket(String token) async {
    final r = await _client.post(Uri.parse('$_shop/chat/subscribe-ticket'),
        headers: _headers(token: token, json: true), body: '{}');
    return '${_obj(await _decode(r))['ticket']}';
  }

  /// Opens the live stream on its own connection; [close] it to disconnect.
  Future<({Stream<SseFrame> frames, void Function() close})> subscribe(String ticket) async {
    final client = _newClient();
    try {
      final req = http.Request('GET', Uri.parse('$_shop/chat/subscribe?ticket=${Uri.encodeComponent(ticket)}'))
        ..headers.addAll(_headers());
      final res = await client.send(req);
      if (res.statusCode >= 400) {
        await _decode(await http.Response.fromStream(res));
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
    final r = await http.Response.fromStream(await _client.send(req));
    return '${_obj(await _decode(r))['image_ref']}';
  }

  /// Magento cart binding (PROTOCOL §8). True when the cart is now bound.
  Future<bool> bindCart(String userId, Map<String, dynamic>? proof) async {
    final r = await _client.post(Uri.parse('$apiBase/widget/cart-binding'),
        headers: _headers(json: true), body: jsonEncode({'key': shopKey, 'user_id': userId, 'proof': proof}));
    return _obj(await _decode(r))['bound'] == true;
  }

  void close() => _client.close();
}
