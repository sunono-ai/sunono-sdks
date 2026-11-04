@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/sunono.dart';

import '../fake_server.dart';
import 'golden_harness.dart';

/// The header (back, monogram, title, status, ⋮) and the welcome card over
/// an empty thread, AR/EN, light/dark.
void main() {
  setUpAll(loadGoldenFonts);

  for (final lang in ['ar', 'en']) {
    for (final dark in [false, true]) {
      final name = 'header_welcome_${lang}_${dark ? 'dark' : 'light'}';
      testWidgets(name, (tester) async {
        goldenPhone(tester);
        final server = FakeServer()
          ..config = {
            'enabled': true,
            'header_title_ar': 'مساعد المتجر',
            'header_title_en': 'Shop Assistant',
            if (dark) 'color_scheme': 'dark',
          };
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
        );
        await tester.pumpWidget(goldenApp(SunonoChatView(controller: c, onBack: () {}), dark: dark));
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
          await tester.pump(const Duration(milliseconds: 20));
        }
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('$name.png'));
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        server.close();
      });
    }
  }
}
