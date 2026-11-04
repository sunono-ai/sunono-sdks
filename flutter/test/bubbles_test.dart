import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/src/core/format.dart';
import 'package:sunono/src/ui/header.dart';
import 'package:sunono/sunono.dart';

import 'fake_server.dart';

Map<String, dynamic> row(String role, String text, {required String ref, DateTime? at}) => {
      'role': role == 'user' ? 'user' : 'bot',
      'sender': role,
      'text': text,
      'msg_ref': ref,
      'ts': (at ?? DateTime.now()).toUtc().toIso8601String(),
      'products': <Object>[],
      'has_more': false,
    };

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
        recoveryChecks: const [Duration(milliseconds: 5)],
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

  List<String> mockClipboard(WidgetTester tester) {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    return copied;
  }

  test('formatDayLabel: today / yesterday / day + month, Latin digits, يونيو not حزيران', () {
    final now = DateTime(2026, 6, 15, 0, 30);
    final cases = {
      (DateTime(2026, 6, 15, 23, 59), 'ar'): 'اليوم',
      (DateTime(2026, 6, 15, 0, 0), 'en'): 'Today',
      (DateTime(2026, 6, 14, 23, 59), 'ar'): 'مبارح',
      (DateTime(2026, 6, 14, 0, 1), 'en'): 'Yesterday',
      (DateTime(2026, 6, 13, 12), 'ar'): '13 يونيو',
      (DateTime(2026, 6, 13, 12), 'en'): '13 June',
      (DateTime(2026, 1, 4), 'ar'): '4 يناير',
      (DateTime(2026, 12, 31), 'en'): '31 December',
      (DateTime(2025, 11, 4), 'ar'): '4 نوفمبر 2025',
    };
    cases.forEach((k, want) => expect(formatDayLabel(k.$1, k.$2, now), want, reason: '$k'));
    // Across a DST change the calendar day still counts, not 24 h blocks.
    expect(formatDayLabel(DateTime(2026, 3, 28, 23), 'en', DateTime(2026, 3, 29, 23)), 'Yesterday');
  });

  testWidgets('date pill: once for a single-day thread, again on a day change', (tester) async {
    final today = DateTime.now();
    server.historyRows = [
      row('user', 'سؤال', ref: 'u1', at: today),
      row('bot', 'جواب', ref: 'b1', at: today),
    ];
    await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
    await settle(tester);
    expect(find.text('اليوم'), findsOneWidget);
    await finish(tester);

    server = FakeServer();
    final yesterday = today.subtract(const Duration(days: 1));
    server.historyRows = [
      row('user', 'old', ref: 'u1', at: yesterday),
      row('bot', 'old reply', ref: 'b1', at: yesterday),
      row('user', 'new', ref: 'u2', at: today),
    ];
    await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
    await settle(tester);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    // The day's pill sits above its first message.
    expect(tester.getTopLeft(find.text('Today')).dy, lessThan(tester.getTopLeft(find.text('new')).dy));
    expect(tester.getTopLeft(find.text('Today')).dy, greaterThan(tester.getTopLeft(find.text('old reply')).dy));
    await finish(tester);
  });

  testWidgets('the avatar sits only beside the last bubble of a bot group, on the start side', (tester) async {
    server.historyRows = [
      row('bot', 'b1', ref: 'b1'),
      row('bot', 'b2', ref: 'b2'),
      row('user', 'u1', ref: 'u1'),
      row('staff', 'b3', ref: 'b3'),
    ];
    await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
    await settle(tester);
    Finder avatarBeside(String text) => find.descendant(
        of: find.ancestor(
            of: find.text(text), matching: find.byWidgetPredicate((w) => '${w.runtimeType}' == '_MessageItem')),
        matching: find.byType(ShopAvatar));
    final small = find.byWidgetPredicate((w) => w is ShopAvatar && w.size == 32);
    expect(small, findsNWidgets(2));
    expect(avatarBeside('b1'), findsNothing);
    expect(avatarBeside('b2'), findsOneWidget);
    expect(avatarBeside('u1'), findsNothing);
    expect(avatarBeside('b3'), findsOneWidget);
    // RTL: start = right of the bubble.
    expect(tester.getCenter(avatarBeside('b2')).dx, greaterThan(tester.getCenter(find.text('b2')).dx));
    await finish(tester);
  });

  testWidgets('ticks: a clock while the turn runs, ✓✓ once delivered and on restored rows, none when failed',
      (tester) async {
    server.historyRows = [row('user', 'restored', ref: 'u1')];
    final gate = Completer<void>();
    server.beforeChatReply = () => gate.future;
    await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
    await settle(tester);
    expect(find.byIcon(Icons.done_all), findsOneWidget, reason: 'restored history row');

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await settle(tester);
    expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
    expect(tester.widget<Icon>(find.byIcon(Icons.schedule_rounded)).semanticLabel, 'Sending');
    gate.complete();
    await settle(tester);
    expect(find.byIcon(Icons.schedule_rounded), findsNothing);
    expect(find.byIcon(Icons.done_all), findsNWidgets(2));

    server.beforeChatReply = null;
    server.dropChat = true;
    await tester.enterText(find.byType(TextField), 'lost');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await settle(tester);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byIcon(Icons.schedule_rounded), findsNothing);
    expect(find.byIcon(Icons.done_all), findsNWidgets(2), reason: 'the failed bubble has no tick');
    await finish(tester);
  });

  testWidgets('one screen-reader node per message: sender, text, time, status, and a Copy action', (tester) async {
    final semantics = tester.ensureSemantics();
    final copied = mockClipboard(tester);
    final at = DateTime(2026, 10, 30, 9, 5);
    server.historyRows = [row('user', 'سؤال', ref: 'u1', at: at), row('bot', 'جواب', ref: 'b1', at: at)];
    await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
    await settle(tester);
    final user = tester.getSemantics(find.text('سؤال'));
    for (final part in ['أنت', 'سؤال', '09:05', 'تم الإرسال']) {
      expect(user.label, contains(part));
    }
    final bot = tester.getSemantics(find.text('جواب'));
    expect(bot.label, allOf(contains('مساعد'), contains('جواب'), contains('09:05')));
    const copy = CustomSemanticsAction(label: 'نسخ');
    // ignore: deprecated_member_use
    expect(bot, containsSemantics(customActions: [copy]));
    bot.owner!.performAction(bot.id, SemanticsAction.customAction, CustomSemanticsAction.getIdentifier(copy));
    await tester.pump();
    expect(copied, ['جواب']);
    semantics.dispose();
    await finish(tester);
  });

  testWidgets('long-press a bubble: Copy puts its text on the clipboard', (tester) async {
    final copied = mockClipboard(tester);
    server.historyRows = [
      row('user', 'my order 1042', ref: 'u1'),
      row('bot', '**Order 1042** is on its way', ref: 'b1')
    ];
    await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
    await settle(tester);
    await tester.longPress(find.text('Order 1042 is on its way'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, ['Order 1042 is on its way'], reason: 'the shown (sanitized) text');
    await tester.longPress(find.text('my order 1042'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied.last, 'my order 1042');
    await finish(tester);
  });

  testWidgets('a phone in an Arabic bubble keeps its LTR digit order', (tester) async {
    server.historyRows = [row('bot', 'اتصل على +962 79 123 4567 وشكراً', ref: 'b1')];
    await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
    await settle(tester);
    final p = tester.renderObject<RenderParagraph>(
        find.descendant(of: find.textContaining('اتصل على'), matching: find.byType(RichText)));
    final plain = p.text.toPlainText();
    double leftOf(String s) {
      final i = plain.indexOf(s);
      return p.getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + s.length)).first.left;
    }

    expect(leftOf('+962'), lessThan(leftOf('79')));
    expect(leftOf('79'), lessThan(leftOf('123')));
    expect(leftOf('123'), lessThan(leftOf('4567')));
    await finish(tester);
  });

  testWidgets('200% text at 320 dp: pill, avatar, ticks and a failed send lay out', (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    server.historyRows = [
      row('user', 'سؤال طويل شوي عن التوصيل لإربد', ref: 'u1', at: now.subtract(const Duration(days: 3))),
      row('bot', 'أكيد! بنوصّل لكل المحافظات خلال يومين إلى ثلاث أيام عمل.', ref: 'b1', at: now),
      row('user', 'تمام', ref: 'u2', at: now),
    ];
    server.dropChat = true;
    await tester.pumpWidget(app(SunonoChatView(controller: make('ar')), textScale: 2));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'مرحبا');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await settle(tester);
    expect(find.text('أعد المحاولة'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
}
