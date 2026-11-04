import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/src/core/format.dart';
import 'package:sunono/src/ui/cards.dart' show ProductTile;
import 'package:sunono/sunono.dart';

import 'fake_server.dart';

Map<String, dynamic> row(String role, String text,
        {String? ref, String? ts, String sender = 'bot', List<Map<String, dynamic>>? products, bool more = false}) =>
    {
      'role': role == 'user' ? 'user' : 'bot',
      'sender': role == 'user' ? 'user' : sender,
      'text': text,
      'msg_ref': ref,
      'ts': ts,
      'products': products ?? [],
      'has_more': more,
    };

void main() {
  late FakeServer server;
  late SunonoChatController c;
  late List<SunonoEvent> events;

  SunonoChatController make(String lang,
          {Map<String, List<String>>? starters,
          Map<String, List<SunonoQuickReply>>? quick,
          bool Function(SunonoIntent)? onIntent}) =>
      c = SunonoChatController(
        api: SunonoApi(
          shopKey: 'pk_test',
          apiBase: 'https://api.test/api',
          appOrigin: 'https://shop.example',
          clientFactory: () => MockClient.streaming(server.handle),
        ),
        storage: MemoryStorage(),
        lang: lang,
        starterPrompts: starters,
        quickReplies: quick,
        onIntent: onIntent,
        recoveryChecks: const [Duration(milliseconds: 5)],
      )..events.listen(events.add);

  setUp(() {
    server = FakeServer();
    events = [];
  });

  Widget app(Widget child, {double textScale = 1}) => MaterialApp(
        theme: ThemeData(colorSchemeSeed: const Color(0xFF57227D)),
        home: MediaQuery(
          data: MediaQueryData(
              disableAnimations: true, size: const Size(400, 800), textScaler: TextScaler.linear(textScale)),
          child: Scaffold(body: child),
        ),
      );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    server.close();
  }

  Future<void> sendFromUi(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await settle(tester);
  }

  group('format', () {
    test('formatTime: HH:MM, 24 h, Latin digits, local, same for both languages', () {
      expect(formatTime(DateTime(2026, 1, 1, 9, 5), 'ar'), '09:05');
      expect(formatTime(DateTime(2026, 1, 1, 21, 40), 'en'), '21:40');
      expect(formatTime(DateTime(2026, 1, 1, 0, 0), 'ar'), '00:00');
      final utc = DateTime.utc(2026, 1, 1, 12, 30);
      expect(formatTime(utc, 'en'), '${utc.toLocal().hour.toString().padLeft(2, '0')}:30');
    });

    test('isSafeLink: https only, no format chars, ASCII host', () {
      expect(isSafeLink('https://shop.example/p/1'), isTrue);
      expect(isSafeLink('http://shop.example'), isFalse);
      expect(isSafeLink('javascript:alert(1)'), isFalse);
      for (final cf
          in [0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2069].map(String.fromCharCode)) {
        expect(isSafeLink('https://shop.example/${cf}p'), isFalse, reason: cf.codeUnitAt(0).toRadixString(16));
      }
      expect(isSafeLink('https://shöp.example/p'), isFalse);
      expect(isSafeLink('https://пример.example/'), isFalse);
      expect(isSafeLink('https://'), isFalse);
      expect(isSafeLink('https://shop.example@evil.com/p'), isFalse, reason: 'userinfo');
      expect(isSafeLink('https://user:pw@shop.example/'), isFalse);
      expect(isSafeLink('https://shop.example/p@x'), isTrue, reason: '@ in the path is fine');
      expect(trimLinkTail('https://shop.example/p${String.fromCharCode(0x200F)}'), 'https://shop.example/p');
      expect(trimLinkTail('https://shop.example/p.${String.fromCharCode(0x200F)}؟'), 'https://shop.example/p');
    });

    test('welcome has no cross-language fallback', () {
      const only = ShopConfig(welcomeAr: 'أهلين');
      expect(only.welcome('ar'), 'أهلين');
      expect(only.welcome('en'), isNull);
      expect(const ShopConfig(welcomeEn: 'Hi').welcome('ar'), isNull);
    });
  });

  testWidgets('an app-style history restores its cards, the 5 products and Show more', (tester) async {
    final f = jsonDecode(File('../protocol/fixtures/history_app.json').readAsStringSync()) as Map<String, dynamic>;
    server.historyBody = f['response'];
    await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
    await settle(tester);
    expect(c.messages.where((m) => m.checkout != null), hasLength(3), reason: 'collect, confirm, placed');
    expect(c.messages.where((m) => m.orderIds != null).single.orderIds!.number, '1001');
    expect(c.messages.where((m) => m.handoff?.target == 'cart'), hasLength(1));
    expect(c.messages.last.products, hasLength(5));
    expect(find.byType(ProductTile), findsNWidgets(5));
    expect(find.text('شوف أكثر'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  group('pause pills', () {
    List<String> shape() => c.messages.map((m) => m.role == ChatRole.system ? '[${m.text}]' : m.text).toList();

    test('history: staff after the pause: pill sorted at bot_paused_at, before that staff row', () async {
      server.historyBody = {
        'messages': [
          row('user', 'hi', ts: '2026-10-30T22:19:00+00:00'),
          row('bot', 'bot reply', ts: '2026-10-30T22:20:30+00:00'),
          row('bot', 'staff here', ref: 's1', ts: '2026-10-30T22:21:00+00:00', sender: 'staff'),
        ],
        'bot_paused_at': '2026-10-30T22:20:59+00:00',
        'cart': null,
      };
      make('ar');
      await c.open();
      await server.until(() => c.messages.isNotEmpty);
      expect(shape(), ['hi', 'bot reply', '[paused]', 'staff here']);
      expect(c.messages[2].ts, DateTime.utc(2026, 10, 30, 22, 20, 59));
    });

    Map<String, dynamic> pauseHistory(String staffTs, String pausedAt) => {
          'messages': [
            row('user', 'hi', ref: 'u0', ts: '2026-10-30T22:19:00+00:00'),
            row('bot', 'bot reply', ref: 'b0', ts: '2026-10-30T22:19:30+00:00'),
            row('bot', 'staff here', ref: 's1', ts: staffTs, sender: 'staff'),
          ],
          'bot_paused_at': pausedAt,
          'cart': null,
        };

    test('staff row saved first (ts = bot_paused_at - 50 ms): [paused, staff] on cold load and after refresh',
        () async {
      server.historyBody = pauseHistory('2026-10-30T22:20:00.000+00:00', '2026-10-30T22:20:00.050+00:00');
      make('ar');
      await c.open();
      await server.until(() => c.messages.isNotEmpty);
      expect(shape(), ['hi', 'bot reply', '[paused]', 'staff here']);
      final pill = c.messages[2];
      await c.refreshHistory();
      await c.refreshHistory();
      expect(shape(), ['hi', 'bot reply', '[paused]', 'staff here']);
      expect(c.messages[2], same(pill), reason: 'the pill does not jump or get rebuilt');
    });

    test('a live pill that follows its staff message by 50 ms stays put across a refresh', () async {
      server.historyBody = {
        'messages': [
          row('user', 'hi', ref: 'u0', ts: '2026-10-30T22:19:00+00:00'),
          row('bot', 'bot reply', ref: 'b0', ts: '2026-10-30T22:19:30+00:00'),
        ],
        'cart': null,
      };
      make('ar');
      await c.open();
      await server.until(() => server.live != null && c.messages.length == 2);
      server.pushLive('message.new',
          {'body_text': 'staff here', 'sent_by': 'owner', 'msg_ref': 's1', 'ts': '2026-10-30T22:20:00.000+00:00'});
      await server.until(() => c.messages.length == 3);
      server.pushLive('conversation.paused', {'bot_paused_at': '2026-10-30T22:20:00.050+00:00'});
      await server.until(() => c.messages.length == 4);
      expect(shape(), ['hi', 'bot reply', '[paused]', 'staff here']);
      final pill = c.messages[2];
      server.historyBody = pauseHistory('2026-10-30T22:20:00.000+00:00', '2026-10-30T22:20:00.050+00:00');
      await c.refreshHistory();
      expect(shape(), ['hi', 'bot reply', '[paused]', 'staff here']);
      expect(c.messages[2], same(pill));
    });

    test('a staff row more than 60 s before the pause is not an anchor', () async {
      server.historyBody = pauseHistory('2026-10-30T22:19:00.000+00:00', '2026-10-30T22:20:30+00:00');
      make('ar');
      await c.open();
      await server.until(() => c.messages.isNotEmpty);
      expect(shape(), ['hi', 'bot reply', 'staff here', '[paused]']);
    });

    test('a staff row long after the pause: the pill sits at bot_paused_at', () async {
      server.historyBody = {
        'messages': [
          row('user', 'hi', ts: '2026-10-30T22:19:00+00:00'),
          row('bot', 'late bot', ts: '2026-10-30T22:22:00+00:00'),
          row('bot', 'staff late', ref: 's1', ts: '2026-10-30T22:25:00+00:00', sender: 'staff'),
        ],
        'bot_paused_at': '2026-10-30T22:20:00+00:00',
        'cart': null,
      };
      make('ar');
      await c.open();
      await server.until(() => c.messages.isNotEmpty);
      expect(shape(), ['hi', '[paused]', 'late bot', 'staff late']);
    });

    test('live pill sorts by ts; a tie goes before the same-ts staff bubble; exact repeat is dropped', () async {
      make('ar');
      await c.open();
      await server.until(() => server.live != null);
      server.pushLive('message.new',
          {'body_text': 'staff', 'sent_by': 'owner', 'msg_ref': 'm2', 'ts': '2026-10-30T22:21:00+00:00'});
      await server.until(() => c.messages.isNotEmpty);
      server.pushLive('conversation.paused', {'bot_paused_at': '2026-10-30T22:21:00+00:00'});
      await server.until(() => c.messages.length == 2);
      expect(shape(), ['[paused]', 'staff']);
      server.pushLive('conversation.paused', {'bot_paused_at': '2026-10-30T22:21:00+00:00'});
      server.pushLive('conversation.resumed', {});
      await server.until(() => c.messages.length == 3);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(shape(), ['[paused]', 'staff', '[resumed]']);
    });

    test('the live pill and the history rebuild are one pill', () async {
      make('ar');
      await c.open();
      await server.until(() => server.live != null);
      server.pushLive('conversation.paused', {'bot_paused_at': '2026-10-30T22:20:59+00:00'});
      await server.until(() => c.messages.length == 1);
      server.historyBody = {
        'messages': [row('bot', 'staff here', ref: 's1', ts: '2026-10-30T22:21:00+00:00', sender: 'staff')],
        'bot_paused_at': '2026-10-30T22:20:59+00:00',
        'cart': null,
      };
      await c.refreshHistory();
      expect(shape(), ['[paused]', 'staff here']);
    });

    test('recovery adopting history keeps pills and re-anchors the pause', () async {
      make('ar');
      await c.open();
      await server.until(() => server.live != null);
      server.pushLive('conversation.paused', {'bot_paused_at': '2026-10-30T22:20:59+00:00'});
      await server.until(() => c.messages.length == 1);
      server.dropChat = true;
      server.historyBody = {
        'messages': [
          row('user', 'hello', ref: 'u1', ts: '2026-10-30T22:20:30+00:00'),
          row('bot', 'staff here', ref: 's1', ts: '2026-10-30T22:21:10+00:00', sender: 'staff'),
        ],
        'bot_paused_at': '2026-10-30T22:20:59+00:00',
        'cart': null,
      };
      await c.send('hello');
      expect(shape(), ['hello', '[paused]', 'staff here']);
    });
  });

  group('live dedupe', () {
    test('msg_ref dedupes; a different msg_ref is a different message', () async {
      make('ar');
      await c.open();
      await server.until(() => server.live != null);
      final t0 = DateTime.now().toUtc();
      void push(String ref, int s) => server.pushLive('message.new', {
            'body_text': 'تمام',
            'sent_by': 'owner',
            'msg_ref': ref,
            'ts': t0.add(Duration(seconds: s)).toIso8601String(),
          });
      push('a', 0);
      await server.until(() => c.messages.length == 1);
      push('a', 40); // same msg_ref
      push('b', 60);
      await server.until(() => c.messages.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(c.messages.map((m) => m.msgRef).toList(), ['a', 'b']);
    });

    test('no msg_ref: same role+text within 15 s is a duplicate, a minute later it is not', () async {
      make('ar');
      await c.open();
      await server.until(() => server.live != null);
      final t0 = DateTime.now().toUtc();
      void push(int s) => server.pushLive('message.new',
          {'body_text': 'تمام', 'sent_by': 'owner', 'ts': t0.add(Duration(seconds: s)).toIso8601String()});
      push(0);
      await server.until(() => c.messages.length == 1);
      push(10);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(c.messages, hasLength(1));
      push(70);
      await server.until(() => c.messages.length == 2);
    });

    test('staff client_ref dedupes a live copy that has a different msg_ref', () async {
      make('ar');
      await c.open();
      await server.until(() => server.live != null);
      server
          .pushLive('message.new', {'body_text': 'أهلين', 'sent_by': 'owner', 'msg_ref': 'm1', 'client_ref': 'dash-1'});
      await server.until(() => c.messages.length == 1);
      server.pushLive(
          'message.new', {'body_text': 'أهلين!', 'sent_by': 'owner', 'msg_ref': 'm2', 'client_ref': 'dash-1'});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(c.messages, hasLength(1));
    });

    test('a bot reply is never deduped by our own client_message_id', () async {
      make('ar');
      await c.open();
      await server.until(() => server.live != null);
      late String cid;
      server.beforeChatReply = () async {
        cid = jsonDecode(server.bodies['/chat']!.last)['client_message_id'] as String;
      };
      server.chatReply = {'reply': 'تفضل', 'msg_ref': 'msg_1', 'action_data': {}};
      await c.send('x');
      server.pushLive('message.new', {'body_text': 'مختلف', 'msg_ref': 'other', 'client_ref': cid});
      await server.until(() => c.messages.where((m) => m.role == ChatRole.bot).length == 2);
    });

    test('a live resumed pill lands after what is already shown, even a staff bubble stamped "now"', () async {
      make('ar');
      await c.open();
      await server.until(() => server.live != null);
      final future = DateTime.now().toUtc().add(const Duration(seconds: 5));
      server.pushLive(
          'message.new', {'body_text': 'staff', 'sent_by': 'owner', 'msg_ref': 'm1', 'ts': future.toIso8601String()});
      await server.until(() => c.messages.isNotEmpty);
      server.pushLive('conversation.resumed', {});
      await server.until(() => c.messages.length == 2);
      expect(c.messages.last.role, ChatRole.system);
    });
  });

  group('intents', () {
    test('an unhandled OpenUrl / checkout intent surfaces UnhandledIntent', () async {
      make('ar', onIntent: (_) => false);
      c.openUrl('https://shop.example/p');
      c.checkout('https://shop.example/checkout');
      await Future<void>.delayed(Duration.zero);
      final errs = events.whereType<ErrorEvent>().map((e) => e.error).whereType<UnhandledIntent>().toList();
      expect(errs.map((e) => e.intent.runtimeType).toList(), [OpenUrlIntent, CheckoutIntent]);
    });

    test('a handled intent is silent; an unsafe URL never reaches the host', () async {
      final got = <SunonoIntent>[];
      make('ar', onIntent: (i) {
        got.add(i);
        return true;
      });
      c.openUrl('https://shop.example/p');
      c.openUrl('http://shop.example/p');
      c.openUrl('https://shop.example/${String.fromCharCode(0x202E)}p');
      await Future<void>.delayed(Duration.zero);
      expect(got.map((i) => (i as OpenUrlIntent).url), ['https://shop.example/p']);
      expect(events.whereType<ErrorEvent>(), isEmpty);
    });

    test('openProduct unhandled stays a silent fallback (the UI asks the assistant)', () async {
      make('ar', onIntent: (_) => false);
      final handled = c.openProduct(ProductCard.fromJson({'public_id': 'p1', 'title_ar': 'x'}));
      expect(handled, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<ErrorEvent>(), isEmpty);
    });
  });

  group('widgets', () {
    testWidgets('welcome is a permanent first bubble: config text, no cross-language fallback, then default',
        (tester) async {
      server.config = {'enabled': true, 'welcome_message_ar': 'أهلين فينا'};
      await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
      await settle(tester);
      expect(find.text('أهلين فينا'), findsOneWidget);
      await sendFromUi(tester, 'مرحبا');
      expect(find.text('أهلين فينا'), findsOneWidget, reason: 'stays above the thread');
      expect(c.messages.where((m) => m.id == 'welcome'), isEmpty, reason: 'not a stored message');
      await finish(tester);
    });

    testWidgets('English with only an Arabic welcome configured shows the English default', (tester) async {
      server.config = {'enabled': true, 'welcome_message_ar': 'أهلين فينا'};
      await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
      await settle(tester);
      expect(find.text('Hi! How can I help you today?'), findsOneWidget);
      expect(find.text('أهلين فينا'), findsNothing);
      await finish(tester);
    });

    testWidgets('Arabic default welcome', (tester) async {
      await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
      await settle(tester);
      expect(find.text('أهلاً بك! كيف يمكنني مساعدتك اليوم؟'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('welcome does not count for history dedupe or recovery', (tester) async {
      server.historyRows = [row('bot', 'أهلاً بك! كيف يمكنني مساعدتك اليوم؟', ref: 'h1')];
      await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
      await settle(tester);
      expect(c.messages, hasLength(1));
      expect(find.text('أهلاً بك! كيف يمكنني مساعدتك اليوم؟'), findsNWidgets(2));
      await finish(tester);
    });

    testWidgets('default quick replies on an empty thread; "Talk to our team" sends the escalate phrase',
        (tester) async {
      await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
      await settle(tester);
      expect(find.text('شو العروض؟'), findsOneWidget);
      expect(find.byIcon(Icons.local_offer_outlined), findsOneWidget);
      expect(find.byIcon(Icons.headset_mic_outlined), findsOneWidget);
      await tester.tap(find.text('احكي مع الفريق'));
      await settle(tester);
      final body = jsonDecode(server.bodies['/chat']!.last) as Map<String, dynamic>;
      expect(body['message'], 'بدي أحكي مع حدا من الفريق');
      expect(body['synthetic'], true);
      await finish(tester);
    });

    testWidgets('quick replies sit under the latest bot reply only; English copy', (tester) async {
      server.historyRows = [
        row('bot', 'first', ref: 'b1'),
        row('user', 'q', ref: 'u1'),
        row('bot', 'second', ref: 'b2'),
      ];
      await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
      await settle(tester);
      expect(find.text('Browse offers'), findsOneWidget);
      expect(find.text('Talk to our team'), findsOneWidget);
      final chip = tester.getTopLeft(find.text('Browse offers')).dy;
      expect(chip, greaterThan(tester.getBottomLeft(find.text('second')).dy), reason: 'under the last reply');
      await tester.tap(find.text('Browse offers'));
      await settle(tester);
      final body = jsonDecode(server.bodies['/chat']!.last) as Map<String, dynamic>;
      expect(body['message'], 'What offers do you have?');
      expect(body['synthetic'], true);
      await finish(tester);

      // The shopper spoke last: no chips.
      server.historyRows = [row('bot', 'first', ref: 'b1'), row('user', 'q', ref: 'u1')];
      await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
      await settle(tester);
      expect(find.text('Browse offers'), findsNothing);
      await finish(tester);
    });

    testWidgets('quick replies hide while a turn runs and while paused', (tester) async {
      final hold = Completer<void>();
      server.beforeChatReply = () => hold.future;
      await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
      await settle(tester);
      await tester.tap(find.text('Browse offers'));
      await settle(tester);
      expect(c.busy, isTrue);
      expect(find.text('Browse offers'), findsNothing);
      hold.complete();
      await settle(tester);
      expect(find.text('Browse offers'), findsOneWidget, reason: 'back under the reply');
      await finish(tester);

      server.historyBody = {
        'messages': [row('bot', 'hi', ref: 'b1', ts: '2026-10-30T22:00:00+00:00')],
        'bot_paused_at': '2026-10-30T22:05:00+00:00',
        'cart': null,
      };
      await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
      await settle(tester);
      expect(c.paused, isTrue);
      expect(find.text('Browse offers'), findsNothing);
      await finish(tester);
    });

    testWidgets('starterPrompts stay on the empty thread only (0.2); quickReplies wins, caps at 3, can run an action',
        (tester) async {
      await tester.pumpWidget(app(SunonoChatView(
          controller: make('en', starters: {
        'en': ['Gift ideas'],
        'ar': ['أفكار هدايا']
      }))));
      await settle(tester);
      expect(find.text('Gift ideas'), findsOneWidget);
      expect(find.text('Browse offers'), findsNothing);
      await tester.tap(find.text('Gift ideas'));
      await settle(tester);
      expect((jsonDecode(server.bodies['/chat']!.last) as Map)['message'], 'Gift ideas');
      expect(find.widgetWithText(InkWell, 'Gift ideas'), findsNothing, reason: 'starters never sit under a reply');
      expect(find.text('Browse offers'), findsOneWidget, reason: 'the defaults do');
      expect(find.text('Talk to our team'), findsOneWidget);
      await finish(tester);

      var opened = 0;
      await tester.pumpWidget(app(SunonoChatView(
          controller: make('en', starters: {
        'en': ['Gift ideas']
      }, quick: {
        'en': [
          SunonoQuickReply('Offers page', Icons.local_offer_outlined, 'unused', action: () => opened++),
          const SunonoQuickReply('Two', null, 'two'),
          const SunonoQuickReply('Three', null, 'three'),
          const SunonoQuickReply('Four', null, 'four'),
        ],
        'ar': const [],
      }))));
      await settle(tester);
      expect(find.text('Gift ideas'), findsNothing);
      expect(find.text('Three'), findsOneWidget);
      expect(find.text('Four'), findsNothing, reason: 'at most 3');
      final sends = server.bodies['/chat']!.length;
      await tester.tap(find.text('Offers page'));
      await settle(tester);
      expect(opened, 1);
      expect(server.bodies['/chat'], hasLength(sends), reason: 'the action runs instead of a send');
      c.lang = 'ar';
      await settle(tester);
      expect(find.text('احكي مع الفريق'), findsNothing, reason: '[] shows none');
      await finish(tester);
    });

    testWidgets('chips are 48 dp tall with a button node', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
      await settle(tester);
      for (final label in ['Browse offers', 'Talk to our team']) {
        final chip = find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first;
        expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
        // ignore: deprecated_member_use
        expect(tester.getSemantics(find.text(label)), containsSemantics(isButton: true, hasTapAction: true));
      }
      semantics.dispose();
      await finish(tester);
    });

    testWidgets('timestamps: HH:MM under user and bot bubbles, Latin digits, none on the welcome', (tester) async {
      server.historyRows = [
        row('user', 'سؤال', ref: 'u1', ts: DateTime(2026, 10, 30, 9, 5).toUtc().toIso8601String()),
        row('bot', 'جواب', ref: 'b1', ts: DateTime(2026, 10, 30, 21, 40).toUtc().toIso8601String()),
      ];
      await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
      await settle(tester);
      expect(find.text('09:05'), findsOneWidget);
      expect(find.text('21:40'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('staff label is «خدمة العملاء» / "Store team"; header default title', (tester) async {
      server.historyRows = [row('bot', 'أهلين', ref: 's1', sender: 'staff')];
      await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
      await settle(tester);
      expect(find.text('خدمة العملاء'), findsOneWidget);
      expect(find.text('مساعد'), findsOneWidget, reason: 'configured title wins');
      await finish(tester);

      server.config = {'enabled': true};
      await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
      await settle(tester);
      expect(find.text('Shop assistant'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Show more only on the last message overall, with products and has_more', (tester) async {
      final prods = [
        {'public_id': 'p1', 'title_ar': 'منتج', 'price_jod': 5, 'has_image': false},
      ];
      server.historyRows = [
        row('bot', 'نتائج', ref: 'b1', products: prods, more: true),
        row('bot', 'ردّ لاحق', ref: 'b2'),
      ];
      await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
      await settle(tester);
      expect(find.text('شوف أكثر'), findsNothing, reason: 'a later message exists');
      await finish(tester);

      server.historyRows = [row('bot', 'نتائج', ref: 'b1', products: prods, more: true)];
      await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
      await settle(tester);
      expect(find.text('شوف أكثر'), findsOneWidget);
      await tester.tap(find.text('شوف أكثر'));
      await settle(tester);
      final body = jsonDecode(server.bodies['/chat']!.last) as Map<String, dynamic>;
      expect(body['message'], 'ورجيني كمان');
      expect(body['synthetic'], true);
      await finish(tester);

      // has_more without products: no chip.
      server.historyRows = [row('bot', 'نتائج', ref: 'b1', more: true)];
      await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
      await settle(tester);
      expect(find.text('شوف أكثر'), findsNothing);
      await finish(tester);
    });

    testWidgets('a pause pill is not a message: it also hides an older Show more', (tester) async {
      final prods = [
        {'public_id': 'p1', 'title_ar': 'منتج', 'price_jod': 5, 'has_image': false},
      ];
      server.historyBody = {
        'messages': [row('bot', 'نتائج', ref: 'b1', products: prods, more: true, ts: '2026-10-30T22:00:00+00:00')],
        'bot_paused_at': '2026-10-30T22:05:00+00:00',
        'cart': null,
      };
      await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
      await settle(tester);
      expect(find.text('شوف أكثر'), findsNothing);
      await finish(tester);
    });

    testWidgets('links: https is tappable, http / bidi-override / IDN hosts stay plain text', (tester) async {
      final got = <SunonoIntent>[];
      server.historyRows = [
        row('bot',
            'ok https://shop.example/a؟ bad http://shop.example/b worse https://shop.example/${String.fromCharCode(0x202E)}c و https://shöp.example/d',
            ref: 'b1'),
      ];
      await tester.pumpWidget(app(SunonoChatView(
          controller: make('ar', onIntent: (i) {
        got.add(i);
        return true;
      }))));
      await settle(tester);
      expect(find.text('https://shop.example/a'), findsOneWidget);
      expect(find.text('http://shop.example/b', findRichText: true), findsNothing);
      await tester.tap(find.text('https://shop.example/a'));
      expect((got.single as OpenUrlIntent).url, 'https://shop.example/a');
      final rich = tester.widgetList<RichText>(find.byType(RichText)).map((r) => r.text.toPlainText()).join('|');
      expect(rich, contains('http://shop.example/b'));
      expect(rich, contains('https://shöp.example/d'));
      await finish(tester);
    });

    testWidgets('a trailing RLM / punctuation after a link keeps it tappable; userinfo links are plain',
        (tester) async {
      final got = <SunonoIntent>[];
      final rlm = String.fromCharCode(0x200F);
      server.historyRows = [
        row('bot', 'شوف https://shop.example/p$rlm و https://shop.example@evil.com/x', ref: 'b1'),
      ];
      await tester.pumpWidget(app(SunonoChatView(
          controller: make('ar', onIntent: (i) {
        got.add(i);
        return true;
      }))));
      await settle(tester);
      await tester.tap(find.text('https://shop.example/p'));
      expect((got.single as OpenUrlIntent).url, 'https://shop.example/p');
      expect(find.text('https://shop.example@evil.com/x'), findsNothing, reason: 'not a link widget');
      await finish(tester);
    });

    testWidgets('lightbox: tap a bubble image, InteractiveViewer, close label, errorBuilder', (tester) async {
      await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
      await settle(tester);
      await sendFromUi(tester, 'photo');
      c.messages.last.imageUrl = 'https://cdn.invalid/x.png';
      c.messages.last.text = 'look';
      c.notifyListeners();
      await settle(tester); // the (blocked) fetch fails -> errorBuilder gives the image a size
      final f = find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'View photo');
      await tester.tap(f);
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget,
          reason: 'the lightbox errorBuilder (the covered bubble is offstage)');
      expect(find.byTooltip('Close'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsNothing);
      await finish(tester);
    }, skip: false);

    testWidgets('320 px at 200% text with timestamps, quick replies and welcome lays out', (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(SunonoChatView(controller: make('ar')), textScale: 2));
      await settle(tester);
      expect(tester.takeException(), isNull);
      // An empty thread starts at the top (welcome card): the quick replies are below it.
      await tester.dragUntilVisible(find.text('احكي مع الفريق'), find.byType(ListView), const Offset(0, -200));
      expect(find.text('احكي مع الفريق'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  });
}
