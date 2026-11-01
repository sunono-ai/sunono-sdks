// Typed views over the protocol v1 payloads (protocol/PROTOCOL.md §5).
// Every parser is lenient: unknown keys are ignored, missing optional keys
// become null, and a wrong-typed field never throws.

T? _as<T>(Object? v) => v is T ? v : null;

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

double? _num(Object? v) => v is num ? v.toDouble() : null;

int? _int(Object? v) => v is num ? v.toInt() : null;

Map<String, dynamic> _map(Object? v) => v is Map ? v.cast<String, dynamic>() : const <String, dynamic>{};

List<Map<String, dynamic>> _maps(Object? v) =>
    v is List ? v.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList() : const [];

/// Picks the [lang] string, falling back to the other language.
String? pickLang(String? ar, String? en, String lang) => lang == 'en' ? (en ?? ar) : (ar ?? en);

/// A flag key is "on" when present and not false (the server sends true or a dict).
bool _on(Object? v) => v != null && v != false;

bool _isHttpUrl(String? u) => u != null && (u.startsWith('https://') || u.startsWith('http://'));

class ProductOptionValue {
  const ProductOptionValue({required this.ar, required this.en, required this.inStock, required this.exists});
  final String? ar;
  final String? en;
  final bool inStock;
  final bool exists;
}

class ProductOption {
  const ProductOption({required this.nameAr, required this.nameEn, required this.values});
  final String? nameAr;
  final String? nameEn;
  final List<ProductOptionValue> values;
}

/// A product card (PROTOCOL §5.1).
class ProductCard {
  const ProductCard({
    required this.publicId,
    this.sku,
    this.titleAr,
    this.titleEn,
    this.priceJod,
    this.discountJod,
    this.priceFrom,
    this.preselectPriceJod,
    this.optionsSummary,
    this.options = const [],
    this.inStock = true,
    this.lowStockQty,
    this.imageUrls = const [],
    this.externalUrl,
    this.chips = const [],
  });

  factory ProductCard.fromJson(Map<String, dynamic> j) {
    final hasImage = j['has_image'] != false;
    final pre = _map(j['preselect_line']);
    final prePrice = _int(pre['price_fils']);
    return ProductCard(
      publicId: _str(j['public_id']) ?? '',
      sku: _str(j['sku']),
      titleAr: _str(j['title_ar']),
      titleEn: _str(j['title_en']),
      priceJod: _num(j['price_jod']),
      discountJod: _num(j['discount_jod']),
      priceFrom: _num(j['price_from']),
      preselectPriceJod: prePrice == null ? null : prePrice / 1000,
      optionsSummary: _str(j['options_summary']),
      options: [
        for (final o in _maps(j['options']))
          ProductOption(
            nameAr: _str(o['name_ar']),
            nameEn: _str(o['name_en']),
            values: [
              for (final v in _maps(o['values']))
                ProductOptionValue(
                  ar: _str(v['ar']),
                  en: _str(v['en']),
                  inStock: v['in_stock'] != false,
                  exists: v['exists'] != false,
                ),
            ],
          ),
      ],
      inStock: j['in_stock'] != false,
      lowStockQty: _int(j['low_stock_qty']),
      imageUrls:
          hasImage ? (_as<List>(j['img_urls']) ?? const []).whereType<String>().where(_isHttpUrl).toList() : const [],
      externalUrl: _isHttpUrl(_str(j['external_url'])?.trim()) ? _str(j['external_url'])!.trim() : null,
      chips: _map(j['metadata'])
          .values
          .where((v) => v is String || v is num)
          .map((v) => '$v')
          .where((v) => v.isNotEmpty)
          .take(3)
          .toList(),
    );
  }

  final String publicId;
  final String? sku;
  final String? titleAr;
  final String? titleEn;
  final double? priceJod;
  final double? discountJod;

  /// Set for a product with options: show «من X» / "From X".
  final double? priceFrom;

  /// A specific variant was named: quote its price, not [priceFrom].
  final double? preselectPriceJod;
  final String? optionsSummary;
  final List<ProductOption> options;
  final bool inStock;
  final int? lowStockQty;
  final List<String> imageUrls;
  final String? externalUrl;
  final List<String> chips;

  String title(String lang) => pickLang(titleAr, titleEn, lang) ?? '';

  /// The one-line options text: the server's Arabic summary, or (English)
  /// built from [options] — in-stock values, then sold-out ones in brackets.
  String optionsLine(String lang) {
    if (lang != 'en') return optionsSummary ?? '';
    return options
        .map((o) {
          final ok = o.values.where((v) => v.inStock).map((v) => v.en ?? v.ar).join(', ');
          final out = o.values.where((v) => !v.inStock && v.exists).map((v) => v.en ?? v.ar).join(', ');
          final bits = [if (ok.isNotEmpty) ok, if (out.isNotEmpty) '($out sold out)'].join(' ');
          return bits.isEmpty ? '' : '${o.nameEn ?? o.nameAr}: $bits';
        })
        .where((s) => s.isNotEmpty)
        .join(' · ');
  }
}

/// A cart line (PROTOCOL §5.2).
class CartLine {
  const CartLine({
    required this.productId,
    this.nameAr,
    this.nameEn,
    this.qty = 1,
    this.priceFils,
    this.subtotalFils,
    this.imageUrl,
    this.variantLabel,
    this.variantLabelEn,
  });

  factory CartLine.fromJson(Map<String, dynamic> j) => CartLine(
        productId: '${j['product_id'] ?? ''}',
        nameAr: _str(j['name_ar']),
        nameEn: _str(j['name_en']),
        qty: _int(j['qty']) ?? 1,
        priceFils: _int(j['price_fils']),
        subtotalFils: _int(j['subtotal_fils']),
        imageUrl: (_as<List>(j['img_urls']) ?? const []).whereType<String>().where(_isHttpUrl).firstOrNull,
        variantLabel: _str(j['variant_label']),
        variantLabelEn: _str(j['variant_label_en']),
      );

  final String productId;
  final String? nameAr;
  final String? nameEn;
  final int qty;
  final int? priceFils;
  final int? subtotalFils;
  final String? imageUrl;
  final String? variantLabel;
  final String? variantLabelEn;

  /// «تيشيرت — L / كحلي». Order lines may only carry Arabic labels.
  String name(String lang) {
    final n = pickLang(nameAr, nameEn, lang) ?? '';
    final label = lang == 'ar' ? variantLabel : (variantLabelEn ?? variantLabel);
    return label == null ? n : '$n — $label';
  }
}

/// A synced-cart line the catalog doesn't know (`remote.extra_lines`, PROTOCOL §5.2).
class ExtraLine {
  const ExtraLine({this.sku, this.qty = 1, this.rowTotalFils});
  final String? sku;
  final int qty;
  final int? rowTotalFils;
}

class Cart {
  const Cart({required this.lines, this.distinctCount = 0, this.totalFils, this.extraLines = const []});

  /// `null` for an empty or missing cart.
  static Cart? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    final lines = _maps(j['items']).map(CartLine.fromJson).toList();
    final extra = [
      for (final x in _maps(_map(j['remote'])['extra_lines']))
        ExtraLine(sku: _str(x['sku']), qty: _int(x['qty']) ?? 1, rowTotalFils: _int(x['row_total_fils'])),
    ];
    if (lines.isEmpty && extra.isEmpty && (_int(j['item_count']) ?? 0) == 0) return null;
    final stale = j['stale'] == true;
    return Cart(
      lines: lines,
      distinctCount: _int(j['item_count']) ?? lines.length,
      totalFils: stale ? null : _int(j['total_fils']),
      extraLines: extra,
    );
  }

  final List<CartLine> lines;
  final int distinctCount;

  /// Null when the totals are withheld (a stale synced cart): show items only.
  final int? totalFils;

  /// Storefront lines outside the catalog; they count toward [count].
  final List<ExtraLine> extraLines;
  int get extraLineCount => extraLines.length;

  /// What a shopper means by "how many things": sum of quantities.
  int get count =>
      (lines.isEmpty ? distinctCount : lines.fold(0, (s, l) => s + l.qty)) + extraLines.fold(0, (s, x) => s + x.qty);
}

class CheckoutField {
  const CheckoutField({required this.key, this.labelAr, this.labelEn, this.value, this.note});
  final String key;
  final String? labelAr;
  final String? labelEn;
  final String? value;
  final String? note;
  String label(String lang) => pickLang(labelAr, labelEn, lang) ?? key;
}

/// One of the four checkout read-backs (PROTOCOL §5.3).
sealed class Checkout {
  const Checkout();

  /// Precedence: placed > confirm > amend > collect.
  static Checkout? fromActionData(Map<String, dynamic> a) {
    Map<String, String> notes() => {
          for (final n in _maps(a['field_notes']))
            if (_str(n['key']) != null && _str(n['note']) != null) n['key'] as String: n['note'] as String,
        };
    List<CheckoutField> details() => [
          for (final d in _maps(a['details']))
            CheckoutField(
              key: _str(d['key']) ?? '',
              labelAr: _str(d['label_ar']),
              labelEn: _str(d['label_en']),
              value: d['value'] == null ? null : '${d['value']}',
              note: notes()[d['key']],
            ),
        ];
    if (_on(a['order_placed'])) {
      final o = _map(a['order']);
      final number = o['order_number'] == null ? null : '${o['order_number']}';
      return CheckoutPlaced(
        orderNumber: number == null || number.isEmpty || number == '—' ? null : number,
        lines: _maps(o['items']).map(CartLine.fromJson).toList(),
        deliveryFeeFils: _int(o['delivery_fee_fils']),
        totalFils: _int(o['total_fils']),
        savingsFils: _int(o['savings_fils']),
        serviceFeeFils: _int(o['service_fee_fils']),
        vatFils: _int(o['vat_fils']),
      );
    }
    final confirm = _on(a['order_confirm']);
    final amend = _on(a['order_amend']);
    if (confirm || amend) {
      final c = CheckoutReview(
        amend: !confirm,
        details: details(),
        totalText: _str(a['order_total_text']),
        vatText: _str(a['vat_text']),
        savingsText: _str(a['savings_text']),
        serviceFeeText: _str(a['service_fee_text']),
      );
      return c.details.isEmpty && c.totalText == null ? null : c;
    }
    if (_on(a['order_collect'])) {
      final n = notes();
      final known = _map(a['known']);
      final missing = [
        for (final f in _maps(a['missing_fields']))
          CheckoutField(
            key: _str(f['key']) ?? '',
            labelAr: _str(f['label_ar']),
            labelEn: _str(f['label_en']),
            note: n[f['key']],
          ),
      ];
      final have = [
        for (final e in known.entries)
          if (e.value != null && '${e.value}'.isNotEmpty)
            CheckoutField(key: e.key, value: '${e.value}', note: n[e.key]),
      ];
      if (missing.isEmpty && have.isEmpty) return null;
      return CheckoutCollect(known: have, missing: missing);
    }
    return null;
  }
}

class CheckoutCollect extends Checkout {
  const CheckoutCollect({required this.known, required this.missing});
  final List<CheckoutField> known;
  final List<CheckoutField> missing;
}

class CheckoutReview extends Checkout {
  const CheckoutReview({
    required this.amend,
    required this.details,
    this.totalText,
    this.vatText,
    this.savingsText,
    this.serviceFeeText,
  });
  final bool amend;
  final List<CheckoutField> details;
  final String? totalText;
  final String? vatText;
  final String? savingsText;
  final String? serviceFeeText;
}

class CheckoutPlaced extends Checkout {
  const CheckoutPlaced({
    this.orderNumber,
    this.lines = const [],
    this.deliveryFeeFils,
    this.totalFils,
    this.savingsFils,
    this.serviceFeeFils,
    this.vatFils,
  });
  final String? orderNumber;
  final List<CartLine> lines;

  /// Null = unknown, 0 = free delivery.
  final int? deliveryFeeFils;
  final int? totalFils;
  final int? savingsFils;
  final int? serviceFeeFils;
  final int? vatFils;
}

/// `action_data.order_ids` (PROTOCOL §4.1).
class OrderIds {
  const OrderIds({this.publicId, this.number, this.storeOrderId, this.source});
  final String? publicId;
  final String? number;
  final String? storeOrderId;

  /// `chat` or `storefront`.
  final String? source;
}

/// The final payload of a turn: `/chat` JSON or the `done` frame (PROTOCOL §4.1).
class TurnResult {
  const TurnResult({
    required this.reply,
    this.msgRef,
    this.products = const [],
    this.hasMore = false,
    this.cart,
    this.cartPresent = false,
    this.cartMutated = false,
    this.checkout,
    this.handoffUrl,
    this.replyLang,
    this.paused = false,
    this.blocked = false,
    this.typingHint,
    this.relink = false,
    this.orderIds,
  });

  factory TurnResult.fromJson(Map<String, dynamic> j) {
    final a = _map(j['action_data']);
    final cartRaw = a['cart_summary'] ?? a['cart'];
    final handoff = _str(_map(a['checkout_handoff'])['url']);
    final ids = _map(a['order_ids']);
    return TurnResult(
      reply: _as<String>(j['reply']) ?? '',
      msgRef: _str(j['msg_ref']),
      products: _maps(a['products']).map(ProductCard.fromJson).where((p) => p.publicId.isNotEmpty).toList(),
      hasMore: a['has_more'] == true,
      cart: Cart.fromJson(cartRaw),
      cartPresent: cartRaw is Map,
      cartMutated: _map(a['cart_sync'])['mutated'] == true,
      checkout: Checkout.fromActionData(a),
      handoffUrl: handoff != null && handoff.startsWith('https://') ? handoff : null,
      replyLang: _str(a['reply_lang']),
      paused: j['paused'] == true,
      blocked: j['blocked'] == true,
      typingHint: j['typing_hint'] is bool ? j['typing_hint'] as bool : null,
      relink: _on(a['cart_relink']),
      orderIds: ids.isEmpty
          ? null
          : OrderIds(
              publicId: _str(ids['public_id']),
              number: ids['number'] == null ? null : _str('${ids['number']}'),
              storeOrderId: ids['store_order_id'] == null ? null : _str('${ids['store_order_id']}'),
              source: _str(ids['source']),
            ),
    );
  }

  final String reply;
  final String? msgRef;
  final List<ProductCard> products;
  final bool hasMore;
  final Cart? cart;

  /// The turn carried a cart snapshot (even an empty one). Absent = unchanged.
  final bool cartPresent;

  /// The bot changed a synced storefront cart: the host should refresh.
  final bool cartMutated;
  final Checkout? checkout;
  final String? handoffUrl;
  final String? replyLang;
  final bool paused;
  final bool blocked;
  final bool? typingHint;

  /// The storefront cart link was dropped: re-bind (PROTOCOL §8).
  final bool relink;
  final OrderIds? orderIds;

  /// Paused/blocked/silenced with nothing to say: render nothing, no retry.
  bool get silent => reply.trim().isEmpty;
}

/// `/widget/config` (PROTOCOL §3).
class ShopConfig {
  const ShopConfig({
    this.enabled = true,
    this.titleAr,
    this.titleEn,
    this.welcomeAr,
    this.welcomeEn,
    this.avatarUrl,
    this.defaultLanguage = 'ar',
    this.typingHint = true,
    this.minSdkVersion,
    this.disabledReason,
  });

  factory ShopConfig.fromJson(Map<String, dynamic> j) => ShopConfig(
        enabled: j['enabled'] != false,
        titleAr: _str(j['header_title_ar']),
        titleEn: _str(j['header_title_en']),
        welcomeAr: _str(j['welcome_message_ar']),
        welcomeEn: _str(j['welcome_message_en']),
        avatarUrl: _isHttpUrl(_str(j['avatar_url'])) ? _str(j['avatar_url']) : null,
        defaultLanguage: _str(j['default_language']) == 'en' ? 'en' : 'ar',
        typingHint: j['typing_hint'] != false,
        minSdkVersion: _str(_map(j['app'])['min_sdk_version']),
        disabledReason: _str(j['reason']),
      );

  final bool enabled;
  final String? titleAr;
  final String? titleEn;
  final String? welcomeAr;
  final String? welcomeEn;
  final String? avatarUrl;
  final String defaultLanguage;
  final bool typingHint;

  /// Oldest SDK version the shop still supports (`app.min_sdk_version`).
  final String? minSdkVersion;

  /// Why `enabled` is false, e.g. `platform_disabled`.
  final String? disabledReason;

  String? title(String lang) => pickLang(titleAr, titleEn, lang);
  String? welcome(String lang) => pickLang(welcomeAr, welcomeEn, lang);
}

/// One row of `/chat/history?shape=v2`.
class HistoryRow {
  const HistoryRow({
    required this.role,
    required this.text,
    this.products = const [],
    this.hasMore = false,
    this.imageUrl,
    this.msgRef,
    this.ts,
    this.handoffUrl,
  });

  factory HistoryRow.fromJson(Map<String, dynamic> j, {String? apiOrigin}) {
    final sender = _str(j['sender']);
    final role = j['role'] == 'user'
        ? 'user'
        : sender == 'staff'
            ? 'staff'
            : 'bot';
    var image = _str(j['image']);
    if (image != null && image.startsWith('/') && apiOrigin != null) image = '$apiOrigin$image';
    final handoff = _str(_map(j['checkout_handoff'])['url']);
    return HistoryRow(
      role: role,
      text: _as<String>(j['text']) ?? '',
      products: _maps(j['products']).map(ProductCard.fromJson).where((p) => p.publicId.isNotEmpty).toList(),
      hasMore: j['has_more'] == true,
      imageUrl: _isHttpUrl(image) ? image : null,
      msgRef: _str(j['msg_ref']),
      ts: DateTime.tryParse(_as<String>(j['ts']) ?? ''),
      handoffUrl: handoff != null && handoff.startsWith('https://') ? handoff : null,
    );
  }

  /// `user`, `bot` or `staff`.
  final String role;
  final String text;
  final List<ProductCard> products;
  final bool hasMore;
  final String? imageUrl;
  final String? msgRef;
  final DateTime? ts;
  final String? handoffUrl;
}

class History {
  const History({required this.rows, this.pausedAt, this.cart, this.cartLinked = false, this.hasCartKey = true});

  factory History.fromJson(Object? raw, {String? apiOrigin}) {
    // Legacy bare-array shape is still accepted.
    final j = raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{'messages': raw};
    return History(
      rows: _maps(j['messages']).map((r) => HistoryRow.fromJson(r, apiOrigin: apiOrigin)).toList(),
      pausedAt: DateTime.tryParse(_as<String>(j['bot_paused_at']) ?? ''),
      cart: Cart.fromJson(j['cart']),
      cartLinked: j['cart_linked'] == true,
      hasCartKey: raw is Map && raw.containsKey('cart'),
    );
  }

  final List<HistoryRow> rows;
  final DateTime? pausedAt;
  final Cart? cart;
  final bool cartLinked;

  /// The response carried a `cart` key (even null = "no cart"). A legacy bare
  /// array says nothing about the cart.
  final bool hasCartKey;
}
