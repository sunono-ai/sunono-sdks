@Tags(['golden'])
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/sunono.dart';

import '../fake_server.dart';
import 'golden_harness.dart';

/// The mockup conversation: welcome card, date pill, bot / shopper / bot with
/// avatars, times and ticks, then a send that failed. AR/EN, light/dark.
void main() {
  setUpAll(loadGoldenFonts);

  const copy = {
    'ar': (
      welcome: 'أهلين! كيف بقدر أساعدك اليوم؟',
      ask: 'في عروض هلأ؟',
      reply: 'ما في أكواد خصم فعّالة هلّق، بس بتلاقي أسعار حلوة بعروض الشهر.\n\nشو حابب تتسوق؟',
      failed: 'بتوصلوا على إربد؟',
    ),
    'en': (
      welcome: 'Hi! What can I help you with today?',
      ask: 'Any offers?',
      reply: "We don't have any active discount codes right now, but you can still find great prices in our "
          'monthly offers.\n\nWhat would you like to shop for?',
      failed: 'Do you deliver to Irbid?',
    ),
  };

  for (final lang in ['ar', 'en']) {
    for (final dark in [false, true]) {
      final name = 'thread_${lang}_${dark ? 'dark' : 'light'}';
      testWidgets(name, (tester) async {
        goldenPhone(tester);
        final t = copy[lang]!;
        final now = DateTime.now();
        final at = DateTime(now.year, now.month, now.day, 12, 12);
        final server = FakeServer()
          ..config = {
            'enabled': true,
            'header_title_ar': 'مساعد المتجر',
            'header_title_en': 'Shop Assistant',
            'welcome_message_$lang': t.welcome,
            if (dark) 'color_scheme': 'dark',
          }
          ..historyRows = [
            for (final (role, text, ref) in [('user', t.ask, 'u1'), ('bot', t.reply, 'b1')])
              {
                'role': role,
                'sender': role,
                'text': text,
                'msg_ref': ref,
                'ts': at.toUtc().toIso8601String(),
                'products': <Object>[],
                'has_more': false,
              },
          ]
          ..dropChat = true;
        final c = SunonoChatController(
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
        Future<void> settle() async {
          for (var i = 0; i < 20; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
            await tester.pump(const Duration(milliseconds: 20));
          }
        }

        await tester.pumpWidget(goldenApp(SunonoChatView(controller: c, onBack: () {}), dark: dark));
        await settle();
        unawaited(c.send(t.failed));
        await settle();
        // Pin the failed send's clock so the golden is stable.
        for (final m in c.messages.skip(2)) {
          m.ts = at.add(const Duration(minutes: 1));
        }
        c.notifyListeners();
        await settle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('$name.png'));
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        server.close();
      });
    }
  }
}
