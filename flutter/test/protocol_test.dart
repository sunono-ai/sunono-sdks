// Conformance: every fixture in protocol/fixtures parses to its `expect`.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
    expect(c.welcome('en'), e['welcome_en_falls_back_to_ar']);
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
