@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/sunono.dart';

import '../fake_server.dart';
import 'golden_harness.dart';

Map<String, dynamic> _row(String role, String text, String ref, int minute,
        {List<Map<String, dynamic>> products = const []}) =>
    {
      'role': role,
      'sender': role,
      'text': text,
      'msg_ref': ref,
      // Today at 12:mm: the date pill reads «اليوم» / "Today" on any run day.
      'ts': DateTime.now()
          .copyWith(hour: 12, minute: minute, second: 0, millisecond: 0, microsecond: 0)
          .toUtc()
          .toIso8601String(),
      'products': products,
      'has_more': products.isNotEmpty,
    };

Map<String, dynamic> _product(String id, String ar, String en, num price, {num? sale}) => {
      'public_id': id,
      'sku': 'SKU-$id',
      'title_ar': ar,
      'title_en': en,
      'price_jod': price,
      if (sale != null) ...{'discount_jod': sale, 'on_sale': true},
      'has_image': false,
    };

/// The flat 0.3 tokens on a short restored thread (placeholder until the
/// redesign tasks add their own goldens).
void main() {
  setUpAll(loadGoldenFonts);

  for (final lang in ['ar', 'en']) {
    for (final dark in [false, true]) {
      final name = 'theme_${lang}_${dark ? 'dark' : 'light'}';
      testWidgets(name, (tester) async {
        goldenPhone(tester);
        final ar = lang == 'ar';
        final server = FakeServer()
          ..config = {
            'enabled': true,
            'header_title_ar': 'مساعد المتجر',
            'header_title_en': 'Shop Assistant',
            if (dark) 'color_scheme': 'dark',
          }
          ..historyRows = [
            _row('user', ar ? 'في عروض؟' : 'Any offers?', 'u1', 12),
            _row('bot', ar ? 'أكيد! هدول عليهم خصم هالأسبوع' : 'Sure! These are on sale this week', 'b1', 13,
                products: [
                  _product('p1', 'كريم مرطب للوجه 50 مل', 'Face moisturiser 50 ml', 12.5, sale: 10),
                  _product('p2', 'غسول لطيف للبشرة', 'Gentle face wash', 7.25),
                ]),
          ];
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
        await tester.pumpWidget(goldenApp(SunonoChatView(controller: c), dark: dark));
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
