import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/src/ui/cards.dart' show ProductCarousel;
import 'package:sunono/sunono.dart';

import 'fake_server.dart';

Map<String, dynamic> product(String id, {String? sku, String? ar, String? en, Map<String, dynamic>? more}) => {
      'public_id': id,
      'sku': sku,
      'title_ar': ar,
      'title_en': en,
      'price_jod': 10,
      'has_image': false,
      ...?more,
    };

void main() {
  late FakeServer server;
  late SunonoChatController c;
  late bool handled;
  late List<SunonoIntent> intents;

  setUp(() {
    server = FakeServer();
    handled = true;
    intents = [];
  });

  SunonoChatController make(String lang) => c = SunonoChatController(
        api: SunonoApi(
          shopKey: 'pk_test',
          apiBase: 'https://api.test/api',
          appOrigin: 'https://shop.example',
          clientFactory: () => MockClient.streaming(server.handle),
        ),
        storage: MemoryStorage(),
        lang: lang,
        onIntent: (i) {
          intents.add(i);
          return handled;
        },
        recoveryChecks: const [Duration(milliseconds: 5)],
      );

  Widget app(Widget child, {double textScale = 1, bool reduceMotion = true}) => MaterialApp(
        theme: ThemeData(colorSchemeSeed: const Color(0xFF57227D)),
        home: MediaQuery(
          data: MediaQueryData(
              disableAnimations: reduceMotion, size: const Size(400, 800), textScaler: TextScaler.linear(textScale)),
          child: Scaffold(body: child),
        ),
      );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// Opens the chat and runs one search turn that answers [products].
  Future<void> showCards(WidgetTester tester, String lang, List<Map<String, dynamic>> products,
      {double textScale = 1, bool reduceMotion = true, String? replyLang}) async {
    server.chatReply = {
      'reply': lang == 'en' ? 'Found these' : 'لقيتلك هدول',
      'msg_ref': 'm1',
      'action_data': {'products': products, if (replyLang != null) 'reply_lang': replyLang},
    };
    await tester
        .pumpWidget(app(SunonoChatView(controller: make(lang)), textScale: textScale, reduceMotion: reduceMotion));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'x');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await settle(tester);
    server.bodies['/chat']!.clear();
  }

  Map<String, dynamic> lastBody() => jsonDecode(server.bodies['/chat']!.last) as Map<String, dynamic>;

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    server.close();
  }

  group('taps', () {
    testWidgets('Add sends exactly the fixture body (English)', (tester) async {
      await showCards(tester, 'en', [product('prod_a', sku: 'SKU-A1', en: 'Medjool Dates')]);
      await tester.tap(find.text('Add to cart'));
      await settle(tester);
      final fixture = jsonDecode(File('../protocol/fixtures/tap_request.json').readAsStringSync())['request'] as Map;
      final body = lastBody();
      expect(body['client_message_id'], matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(body, {...fixture, 'client_message_id': body['client_message_id']});
      await finish(tester);
    });

    testWidgets('Arabic: Add and the details button send the phrase plus the structured tap', (tester) async {
      await showCards(tester, 'ar', [product('prod_a', sku: 'SKU-A1', ar: 'قهوة غوجي')]);
      await tester.tap(find.text('أضف للسلة'));
      await settle(tester);
      expect(lastBody(), containsPair('message', 'ضيف "قهوة غوجي" للسلة'));
      expect(lastBody(), containsPair('action', 'add_to_cart'));
      expect(lastBody(), containsPair('action_ref', 'prod_a'));
      expect(lastBody(), containsPair('product_sku', 'SKU-A1'));
      expect(lastBody(), containsPair('synthetic', true));

      final sem = tester.ensureSemantics();
      expect(find.bySemanticsLabel('التفاصيل: قهوة غوجي'), findsOneWidget);
      sem.dispose();
      await tester.tap(find.byIcon(Icons.info_outline_rounded));
      await settle(tester);
      expect(lastBody(), containsPair('message', 'احكيلي أكثر عن "قهوة غوجي"'));
      expect(lastBody(), containsPair('action', 'product_detail'));
      expect(lastBody(), containsPair('action_ref', 'prod_a'));
      expect(intents, isEmpty, reason: 'ⓘ asks the assistant, it does not open the product');
      await finish(tester);
    });

    testWidgets('English details button; a card without a sku sends no product_sku', (tester) async {
      await showCards(tester, 'en', [product('prod_a', en: 'Dates')]);
      await tester.tap(find.byIcon(Icons.info_outline_rounded));
      await settle(tester);
      expect(lastBody(), containsPair('message', 'Tell me more about "Dates"'));
      expect(lastBody().containsKey('product_sku'), isFalse);
      await finish(tester);
    });

    testWidgets('card body: OpenProductIntent when handled, else the details phrase + tap', (tester) async {
      await showCards(tester, 'en', [product('prod_a', sku: 'S1', en: 'Dates')]);
      await tester.tap(find.text('Dates'));
      await settle(tester);
      expect((intents.single as OpenProductIntent).productId, 'prod_a');
      expect(server.bodies['/chat'], isEmpty);

      handled = false;
      await tester.tap(find.text('Dates'));
      await settle(tester);
      expect(lastBody(), containsPair('message', 'Tell me more about "Dates"'));
      expect(lastBody(), containsPair('action', 'product_detail'));
      await finish(tester);
    });

    testWidgets('retry keeps the tap, the sku and the client_message_id', (tester) async {
      await showCards(tester, 'en', [product('prod_a', sku: 'S1', en: 'Dates')]);
      server.failChatOnceWith = 429;
      await tester.tap(find.text('Add to cart'));
      await settle(tester);
      final first = lastBody();
      await tester.tap(find.text('Retry'));
      await settle(tester);
      expect(server.bodies['/chat'], hasLength(2));
      expect(lastBody(), first);
      expect(first, containsPair('action', 'add_to_cart'));
      expect(first, containsPair('product_sku', 'S1'));
      await finish(tester);
    });
  });

  group('productSku scoping', () {
    testWidgets('SunonoChatView(productSku:) puts product_sku on the initial message', (tester) async {
      await tester
          .pumpWidget(app(SunonoChatView(controller: make('en'), initialMessage: 'In size 42?', productSku: 'SKU-9')));
      await settle(tester);
      expect(lastBody(), containsPair('product_sku', 'SKU-9'));
      expect(lastBody().containsKey('product_id'), isFalse);
      await finish(tester);
    });

    testWidgets('productId wins when both are given', (tester) async {
      await tester.pumpWidget(
          app(SunonoChatView(controller: make('en'), initialMessage: 'hi', productId: 'prod_z', productSku: 'SKU-9')));
      await settle(tester);
      expect(lastBody(), containsPair('product_id', 'prod_z'));
      expect(lastBody().containsKey('product_sku'), isFalse);
      await finish(tester);
    });
  });

  group('badges', () {
    testWidgets('out of stock (ar): a disabled add button plus the badge', (tester) async {
      await showCards(tester, 'ar', [
        product('p', ar: 'قهوة', more: {'in_stock': false})
      ]);
      expect(find.text('مش متوفر'), findsNWidgets(2));
      await tester.tap(find.text('مش متوفر').last);
      await settle(tester);
      expect(server.bodies['/chat'], isEmpty);
      await finish(tester);
    });

    testWidgets('out of stock (en)', (tester) async {
      await showCards(tester, 'en', [
        product('p', en: 'Coffee', more: {'in_stock': false})
      ]);
      expect(find.text('Unavailable'), findsNWidgets(2));
      await finish(tester);
    });

    testWidgets('Arabic: low stock and the sale badge together; -X% next to the struck price', (tester) async {
      await showCards(tester, 'ar', [
        product('p', ar: 'قهوة', more: {'low_stock_qty': 3, 'discount_jod': 7.5, 'price_from': 7.5, 'on_sale': true}),
      ]);
      expect(find.text('باقي 3 بس!'), findsOneWidget);
      expect(find.text('عرض'), findsOneWidget);
      expect(find.text('-25%'), findsOneWidget);
      expect(find.text('10 د.أ'), findsOneWidget, reason: 'struck list price');
      await finish(tester);
    });

    testWidgets('English: low stock + Sale + -X%', (tester) async {
      await showCards(tester, 'en', [
        product('p', en: 'Coffee', more: {'low_stock_qty': 2, 'discount_jod': 8, 'price_from': 8, 'on_sale': true}),
      ]);
      expect(find.text('Only 2 left!'), findsOneWidget);
      expect(find.text('Sale'), findsOneWidget);
      expect(find.text('-20%'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('no sale badge without on_sale or price_from; no -X% outside 0..100', (tester) async {
      await showCards(tester, 'en', [
        product('a', en: 'Plain', more: {'discount_jod': 8, 'on_sale': true}), // no price_from
        product('b', en: 'NoFlag', more: {'discount_jod': 8, 'price_from': 8}), // no on_sale
        product('c', en: 'Free', more: {'discount_jod': 0}), // 100% off
        product('d', en: 'Same', more: {'discount_jod': 10}), // 0% off
      ]);
      expect(find.text('Sale'), findsNothing);
      expect(find.text('-20%'), findsNWidgets(2));
      expect(find.textContaining('-100%'), findsNothing);
      expect(find.textContaining('-0%'), findsNothing);
      await finish(tester);
    });
  });

  group('content', () {
    final pre = {'price_fils': 9000, 'was_fils': 12000, 'label_ar': 'كيلو / حبوب', 'label_en': '1kg / beans'};

    testWidgets('preselect (ar): was struck, label under the title', (tester) async {
      await showCards(tester, 'ar', [
        product('p', ar: 'قهوة', en: 'Coffee', more: {'preselect_line': pre})
      ]);
      expect(find.text('كيلو / حبوب'), findsOneWidget);
      expect(find.text('9 د.أ'), findsOneWidget);
      expect(tester.widget<Text>(find.text('12 د.أ')).style!.decoration, TextDecoration.lineThrough);
      expect(find.text('-25%'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('preselect (en)', (tester) async {
      await showCards(tester, 'en', [
        product('p', ar: 'قهوة', en: 'Coffee', more: {'preselect_line': pre})
      ]);
      expect(find.text('1kg / beans'), findsOneWidget);
      expect(find.text('9 JOD'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('up to three metadata chips', (tester) async {
      await showCards(tester, 'en', [
        product('p', en: 'Coffee', more: {
          'metadata': {'a': 'Ethiopia', 'b': 'light', 'c': 87, 'd': 'fourth'},
        }),
      ]);
      expect(find.text('Ethiopia'), findsOneWidget);
      expect(find.text('light'), findsOneWidget);
      expect(find.text('87'), findsOneWidget);
      expect(find.text('fourth'), findsNothing);
      await finish(tester);
    });
  });

  group('busy', () {
    for (final reduce in [true, false]) {
      testWidgets('only the tapped card spins (reduce motion: $reduce); the others no-op', (tester) async {
        final gate = Completer<void>();
        await showCards(
            tester,
            'en',
            [
              product('a', sku: 'A', en: 'First'),
              product('b', sku: 'B', en: 'Second'),
            ],
            reduceMotion: reduce);
        server.beforeChatReply = () => gate.future;
        await tester.tap(find.text('Add to cart').first);
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(CircularProgressIndicator), reduce ? findsNothing : findsOneWidget);
        expect(find.byIcon(Icons.hourglass_top_rounded), reduce ? findsOneWidget : findsNothing);
        expect(find.text('Add to cart'), findsNWidgets(2), reason: 'labels stay on both buttons');

        await tester.pump(const Duration(seconds: 1)); // let the list finish scrolling
        await tester.tap(find.text('Add to cart').last);
        await tester.pump(const Duration(milliseconds: 50));
        expect(server.bodies['/chat'], hasLength(1), reason: 'busy: the second tap does nothing');

        gate.complete();
        await settle(tester);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byIcon(Icons.hourglass_top_rounded), findsNothing);
        await finish(tester);
      });
    }
  });

  group('languages', () {
    testWidgets('UI Arabic over an English reply: chrome Arabic, content English, carousel LTR', (tester) async {
      await showCards(
          tester,
          'ar',
          [
            product('p', sku: 'S', ar: 'قهوة', en: 'Coffee', more: {'in_stock': false})
          ],
          replyLang: 'en');
      expect(find.text('Coffee'), findsOneWidget);
      expect(find.text('10 JOD'), findsOneWidget);
      expect(find.text('مش متوفر'), findsNWidgets(2), reason: 'chrome follows the UI language');
      final dir = tester.widget<Directionality>(
          find.descendant(of: find.byType(ProductCarousel), matching: find.byType(Directionality)).first);
      expect(dir.textDirection, TextDirection.ltr);
      await finish(tester);
    });

    testWidgets('UI English over an Arabic reply: chrome English, content Arabic, carousel RTL', (tester) async {
      await showCards(tester, 'en', [product('p', sku: 'S', ar: 'قهوة', en: 'Coffee')], replyLang: 'ar');
      expect(find.text('قهوة'), findsOneWidget);
      expect(find.text('10 د.أ'), findsOneWidget);
      expect(find.text('Add to cart'), findsOneWidget);
      final dir = tester.widget<Directionality>(
          find.descendant(of: find.byType(ProductCarousel), matching: find.byType(Directionality)).first);
      expect(dir.textDirection, TextDirection.rtl);
      await tester.tap(find.text('Add to cart'));
      await settle(tester);
      expect(lastBody(), containsPair('message', 'ضيف "قهوة" للسلة'));
      expect(lastBody(), containsPair('lang', 'en'), reason: 'lang is the UI hint');
      await finish(tester);
    });
  });

  testWidgets('200% text on a 320px phone: badges + chips + preselect + sale lay out without overflow', (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await showCards(
        tester,
        'ar',
        [
          product('p', sku: 'S', ar: 'اسم منتج طويل جداً جداً جداً يلف على سطرين', more: {
            'low_stock_qty': 3,
            'price_from': 1234.5,
            'on_sale': true,
            'price_jod': 2000,
            'discount_jod': 1234.5,
            'options_summary': 'الوزن: ٢٥٠ جرام، نص كيلو، كيلو · الطحن: حبوب، إسبريسو',
            'metadata': {'a': 'إثيوبيا المرتفعات', 'b': 'تحميص فاتح جداً', 'c': 'عضوي'},
          }),
          product('q', sku: 'T', ar: 'منتج مع نسخة', more: {
            'preselect_line': {'price_fils': 900000, 'was_fils': 1200000, 'label_ar': 'كيلو / حبوب كاملة'},
            'metadata': {'a': 'x', 'b': 'y'},
          }),
        ],
        textScale: 2);
    expect(tester.takeException(), isNull);
    expect(find.text('أضف للسلة'), findsNWidgets(2));
    await finish(tester);
  });
}
