import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/sunono.dart';
import 'package:sunono/src/ui/cards.dart';
import 'package:sunono/src/ui/theme.dart' show contrastRatio, onColor;

import 'fake_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // attach() follows the app lifecycle
  late FakeServer server;
  late SunonoChatController c;
  late List<SunonoEvent> events;

  SunonoChatController make({SunonoStorage? storage, String? lang, DateTime Function()? clock}) {
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
      clock: clock ?? DateTime.now,
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

    test('contrast: a dark brand on the dark scheme reads as text; fills keep the brand', () {
      final t = SunonoTheme.fromConfig(const ShopConfig(primaryColor: Color(0xFF57227D), colorScheme: 'dark'),
          fallback: const SunonoTheme());
      expect(t.primary, const Color(0xFF57227D), reason: 'fills keep the brand');
      expect(contrastRatio(t.primary, t.surface), lessThan(4.5), reason: 'the case being fixed');
      expect(contrastRatio(t.primaryText, t.surface), greaterThanOrEqualTo(4.5));
      expect(contrastRatio(t.primaryText, t.background), greaterThanOrEqualTo(4.5));
      expect(contrastRatio(t.onPrimary, t.primary), greaterThanOrEqualTo(4.5));
    });

    test('contrast: a light brand color gets dark text on its fills and darker text on white', () {
      final t =
          SunonoTheme.fromConfig(const ShopConfig(primaryColor: Color(0xFFFFE066)), fallback: const SunonoTheme());
      expect(t.onPrimary.computeLuminance(), lessThan(0.1));
      expect(contrastRatio(t.onPrimary, t.primary), greaterThanOrEqualTo(4.5));
      expect(contrastRatio(t.primaryText, t.surface), greaterThanOrEqualTo(4.5));
    });

    test('light scheme: primaryText reads on both the white surface and the #F7F7FB background', () {
      for (final hex in [0xFF8A7CFF, 0xFF57227D, 0xFFFFE066, 0xFF00C2FF, 0xFF6C4BFF, 0xFF9E9E9E]) {
        final t = SunonoTheme.fromConfig(ShopConfig(primaryColor: Color(hex)), fallback: const SunonoTheme());
        expect(t.background, const Color(0xFFF7F7FB));
        expect(contrastRatio(t.primaryText, t.surface), greaterThanOrEqualTo(4.5), reason: hex.toRadixString(16));
        expect(contrastRatio(t.primaryText, t.background), greaterThanOrEqualTo(4.5), reason: hex.toRadixString(16));
      }
    });

    test('copyWith(primary:) recomputes onPrimary and primaryText unless passed', () {
      const base = SunonoTheme();
      final t = base.copyWith(primary: const Color(0xFFFFE066));
      expect(t.onPrimary.computeLuminance(), lessThan(0.1));
      expect(contrastRatio(t.onPrimary, t.primary), greaterThanOrEqualTo(4.5));
      expect(contrastRatio(t.primaryText, t.surface), greaterThanOrEqualTo(4.5));
      expect(contrastRatio(t.primaryText, t.background), greaterThanOrEqualTo(4.5));
      final kept = base.copyWith(primary: const Color(0xFFFFE066), onPrimary: Colors.red, primaryText: Colors.blue);
      expect(kept.onPrimary, Colors.red);
      expect(kept.primaryText, Colors.blue);
      final same = t.copyWith(accent: Colors.green);
      expect(same.onPrimary, t.onPrimary);
      expect(same.primaryText, t.primaryText);
    });

    test('badge fills (accent, muted, danger) get readable text, light and dark; staff label reads', () {
      final themes = [
        const SunonoTheme(),
        SunonoTheme.fromConfig(const ShopConfig(colorScheme: 'dark'), fallback: const SunonoTheme()),
      ];
      for (final t in themes) {
        for (final fill in [t.accent, t.muted, t.danger]) {
          expect(contrastRatio(onColor(fill), fill), greaterThanOrEqualTo(4.5), reason: '$fill');
        }
        expect(contrastRatio(t.accentText, t.surface), greaterThanOrEqualTo(4.5));
      }
      expect(const SunonoTheme().onAccent.computeLuminance(), lessThan(0.1), reason: 'dark text on #00C2FF');
    });

    testWidgets('the Sale badge on the default accent uses dark text', (tester) async {
      final p = ProductCard.fromJson({
        'public_id': 'p',
        'title_en': 'Coffee',
        'price_jod': 10,
        'discount_jod': 8,
        'price_from': 8,
        'on_sale': true,
        'has_image': false,
      });
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: ProductTile(product: p, theme: const SunonoTheme(), lang: 'en', onOpen: () {}))));
      expect(tester.widget<Text>(find.text('Sale')).style!.color, const SunonoTheme().onAccent);
    });

    test('fromMaterial: onPrimary is the scheme onPrimary', () {
      final m = ThemeData(colorSchemeSeed: const Color(0xFFFFE066));
      expect(SunonoTheme.fromMaterial(m).onPrimary, m.colorScheme.onPrimary);
    });

    testWidgets('the user bubble and the send button use onPrimary', (tester) async {
      server.config = {'enabled': true, 'primary_color': '#FFE066'};
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true, size: Size(400, 800)),
              child: Scaffold(body: SunonoChatView(controller: c)))));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      final icon = tester.widget<Icon>(find.byIcon(Icons.arrow_upward_rounded));
      expect(icon.color!.computeLuminance(), lessThan(0.1), reason: 'dark on a light brand');
      await tester.pumpWidget(const SizedBox());
      c.suspend();
    });
  });

  group('min SDK version', () {
    final old = {
      'enabled': true,
      'app': {'min_sdk_version': '99.0.0'},
    };

    test('assistant_update_required once, however often config is fetched', () async {
      server.config = old;
      await c.open();
      expect(c.updateRequired, isTrue);
      await c.reset(); // open → config again
      expect(server.count('/widget/config'), 2);
      expect(analytics().where((n) => n == 'assistant_update_required'), hasLength(1));
    });

    test('an unsupported SDK binds no cart, never goes live, counts nothing, sends nothing', () async {
      var now = DateTime(2026, 1, 1);
      server.config = old;
      c.dispose();
      c = make(clock: () => now);
      c.attach();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      c.resume();
      await c.send('hi');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.count('/chat/subscribe-ticket'), 0);
      expect(server.count('/chat/history'), 0);
      expect(server.count('/chat'), 0);
      expect(c.unread.value, 0);

      server.config = {'enabled': true}; // the shop lowered its minimum
      now = now.add(const Duration(seconds: 61));
      c.resume();
      await server.until(() => server.live != null);
      expect(c.updateRequired, isFalse);
    });
  });

  group('app lifecycle', () {
    tearDown(() => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed));

    for (final state in [AppLifecycleState.hidden, AppLifecycleState.paused]) {
      test('attach while the app is ${state.name}: no live until it comes back', () async {
        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(state);
        c.attach();
        await server.until(() => c.status == ChatStatus.ready);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(server.count('/chat/subscribe-ticket'), 0);
        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await server.until(() => server.live != null);
      });
    }

    test('hidden stops the live connection', () async {
      c.attach();
      await server.until(() => server.live != null);
      c.didChangeAppLifecycleState(AppLifecycleState.hidden);
      server.pushLive('message.new', staff('s1'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.messages, isEmpty);
    });
  });

  group('secure storage fails', () {
    for (final (name, setup) in [
      ('read throws', (_FlakyStorage s) => s.failUserIdRead = true),
      ('read hangs', (_FlakyStorage s) => s.hangUserIdRead = true),
      ('write throws', (_FlakyStorage s) => s.failUserIdWrite = true),
    ]) {
      test('$name: chat still sends on an in-memory shopper, and it is reported', () async {
        final storage = _FlakyStorage();
        setup(storage);
        c.dispose();
        c = make(storage: storage);
        await c.open();
        await c.send('hi').timeout(const Duration(seconds: 15));
        expect(c.messages.last.text, server.chatReply['reply']);
        expect(c.userId, isNotNull);
        expect(events.whereType<ErrorEvent>().map((e) => '${e.error}'),
            anyElement(anyOf(contains('keychain'), contains('TimeoutException'))));
      }, timeout: const Timeout(Duration(seconds: 30)));
    }
  });

  group('reset forgets the device', () {
    const pendingKey = 'sunono.pending_forget.pk_test';

    test('forget goes out with the old shopper token; the new shopper differs', () async {
      await c.open();
      await server.until(() => server.live != null);
      final old = c.userId;
      await c.reset();
      await server.until(() => server.count('/chat/forget') == 1);
      final forget = server.requests.singleWhere((r) => r.url.path.endsWith('/chat/forget'));
      expect(forget.headers['Authorization'], 'Bearer tok1', reason: "the old shopper's token");
      expect(server.bodies['/chat/forget']!.single, '{}');
      await server.until(() => c.userId != null);
      expect(c.userId, isNot(old));
    });

    test('nothing of the old shopper restarts while its forget is held', () async {
      final storage = MemoryStorage();
      c.dispose();
      c = make(storage: storage);
      await c.open();
      await server.until(() => server.live != null);
      final old = c.userId;
      final gate = Completer<void>();
      server.beforeForget = () => gate.future;
      final mark = server.requests.length;
      final resetting = c.reset();
      c.didChangeAppLifecycleState(AppLifecycleState.resumed); // a resume races the reset
      unawaited(c.send('for the old thread'));
      await resetting; // never waits on the network forget
      await server.until(() => server.count('/chat/forget') == 1);
      c.didChangeAppLifecycleState(AppLifecycleState.resumed); // and one during the held forget
      await server.until(() => server.count('/chat/subscribe?') == 2); // the new shopper went live
      expect(await storage.read(pendingKey), old, reason: 'pending until the forget lands');
      gate.complete();
      for (var i = 0; i < 100 && await storage.read(pendingKey) != null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(await storage.read(pendingKey), isNull);

      final after = server.requests.skip(mark).toList();
      for (final r in after) {
        final auth = r.headers['Authorization'];
        if (r.url.path.endsWith('/chat/forget')) {
          expect(auth, 'Bearer tok1', reason: 'the forget is the old shopper');
        } else {
          expect(auth, isNot('Bearer tok1'), reason: '${r.url.path} must be the new shopper');
        }
      }
      expect(after.where((r) => r.url.path.endsWith('/chat')), isEmpty, reason: 'the send was dropped');
      final inits = server.bodies['/shops/init']!.skip(1).map((b) => jsonDecode(b)['user_id']);
      expect(inits, isNot(contains(old)), reason: 'the new session never re-inits the old id');
    });

    test('an expired old token: the forget re-inits as the old shopper, never the new one', () async {
      await c.open();
      await server.until(() => server.live != null);
      final old = c.userId;
      server.failForgetTimes = 1;
      server.failForgetWith = 401;
      await c.reset();
      await server.until(() => server.count('/chat/forget') == 2);
      expect(server.requests.where((r) => r.url.path.endsWith('/chat/forget')).last.headers['Authorization'],
          isNot('Bearer tok1'));
      expect(server.bodies['/shops/init']!.where((b) => jsonDecode(b)['user_id'] == old), hasLength(2));
    });

    test('a failed forget is kept per shop and retried on the next open, then dropped', () async {
      final storage = MemoryStorage();
      c.dispose();
      c = make(storage: storage);
      await c.open();
      await server.until(() => server.live != null);
      final old = c.userId!;
      server.failForgetTimes = 1000;
      await c.reset();
      await server.until(() => server.count('/chat/forget') >= 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await storage.read(pendingKey), old);
      expect(await storage.read('sunono.pending_forget'), isNull, reason: 'keyed per shop');

      c.dispose();
      server.failForgetTimes = 0;
      final before = server.count('/chat/forget');
      c = make(storage: storage); // next cold start
      await c.open();
      await server.until(() => server.count('/chat/forget') == before + 1);
      for (var i = 0; i < 100 && await storage.read(pendingKey) != null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(await storage.read(pendingKey), isNull);
      expect(server.bodies['/shops/init']!.where((b) => jsonDecode(b)['user_id'] == old).length, greaterThan(1),
          reason: 'the retry re-inits as the old shopper');
    });

    test('a retry leaves a newer pending shopper in place', () async {
      final storage = MemoryStorage();
      await storage.write(pendingKey, '11111111-1111-4111-8111-111111111111');
      c.dispose();
      c = make(storage: storage);
      server.beforeForget = () async {
        await storage.write(pendingKey, '22222222-2222-4222-8222-222222222222'); // a reset meanwhile
      };
      await c.open();
      await server.until(() => server.count('/chat/forget') == 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await storage.read(pendingKey), '22222222-2222-4222-8222-222222222222');
    });

    test('a failing storage delete never brings the old shopper back', () async {
      final storage = _FlakyStorage();
      c.dispose();
      c = make(storage: storage);
      await c.open();
      await server.until(() => server.live != null);
      final old = c.userId;
      storage.failUserIdDelete = true;
      final mark = server.requests.length;
      await c.reset();
      await server.until(() => server.count('/chat/subscribe?') == 2);
      expect(c.userId, isNot(old));
      expect(await storage.read('sunono.user_id.pk_test'), c.userId, reason: 'the key was overwritten');
      await server.until(() => server.count('/chat/forget') == 1);
      final after = server.requests.skip(mark).toList();
      for (final r in after) {
        final auth = r.headers['Authorization'];
        if (r.url.path.endsWith('/chat/forget')) {
          expect(auth, 'Bearer tok1');
        } else {
          expect(auth, isNot('Bearer tok1'), reason: r.url.path);
        }
      }
      final inits = server.bodies['/shops/init']!.skip(1).map((b) => jsonDecode(b)['user_id']);
      expect(inits, isNot(contains(old)));
    });

    test('a hung storage delete: reset still resolves and a fresh shopper is used', () async {
      final storage = _FlakyStorage();
      c.dispose();
      c = make(storage: storage);
      await c.open();
      await server.until(() => server.live != null);
      final old = c.userId;
      storage.hangUserIdDelete = true;
      await c.reset().timeout(const Duration(seconds: 1), onTimeout: () => fail('reset waited on storage'));
      // The new session waits out the hung delete (storageTimeout), then mints afresh.
      await server.until(() => server.count('/chat/subscribe?') == 2, timeout: const Duration(seconds: 10));
      expect(c.userId, isNot(old));
      await server.until(() => server.count('/chat/forget') == 1);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('two quick resets forget both shoppers', () async {
      await c.open();
      await server.until(() => server.live != null);
      final a = c.userId;
      await c.reset();
      await server.until(() => c.userId != null && c.userId != a);
      final b = c.userId;
      await c.reset();
      await server.until(() => server.count('/chat/forget') == 2);
      final tokens =
          server.requests.where((r) => r.url.path.endsWith('/chat/forget')).map((r) => r.headers['Authorization']);
      expect(tokens.toSet(), hasLength(2), reason: 'each with its own shopper token ($a, $b)');
    });

    test('reset while open() is still loading opens the new shopper', () async {
      final gate = Completer<void>();
      server.beforeConfig = () => gate.future;
      final opening = c.open();
      await server.until(() => server.count('/widget/config') == 1);
      final resetting = c.reset();
      gate.complete();
      await Future.wait([opening, resetting]);
      await server.until(() => c.status == ChatStatus.ready);
    });

    test('reset while disabled checks the shop again', () async {
      server.config = {'enabled': false};
      await c.open();
      expect(c.status, ChatStatus.disabled);
      server.config = {'enabled': true};
      await c.reset();
      await server.until(() => c.status == ChatStatus.ready);
    });

    test('a resume while a reset waits on storage opens the new shopper at once', () async {
      final storage = _FlakyStorage();
      c.dispose();
      c = make(storage: storage);
      c.attach();
      await server.until(() => server.live != null);
      storage.hangPendingWrite = true;
      unawaited(c.reset()); // waits up to storageTimeout before re-opening
      expect(c.status, ChatStatus.idle);
      c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await server.until(() => c.status == ChatStatus.ready, timeout: const Duration(seconds: 1));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a controller never used sends no forget', () async {
      await c.reset();
      await Future<void>.delayed(const Duration(milliseconds: 20));
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

/// Storage whose delete of the shopper id fails or never completes.
class _FlakyStorage extends MemoryStorage {
  bool failUserIdDelete = false;
  bool hangUserIdDelete = false;
  bool failUserIdRead = false;
  bool hangUserIdRead = false;
  bool failUserIdWrite = false;
  bool hangPendingWrite = false;

  @override
  Future<String?> read(String key) {
    if (key.startsWith('sunono.user_id.')) {
      if (failUserIdRead) return Future.error(StateError('keychain locked'));
      if (hangUserIdRead) return Completer<String?>().future;
    }
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) {
    if (key.startsWith('sunono.user_id.') && failUserIdWrite) return Future.error(StateError('keychain locked'));
    if (key.startsWith('sunono.pending_forget.') && hangPendingWrite) return Completer<void>().future;
    return super.write(key, value);
  }

  @override
  Future<void> delete(String key) {
    if (key.startsWith('sunono.user_id.')) {
      if (failUserIdDelete) return Future.error(StateError('keychain locked'));
      if (hangUserIdDelete) return Completer<void>().future;
    }
    return super.delete(key);
  }
}
