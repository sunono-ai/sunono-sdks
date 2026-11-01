import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/sunono.dart';
import 'package:sunono/src/ui/cards.dart';

import 'fake_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // attach() follows the app lifecycle
  late FakeServer server;
  late SunonoChatController c;
  late List<SunonoEvent> events;

  SunonoChatController make({SunonoStorage? storage, String? lang, Duration? forgetTimeout}) {
    final ctl = SunonoChatController(
      api: SunonoApi(
        shopKey: 'pk_test',
        apiBase: 'https://api.test/api',
        appOrigin: 'https://shop.example',
        clientFactory: () => MockClient.streaming(server.handle),
      ),
      storage: storage ?? MemoryStorage(),
      lang: lang,
      recoveryChecks: const [Duration(milliseconds: 5)],
      forgetTimeout: forgetTimeout ?? const Duration(seconds: 3),
    );
    ctl.events.listen(events.add);
    return ctl;
  }

  setUp(() {
    server = FakeServer();
    events = [];
    c = make();
  });

  tearDown(() {
    c.dispose();
    server.close();
  });

  Map<String, dynamic> staff(String ref) => {'body_text': 'أهلين', 'sent_by': 'owner', 'msg_ref': ref};

  Iterable<String> analytics() => events.whereType<AnalyticsEvent>().map((e) => e.name);

  group('host signals', () {
    test('cartCount follows a turn cart and a live cart update', () async {
      final counts = <int>[];
      c.cartCount.addListener(() => counts.add(c.cartCount.value));
      await c.open();
      await server.until(() => server.live != null);
      server.chatReply = {
        'reply': 'ضفتها',
        'action_data': {
          'cart': {
            'items': [
              {'product_id': 'p', 'qty': 2},
            ],
          },
        },
      };
      await c.send('ضيف 2');
      expect(c.cartCount.value, 2);
      server.pushLive('cart.updated', {
        'cart': {
          'items': [
            {'product_id': 'p', 'qty': 5},
          ],
        },
      });
      await server.until(() => c.cartCount.value == 5);
      expect(counts, [2, 5]);
    });

    test('unread counts bot and staff messages while no view is visible; a visible view clears it', () async {
      final view = Object();
      c.attach();
      await server.until(() => server.live != null);
      server.pushLive('message.new', staff('s1'));
      server.pushLive('message.new', {'body_text': 'bot', 'msg_ref': 'b1'});
      await server.until(() => c.unread.value == 2);
      c.setVisible(view, true);
      expect(c.unread.value, 0);
      server.pushLive('message.new', staff('s2'));
      await server.until(() => c.messages.length == 3);
      expect(c.unread.value, 0, reason: 'seen while visible');
      c.setVisible(view, false); // e.g. the shopper switched tabs
      server.pushLive('message.new', staff('s3'));
      await server.until(() => c.unread.value == 1);
    });

    test('a reply whose live copy landed first counts once', () async {
      await c.open();
      await server.until(() => server.live != null);
      server.beforeChatReply = () async {
        server.pushLive('message.new', {'body_text': 'تمام', 'msg_ref': 'msg_ok'});
        await server.until(() => c.messages.any((m) => m.msgRef == 'msg_ok'));
      };
      await c.send('hi');
      expect(c.messages.where((m) => m.msgRef == 'msg_ok'), hasLength(1));
      expect(c.unread.value, 1);
    });

    test('detach with no views keeps live; background stops it, foreground brings it back', () async {
      c.attach();
      await server.until(() => server.live != null);
      c.detach(Object()); // the only view went away
      server.pushLive('message.new', staff('s1'));
      await server.until(() => c.unread.value == 1, timeout: const Duration(seconds: 1));

      c.didChangeAppLifecycleState(AppLifecycleState.paused);
      server.pushLive('message.new', staff('s2')); // the live connection stopped: never processed
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.messages.map((m) => m.msgRef), ['s1']);
      await c.reset(); // reopens, but stays offline while backgrounded
      expect(server.count('/chat/subscribe?'), 1);

      c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await server.until(() => server.count('/chat/subscribe?') == 2);
    });

    test('assistant_opened on every attach', () async {
      c.attach();
      c.attach(); // a sheet over the tab
      await server.until(() => server.live != null);
      expect(analytics().where((n) => n == 'assistant_opened'), hasLength(2));
    });
  });

  group('language', () {
    test('no locale: the shop default_language once config loads', () async {
      server.config = {'enabled': true, 'default_language': 'en'};
      await c.open();
      expect(c.lang, 'en');
    });

    test('a host locale wins over the shop default', () async {
      server.config = {'enabled': true, 'default_language': 'en'};
      c.dispose();
      c = make(lang: 'ar');
      await c.open();
      expect(c.lang, 'ar');
    });
  });

  group('dashboard theme', () {
    test('primary_color and color_scheme parse; junk is ignored', () {
      final cfg = ShopConfig.fromJson({'primary_color': '#57227D', 'color_scheme': 'dark'});
      expect(cfg.primaryColor, const Color(0xFF57227D));
      expect(cfg.colorScheme, 'dark');
      final bad = ShopConfig.fromJson({'primary_color': 'red', 'color_scheme': 'neon'});
      expect(bad.primaryColor, isNull);
      expect(bad.colorScheme, isNull);
    });

    test('fromConfig: the shop color over the fallback, dark surfaces only for dark', () {
      const fallback = SunonoTheme(primary: Color(0xFF111111), surface: Color(0xFFFFFFFF));
      final light = SunonoTheme.fromConfig(const ShopConfig(primaryColor: Color(0xFF57227D)), fallback: fallback);
      expect(light.primary, const Color(0xFF57227D));
      expect(light.surface, fallback.surface);
      final dark = SunonoTheme.fromConfig(const ShopConfig(colorScheme: 'dark'), fallback: fallback);
      expect(dark.primary, fallback.primary);
      expect(dark.surface.computeLuminance(), lessThan(0.1));
      expect(dark.onSurface.computeLuminance(), greaterThan(0.7));
    });
  });

  test('min SDK version: assistant_update_required once, however often config is fetched', () async {
    server.config = {
      'enabled': true,
      'app': {'min_sdk_version': '99.0.0'},
    };
    await c.open();
    expect(c.updateRequired, isTrue);
    c.suspend();
    await c.reset(); // open → config again
    expect(server.count('/widget/config'), 2);
    expect(analytics().where((n) => n == 'assistant_update_required'), hasLength(1));
  });

  group('reset forgets the device', () {
    test('forget goes out with the old shopper token before anything is cleared', () async {
      await c.open();
      await server.until(() => server.live != null);
      final old = c.userId;
      await c.reset();
      expect(server.count('/chat/forget'), 1);
      final forget = server.requests.singleWhere((r) => r.url.path.endsWith('/chat/forget'));
      expect(forget.headers['Authorization'], 'Bearer tok1', reason: "the old shopper's token");
      expect(server.bodies['/chat/forget']!.single, '{}');
      await server.until(() => c.userId != null);
      expect(c.userId, isNot(old));
    });

    test('a failed forget is kept and retried on the next open, then dropped', () async {
      final storage = MemoryStorage();
      c.dispose();
      c = make(storage: storage);
      await c.open();
      await server.until(() => server.live != null);
      final old = c.userId!;
      server.failForgetTimes = 2; // the reset's forget and the reopen's retry
      await c.reset();
      await server.until(() => server.count('/chat/forget') == 2);
      expect(await storage.read('sunono.pending_forget'), old);

      c.dispose();
      c = make(storage: storage); // next cold start
      await c.open();
      await server.until(() => server.count('/chat/forget') == 3);
      for (var i = 0; i < 100 && await storage.read('sunono.pending_forget') != null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(await storage.read('sunono.pending_forget'), isNull);
      final asOld = server.bodies['/shops/init']!.where((b) => jsonDecode(b)['user_id'] == old);
      expect(asOld, hasLength(3), reason: 'first use, then one re-init per retry');
    });

    test('a hanging forget never holds reset past forgetTimeout', () async {
      final storage = MemoryStorage();
      c.dispose();
      c = make(storage: storage, forgetTimeout: const Duration(milliseconds: 50));
      await c.open();
      await server.until(() => server.live != null);
      final old = c.userId;
      final gate = Completer<void>();
      server.beforeForget = () => gate.future;
      final sw = Stopwatch()..start();
      await c.reset();
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      expect(await storage.read('sunono.pending_forget'), old);
      gate.complete();
    });

    test('a controller never used sends no forget', () async {
      await c.reset();
      expect(server.count('/chat/forget'), 0);
      expect(server.count('/shops/init'), 0);
    });
  });

  test('every token re-init (401) sends channel app', () async {
    await c.open();
    await server.until(() => server.live != null);
    server.failChatOnceWith = 401;
    await c.send('hi');
    final inits = server.bodies['/shops/init']!;
    expect(inits, hasLength(2));
    for (final b in inits) {
      expect(jsonDecode(b)['channel'], 'app');
    }
  });

  group('view', () {
    Widget app(Widget child) => MaterialApp(
          theme: ThemeData(colorSchemeSeed: const Color(0xFF57227D)),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true, size: Size(400, 800)),
            child: Scaffold(body: child),
          ),
        );

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<void> live(WidgetTester tester, String type, Map<String, dynamic> data) async {
      await tester.runAsync(() async {
        await server.until(() => server.live != null);
        server.pushLive(type, data);
      });
      await settle(tester);
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      c.suspend();
    }

    for (final (lang, text) in [
      ('ar', 'حدّث التطبيق عشان تستخدم المساعد'),
      ('en', 'Please update the app to use the assistant'),
    ]) {
      testWidgets('min version: the update notice ($lang)', (tester) async {
        server.config = {
          'enabled': true,
          'app': {'min_sdk_version': '99.0.0'},
        };
        c.lang = lang;
        await tester.pumpWidget(app(SunonoChatView(controller: c)));
        await settle(tester);
        expect(find.text(text), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        await finish(tester);
      });
    }

    testWidgets('a hidden tab (tickers off) counts unread; showing it clears the badge', (tester) async {
      var shown = false;
      late StateSetter setOuter;
      await tester.pumpWidget(app(StatefulBuilder(builder: (_, set) {
        setOuter = set;
        return TickerMode(enabled: shown, child: SunonoChatView(controller: c));
      })));
      await settle(tester);
      await live(tester, 'message.new', staff('s1'));
      expect(c.unread.value, 1);
      setOuter(() => shown = true);
      await settle(tester);
      expect(c.unread.value, 0);
      await live(tester, 'message.new', staff('s2'));
      expect(c.unread.value, 0);
      await finish(tester);
    });

    testWidgets('a route pushed over the chat hides it until popped', (tester) async {
      await tester.pumpWidget(app(SunonoChatView(controller: c)));
      await settle(tester);
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const Scaffold())));
      await settle(tester);
      await live(tester, 'message.new', staff('s1'));
      expect(c.unread.value, 1);
      nav.pop();
      await settle(tester);
      expect(c.unread.value, 0);
      await finish(tester);
    });

    testWidgets('a new message on screen is announced politely', (tester) async {
      final said = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility,
          (m) async {
        said.add(m);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility, null));
      await tester.pumpWidget(app(SunonoChatView(controller: c)));
      await settle(tester);
      await live(tester, 'message.new', staff('s1'));
      final announce = said.whereType<Map>().where((m) => m['type'] == 'announce').single;
      expect((announce['data'] as Map)['message'], 'أهلين');
      expect((announce['data'] as Map)['assertiveness'] ?? 0, 0, reason: 'polite');
      await finish(tester);
    });

    testWidgets('the composer autofocuses only when asked', (tester) async {
      await tester.pumpWidget(app(SunonoChatView(controller: c)));
      await settle(tester);
      expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(SunonoChatView(controller: c, autofocus: true)));
      await settle(tester);
      expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isTrue);
      await finish(tester);
    });

    testWidgets('header shows the shop avatar, with the orb as its fallback', (tester) async {
      server.config = {'enabled': true, 'avatar_url': 'https://cdn.test/a.png'};
      await tester.pumpWidget(app(SunonoChatView(controller: c)));
      await settle(tester);
      String? url(ImageProvider p) => p is ResizeImage ? url(p.imageProvider) : (p as NetworkImage).url;
      final avatar =
          tester.widget<Image>(find.byWidgetPredicate((w) => w is Image && url(w.image) == 'https://cdn.test/a.png'));
      expect(avatar.excludeFromSemantics, isTrue);
      await finish(tester);
    });

    testWidgets('a failed send is a live region', (tester) async {
      server.dropChat = true;
      await tester.pumpWidget(app(SunonoChatView(controller: c)));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await settle(tester);
      final region = find.ancestor(of: find.text('ما وصلت الرسالة'), matching: find.byType(Semantics));
      expect(tester.widgetList<Semantics>(region).any((s) => s.properties.liveRegion == true), isTrue);
      await finish(tester);
    });

    testWidgets('a card image is labelled with the product title', (tester) async {
      final p = ProductCard.fromJson({
        'public_id': 'p1',
        'title_en': 'Dates',
        'price_jod': 3,
        'has_image': true,
        'img_urls': ['https://cdn.test/d.jpg'],
      });
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: ProductTile(product: p, theme: const SunonoTheme(), lang: 'en', onOpen: () {}))));
      expect(tester.widget<Image>(find.byType(Image)).semanticLabel, 'Dates');
    });
  });
}
