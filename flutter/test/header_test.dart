import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/sunono.dart';

import 'fake_server.dart';

void main() {
  late FakeServer server;
  late SunonoChatController c;

  setUp(() => server = FakeServer());

  SunonoChatController make(String lang) => c = SunonoChatController(
        api: SunonoApi(
          shopKey: 'pk_test',
          apiBase: 'https://api.test/api',
          appOrigin: 'https://shop.example',
          clientFactory: () => MockClient.streaming(server.handle),
        ),
        storage: MemoryStorage(),
        lang: lang,
        onIntent: (_) => true,
      );

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

  testWidgets('back calls onBack; back and ⋮ are 48 dp', (tester) async {
    var backs = 0;
    await tester.pumpWidget(app(SunonoChatView(controller: make('en'), onBack: () => backs++)));
    await settle(tester);
    expect(find.byType(BackButtonIcon), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    expect(backs, 1);
    expect(tester.getSize(find.widgetWithIcon(IconButton, Icons.more_vert_rounded)), const Size(48, 48));
    expect(tester.getSize(find.ancestor(of: find.byType(BackButtonIcon), matching: find.byType(IconButton))),
        const Size(48, 48));
    await finish(tester);
  });

  testWidgets('no onBack and no onClose: no back button', (tester) async {
    await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
    await settle(tester);
    expect(find.byType(BackButtonIcon), findsNothing);
    await finish(tester);
  });

  testWidgets('RTL: the back arrow is on the right, the ⋮ on the left', (tester) async {
    await tester.pumpWidget(app(SunonoChatView(controller: make('ar'), onBack: () {})));
    await settle(tester);
    final back = tester.getCenter(find.byTooltip('رجوع'));
    final more = tester.getCenter(find.byTooltip('خيارات أكثر'));
    expect(back.dx, greaterThan(300));
    expect(more.dx, lessThan(100));
    await finish(tester);
  });

  testWidgets('⋮ lists the built-in item and host items; Talk to our team escalates', (tester) async {
    var help = 0;
    await tester.pumpWidget(app(SunonoChatView(
      controller: make('en'),
      menuItems: [SunonoMenuItem(label: 'Help center', icon: Icons.help_outline, onTap: () => help++)],
    )));
    await settle(tester);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    expect(find.text('Talk to our team'), findsOneWidget);
    expect(find.text('Help center'), findsOneWidget);
    await tester.tap(find.text('Help center'));
    await tester.pumpAndSettle();
    expect(help, 1);

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Talk to our team'));
    await settle(tester);
    final body = jsonDecode(server.bodies['/chat']!.last) as Map<String, dynamic>;
    expect(body['message'], "I'd like to talk to someone from your team");
    expect(body['synthetic'], true);
    await finish(tester);
  });

  testWidgets('status: active Arabic', (tester) async {
    await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
    await settle(tester);
    expect(find.text('متصل • جاهزين نساعدك'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('status: paused shows the team, and the menu drops Talk to our team', (tester) async {
    server.historyBody = {'messages': [], 'bot_paused_at': DateTime.now().toUtc().toIso8601String()};
    await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
    await settle(tester);
    expect(find.text('Store team is with you'), findsOneWidget);
    expect(find.text('Online • Here to help'), findsNothing);
    expect(find.byTooltip('More options'), findsNothing); // no host items: nothing to show
    await finish(tester);
  });

  testWidgets('status: disabled reads unavailable with a grey dot', (tester) async {
    server.config = {'enabled': false};
    await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
    await settle(tester);
    expect(find.text('غير متاح هلّق'), findsOneWidget);
    expect(find.text('متصل • جاهزين نساعدك'), findsNothing);
    expect(find.byTooltip('خيارات أكثر'), findsNothing);
    await finish(tester);
  });

  testWidgets('welcome card: default copy, host overrides per language', (tester) async {
    await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
    await settle(tester);
    expect(find.text('Hello, how can we help?'), findsOneWidget);
    expect(find.text('Ask about products, offers or your order.'), findsOneWidget);
    expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    await finish(tester);

    server = FakeServer();
    await tester.pumpWidget(app(SunonoChatView(
        controller: make('ar'), welcomeTitle: const {'ar': 'يا هلا'}, welcomeSubtitle: const {'en': 'unused'})));
    await settle(tester);
    expect(find.text('يا هلا'), findsOneWidget);
    expect(find.text('اسأل عن المنتجات، العروض أو طلبك.'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('200% text at 320 dp: no overflow, the long title ellipsizes', (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    const longTitle = 'A very long shop assistant name that cannot fit';
    server.config = {'enabled': true, 'header_title_en': longTitle};
    await tester.pumpWidget(app(
        SunonoChatView(controller: make('en'), onBack: () {}, menuItems: [SunonoMenuItem(label: 'Help', onTap: () {})]),
        textScale: 2));
    await settle(tester);
    expect(tester.takeException(), isNull);
    final title = tester.widget<Text>(find.text(longTitle));
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(tester.getSize(find.text(longTitle)).width, lessThan(320));
    // The card sits at the top of the thread: scroll up to it.
    await tester.drag(find.byType(ListView), const Offset(0, 2000));
    await tester.pump();
    expect(find.text('Hello, how can we help?'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
}
