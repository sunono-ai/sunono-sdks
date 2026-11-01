import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/sunono.dart';
import 'package:sunono/src/ui/cards.dart';
import 'package:sunono/src/ui/copy.dart';

import 'fake_server.dart';

Map<String, dynamic> _cart(int qty, {Map<String, dynamic>? extra}) => {
      'items': [
        {'product_id': 'p', 'name_ar': 'قهوة', 'qty': qty, 'subtotal_fils': 1000 * qty},
      ],
      'item_count': 1,
      'total_fils': 1000 * qty,
      if (extra != null) 'remote': extra,
    };

Map<String, dynamic> _turn(Map<String, dynamic> actionData) =>
    {'reply': 'تمام', 'msg_ref': 'm', 'action_data': actionData};

void main() {
  late FakeServer server;
  late _Bridge bridge;
  late SunonoChatController c;
  late List<SunonoEvent> events;

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  List<CartChangedEvent> cartEvents() => events.whereType<CartChangedEvent>().toList();

  setUp(() {
    server = FakeServer();
    bridge = _Bridge();
    events = [];
    c = SunonoChatController(
      api: SunonoApi(
        shopKey: 'pk_test',
        apiBase: 'https://api.test/api',
        appOrigin: 'https://shop.example',
        clientFactory: () => MockClient.streaming(server.handle),
      ),
      storage: MemoryStorage(),
      cartBridge: bridge,
      onIntent: (_) => true,
      recoveryChecks: const [Duration(milliseconds: 10)],
    );
    c.events.listen(events.add);
  });

  tearDown(() {
    c.dispose();
    server.close();
  });

  /// Open with the server saying the cart is linked, and wait until bound.
  Future<void> openBound() async {
    server
      ..historyCartLinked = true
      ..cartBody = {'cart': _cart(1), 'linked': true};
    await c.open();
    await server.until(() => server.count('/chat/cart') == 1 && server.count('/widget/cart-binding') == 1);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await c.send('hi');
    expect(bridge.ensures, 0, reason: 'bound: no ensure needed');
  }

  test('history cart_linked:false after being bound: the next send ensures again', () async {
    await openBound();
    server.historyCartLinked = false;
    await c.refreshHistory();
    await c.send('again');
    expect(bridge.ensures, 1);
  });

  test('/chat/cart linked:false also unbinds', () async {
    await openBound();
    server.cartBody = {'cart': null, 'linked': false};
    await c.refreshCart();
    await c.send('again');
    expect(bridge.ensures, 1);
  });

  test('a relink turn: the next send ensures', () async {
    await openBound();
    server.chatReply = _turn({'cart_relink': true});
    await c.send('one');
    expect(bridge.ensures, 0);
    server.chatReply = _turn({});
    await c.send('two');
    expect(bridge.ensures, 1);
  });

  test('after checkout() the next send ensures', () async {
    await openBound();
    c.checkout('https://shop.example/checkout');
    await c.send('thanks');
    expect(bridge.ensures, 1);
  });

  test('a stale pull started before a turn is dropped on arrival', () async {
    final gate = Completer<void>();
    server
      ..cartBody = {'cart': _cart(1), 'linked': true}
      ..beforeCartReply = () => gate.future;
    await c.open();
    final pull = c.refreshCart();
    await server.until(() => server.count('/chat/cart') == 1);
    server.chatReply = _turn({'cart_summary': _cart(2)});
    await c.send('two please');
    expect(c.cart!.count, 2);
    gate.complete();
    await pull;
    expect(c.cart!.count, 2, reason: 'the pull is older than the turn');
  });

  test('a legacy bare-array history leaves the cart alone; a cart key (even null) is the truth', () async {
    await c.open();
    server.chatReply = _turn({'cart_summary': _cart(2)});
    await c.send('x');
    server.historyBody = <Object>[];
    await c.refreshHistory();
    expect(c.cart!.count, 2);
    server.historyBody = {'messages': [], 'cart': null, 'cart_linked': false};
    await c.refreshHistory();
    expect(c.cart, isNull);
  });

  test('CartChangedEvent.fromSync: storefront-side changes only', () async {
    await c.open();
    // A turn that changes the count but did not touch the storefront.
    server.chatReply = _turn({'cart_summary': _cart(1)});
    await c.send('a');
    await pump();
    expect(cartEvents().map((e) => e.fromSync), [false]);
    // The same cart again: nothing changed, no event.
    await c.send('b');
    await pump();
    expect(cartEvents(), hasLength(1));
    // The bot mutated the storefront cart.
    server.chatReply = _turn({
      'cart_summary': _cart(2),
      'cart_sync': {'mutated': true}
    });
    await c.send('c');
    await pump();
    expect(cartEvents().last.fromSync, isTrue);
    // Live update.
    server.pushLive('cart.updated', {'cart': _cart(3)});
    await server.until(() => c.cart?.count == 3);
    await pump();
    expect(cartEvents().last.fromSync, isTrue);
    // A pull returning a different linked cart.
    server.cartBody = {'cart': _cart(4), 'linked': true};
    await c.refreshCart();
    expect(c.cart!.count, 4);
    await pump();
    expect(cartEvents().last.fromSync, isTrue);
    // A pull returning the same cart: quiet.
    final n = cartEvents().length;
    await c.refreshCart();
    await pump();
    expect(cartEvents(), hasLength(n));
  });

  test('history changes the cart: event, not from sync', () async {
    server.historyCart = _cart(2);
    await c.open();
    await server.until(() => c.cart != null);
    await pump();
    expect(cartEvents().single.fromSync, isFalse);
  });

  test('extra store lines count toward the badge and show on the cart bar', () async {
    final cart = Cart.fromJson(_cart(2, extra: {
      'extra_lines': [
        {'sku': 'X1', 'qty': 1},
        {'sku': 'X2', 'qty': 3},
      ],
    }))!;
    expect(cart.count, 6);
    expect(cart.extraLineCount, 2);
    expect(SunonoCopy.of('en').otherStoreItems(2), '+2 other store items');
    expect(SunonoCopy.of('ar').otherStoreItems(2), '+2 قطع من المتجر');
  });

  testWidgets('the cart bar names the other store items', (tester) async {
    final cart = Cart(lines: const [], distinctCount: 1, extraLines: const [ExtraLine(sku: 'X', qty: 1)]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: CartBar(cart: cart, theme: const SunonoTheme(), lang: 'en', onTap: () {})),
    ));
    expect(find.textContaining('+1 other store items'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

class _Bridge implements SunonoCartBridge {
  int ensures = 0;
  @override
  Future<Map<String, dynamic>?> probe(String userId) async => {'sig': 'p'};
  @override
  Future<Map<String, dynamic>?> ensureBind(String userId) async {
    ensures++;
    return {'sig': 'e'};
  }
}
