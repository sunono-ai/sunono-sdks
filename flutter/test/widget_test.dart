import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/sunono.dart';

import 'fake_server.dart';

void main() {
  late FakeServer server;
  late SunonoChatController c;
  final intents = <SunonoIntent>[];

  setUp(() {
    server = FakeServer();
    intents.clear();
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
          return true;
        },
        recoveryChecks: const [Duration(milliseconds: 5)],
      );

  // Reduced motion keeps the orb still, so the tree can settle.
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
      await tester.pump(const Duration(milliseconds: 20)); // advances fake timers too
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    server.close();
  }

  testWidgets('Arabic: welcome, then a turn with RTL bubbles, a product card and the cart bar', (tester) async {
    server.chatReply = {
      'reply': 'لقيتلك هدول:',
      'msg_ref': 'msg_1',
      'action_data': {
        'products': [
          {'public_id': 'prod_1', 'sku': 'SKU-1', 'title_ar': 'قهوة غوجي', 'price_jod': 9, 'has_image': false},
        ],
        'has_more': true,
        'cart_summary': {
          'items': [
            {'product_id': 'prod_1', 'name_ar': 'قهوة', 'qty': 2, 'subtotal_fils': 18000},
          ],
          'total_fils': 18000,
        },
      },
    };
    await tester.pumpWidget(app(SunonoChatView(controller: make('ar'))));
    await settle(tester);
    expect(find.text('أهلاً بك! كيف يمكنني مساعدتك اليوم؟'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'بدي قهوة');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await settle(tester);

    expect(find.text('لقيتلك هدول:'), findsOneWidget);
    expect(find.text('قهوة غوجي'), findsOneWidget);
    expect(find.text('9 د.أ'), findsOneWidget);
    expect(find.text('أضف للسلة'), findsOneWidget);
    expect(find.text('شوف أكثر'), findsOneWidget);
    expect(find.text('18 د.أ'), findsOneWidget, reason: 'cart bar total');
    final dir = tester.widget<Text>(find.text('لقيتلك هدول:')).textDirection;
    expect(dir, TextDirection.rtl);

    await tester.tap(find.text('قهوة غوجي'));
    expect((intents.single as OpenProductIntent).sku, 'SKU-1');

    await tester.tap(find.text('أضف للسلة'));
    await settle(tester);
    expect(server.bodies['/chat']!.last, contains('ضيف \\"قهوة غوجي\\" للسلة'));
    expect(server.bodies['/chat']!.last, contains('"synthetic":true'));
    await finish(tester);
  });

  testWidgets('English: failed send shows a retry chip', (tester) async {
    server.dropChat = true;
    await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await settle(tester);
    expect(find.text("The message didn't go through"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('kill switch shows the unavailable state', (tester) async {
    server.config = {'enabled': false};
    await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
    await settle(tester);
    expect(find.text('The assistant is unavailable right now'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await finish(tester);
  });

  testWidgets('handoff button raises a checkout intent', (tester) async {
    server.chatReply = {
      'reply': 'Ready!',
      'action_data': {
        'checkout_handoff': {'url': 'https://shop.example/checkout/'},
      },
    };
    await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'checkout');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await settle(tester);
    await tester.tap(find.text('Complete order on the site'));
    expect((intents.single as CheckoutIntent).url, 'https://shop.example/checkout/');
    await finish(tester);
  });

  testWidgets('large text (200%) on a small phone lays out without overflow', (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    server.chatReply = {
      'reply': 'تمام! كمّل الطلب من صفحة الدفع، وإذا بدك أي إشي ثاني احكيلي.',
      'action_data': {
        'products': [
          {
            'public_id': 'p1',
            'title_ar': 'اسم منتج طويل جداً جداً جداً',
            'price_jod': 1234.5,
            'discount_jod': 999,
            'has_image': false
          },
        ],
        'has_more': true,
        'checkout_handoff': {'url': 'https://shop.example/checkout/'},
        'order_confirm': true,
        'details': [
          {'key': 'area', 'label_ar': 'المنطقة (وين نوصّل)', 'value': 'شارع الملكة رانيا العبدالله، عمّان'},
        ],
        'order_total_text': '1,234.5 دينار',
        'service_fee_text': '0.5 دينار',
        'cart_summary': {
          'items': [
            {'product_id': 'p1', 'name_ar': 'x', 'qty': 12, 'subtotal_fils': 1234500},
          ],
          'total_fils': 1234500,
        },
      },
    };
    await tester.pumpWidget(app(SunonoChatView(controller: make('ar')), textScale: 2));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'كمّل');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await settle(tester);
    expect(find.text('كمّل الطلب بالموقع'), findsOneWidget);
    await finish(tester);
  });
}
