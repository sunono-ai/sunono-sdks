import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/sunono.dart';

import 'fake_server.dart';

void main() {
  late FakeServer server;
  late SunonoChatController c;
  late List<SunonoEvent> events;
  late List<SunonoIntent> intents;

  SunonoChatController make({SunonoStorage? storage, SunonoCartBridge? bridge}) {
    final ctl = SunonoChatController(
      api: SunonoApi(
        shopKey: 'pk_test',
        apiBase: 'https://api.test/api',
        appOrigin: 'https://shop.example',
        clientFactory: () => MockClient.streaming(server.handle),
      ),
      storage: storage ?? MemoryStorage(),
      cartBridge: bridge,
      onIntent: (i) {
        intents.add(i);
        return true;
      },
      recoveryChecks: const [Duration(milliseconds: 10), Duration(milliseconds: 10)],
    );
    ctl.events.listen(events.add);
    return ctl;
  }

  setUp(() {
    server = FakeServer();
    events = [];
    intents = [];
    c = make();
  });

  tearDown(() {
    c.dispose();
    server.close();
  });

  test('open loads config, history and goes live; requests carry origin + client header', () async {
    await c.open();
    await server.until(() => server.count('/chat/subscribe?') == 1);
    expect(c.status, ChatStatus.ready);
    expect(c.config.title('ar'), 'مساعد');
    final init = server.requests.firstWhere((r) => r.url.path.endsWith('/shops/init'));
    expect(init.headers['Origin'], 'https://shop.example');
    expect(init.headers['X-Sunono-Client'], startsWith('sunono-flutter/'));
    expect(server.count('/chat/history'), 1);
  });

  test('a text turn goes to /chat (never /chat/stream), never sends channel, renders cards and cart', () async {
    server.chatReply = {
      'reply': 'لقيتلك:',
      'msg_ref': 'msg_1',
      'action_data': {
        'products': [
          {'public_id': 'prod_1', 'sku': 'SKU-1', 'title_ar': 'قهوة', 'price_jod': 9},
        ],
        'cart_summary': {
          'items': [
            {'product_id': 'prod_1', 'name_ar': 'قهوة', 'qty': 2, 'subtotal_fils': 18000},
          ],
          'item_count': 1,
          'total_fils': 18000,
        },
        'cart_sync': {'mutated': true},
      },
    };
    await c.open();
    await c.send('بدي قهوة');
    final body = jsonDecode(server.bodies['/chat']!.last) as Map<String, dynamic>;
    expect(body.containsKey('channel'), isFalse);
    expect(body['message'], 'بدي قهوة');
    expect(server.count('/chat/stream'), 0);
    final bot = c.messages.last;
    expect(bot.role, ChatRole.bot);
    expect(bot.products.single.sku, 'SKU-1');
    expect(c.cart!.count, 2);
    await pumpEvents();
    expect(events.whereType<CartChangedEvent>(), hasLength(1));

    c.openProduct(bot.products.single);
    expect((intents.single as OpenProductIntent).sku, 'SKU-1');
  });

  test('401 re-inits once with the same user id, then succeeds', () async {
    await c.open();
    await server.until(() => server.live != null);
    final before = server.count('/shops/init');
    server.failChatOnceWith = 401;
    await c.send('hi');
    expect(server.count('/shops/init'), before + 1);
    final inits = server.bodies['/shops/init']!;
    expect(jsonDecode(inits.last)['user_id'], jsonDecode(inits.first)['user_id']);
    expect(c.messages.last.text, server.chatReply['reply']);
  });

  test('network drop: recovery adopts the turn from history instead of resending', () async {
    await c.open();
    server.dropChat = true;
    server.historyRows = [
      {'role': 'user', 'sender': 'user', 'text': 'بدي قهوة', 'ts': DateTime.now().toIso8601String()},
      {'role': 'bot', 'sender': 'bot', 'text': 'تفضل', 'msg_ref': 'msg_9', 'ts': DateTime.now().toIso8601String()},
    ];
    await c.send('بدي قهوة');
    expect(server.count('/chat'), 1, reason: 'never resent automatically');
    expect(c.messages.map((m) => m.text).toList(), ['بدي قهوة', 'تفضل']);
    expect(c.messages.every((m) => m.state == MessageState.done), isTrue);
  });

  test('network drop with nothing in history: retry chip, shopper retries', () async {
    await c.open();
    server.dropChat = true;
    await c.send('hello');
    expect(c.messages.last.state, MessageState.failed);
    expect(c.messages.last.errorCode, 'not_delivered');
    server.dropChat = false;
    await c.retry(c.messages.last);
    expect(server.count('/chat'), 2);
    expect(c.messages.last.state, MessageState.done);
    expect(c.messages.where((m) => m.role == ChatRole.user), hasLength(1));
  });

  test('429 fails without recovery and without resending', () async {
    await c.open();
    server.failChatOnceWith = 429;
    await c.send('hi');
    expect(c.messages.last.errorCode, 'rate_limited');
    expect(server.count('/chat/history'), 1, reason: 'only the open-time fetch');
  });

  test('a live message.new that beats the /chat response ends as one bubble', () async {
    await c.open();
    await server.until(() => server.live != null);
    server.beforeChatReply = () async {
      server.pushLive(
          'message.new', {'body_text': 'لقيتلك:', 'msg_ref': 'msg_1', 'ts': DateTime.now().toIso8601String()});
      await Future<void>.delayed(const Duration(milliseconds: 20));
    };
    server.chatReply = {'reply': 'لقيتلك:', 'msg_ref': 'msg_1', 'action_data': {}};
    await c.send('x');
    expect(c.messages.where((m) => m.msgRef == 'msg_1'), hasLength(1));
  });

  test('live events: staff message, pause pill, cart update, unknown event ignored', () async {
    await c.open();
    await server.until(() => server.live != null);
    server.pushLive('message.new', {'body_text': 'أهلين', 'sent_by': 'owner', 'msg_ref': 'm2'});
    server.pushLive('conversation.paused', {'bot_paused_at': '2026-10-30T22:20:59+00:00'});
    server.pushLive('brand.new.event', {});
    server.pushLive('cart.updated', {
      'cart': {
        'items': [
          {'product_id': 'p', 'qty': 3},
        ],
      },
    });
    await server.until(() => c.cart != null);
    await pumpEvents();
    expect(c.messages.map((m) => m.role).toList(), [ChatRole.system, ChatRole.staff],
        reason: 'the pill sorts by bot_paused_at');
    expect(c.paused, isTrue);
    expect(c.cart!.count, 3);
    expect(events.whereType<CartChangedEvent>(), hasLength(1));
  });

  test('silenced turn removes the placeholder and shows no retry', () async {
    await c.open();
    server.chatReply = {'reply': '', 'paused': true, 'typing_hint': false, 'action_data': {}};
    await c.send('anyone?');
    expect(c.messages.map((m) => m.role).toList(), [ChatRole.user]);
  });

  test('kill switch: disabled config never inits', () async {
    server.config = {'enabled': false};
    await c.open();
    expect(c.status, ChatStatus.disabled);
    expect(server.count('/shops/init'), 0);
  });

  test('user id persists across controllers; reset mints a new one', () async {
    final storage = MemoryStorage();
    final a = make(storage: storage);
    await a.open();
    final id = a.userId;
    a.dispose();
    final b = make(storage: storage);
    await b.open();
    expect(b.userId, id);
    await b.reset();
    await server.until(() => b.userId != null);
    expect(b.userId, isNot(id));
    b.dispose();
  });

  test('cart bridge: probe on open, ensure before the first send, proof posted with origin', () async {
    final bridge = _Bridge();
    final ctl = make(bridge: bridge);
    await ctl.open();
    await server.until(() => bridge.calls.isNotEmpty);
    expect(bridge.calls.first, 'probe');
    await ctl.send('hi');
    expect(bridge.calls, contains('ensure'));
    final bind = server.requests.lastWhere((r) => r.url.path.endsWith('/widget/cart-binding'));
    expect(bind.headers['Origin'], 'https://shop.example');
    expect(jsonDecode(server.bodies['/widget/cart-binding']!.last)['proof'], {'sig': 'x'});
    ctl.dispose();
  });

  test('photo turn uploads then streams; stage updates the placeholder', () async {
    await c.open();
    await c.attachPhoto(SunonoImage(Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2])));
    expect(server.count('/chat/upload'), 1, reason: 'uploaded on pick');
    await c.send('شو هاد؟');
    expect(server.count('/chat/upload'), 1, reason: 'the send reuses the ref');
    expect(server.count('/chat/stream'), 1);
    expect(jsonDecode(server.bodies['/chat/stream']!.last)['image_ref'], 'img_ref_1');
    expect(c.messages.last.text, 'هاي الصورة');
  });

  group('review fixes', () {
    test('a 5xx may come after the turn ran: recover from history, never a plain retry', () async {
      await c.open();
      server.failChatOnceWith = 502;
      server.historyRows = [
        {'role': 'user', 'sender': 'user', 'text': 'ضيف 2', 'msg_ref': 'u1'},
        {'role': 'bot', 'sender': 'bot', 'text': 'ضفتهم', 'msg_ref': 'b1'},
      ];
      await c.send('ضيف 2');
      expect(server.count('/chat'), 1);
      expect(c.messages.map((m) => m.text).toList(), ['ضيف 2', 'ضفتهم']);
    });

    test('resume never duplicates the user bubble, whatever the clocks say', () async {
      await c.open();
      await server.until(() => server.live != null);
      server.chatReply = {'reply': 'تمام', 'msg_ref': 'b1', 'action_data': {}};
      await c.send('مرحبا');
      // Server rows: far-off timestamps (skew / slow turn), user row has its own msg_ref.
      server.historyRows = [
        {'role': 'user', 'sender': 'user', 'text': 'مرحبا', 'msg_ref': 'u1', 'ts': '2020-01-01T00:00:00+00:00'},
        {'role': 'bot', 'sender': 'bot', 'text': 'تمام', 'msg_ref': 'b1', 'ts': '2020-01-01T00:00:30+00:00'},
      ];
      await c.refreshHistory();
      await c.refreshHistory();
      expect(c.messages.map((m) => m.text).toList(), ['مرحبا', 'تمام']);
    });

    test('a repeated text is still recognised as a new turn during recovery', () async {
      await c.open();
      server.chatReply = {'reply': 'أكيد', 'msg_ref': 'b1', 'action_data': {}};
      await c.send('نعم');
      server.dropChat = true;
      server.historyRows = [
        {'role': 'user', 'sender': 'user', 'text': 'نعم', 'msg_ref': 'u1'},
        {'role': 'bot', 'sender': 'bot', 'text': 'أكيد', 'msg_ref': 'b1'},
        {'role': 'user', 'sender': 'user', 'text': 'نعم', 'msg_ref': 'u2'},
        {'role': 'bot', 'sender': 'bot', 'text': 'تم الطلب', 'msg_ref': 'b2'},
      ];
      await c.send('نعم');
      expect(c.messages.last.text, 'تم الطلب');
      expect(c.messages.last.state, MessageState.done);
    });

    test('closing one of two views keeps the live connection for the other', () async {
      c.attach();
      await server.until(() => server.live != null);
      c.attach(); // a sheet over the tab
      c.detach(); // the sheet closes
      server.pushLive('message.new', {'body_text': 'staff here', 'sent_by': 'owner', 'msg_ref': 's1'});
      await server.until(() => c.messages.isNotEmpty);
      expect(c.messages.single.role, ChatRole.staff);
    });

    test('reset during an in-flight turn drops the old shopper\'s reply', () async {
      await c.open();
      final gate = Completer<void>();
      server.beforeChatReply = () => gate.future;
      final sending = c.send('old shopper');
      await server.until(() => server.count('/chat') == 1);
      final resetting = c.reset();
      gate.complete();
      await Future.wait([sending, resetting]);
      expect(c.messages.where((m) => m.text == 'old shopper' || m.text == server.chatReply['reply']), isEmpty);
      expect(c.busy, isFalse);
    });

    test('concurrent first use mints exactly one shopper id', () async {
      final storage = MemoryStorage();
      final ctl = make(storage: storage, bridge: _Bridge());
      await ctl.open(); // bind + live start race for the id
      await server.until(() => server.count('/shops/init') >= 1);
      final ids = server.bodies['/shops/init']!.map((b) => jsonDecode(b)['user_id']).toSet();
      expect(ids, hasLength(1));
      expect(ctl.userId, ids.single);
      ctl.dispose();
    });

    test('a live bot reply during recovery ends it early', () async {
      final ctl = SunonoChatController(
        api: SunonoApi(
            shopKey: 'pk_test',
            apiBase: 'https://api.test/api',
            clientFactory: () => MockClient.streaming(server.handle)),
        storage: MemoryStorage(),
        recoveryChecks: const [Duration(seconds: 30)],
      );
      await ctl.open();
      await server.until(() => server.live != null);
      server.dropChat = true;
      final sending = ctl.send('hello');
      await server.until(() => ctl.messages.any((m) => m.state == MessageState.recovering));
      server.historyRows = [
        {'role': 'user', 'sender': 'user', 'text': 'hello', 'msg_ref': 'u9'},
        {'role': 'bot', 'sender': 'bot', 'text': 'hi there', 'msg_ref': 'b9'},
      ];
      server.pushLive('message.new', {'body_text': 'hi there', 'msg_ref': 'b9'});
      await sending.timeout(const Duration(seconds: 5));
      expect(ctl.messages.map((m) => m.text).toList(), ['hello', 'hi there']);
      ctl.dispose();
    });

    test('history clears a cart that emptied elsewhere', () async {
      await c.open();
      server.chatReply = {
        'reply': 'ok',
        'action_data': {
          'cart': {
            'items': [
              {'product_id': 'p', 'qty': 1}
            ]
          },
        },
      };
      await c.send('x');
      expect(c.cart, isNotNull);
      await c.refreshHistory(); // server says: no cart
      expect(c.cart, isNull);
    });
  });
}

Future<void> pumpEvents() => Future<void>.delayed(Duration.zero);

class _Bridge implements SunonoCartBridge {
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>?> probe(String userId) async {
    calls.add('probe');
    return null;
  }

  @override
  Future<Map<String, dynamic>?> ensureBind(String userId) async {
    calls.add('ensure');
    return {'sig': 'x'};
  }
}
