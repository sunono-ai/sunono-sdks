import 'dart:async';
import 'dart:convert';

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sunono/sunono.dart';
import 'package:sunono/src/core/live.dart';
import 'package:sunono/src/core/session.dart';
import 'package:sunono/src/core/sse.dart';
import 'package:sunono/src/ui/cards.dart';

import 'fake_server.dart';

void main() {
  imageTests();
  late FakeServer server;
  late SunonoChatController c;
  var made = false;
  var now = DateTime(2026, 1, 1);

  SunonoApi api({Duration? turnTimeout, Duration? requestTimeout, String apiBase = 'https://api.test/api'}) =>
      SunonoApi(
        shopKey: 'pk_test',
        apiBase: apiBase,
        turnTimeout: turnTimeout ?? const Duration(seconds: 90),
        requestTimeout: requestTimeout ?? const Duration(seconds: 15),
        clientFactory: () => MockClient.streaming(server.handle),
      );

  SunonoChatController make({
    Duration? turnTimeout,
    Duration? requestTimeout,
    List<Duration> recoveryChecks = const [Duration(milliseconds: 20), Duration(milliseconds: 20)],
    SunonoCartBridge? bridge,
  }) {
    made = true;
    return c = SunonoChatController(
      api: api(turnTimeout: turnTimeout, requestTimeout: requestTimeout),
      storage: MemoryStorage(),
      cartBridge: bridge,
      recoveryChecks: recoveryChecks,
      clock: () => now,
    );
  }

  setUp(() {
    server = FakeServer();
    now = DateTime(2026, 1, 1);
    made = false;
  });

  tearDown(() {
    if (made) c.dispose();
    server.close();
  });

  test('a stalled /chat times out into recovery, then fails as not_delivered', () async {
    make(turnTimeout: const Duration(milliseconds: 50), recoveryChecks: const [Duration(milliseconds: 80)]);
    await c.open();
    final gate = Completer<void>();
    server.beforeChatReply = () => gate.future;
    final sending = c.send('hello');
    await server.until(() => c.messages.any((m) => m.state == MessageState.recovering));
    await sending;
    expect(c.messages.last.state, MessageState.failed);
    expect(c.messages.last.errorCode, 'not_delivered');
    gate.complete();
  });

  test('a stalled photo upload times out: the photo fails (offline) and the composer is not stuck', () async {
    make(turnTimeout: const Duration(milliseconds: 50), requestTimeout: const Duration(milliseconds: 50));
    await c.open();
    final gate = Completer<void>();
    server.beforeUpload = () => gate.future;
    await c.attachPhoto(SunonoImage(Uint8List.fromList([0xFF, 0xD8, 0xFF, 1]))).timeout(const Duration(seconds: 5));
    expect((c.photo.value as PhotoFailed).code, 'offline');
    expect(c.busy, isFalse);
    gate.complete();
  });

  test('a /chat/stream connect that times out still drains the late response', () async {
    final released = Completer<void>();
    final api = SunonoApi(
      shopKey: 'pk_test',
      apiBase: 'https://api.test/api',
      turnTimeout: const Duration(milliseconds: 20),
      clientFactory: () => MockClient.streaming((req, body) async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        final late = StreamController<List<int>>(onCancel: released.complete);
        return http.StreamedResponse(late.stream, 200);
      }),
    );
    await expectLater(api.chatStream('t', 'x', lang: 'ar').drain<void>(), throwsA(isA<TimeoutException>()));
    await released.future.timeout(const Duration(seconds: 2));
  });

  test('parseSse: lone CR breaks lines, CRLF (even split across chunks) breaks once', () async {
    final chunks = ['data: a\r', '\ndata: b\r\r', 'data: c\n\n', 'event: e\r\ndata: d\r\n\r\n']
        .map((t) => utf8.encode(t))
        .toList();
    final frames = await parseSse(Stream.fromIterable(chunks)).toList();
    expect(frames.map((f) => (f.event, f.data)).toList(), [(null, 'a\nb'), (null, 'c'), ('e', 'd')]);
  });

  test('parseSse: a 200 KB frame in one-byte chunks stays linear and intact', () async {
    final bytes = utf8.encode('data: ${'q' * 200000}\n\n');
    final frames = await parseSse(Stream.fromIterable(bytes.map((b) => [b]))).toList();
    expect(frames.single.data.length, 200000);
  });

  group('history beyond the 300 cap', () {
    List<Map<String, dynamic>> rows() => [
          {'role': 'user', 'sender': 'user', 'text': 'hi', 'msg_ref': 'u0'},
          {'role': 'bot', 'sender': 'bot', 'text': 'hello', 'msg_ref': 'b0'},
          for (var i = 2; i < 400; i++) {'role': 'bot', 'sender': 'bot', 'text': 'm$i', 'msg_ref': 'r$i'},
        ];

    test('refreshing again keeps order and length (trimmed rows are not re-appended)', () async {
      server.historyRows = rows();
      make();
      await c.open();
      await server.until(() => server.live != null);
      await c.refreshHistory();
      await c.refreshHistory();
      expect(c.messages, hasLength(300));
      expect(c.messages.first.text, 'm100');
      expect(c.messages.last.text, 'm399');
    });

    test('recovery does not adopt a trimmed old row with the same text', () async {
      server.historyRows = rows();
      make();
      await c.open();
      await server.until(() => server.live != null);
      server.dropChat = true;
      await c.send('hi'); // the old, trimmed 'hi' (u0) must not count as this send
      expect(c.messages.last.state, MessageState.failed);
      expect(c.messages.last.errorCode, 'not_delivered');
    });
  });

  test('resume on a disabled chat re-opens it once the shop switches chat back on', () async {
    server.config = {'enabled': false, 'reason': 'platform_disabled'};
    make();
    await c.open();
    expect(c.status, ChatStatus.disabled);
    server.config = {'enabled': true};
    now = now.add(const Duration(seconds: 30));
    c.resume();
    await pumpEvents();
    expect(c.status, ChatStatus.disabled, reason: 'config is still fresh');
    now = now.add(const Duration(seconds: 31));
    c.resume();
    await server.until(() => c.status == ChatStatus.ready);
    expect(c.disabledReason, isNull);
  });

  test('apiBase must be https, except local development hosts', () {
    expect(() => api(apiBase: 'http://evil'), throwsArgumentError);
    expect(() => api(apiBase: 'http://api.sunono.ai/api'), throwsArgumentError);
    expect(() => api(apiBase: 'ftp://localhost'), throwsArgumentError);
    for (final ok in [
      'https://api.test/api',
      'http://localhost:5000/api',
      'http://127.0.0.1:5000/api',
      'http://10.0.2.2:5000/api'
    ]) {
      expect(() => api(apiBase: ok), returnsNormally, reason: ok);
    }
  });

  test('parseSse aborts on a 2 MB line and on 1 MB+ of frame data', () async {
    final big = utf8.encode('data: ${'x' * (2 * 1024 * 1024)}\n\n');
    await expectLater(parseSse(Stream.value(big)).toList(), throwsA(isA<SseTooLarge>()));
    final lines = 'data: ${'y' * 100000}\n' * 11;
    await expectLater(parseSse(Stream.value(utf8.encode('$lines\n'))).toList(), throwsA(isA<SseTooLarge>()));
    final ok = await parseSse(Stream.value(utf8.encode('data: ${'z' * 200000}\n\n'))).toList();
    expect(ok.single.data.length, 200000);
  });

  test('an oversized live frame drops the stream and the connection reconnects', () async {
    final errors = <Object>[];
    final a = api();
    final live = LiveConnection(
      api: a,
      session: Session(a, MemoryStorage()),
      onEvent: (_, __) {},
      beforeConnect: () async {},
      onError: (e, s) => errors.add(e),
      backoff: const [Duration(milliseconds: 10)],
    );
    live.start();
    await server.until(() => server.live != null);
    server.live!.add(utf8.encode('data: ${'x' * (2 * 1024 * 1024)}\n\n'));
    await server.until(() => server.count('/chat/subscribe?') == 2);
    expect(errors.single, isA<SseTooLarge>());
    live.stop();
  });

  test('the on-screen history is capped at the newest 300 messages', () async {
    server.historyRows = [
      for (var i = 0; i < 400; i++) {'role': 'bot', 'sender': 'bot', 'text': 'm$i', 'msg_ref': 'r$i'},
    ];
    make();
    await c.open();
    await server.until(() => server.live != null);
    expect(c.messages, hasLength(300));
    expect(c.messages.first.text, 'm100');
    expect(c.messages.last.text, 'm399');
  });

  test('init body carries channel app; every request has the client header and the config URL the platform', () async {
    make();
    await c.open();
    await server.until(() => server.live != null);
    final init = jsonDecode(server.bodies['/shops/init']!.single) as Map<String, dynamic>;
    expect(init['channel'], 'app');
    expect(init['user_id'], isA<String>());
    final pattern = RegExp(r'^sunono-flutter/\S+ \((ios|android|other)\)$');
    for (final r in server.requests) {
      expect(r.headers['X-Sunono-Client'], matches(pattern), reason: r.url.path);
    }
    final cfg = server.requests.firstWhere((r) => r.url.path.endsWith('/widget/config'));
    expect(cfg.url.queryParameters['platform'], matches(RegExp(r'^(ios|android|other)$')));
    expect(cfg.url.queryParameters['key'], 'pk_test');
  });

  test('a retry reuses the client_message_id; a new message gets a fresh one', () async {
    make();
    await c.open();
    server.dropChat = true;
    await c.send('hello');
    server.dropChat = false;
    await c.retry(c.messages.last);
    await c.send('another');
    final ids = server.bodies['/chat']!.map((b) => jsonDecode(b)['client_message_id'] as String).toList();
    expect(ids, hasLength(3));
    expect(ids[0], ids[1]);
    expect(ids[2], isNot(ids[0]));
    expect(ids[0], matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
  });

  test('409 turn_in_progress keeps the bubble recovering until the reply lands', () async {
    make(recoveryChecks: const [Duration(seconds: 30)]);
    await c.open();
    await server.until(() => server.live != null);
    server.failChatOnceWith = 409;
    server.failChatBody = {'error': 'turn_in_progress'};
    final sending = c.send('hello');
    await server.until(() => c.messages.any((m) => m.state == MessageState.recovering));
    expect(c.messages.any((m) => m.state == MessageState.failed), isFalse);
    expect(server.count('/chat'), 1, reason: 'never resent automatically');
    server.historyRows = [
      {'role': 'user', 'sender': 'user', 'text': 'hello', 'msg_ref': 'u1'},
      {'role': 'bot', 'sender': 'bot', 'text': 'hi there', 'msg_ref': 'b1'},
    ];
    server.pushLive('message.new', {'body_text': 'hi there', 'msg_ref': 'b1'});
    await sending.timeout(const Duration(seconds: 5));
    expect(c.messages.map((m) => m.text).toList(), ['hello', 'hi there']);
  });

  test('403 platform_disabled switches the chat to the disabled state', () async {
    make();
    await c.open();
    server.failChatOnceWith = 403;
    server.failChatBody = {'error': 'platform_disabled'};
    await c.send('hello');
    expect(c.status, ChatStatus.disabled);
    expect(c.disabledReason, 'platform_disabled');
    expect(c.messages.any((m) => m.state == MessageState.failed), isFalse);
  });

  test('config reason platform_disabled is surfaced on open', () async {
    server.config = {'enabled': false, 'reason': 'platform_disabled'};
    make();
    await c.open();
    expect(c.status, ChatStatus.disabled);
    expect(c.disabledReason, 'platform_disabled');
  });

  group('config freshness on resume', () {
    test('refetches only when the last fetch is older than 60 s', () async {
      make();
      await c.open();
      await server.until(() => server.live != null);
      expect(server.count('/widget/config'), 1);
      now = now.add(const Duration(seconds: 59));
      c.resume();
      await pumpEvents();
      expect(server.count('/widget/config'), 1);
      now = now.add(const Duration(seconds: 2));
      c.resume();
      await server.until(() => server.count('/widget/config') == 2);
    });

    test('applies the kill switch', () async {
      make();
      await c.open();
      await server.until(() => server.live != null);
      server.config = {'enabled': false};
      now = now.add(const Duration(seconds: 61));
      c.resume();
      await server.until(() => c.status == ChatStatus.disabled);
    });

    test('applies the min SDK version', () async {
      make();
      await c.open();
      await server.until(() => server.live != null);
      expect(c.updateRequired, isFalse);
      server.config = {
        'enabled': true,
        'app': {'min_sdk_version': '99.0.0'},
      };
      now = now.add(const Duration(seconds: 61));
      c.resume();
      await server.until(() => c.updateRequired);
    });
  });

  test('the cart proof is posted with only the ten protocol keys', () async {
    make(bridge: _Bridge());
    await c.open();
    await c.send('hi');
    final proof = jsonDecode(server.bodies['/widget/cart-binding']!.last)['proof'] as Map<String, dynamic>;
    expect(proof.keys.toSet(), {
      'v', 'shop_key', 'widget_user_id', 'origin', 'binding_ref', 'store_code', 'issued_at', 'expires_at', 'nonce',
      'sig' //
    });
    expect(proof['sig'], 's');
  });
}

void imageTests() {
  testWidgets('network images decode at the displayed width x pixel ratio and have an error fallback', (tester) async {
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final p = ProductCard.fromJson({
      'public_id': 'prod_1',
      'sku': 'S',
      'title_ar': 'x',
      'img_urls': ['https://cdn.test/a.jpg'],
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ProductTile(product: p, theme: SunonoTheme.fromMaterial(ThemeData()), lang: 'en', onOpen: () {}),
      ),
    ));
    final img = tester.widget<Image>(find.byType(Image));
    expect((img.image as ResizeImage).width, (164 * 2.5).ceil());
    expect(img.errorBuilder, isNotNull);
  });
}

Future<void> pumpEvents() => Future<void>.delayed(const Duration(milliseconds: 20));

class _Bridge implements SunonoCartBridge {
  static const _keys = [
    'v', 'shop_key', 'widget_user_id', 'origin', 'binding_ref', 'store_code', 'issued_at', 'expires_at', 'nonce',
    'sig' //
  ];
  @override
  Future<Map<String, dynamic>?> probe(String userId) async => null;

  @override
  Future<Map<String, dynamic>?> ensureBind(String userId) async => {
        for (final k in _keys) k: k == 'v' ? 1 : k,
        'sig': 's',
        '__typename': 'MagentoProof',
        'extra': 'x',
      };
}
