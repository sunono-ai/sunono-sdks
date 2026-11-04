@Tags(['golden'])
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/sunono.dart';

import '../fake_server.dart';
import 'golden_harness.dart';

/// Cards on the chat page, AR/EN, light/dark:
/// - `cards_*`: a product carousel (sale, low stock, out of stock), Show
///   more, the quick replies under the reply and the cart bar.
/// - `checkout_*`: a confirm read-back with a phone (LTR in Arabic), then the
///   placed card with Order details and the handoff button.
/// - `handoff_cart_*` (light): app checkout (D1), «افتح السلة» / "Open cart".
void main() {
  setUpAll(loadGoldenFonts);

  const copy = {
    'ar': (
      ask: 'بدي قهوة',
      found: 'لقيتلك هدول',
      coffee: 'قهوة عربية محمصة بالهيل',
      tea: 'شاي أخضر',
      mug: 'كوب سيراميك',
      order: 'اطلب',
      confirm: 'هاي تفاصيل طلبك، أأكد؟',
      yes: 'آه أكد',
      placed: 'تم الطلب! بنتواصل معك قريباً.',
      name: 'الاسم',
      phone: 'الهاتف',
      area: 'المنطقة',
      sara: 'سارة',
      amman: 'عمّان، الصويفية',
      total: '12.500 د.أ',
      checkout: 'خلص بدي أطلب',
      cartReady: 'سلتك جاهزة، افتح السلة من التطبيق وكمّل الطلب من هناك.',
    ),
    'en': (
      ask: 'I want coffee',
      found: 'Here is what I found',
      coffee: 'Roasted Arabic coffee with cardamom',
      tea: 'Green tea',
      mug: 'Ceramic mug',
      order: 'Order it',
      confirm: 'Here are your order details. Confirm?',
      yes: 'Yes, confirm',
      placed: "Your order is placed! We'll be in touch soon.",
      name: 'Name',
      phone: 'Phone',
      area: 'Area',
      sara: 'Sara',
      amman: 'Amman, Sweifieh',
      total: '12.500 JOD',
      checkout: "I'm ready to order",
      cartReady: 'Your cart is ready. Open your cart in the app to finish your order.',
    ),
  };

  for (final kind in ['cards', 'checkout', 'handoff_cart']) {
    for (final lang in ['ar', 'en']) {
      for (final dark in kind == 'handoff_cart' ? [false] : [false, true]) {
        final name = '${kind}_${lang}_${dark ? 'dark' : 'light'}';
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
            recoveryChecks: const [Duration(milliseconds: 5)],
          );
          Future<void> settle() async {
            for (var i = 0; i < 20; i++) {
              await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
              await tester.pump(const Duration(milliseconds: 20));
            }
          }

          Future<void> turn(String ask, String reply, Map<String, dynamic> a) async {
            server.chatReply = {
              'reply': reply,
              'msg_ref': 'm${c.messages.length}',
              'action_data': {...a, 'reply_lang': lang},
            };
            unawaited(c.send(ask));
            await settle();
          }

          await tester.pumpWidget(goldenApp(SunonoChatView(controller: c, onBack: () {}), dark: dark));
          await settle();
          if (kind == 'cards') {
            Map<String, dynamic> p(String id, String title, Map<String, dynamic> more) =>
                {'public_id': id, 'title_$lang': title, 'price_jod': 10, 'has_image': false, ...more};
            await turn(t.ask, t.found, {
              'products': [
                p('p1', t.coffee, {'discount_jod': 7.5, 'price_from': 7.5, 'on_sale': true}),
                p('p2', t.tea, {'price_jod': 4.25, 'low_stock_qty': 2}),
                p('p3', t.mug, {'in_stock': false}),
              ],
              'has_more': true,
              'cart_summary': {
                'items': [
                  {'product_id': 'p2', 'name_$lang': t.tea, 'qty': 2, 'subtotal_fils': 8500},
                ],
                'total_fils': 8500,
              },
            });
          } else if (kind == 'handoff_cart') {
            await turn(t.checkout, t.cartReady, {
              'checkout_handoff': {'target': 'cart', 'url': 'https://shop.example/checkout/'},
            });
          } else {
            await turn(t.order, t.confirm, {
              'order_confirm': true,
              'details': [
                {'key': 'name', 'label_$lang': t.name, 'value': t.sara},
                {'key': 'phone', 'label_$lang': t.phone, 'value': '+962790000000'},
                {'key': 'area', 'label_$lang': t.area, 'value': t.amman},
              ],
              'order_total_text': t.total,
            });
            await turn(t.yes, t.placed, {
              'order_placed': true,
              'order': {
                'order_number': '1007',
                'items': [
                  {'product_id': 'p1', 'name_$lang': t.coffee, 'qty': 1, 'subtotal_fils': 12500},
                ],
                'delivery_fee_fils': 0,
                'total_fils': 12500,
              },
              'order_ids': {'public_id': 'ord_1', 'number': 1007, 'source': 'chat'},
              'checkout_handoff': {'url': 'https://shop.example/checkout/'},
            });
          }
          // Pin the clock so the golden is stable.
          for (final m in c.messages) {
            m.ts = at;
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
}
