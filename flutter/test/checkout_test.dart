import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/src/ui/cards.dart' show CheckoutCardView;
import 'package:sunono/src/ui/theme.dart' show contrastRatio;
import 'package:sunono/sunono.dart';

import 'fake_server.dart';

class _Custom extends SunonoIntent {
  const _Custom();
}

class _Bridge implements SunonoCartBridge {
  @override
  Future<Map<String, dynamic>?> probe(String userId) async => {'sig': 'p'};
  @override
  Future<Map<String, dynamic>?> ensureBind(String userId) async => {'sig': 'e'};
}

Map<String, dynamic> _turn(Map<String, dynamic> a, {String reply = 'تمام'}) =>
    {'reply': reply, 'msg_ref': 'm1', 'action_data': a};

const _placed = {
  'order_placed': true,
  'order': {'order_number': '1007', 'total_fils': 5000},
  'order_ids': {'public_id': 'ord_1', 'number': 1007, 'store_order_id': '55', 'source': 'chat'},
};

/// The keys the server copies into an app history row's `action` (B1).
const _historyActionKeys = {
  'reply_lang', 'order_collect', 'known', 'missing_fields', 'field_notes', 'order_confirm', 'order_amend', //
  'details', 'order_total_text', 'vat_text', 'savings_text', 'service_fee_text', 'order_placed', 'order',
  'checkout_handoff', 'cancelled', 'cancelled_before_store', 'cancel_pending', 'cancel_pending_store',
  'cancel_refused', 'cancel_store_error', 'cancel_aborted', 'order_ids',
};

/// The app history row the server stores for a live turn answering [a].
Map<String, dynamic> _replyRow(Map<String, dynamic> a, {String text = 'تمام', bool action = true}) => {
      'role': 'bot',
      'sender': 'bot',
      'text': text,
      'msg_ref': 'm1',
      'image': null,
      'ts': '2026-11-03T10:00:00+00:00',
      'products': a['products'] ?? <Object>[],
      'has_more': a['has_more'] == true,
      'checkout_handoff': a['checkout_handoff'],
      if (action)
        'action': {
          for (final e in a.entries)
            if (_historyActionKeys.contains(e.key)) e.key: e.value
        },
    };

const _userRow = {'role': 'user', 'sender': 'user', 'text': 'go', 'msg_ref': 'u1', 'products': <Object>[]};

(String, String?, String?, String?, String?) _field(CheckoutField f) => (f.key, f.labelAr, f.labelEn, f.value, f.note);

/// What a bubble renders, as plain values (lists compare deeply).
List<Object?> _shape(ChatMessage m) => [
      m.role,
      m.text,
      m.imageUrl,
      [
        for (final p in m.products)
          [
            p.publicId, p.sku, p.title('ar'), p.title('en'), p.shownPrice, p.struckPrice, p.salePct, p.inStock, //
            p.lowStockQty, p.optionsLine('ar'), p.optionsLine('en'), p.externalUrl, p.imageUrls, p.chips
          ],
      ],
      m.hasMore,
      switch (m.checkout) {
        null => null,
        CheckoutCollect(:final known, :final missing) => [
            'collect',
            known.map(_field).toList(),
            missing.map(_field).toList(),
          ],
        final CheckoutReview r => [
            'review',
            r.amend,
            r.details.map(_field).toList(),
            r.totalText,
            r.vatText,
            r.savingsText,
            r.serviceFeeText,
          ],
        final CheckoutPlaced p => [
            'placed',
            p.orderNumber,
            [for (final l in p.lines) (l.productId, l.name('ar'), l.name('en'), l.qty, l.subtotalFils)],
            p.deliveryFeeFils,
            p.totalFils,
            p.savingsFils,
            p.serviceFeeFils,
            p.vatFils,
          ],
      },
      m.orderIds == null
          ? null
          : (m.orderIds!.publicId, m.orderIds!.number, m.orderIds!.storeOrderId, m.orderIds!.source),
      m.handoff,
      m.handoffUrl,
      m.replyLang,
    ];

void main() {
  late FakeServer server;
  late SunonoChatController c;
  late List<SunonoIntent> intents;
  late List<SunonoEvent> events;
  late bool handled;
  late int closes;

  setUp(() {
    server = FakeServer();
    intents = [];
    events = [];
    handled = true;
    closes = 0;
  });

  SunonoChatController make(String lang, {bool native = false, bool bridge = false}) => c = SunonoChatController(
        api: SunonoApi(
          shopKey: 'pk_test',
          apiBase: 'https://api.test/api',
          appOrigin: 'https://shop.example',
          clientFactory: () => MockClient.streaming(server.handle),
        ),
        storage: MemoryStorage(),
        lang: lang,
        nativeCheckout: native,
        cartBridge: bridge ? _Bridge() : null,
        onIntent: (i) {
          intents.add(i);
          return handled;
        },
        recoveryChecks: const [Duration(milliseconds: 5)],
      )..events.listen(events.add);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// Opens the chat and runs one turn answering [actionData].
  Future<void> turn(WidgetTester tester, String lang, Map<String, dynamic> actionData,
      {bool native = false, bool bridge = false, double textScale = 1}) async {
    server.chatReply = _turn(actionData);
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
            disableAnimations: true, size: const Size(400, 800), textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
            body: SunonoChatView(controller: make(lang, native: native, bridge: bridge), onClose: () => closes++)),
      ),
    ));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'go');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    server.close();
  }

  List<Object> errors() => events.whereType<ErrorEvent>().map((e) => e.error).toList();
  List<String> sent() => (server.bodies['/chat'] ?? []);

  group('collect card', () {
    const collect = {
      'order_collect': true,
      'known': {'name': 'سارة', 'phone': '0791234567'},
      'missing_fields': [
        {'key': 'area', 'label_ar': 'المنطقة', 'label_en': 'Area'},
      ],
      'field_notes': [
        {'key': 'area', 'note': 'اكتبي المنطقة'},
        {'key': 'name', 'note': 'NOTE-KNOWN'},
      ],
    };

    testWidgets('ar: known = tick + value only (no raw key), missing = dot + label + note', (tester) async {
      await turn(tester, 'ar', collect);
      expect(find.text('سارة'), findsOneWidget);
      expect(find.text('0791234567'), findsOneWidget);
      expect(find.text('name'), findsNothing);
      expect(find.text('phone'), findsNothing);
      expect(find.text('NOTE-KNOWN'), findsNothing);
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
      expect(find.text('المنطقة'), findsOneWidget);
      expect(find.text('اكتبي المنطقة'), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsOneWidget);
      await finish(tester);
    });

    testWidgets('missing labels follow reply_lang, else Arabic (even in an English UI)', (tester) async {
      await turn(tester, 'en', {...collect, 'reply_lang': 'en'});
      expect(find.text('Area'), findsOneWidget);
      await finish(tester);
      await turn(tester, 'en', collect);
      expect(find.text('المنطقة'), findsOneWidget);
      await finish(tester);
    });
  });

  group('review card', () {
    const details = [
      {'key': 'area', 'label_ar': 'المنطقة', 'label_en': 'Area', 'value': 'عمّان'},
    ];
    const notes = [
      {'key': 'area', 'note': 'NOTE-AREA'},
    ];

    testWidgets('amend: edit icon + title + field notes', (tester) async {
      await turn(tester, 'ar', {'order_amend': true, 'details': details, 'field_notes': notes});
      expect(find.text('شو حاب تغيّر؟'), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.text('NOTE-AREA'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('amend title in English', (tester) async {
      await turn(tester, 'en', {'order_amend': true, 'details': details, 'reply_lang': 'en'});
      expect(find.text("What'd you like to change?"), findsOneWidget);
      await finish(tester);
    });

    testWidgets('confirm: no edit icon, notes hidden', (tester) async {
      await turn(tester, 'ar', {'order_confirm': true, 'details': details, 'field_notes': notes});
      expect(find.text('تأكيد الطلب'), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      expect(find.text('NOTE-AREA'), findsNothing);
      await finish(tester);
    });
  });

  group('values (F7) and notes (F10)', () {
    const confirm = {
      'order_confirm': true,
      'details': [
        {'key': 'name', 'label_ar': 'الاسم', 'value': 'سارة'},
        {'key': 'phone', 'label_ar': 'الهاتف', 'value': '+962790000000'},
        {'key': 'email', 'label_ar': 'الإيميل', 'value': 'sara@shop.example'},
      ],
      'order_total_text': '12.500 د.أ',
    };

    TextDirection dirOf(WidgetTester tester, String text) => tester
        .widget<Directionality>(find.ancestor(of: find.text(text), matching: find.byType(Directionality)).first)
        .textDirection;

    testWidgets('a phone and an email read left to right inside an Arabic card, at its end side', (tester) async {
      await turn(tester, 'ar', confirm);
      expect(dirOf(tester, '+962790000000'), TextDirection.ltr);
      expect(dirOf(tester, 'sara@shop.example'), TextDirection.ltr);
      expect(dirOf(tester, 'سارة'), TextDirection.rtl, reason: 'Arabic values keep the card direction');
      // RTL: the label is on the right, the value on the left (the end side).
      expect(tester.getCenter(find.text('+962790000000')).dx, lessThan(tester.getCenter(find.text('الهاتف')).dx));
      await finish(tester);
    });

    testWidgets('Arabic placed card: money is LTR-isolated, «× qty» is isolated and glued to the name', (tester) async {
      await turn(tester, 'ar', {
        'order_placed': true,
        'savings_fils': 1000,
        'order': {
          'order_number': '1007',
          'items': [
            {'product_id': 'p1', 'name_ar': 'قهوة', 'qty': 2, 'subtotal_fils': 12500},
          ],
          'delivery_fee_fils': 2000,
          'total_fils': 14500,
        },
      });
      for (final money in ['12.5 د.أ', '2 د.أ', '14.5 د.أ']) {
        expect(dirOf(tester, money), TextDirection.ltr, reason: money);
      }
      expect(find.text('قهوة\u00A0\u2066×\u00A02\u2069'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Arabic review total and savings are LTR-isolated; cart bar total too', (tester) async {
      await turn(tester, 'ar', {
        ...confirm,
        'savings_text': '1 د.أ',
        'cart_summary': {
          'items': [
            {'product_id': 'p1', 'name_ar': 'قهوة', 'qty': 1, 'subtotal_fils': 8500},
          ],
          'total_fils': 8500,
        },
      });
      expect(dirOf(tester, '12.500 د.أ'), TextDirection.ltr);
      expect(dirOf(tester, '1 د.أ'), TextDirection.ltr);
      expect(dirOf(tester, '8.5 د.أ'), TextDirection.ltr, reason: 'cart bar');
      await finish(tester);
    });

    testWidgets('a known phone in the collect card is LTR too', (tester) async {
      await turn(tester, 'ar', {
        'order_collect': true,
        'known': {'phone': '+962790000000'},
        'missing_fields': <Object>[],
      });
      expect(dirOf(tester, '+962790000000'), TextDirection.ltr);
      await finish(tester);
    });

    testWidgets('field notes are contrast-checked on the card', (tester) async {
      await turn(tester, 'ar', {
        'order_amend': true,
        'details': [
          {'key': 'area', 'label_ar': 'المنطقة', 'value': 'عمّان'},
        ],
        'field_notes': [
          {'key': 'area', 'note': 'NOTE-AREA'},
        ],
      });
      final color = tester.widget<Text>(find.text('NOTE-AREA')).style!.color!;
      expect(contrastRatio(color, Colors.white), greaterThanOrEqualTo(4.5));
      await finish(tester);
    });

    testWidgets('200% text on 320px: a confirm card with a long phone and email lays out', (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await turn(tester, 'ar', confirm, textScale: 2);
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  });

  group('handoff', () {
    const handoff = {
      'checkout_handoff': {'url': 'https://shop.example/checkout/'},
    };

    for (final (lang, native, label) in [
      ('ar', false, 'كمّل الطلب بالموقع'),
      ('ar', true, 'كمّل الطلب'),
      ('en', false, 'Complete order on the site'),
      ('en', true, 'Complete your order'),
    ]) {
      testWidgets('$lang native=$native: «$label», decided without asking the host', (tester) async {
        await turn(tester, lang, handoff, native: native);
        expect(find.text(label), findsOneWidget);
        expect(intents, isEmpty, reason: 'never call onIntent while rendering');
        await finish(tester);
      });
    }

    testWidgets('the button and the order details chip are 48 dp tall', (tester) async {
      await turn(tester, 'en', {...handoff, ..._placed});
      for (final label in ['Complete order on the site', 'Order details']) {
        final box = find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first;
        expect(tester.getSize(box).height, greaterThanOrEqualTo(48), reason: label);
      }
      await finish(tester);
    });

    testWidgets('handled tap: intent, then the sheet closes', (tester) async {
      await turn(tester, 'en', handoff, native: true);
      await tester.tap(find.text('Complete your order'));
      await tester.pump();
      expect((intents.single as CheckoutIntent).url, 'https://shop.example/checkout/');
      expect(closes, 1);
      await finish(tester);
    });

    testWidgets('unhandled tap: UnhandledIntent(CheckoutIntent), the sheet stays', (tester) async {
      handled = false;
      await turn(tester, 'en', handoff);
      await tester.tap(find.text('Complete order on the site'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(errors().whereType<UnhandledIntent>().single.intent, isA<CheckoutIntent>());
      expect(closes, 0);
      await finish(tester);
    });
  });

  group('order details', () {
    testWidgets('placed card shows the button; handled tap hands over every id', (tester) async {
      await turn(tester, 'ar', _placed);
      await tester.tap(find.text('تفاصيل الطلب'));
      await tester.pump();
      final i = intents.single as OpenOrderIntent;
      expect((i.number, i.storeOrderId, i.publicId, i.source), ('1007', '55', 'ord_1', 'chat'));
      expect(sent(), hasLength(1), reason: 'handled: nothing is sent to the chat');
      await finish(tester);
    });

    testWidgets('unhandled chat order: asks the assistant', (tester) async {
      handled = false;
      await turn(tester, 'ar', _placed);
      await tester.tap(find.text('تفاصيل الطلب'));
      await settle(tester);
      expect(sent(), hasLength(2));
      expect(sent().last, contains('وين صار طلبي 1007؟'));
      expect(errors().whereType<UnhandledIntent>(), isEmpty);
      await finish(tester);
    });

    testWidgets('unhandled chat order in English', (tester) async {
      handled = false;
      await turn(tester, 'en', _placed);
      await tester.tap(find.text('Order details'));
      await settle(tester);
      expect(sent().last, contains('Where is my order 1007?'));
      await finish(tester);
    });

    testWidgets('unhandled storefront order: UnhandledIntent, nothing sent', (tester) async {
      handled = false;
      await turn(tester, 'en', {
        'reply_lang': 'en',
        'order_ids': {'number': '9', 'source': 'storefront'},
      });
      await tester.tap(find.text('Order details'));
      await settle(tester);
      expect(errors().whereType<UnhandledIntent>().single.intent, isA<OpenOrderIntent>());
      expect(sent(), hasLength(1));
      await finish(tester);
    });

    testWidgets('an order-status reply (no card) carries the button too, and it survives a rebuild', (tester) async {
      await turn(tester, 'en', {
        'reply_lang': 'en',
        'order_ids': {'number': '9', 'source': 'chat'},
      });
      expect(find.text('Order details'), findsOneWidget);
      expect(c.messages.last.orderIds?.number, '9');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SunonoChatView(controller: c))));
      await settle(tester);
      expect(find.text('Order details'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('no order_ids: no button', (tester) async {
      await turn(tester, 'en', {
        'order_placed': true,
        'order': {'order_number': '5'}
      });
      expect(find.text('Order details'), findsNothing);
      await finish(tester);
    });
  });

  group('view cart', () {
    const cartTurn = {
      'cart_summary': {
        'items': [
          {'product_id': 'a', 'name_ar': 'قهوة', 'name_en': 'Coffee', 'qty': 2, 'subtotal_fils': 2000},
          {
            'product_id': 'b',
            'name_ar': 'شاي',
            'name_en': 'Tea',
            'qty': 1,
            'subtotal_fils': 1500,
            'img_urls': ['https://cdn.test/t.jpg'],
          },
        ],
        'item_count': 2,
        'total_fils': 3500,
      },
    };

    testWidgets('bar: last line name, +N other units, total', (tester) async {
      await turn(tester, 'en', {...cartTurn, 'reply_lang': 'en'});
      expect(find.text('Tea'), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
      expect(find.textContaining('3.5'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('bar follows the latest reply language (Arabic UI, English reply)', (tester) async {
      await turn(tester, 'ar', {...cartTurn, 'reply_lang': 'en'});
      expect(find.text('Tea'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('bar hides the total when stale', (tester) async {
      await turn(tester, 'en', {
        'reply_lang': 'en',
        'cart_summary': {...(cartTurn['cart_summary']! as Map<String, dynamic>), 'stale': true},
      });
      expect(find.text('Tea'), findsOneWidget);
      expect(find.textContaining('3.5'), findsNothing);
      await finish(tester);
    });

    testWidgets('not bound: asks the assistant, never the host', (tester) async {
      await turn(tester, 'en', cartTurn);
      await tester.tap(find.byIcon(Icons.shopping_cart_outlined));
      await settle(tester);
      expect(intents, isEmpty);
      expect(sent().last, contains("What's in my cart?"));
      await finish(tester);
    });

    testWidgets('ar phrase', (tester) async {
      await turn(tester, 'ar', cartTurn);
      await tester.tap(find.byIcon(Icons.shopping_cart_outlined));
      await settle(tester);
      expect(sent().last, contains('شو يلي بالسلة؟'));
      await finish(tester);
    });

    test('bound: OpenCartIntent; unhandled: falls back to the assistant', () async {
      server
        ..historyCartLinked = true
        ..cartBody = {'cart': null, 'linked': true};
      make('en', bridge: true);
      await c.open();
      await server.until(() => server.count('/widget/cart-binding') == 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await c.openCart();
      expect(intents.single, isA<OpenCartIntent>());
      expect(server.count('/chat'), 0);
      handled = false;
      await c.openCart();
      expect(server.count('/chat'), 1);
      expect(server.bodies['/chat']!.single, contains("What's in my cart?"));
      c.dispose();
      server.close();
    });

    testWidgets('disabled while a turn is running', (tester) async {
      await turn(tester, 'en', cartTurn);
      final gate = Completer<void>();
      server.beforeChatReply = () => gate.future;
      final running = c.send('x');
      await tester.pump();
      expect(c.busy, isTrue);
      await tester.tap(find.byIcon(Icons.shopping_cart_outlined));
      await tester.pump();
      expect(intents, isEmpty);
      gate.complete();
      await tester.runAsync(() => running);
      await settle(tester);
      expect(sent(), hasLength(2), reason: 'the tap sent nothing');
      await finish(tester);
    });
  });

  group('history restore == live', () {
    /// Opens [c] and waits until its history is applied (live comes after it).
    Future<void> openFresh() async {
      final n = server.count('/chat/subscribe?');
      await c.open();
      await server.until(() => server.count('/chat/subscribe?') > n);
    }

    const order = {
      'order_number': '1007',
      'status': 'pending',
      'items': [
        {'product_id': 'p1', 'name_ar': 'قهوة', 'name_en': 'Coffee', 'qty': 2, 'subtotal_fils': 8000},
      ],
      'delivery_fee_fils': 0,
      'total_fils': 8500,
      'service_fee_fils': 500,
      'vat_fils': 0,
    };
    const ids = {'public_id': 'ord_1', 'number': '1007', 'store_order_id': '55', 'source': 'chat'};
    final cases = <String, Map<String, dynamic>>{
      'products + has_more': {
        'products': [
          {'public_id': 'p1', 'sku': 'S1', 'title_ar': 'قهوة', 'title_en': 'Coffee', 'price_jod': 8, 'discount_jod': 6},
          {
            'public_id': 'p2',
            'title_ar': 'تيشيرت',
            'price_jod': 9,
            'price_from': 9,
            'options_summary': 'المقاس: L',
            'options': [
              {
                'name_ar': 'المقاس',
                'name_en': 'Size',
                'values': [
                  {'ar': 'L', 'en': 'L', 'in_stock': true},
                ],
              },
            ],
            'low_stock_qty': 2,
            'external_url': 'https://shop.example/p/2',
            'metadata': {'fit': 'slim'},
          },
        ],
        'has_more': true,
      },
      'collect': {
        'order_collect': true,
        'known': {'name': 'Lian'},
        'missing_fields': [
          {'key': 'phone', 'label_ar': 'رقم الهاتف', 'label_en': 'Phone', 'type': 'phone'},
        ],
        'field_notes': [
          {'key': 'phone', 'note': 'missing'},
        ],
      },
      'confirm': {
        'order_confirm': true,
        'details': [
          {'key': 'name', 'label_en': 'Name', 'value': 'Lian'},
          {'key': 'phone', 'label_en': 'Phone', 'value': '+962790000000'},
        ],
        'order_total_text': '8.500 JOD',
        'vat_text': null,
        'savings_text': null,
        'service_fee_text': '0.500 JOD',
      },
      'amend': {
        'order_amend': true,
        'details': [
          {'key': 'area', 'label_en': 'Area', 'value': 'Irbid'},
        ],
        'field_notes': [
          {'key': 'area', 'note': 'outside the delivery zone'},
        ],
        'order_total_text': '8.500 JOD',
      },
      'placed + order_ids': {'order_placed': true, 'order': order, 'order_ids': ids},
      'handoff url': {
        'checkout_handoff': {'url': 'https://shop.example/checkout/'},
      },
      'handoff target cart': {
        'checkout_handoff': {'target': 'cart'},
      },
      'tracking + order_ids': {'order': order, 'order_ids': ids},
      'cancelled + order_ids': {'cancelled': true, 'order': order, 'order_ids': ids},
    };

    for (final MapEntry(key: name, value: a) in cases.entries) {
      for (final lang in ['ar', 'en']) {
        test('$name ($lang)', () async {
          final action = {...a, 'reply_lang': lang};
          server.chatReply = {'reply': 'تمام', 'msg_ref': 'm1', 'action_data': action};
          make('en');
          await openFresh();
          await c.send('go');
          final live = _shape(c.messages.last);
          c.dispose();

          server.historyRows = [_userRow, _replyRow(action)];
          make('en');
          await openFresh();
          expect(_shape(c.messages.last), live);
          expect(c.messages.last.delivered, isTrue);
          c.dispose();
          server.close();
        });
      }
    }

    test('a staff photo restores as it arrived live', () async {
      make('ar');
      await openFresh();
      await server.until(() => server.live != null);
      server.pushLive('message.new', {
        'body_text': 'أهلين',
        'msg_ref': 's1',
        'sent_by': 'owner',
        'media_stored': {'kind': 'image', 'url': '/api/media/s.jpg'},
        'ts': '2026-11-03T10:00:00+00:00',
      });
      await server.until(() => c.messages.isNotEmpty);
      final live = _shape(c.messages.last);
      expect(c.messages.last.imageUrl, 'https://api.test/api/media/s.jpg');
      c.dispose();
      server.close();

      server = FakeServer()
        ..historyRows = [
          {
            'role': 'bot',
            'sender': 'staff',
            'text': 'أهلين',
            'msg_ref': 's1',
            'image': '/api/media/s.jpg',
            'ts': '2026-11-03T10:00:00+00:00',
            'products': <Object>[],
            'action': <String, Object>{},
          },
        ];
      make('ar');
      await openFresh();
      expect(_shape(c.messages.last), live);
      c.dispose();
      server.close();
    });

    test('an older server (no action) restores as 0.2: text, cards and the site handoff only', () async {
      server.historyRows = [
        _userRow,
        _replyRow({
          'reply_lang': 'en',
          ..._placed,
          'checkout_handoff': {'url': 'https://shop.example/checkout/'},
        }, action: false),
      ];
      make('en');
      await openFresh();
      final m = c.messages.last;
      expect((m.text, m.checkout, m.orderIds, m.replyLang), ('تمام', null, null, null));
      expect(m.handoffUrl, 'https://shop.example/checkout/');
      expect(m.handoff, (url: 'https://shop.example/checkout/', target: 'checkout'));
      c.dispose();
      server.close();
    });

    testWidgets('restored placed card: Order details hands over the number and the store id', (tester) async {
      server.historyRows = [
        _userRow,
        _replyRow({..._placed, 'reply_lang': 'en'})
      ];
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true, size: Size(400, 800)),
          child: Scaffold(body: SunonoChatView(controller: make('en'))),
        ),
      ));
      await settle(tester);
      expect(find.byType(CheckoutCardView), findsOneWidget);
      await tester.tap(find.text('Order details'));
      await tester.pump();
      final i = intents.single as OpenOrderIntent;
      expect((i.number, i.storeOrderId, i.publicId, i.source), ('1007', '55', 'ord_1', 'chat'));
      expect(sent(), isEmpty);
      await finish(tester);
    });
  });

  test('intents are open: a host (or test) can subclass and switch with default', () {
    final SunonoIntent i = const _Custom();
    final r = switch (i) {
      OpenCartIntent() => 'cart',
      _ => 'other',
    };
    expect(r, 'other');
  });

  testWidgets('200% text on 320px: placed card with the details button lays out', (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await turn(tester, 'ar', _placed, textScale: 2);
    expect(find.text('تفاصيل الطلب'), findsOneWidget);
    await finish(tester);
  });
}
