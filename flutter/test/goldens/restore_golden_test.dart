@Tags(['golden'])
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/sunono.dart';

import '../fake_server.dart';
import 'golden_harness.dart';

/// Live equals restored, in pixels: a confirm read-back, then the placed card
/// with Order details and the handoff button. The live run (two turns) and the
/// restored run (the same turns as history rows, as after an app kill) must
/// both match `restore_{ar,en}.png`.
void main() {
  setUpAll(loadGoldenFonts);

  const copy = {
    'ar': (
      order: 'اطلب',
      confirm: 'هاي تفاصيل طلبك، أأكد؟',
      yes: 'آه أكد',
      placed: 'تم الطلب! بنتواصل معك قريباً.',
      name: 'الاسم',
      phone: 'الهاتف',
      sara: 'سارة',
      coffee: 'قهوة عربية',
      total: '12.500 د.أ',
    ),
    'en': (
      order: 'Order it',
      confirm: 'Here are your order details. Confirm?',
      yes: 'Yes, confirm',
      placed: "Your order is placed! We'll be in touch soon.",
      name: 'Name',
      phone: 'Phone',
      sara: 'Sara',
      coffee: 'Arabic coffee',
      total: '12.500 JOD',
    ),
  };

  for (final lang in ['ar', 'en']) {
    final t = copy[lang]!;
    final turns = [
      (
        t.order,
        t.confirm,
        <String, dynamic>{
          'reply_lang': lang,
          'order_confirm': true,
          'details': [
            {'key': 'name', 'label_$lang': t.name, 'value': t.sara},
            {'key': 'phone', 'label_$lang': t.phone, 'value': '+962790000000'},
          ],
          'order_total_text': t.total,
        },
      ),
      (
        t.yes,
        t.placed,
        <String, dynamic>{
          'reply_lang': lang,
          'order_placed': true,
          'order': {
            'order_number': '1007',
            'items': [
              {'product_id': 'p1', 'name_$lang': t.coffee, 'qty': 1, 'subtotal_fils': 12500},
            ],
            'delivery_fee_fils': 0,
            'total_fils': 12500,
          },
          'order_ids': {'public_id': 'ord_1', 'number': '1007', 'source': 'chat'},
          'checkout_handoff': {'url': 'https://shop.example/checkout/'},
        },
      ),
    ];

    for (final restored in [false, true]) {
      testWidgets('restore_$lang ${restored ? 'restored' : 'live'}', (tester) async {
        goldenPhone(tester);
        final now = DateTime.now();
        final at = DateTime(now.year, now.month, now.day, 12, 12);
        final server = FakeServer()
          ..config = {'enabled': true, 'header_title_ar': 'مساعد المتجر', 'header_title_en': 'Shop Assistant'};
        if (restored) {
          var n = 0;
          server.historyRows = [
            for (final (ask, reply, a) in turns) ...[
              {'role': 'user', 'sender': 'user', 'text': ask, 'msg_ref': 'u${n++}', 'products': <Object>[]},
              {
                'role': 'bot',
                'sender': 'bot',
                'text': reply,
                'msg_ref': 'b${n++}',
                'products': <Object>[],
                'has_more': false,
                'checkout_handoff': a['checkout_handoff'],
                'action': a,
              },
            ],
          ];
        }
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

        await tester.pumpWidget(goldenApp(SunonoChatView(controller: c, onBack: () {})));
        await settle();
        if (!restored) {
          for (final (ask, reply, a) in turns) {
            server.chatReply = {'reply': reply, 'msg_ref': 'm${c.messages.length}', 'action_data': a};
            unawaited(c.send(ask));
            await settle();
          }
        }
        for (final m in c.messages) {
          m.ts = at;
        }
        c.notifyListeners();
        await settle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('restore_$lang.png'));
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        server.close();
      });
    }
  }
}
