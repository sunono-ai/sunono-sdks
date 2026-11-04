// Conformance: every fixture in protocol/fixtures parses to its `expect`.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sunono/src/core/api.dart';
import 'package:sunono/src/core/format.dart';
import 'package:sunono/src/core/models.dart';
import 'package:sunono/src/core/sse.dart';

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('../protocol/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

Stream<List<int>> sseBytes(String name) =>
    Stream.value(utf8.encode(File('../protocol/fixtures/$name').readAsStringSync()));

void main() {
  test('config', () {
    final f = fixture('config.json');
    final c = ShopConfig.fromJson(f['response'] as Map<String, dynamic>);
    final e = f['expect'] as Map<String, dynamic>;
    expect(c.enabled, e['enabled']);
    expect(c.title('ar'), e['title_ar']);
    expect(c.title('en'), e['title_en']);
    expect(c.welcome('ar'), e['welcome_ar']);
    expect(c.welcome('en'), e['welcome_en'], reason: 'no cross-language fallback');
    expect(c.typingHint, e['typing_hint']);
    expect(ShopConfig.fromJson(fixture('config_disabled.json')['response'] as Map<String, dynamic>).enabled, isFalse);
  });

  test('search turn', () {
    final f = fixture('turn_search.json');
    final r = TurnResult.fromJson(f['response'] as Map<String, dynamic>);
    final e = f['expect'] as Map<String, dynamic>;
    expect(sanitizeReply(r.reply), e['reply_sanitized']);
    expect(r.msgRef, e['msg_ref']);
    expect(r.products, hasLength(e['products'] as int));
    expect(r.hasMore, e['has_more']);
    expect(r.replyLang, e['reply_lang']);
    expect(r.cartPresent, e['cart_present']);
    expect(r.checkout, isNull);
    expect(r.silent, e['silent']);
    final c0 = e['card0'] as Map<String, dynamic>;
    final p0 = r.products[0];
    expect(p0.publicId, c0['public_id']);
    expect(p0.sku, c0['sku']);
    expect(p0.priceFrom, c0['price_from']);
    expect(p0.optionsLine('en'), c0['options_line_en']);
    expect(p0.chips, c0['chips']);
    expect(p0.imageUrls.first, c0['image']);
    expect(p0.externalUrl, c0['external_url']);
    final c1 = e['card1'] as Map<String, dynamic>;
    expect(r.products[1].sku, c1['sku']);
    expect(r.products[1].discountJod, c1['discount_jod']);
    expect(r.products[1].lowStockQty, c1['low_stock_qty']);
    expect(r.products[1].externalUrl, c1['external_url']);
    final c2 = e['card2'] as Map<String, dynamic>;
    expect(r.products[2].sku, c2['sku']);
    expect(r.products[2].inStock, c2['in_stock']);
    expect(r.products[2].imageUrls, hasLength(c2['images'] as int));
    expect(r.products[2].title('en'), c2['title_en']);
  });

  test('synced add turn', () {
    final f = fixture('turn_add_synced.json');
    final r = TurnResult.fromJson(f['response'] as Map<String, dynamic>);
    final e = f['expect'] as Map<String, dynamic>;
    expect(r.cartPresent, e['cart_present']);
    expect(r.cart!.count, e['cart_count']);
    expect(r.cart!.totalFils, e['cart_total_fils']);
    expect(r.cartMutated, e['cart_mutated']);
    expect(r.cart!.lines[1].name('ar'), e['line1_name_ar']);
    expect(r.cart!.lines[1].name('en'), e['line1_name_en']);
    expect(formatFils(r.cart!.totalFils, 'ar'), e['total_text_ar']);
    expect(formatFils(r.cart!.totalFils, 'en'), e['total_text_en']);
  });

  test('stale cart withholds totals', () {
    final f = fixture('turn_cart_stale.json');
    final r = TurnResult.fromJson(f['response'] as Map<String, dynamic>);
    final e = f['expect'] as Map<String, dynamic>;
    expect(r.cart!.count, e['cart_count']);
    expect(r.cart!.totalFils, e['cart_total_fils']);
  });

  test('handoff', () {
    final f = fixture('turn_handoff.json');
    final r = TurnResult.fromJson(f['response'] as Map<String, dynamic>);
    expect(r.handoffUrl, (f['expect'] as Map)['handoff_url']);
    expect(r.checkout, isNull);
  });

  test('checkout collect / confirm / placed', () {
    var f = fixture('turn_collect.json');
    var e = f['expect'] as Map<String, dynamic>;
    final collect = TurnResult.fromJson(f['response'] as Map<String, dynamic>).checkout as CheckoutCollect;
    expect(collect.known.map((k) => {'key': k.key, 'value': k.value}).toList(), e['known']);
    expect(collect.missing.map((m) => m.key).toList(), e['missing']);
    expect(collect.missing[0].note, e['missing0_note']);
    expect(collect.missing[1].label('en'), e['missing1_label_en']);

    f = fixture('turn_confirm.json');
    e = f['expect'] as Map<String, dynamic>;
    final review = TurnResult.fromJson(f['response'] as Map<String, dynamic>).checkout as CheckoutReview;
    expect(review.amend, isFalse);
    expect(review.details, hasLength(e['details'] as int));
    expect(review.totalText, e['total_text']);
    expect(review.serviceFeeText, e['service_fee_text']);
    expect(review.vatText, e['vat_text']);

    f = fixture('turn_placed.json');
    e = f['expect'] as Map<String, dynamic>;
    final placed = TurnResult.fromJson(f['response'] as Map<String, dynamic>).checkout as CheckoutPlaced;
    expect(placed.orderNumber, e['order_number']);
    expect(placed.lines, hasLength(e['lines'] as int));
    expect(placed.deliveryFeeFils, e['delivery_fee_fils']);
    expect(placed.totalFils, e['total_fils']);
  });

  test('silent turns', () {
    final paused = TurnResult.fromJson(fixture('turn_paused_silent.json')['response'] as Map<String, dynamic>);
    expect(paused.silent, isTrue);
    expect(paused.paused, isTrue);
    expect(paused.typingHint, isFalse);
    final blocked = TurnResult.fromJson(fixture('turn_blocked.json')['response'] as Map<String, dynamic>);
    expect(blocked.silent && blocked.blocked, isTrue);
    final timeout = TurnResult.fromJson(fixture('turn_timeout.json')['response'] as Map<String, dynamic>);
    expect(timeout.silent, isFalse);
    expect(timeout.products, isEmpty);
    expect(timeout.cartPresent, isFalse);
  });

  test('history v2 and legacy', () {
    final f = fixture('history_v2.json');
    final e = f['expect'] as Map<String, dynamic>;
    final h = History.fromJson(f['response'], apiOrigin: f['api_origin'] as String);
    expect(h.rows, hasLength(e['rows'] as int));
    expect(h.rows.map((r) => r.role).toList(), e['roles']);
    expect(h.rows[1].products, hasLength(e['row1_products'] as int));
    expect(h.rows[1].hasMore, e['row1_has_more']);
    expect(h.rows[2].imageUrl, e['row2_image']);
    expect(h.rows[2].handoffUrl, e['row2_handoff']);
    expect(h.pausedAt != null, e['paused']);
    expect(h.cart!.count, e['cart_count']);
    expect(h.cart!.totalFils, e['cart_total_fils']);
    expect(h.cartLinked, e['cart_linked']);

    final legacy = History.fromJson(fixture('history_legacy_array.json')['response']);
    expect(legacy.rows.single.role, 'user');
    expect(legacy.pausedAt, isNull);
  });

  test('app history v1.2: every reply row carries its action', () {
    final f = fixture('history_app.json');
    final e = f['expect'] as Map<String, dynamic>;
    final rows = History.fromJson(f['response'], apiOrigin: f['api_origin'] as String).rows;
    expect(rows, hasLength(e['rows'] as int));
    String? kind(Checkout? c) => switch (c) {
          CheckoutCollect() => 'collect',
          CheckoutReview(amend: false) => 'confirm',
          CheckoutReview() => 'amend',
          CheckoutPlaced() => 'placed',
          null => null,
        };
    expect(rows.map((r) => kind(r.checkout)).toList(), e['checkouts']);
    expect(rows.map((r) => r.orderIds?.number).toList(), e['order_ids_number']);
    expect(rows.map((r) => r.replyLang).toList(), e['reply_lang']);
    expect(rows[4].handoff?.target, e['row4_handoff_target']);
    expect(rows[4].handoffUrl, e['row4_handoff_url']);
    expect(rows[5].imageUrl, e['row5_image']);
    expect(rows[6].audio?.url, e['row6_audio_url']);
    expect(rows[6].audio?.durationMs, e['row6_audio_duration_ms']);
    expect(rows[7].products, hasLength(e['row7_products'] as int));
    expect(rows[7].hasMore, e['row7_has_more']);
    // An older server sends no `action`: rows parse as in 0.2.
    final old = History.fromJson(fixture('history_v2.json')['response']).rows;
    expect(old.map((r) => (r.checkout, r.orderIds, r.replyLang, r.audio)).toSet(), {(null, null, null, null)});
  });

  test('sse streams', () async {
    final e = fixture('sse_expect.json');
    final photo = await parseSse(sseBytes('stream_photo.sse')).toList();
    final pe = e['stream_photo.sse'] as Map<String, dynamic>;
    expect(photo, hasLength(pe['frames'] as int));
    expect(photo.where((f) => f.json?['type'] == 'stage').map((f) => f.json!['stage']).toList(), pe['stages']);
    final done = photo.last.json!;
    expect(done['msg_ref'], pe['done_msg_ref']);
    expect(TurnResult.fromJson(done).reply, pe['done_reply']);

    final live = await parseSse(sseBytes('live.sse')).toList();
    final le = e['live.sse'] as Map<String, dynamic>;
    expect(live.map((f) => f.event).toList(), le['events']);
    expect((live[1].json!['data'] as Map)['sent_by'] == 'owner', le['message_staff']);
    expect(Cart.fromJson((live[4].json!['data'] as Map)['cart'])!.count, le['cart_count']);
  });

  test('v1.1 additive fields', () {
    var f = fixture('turn_relink.json');
    expect(TurnResult.fromJson(f['response'] as Map<String, dynamic>).relink, isTrue);
    expect(TurnResult.fromJson(fixture('turn_search.json')['response'] as Map<String, dynamic>).relink, isFalse);

    f = fixture('turn_order_ids.json');
    var e = f['expect'] as Map<String, dynamic>;
    final ids = TurnResult.fromJson(f['response'] as Map<String, dynamic>).orderIds!;
    expect(ids.publicId, e['public_id']);
    expect(ids.number, e['number']);
    expect(ids.storeOrderId, e['store_order_id']);
    expect(ids.source, e['source']);
    expect(TurnResult.fromJson(fixture('turn_placed.json')['response'] as Map<String, dynamic>).orderIds, isNull);

    f = fixture('config_app.json');
    for (final k in ['min_version', 'platform_disabled']) {
      final c = f[k] as Map<String, dynamic>;
      e = c['expect'] as Map<String, dynamic>;
      final cfg = ShopConfig.fromJson(c['response'] as Map<String, dynamic>);
      expect(cfg.enabled, e['enabled'], reason: k);
      expect(cfg.minSdkVersion, e['min_sdk_version'], reason: k);
      expect(cfg.disabledReason, e['disabled_reason'], reason: k);
    }
    expect(ShopConfig.fromJson(fixture('config.json')['response'] as Map<String, dynamic>).minSdkVersion, isNull);

    f = fixture('cart_extra_lines.json');
    e = f['expect'] as Map<String, dynamic>;
    final cart = Cart.fromJson(f['response'])!;
    expect(cart.extraLineCount, e['extra_line_count']);
    expect(cart.count, e['count']);
    expect(cart.totalFils, e['total_fils']);
    final x0 = e['extra0'] as Map<String, dynamic>;
    expect(cart.extraLines[0].sku, x0['sku']);
    expect(cart.extraLines[0].qty, x0['qty']);
    expect(cart.extraLines[0].rowTotalFils, x0['row_total_fils']);
    expect(
        Cart.fromJson(fixture('turn_add_synced.json')['response']['action_data']['cart_summary'])!.extraLineCount, 0);

    expect((fixture('tap_request.json')['request'] as Map)['action'], 'add_to_cart');
  });

  test('v1.2: app checkout hands off to the host cart', () {
    final f = fixture('turn_handoff_cart.json');
    for (final k in ['unlinked', 'linked', 'site']) {
      final c = f[k] as Map<String, dynamic>;
      final e = c['expect'] as Map<String, dynamic>;
      final r = TurnResult.fromJson(c['response'] as Map<String, dynamic>);
      expect(r.handoff?.target, e['target'], reason: k);
      expect(r.handoff?.url, e['url'], reason: k);
      expect(r.checkout, isNull, reason: k);
    }
  });

  test('v1.2: unlinked app cart refusals', () {
    final f = fixture('turn_app_cart_unlinked.json');
    final add = f['add'] as Map<String, dynamic>;
    var e = add['expect'] as Map<String, dynamic>;
    var r = TurnResult.fromJson(add['response'] as Map<String, dynamic>);
    expect(r.cartUnlinked, e['cart_unlinked']);
    expect(r.products, hasLength(e['products'] as int));
    expect(r.products[0].sku, e['sku0']);
    expect(r.cartPresent, e['cart_present']);
    expect(r.handoff, e['handoff']);
    final view = f['view'] as Map<String, dynamic>;
    e = view['expect'] as Map<String, dynamic>;
    r = TurnResult.fromJson(view['response'] as Map<String, dynamic>);
    expect(r.cartUnlinked, e['cart_unlinked']);
    expect(r.products, hasLength(e['products'] as int));
    expect(r.cartPresent, e['cart_present']);
    expect(r.handoff?.target, e['handoff_target']);
    expect(TurnResult.fromJson(fixture('turn_search.json')['response'] as Map<String, dynamic>).cartUnlinked, isFalse);
  });

  test('v1.2: voice upload responses and the stream body', () async {
    final f = fixture('upload_audio.json');
    late http.Response next;
    http.BaseRequest? seen;
    String? body;
    final api = SunonoApi(
      shopKey: 'pk_test',
      apiBase: 'https://api.test/api',
      clientFactory: () => MockClient((req) async {
        seen = req;
        body = req.body;
        return next;
      }),
    );
    http.Response res(Map<String, dynamic> c) =>
        http.Response(jsonEncode(c['response']), c['status'] as int, headers: {'content-type': 'application/json'});

    final ok = f['success'] as Map<String, dynamic>;
    next = res(ok);
    final up = await api.uploadAudio('t', [1, 2, 3], mimeType: 'audio/mp4');
    final e = ok['expect'] as Map<String, dynamic>;
    expect(up.ref, e['ref']);
    expect(up.transcript, e['transcript']);
    expect(up.durationMs, e['duration_ms']);
    expect(seen!.url.path, '/api/shops/pk_test/chat/upload');
    expect(body, contains('name="audio"; filename="voice.m4a"'));

    for (final c in (f['errors'] as List).cast<Map<String, dynamic>>()) {
      next = res(c);
      await expectLater(
        api.uploadAudio('t', [1], mimeType: 'audio/mp4'),
        throwsA(isA<SunonoHttpException>()
            .having((x) => x.status, 'status', c['status'])
            .having((x) => x.code, 'code', (c['response'] as Map)['error'])),
      );
    }

    next = http.Response('data: {"type":"done","reply":"ok"}\n\n', 200);
    final want = f['stream_request'] as Map<String, dynamic>;
    await api
        .chatStream('t', want['message'] as String,
            lang: want['lang'] as String,
            audioRef: want['audio_ref'] as String,
            clientMessageId: want['client_message_id'] as String)
        .toList();
    expect(seen!.url.path, '/api/shops/pk_test/chat/stream');
    expect(jsonDecode(body!), want);
  });

  test('format rules', () {
    final f = fixture('format.json');
    for (final c in f['jod'] as List) {
      expect(formatJod(c[0] as num, c[1] as String), c[2], reason: '$c');
    }
    for (final c in f['sanitize'] as List) {
      expect(sanitizeReply(c[0] as String), c[1]);
    }
    for (final c in f['rtl'] as List) {
      expect(isRtlText(c[0] as String, fallbackRtl: c[1] as bool), c[2], reason: '$c');
    }
    expect(stageLabel('brand_new_stage', 'en'), 'Working on it...');
    expect(stageLabel('search', 'ar'), 'بدور على المنتجات…');
  });
}
