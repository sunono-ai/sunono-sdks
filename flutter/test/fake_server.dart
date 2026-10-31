import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// An in-memory Sunono backend for tests (protocol v1 shapes).
class FakeServer {
  final requests = <http.BaseRequest>[];
  final bodies = <String, List<String>>{};
  final _keys = <String>[];

  Map<String, dynamic> config = {'enabled': true, 'header_title_ar': 'مساعد'};
  Map<String, dynamic> chatReply = {'reply': 'تمام', 'msg_ref': 'msg_ok', 'action_data': <String, dynamic>{}};
  List<Map<String, dynamic>> historyRows = [];
  int? failChatOnceWith;
  bool dropChat = false;
  Future<void> Function()? beforeChatReply;
  StreamController<List<int>>? live;
  int _tokens = 0;

  static String keyOf(Uri u) {
    var k = u.path.replaceFirst('/api/shops/pk_test', '').replaceFirst('/api', '');
    if (k == '/chat/subscribe') k = '/chat/subscribe?';
    return k;
  }

  int count(String key) => _keys.where((k) => k == key).length;

  Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 3)}) async {
    final end = DateTime.now().add(timeout);
    while (!cond()) {
      if (DateTime.now().isAfter(end)) throw TimeoutException('condition never became true');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  void pushLive(String type, Map<String, dynamic> data) =>
      live!.add(utf8.encode('event: $type\ndata: ${jsonEncode({'type': type, 'data': data})}\n\n'));

  void close() => live?.close();

  http.StreamedResponse _json(Object body, [int status = 200]) =>
      http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), status);

  Future<http.StreamedResponse> handle(http.BaseRequest req, http.ByteStream bodyStream) async {
    final body = utf8.decode(await bodyStream.toBytes(), allowMalformed: true);
    final key = keyOf(req.url);
    requests.add(req);
    _keys.add(key);
    (bodies[key] ??= []).add(body);

    switch (key) {
      case '/shops/init':
        final uid = (jsonDecode(body) as Map)['user_id'] ?? '00000000-0000-4000-8000-000000000000';
        return _json({'access_token': 'tok${++_tokens}', 'user_id': uid, 'session_id': 's'});
      case '/widget/config':
        return _json(config);
      case '/chat':
        if (dropChat) throw http.ClientException('Connection reset by peer');
        if (failChatOnceWith != null) {
          final s = failChatOnceWith!;
          failChatOnceWith = null;
          return _json({'message': 'nope'}, s);
        }
        await beforeChatReply?.call();
        return _json(chatReply);
      case '/chat/history':
        return _json({'messages': historyRows, 'bot_paused_at': null, 'cart': null, 'cart_linked': false});
      case '/chat/subscribe-ticket':
        return _json({'ticket': 't'});
      case '/chat/subscribe?':
        live = StreamController<List<int>>();
        return http.StreamedResponse(live!.stream, 200);
      case '/chat/upload':
        return _json({'image_ref': 'img_ref_1', 'url': 'https://cdn.test/p.jpg'});
      case '/chat/stream':
        const frames = 'data: {"type":"stage","stage":"understand"}\n\n'
            'data: {"type":"done","reply":"هاي الصورة","msg_ref":"msg_p","action_data":{}}\n\n';
        return http.StreamedResponse(Stream.value(utf8.encode(frames)), 200);
      case '/widget/cart-binding':
        return _json({'bound': true, 'replayed': false});
    }
    return _json({'message': 'not found'}, 404);
  }
}
