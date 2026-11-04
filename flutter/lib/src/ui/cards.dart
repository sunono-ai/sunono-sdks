import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import 'copy.dart';
import 'theme.dart';

/// Horizontally scrolling product cards for one turn.
///
/// Titles, money and options follow [lang] (the turn's reply language, which
/// also sets the carousel's direction); buttons and badges follow [uiLang].
class ProductCarousel extends StatelessWidget {
  const ProductCarousel({
    super.key,
    required this.products,
    required this.theme,
    required this.lang,
    required this.uiLang,
    required this.onOpen,
    required this.onAdd,
    required this.onDetails,
    required this.busy,
    this.addingRef,
  });

  final List<ProductCard> products;
  final SunonoTheme theme;
  final String lang;
  final String uiLang;
  final void Function(ProductCard) onOpen;
  final void Function(ProductCard) onAdd;
  final void Function(ProductCard) onDetails;

  /// A turn is running: Add and Details are no-ops (the buttons keep their look).
  final bool busy;

  /// The card whose Add started that turn: only its button spins.
  final String? addingRef;

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: lang == 'en' ? TextDirection.ltr : TextDirection.rtl,
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.6,
          // Every card is as tall as the tallest one (the web's flex-stretch),
          // so Add lines up along the bottom whatever the font scale.
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsetsDirectional.only(start: 4, end: 16, top: 4, bottom: 8),
            child: IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var i = 0; i < products.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  ProductTile(
                    product: products[i],
                    theme: theme,
                    lang: lang,
                    uiLang: uiLang,
                    onOpen: () => onOpen(products[i]),
                    onAdd: () {
                      if (!busy) onAdd(products[i]);
                    },
                    onDetails: () {
                      if (!busy) onDetails(products[i]);
                    },
                    adding: addingRef == products[i].publicId,
                  ),
                ],
              ]),
            ),
          ),
        ),
      );
}

/// A remote image decoded no larger than it is shown ([width] logical px at
/// the device's pixel ratio), so a huge or hostile image can't balloon memory.
/// A failed load shows [fallback], or a neutral broken-image icon.
/// [semanticLabel] names the image for screen readers (a card's title).
Widget boundedNetworkImage(BuildContext context, String url,
        {required double width, Widget Function()? fallback, String? semanticLabel}) =>
    Image.network(
      url,
      fit: BoxFit.cover,
      semanticLabel: semanticLabel,
      cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).ceil(),
      errorBuilder: (_, __, ___) =>
          fallback?.call() ?? const SizedBox(height: 80, child: Center(child: Icon(Icons.broken_image_outlined))),
    );

/// Prices, percentages and SKUs read left to right inside Arabic text.
Widget _ltr(Widget child) => Directionality(textDirection: TextDirection.ltr, child: child);

/// A filled button's color and its text: [SunonoTheme.primary], moved only as
/// far as it must be to stand out from [on] (3:1), so a white or black brand
/// still shows a button.
(Color, Color) _filled(SunonoTheme theme, Color on) {
  final fill = readableOn(theme.primary, [on], min: 3);
  return (fill, fill == theme.primary ? theme.onPrimary : onColor(fill));
}

class ProductTile extends StatelessWidget {
  const ProductTile({
    super.key,
    required this.product,
    required this.theme,
    required this.lang,
    String? uiLang,
    required this.onOpen,
    this.onAdd,
    this.onDetails,
    this.adding = false,
  }) : uiLang = uiLang ?? lang;

  final ProductCard product;
  final SunonoTheme theme;

  /// Content language: title, money, options, chips.
  final String lang;

  /// Chrome language: buttons and badges.
  final String uiLang;
  final VoidCallback onOpen;
  final VoidCallback? onAdd;
  final VoidCallback? onDetails;

  /// This card's Add started the running turn.
  final bool adding;

  TextDirection _dir(String text) => isRtlText(text, fallbackRtl: lang != 'en') ? TextDirection.rtl : TextDirection.ltr;

  @override
  Widget build(BuildContext context) {
    final t = SunonoCopy.of(uiLang);
    final p = product;
    final title = p.title(lang);
    final image = p.imageUrls.isEmpty ? null : p.imageUrls.first;
    final price = p.shownPrice;
    final struck = p.struckPrice;
    final pct = p.salePct;
    final from = p.preselectPriceJod == null && p.priceFrom != null;
    final options = from ? p.optionsLine(lang) : '';
    final label = p.preselectPriceJod == null ? null : p.preselectLabel(lang);
    final stockBadge = !p.inStock
        ? (t.unavailable, theme.muted)
        : (p.lowStockQty ?? 0) > 0
            ? (t.lowStock(p.lowStockQty!), theme.danger)
            : null;

    return Semantics(
      button: true,
      label: title,
      child: Container(
        width: 164,
        decoration: BoxDecoration(
          color: theme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: theme.outline),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 1.15,
                child: Stack(fit: StackFit.expand, children: [
                  if (image != null)
                    boundedNetworkImage(context, image, width: 164, fallback: _noImage, semanticLabel: title)
                  else
                    _noImage(),
                  if (stockBadge != null)
                    PositionedDirectional(
                      top: 8,
                      start: 8,
                      end: 44, // clear of the details button
                      child: Align(
                          alignment: AlignmentDirectional.centerStart, child: _badge(stockBadge.$1, stockBadge.$2)),
                    ),
                  if (onDetails != null) _detailsButton(t.detailsOf(title)),
                ]),
              ),
              Expanded(
                child: Padding(
                  // No bottom padding: the Add button's 48 dp target supplies it.
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title,
                        textDirection: _dir(title),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.text(size: 13, weight: FontWeight.w600, height: 1.25)),
                    if (label != null) _note(label),
                    if (options.isNotEmpty) _note(options),
                    if (p.chips.isNotEmpty) _chips(p.chips),
                    const Spacer(),
                    Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      _ltr(Text('${from ? '${SunonoCopy.of(lang).from} ' : ''}${formatJod(price, lang)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.text(size: 14, weight: FontWeight.w700, color: theme.primaryText))),
                      if (struck != null)
                        _ltr(Text(formatJod(struck, lang),
                            maxLines: 1,
                            style: theme
                                .text(size: 11, color: theme.muted)
                                .copyWith(decoration: TextDecoration.lineThrough))),
                      if (pct != null)
                        _ltr(Text('-$pct%',
                            maxLines: 1, style: theme.text(size: 11, weight: FontWeight.w700, color: theme.danger))),
                      if (from && p.onSale) _badge(t.sale, theme.accent),
                    ]),
                    _AddButton(
                        theme: theme,
                        label: p.inStock ? t.addToCart : t.unavailable,
                        semanticLabel: '${p.inStock ? t.addToCart : t.unavailable}: $title',
                        onTap: p.inStock ? onAdd : null,
                        spinning: adding),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(text,
            textDirection: _dir(text),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.text(size: 11, color: theme.muted)),
      );

  /// Up to three metadata values; at most two rows, whatever the text scale.
  Widget _chips(List<String> chips) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Builder(builder: (context) {
          final row = MediaQuery.textScalerOf(context).scale(10) * 1.3 + 6;
          return ClipRect(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: row * 2 + 4),
              child: Wrap(spacing: 4, runSpacing: 4, children: [
                for (final c in chips.take(3))
                  Container(
                    constraints: const BoxConstraints(maxWidth: 140),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                        color: theme.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
                    child: Text(c,
                        textDirection: _dir(c),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.text(size: 10, color: theme.muted)),
                  ),
              ]),
            ),
          );
        }),
      );

  Widget _noImage() => DecoratedBox(
        decoration: BoxDecoration(color: Color.alphaBlend(theme.primary.withValues(alpha: 0.06), theme.surface)),
        child: Icon(Icons.shopping_bag_outlined, color: theme.primaryText.withValues(alpha: 0.6)),
      );

  /// Stock status sits top-start; the sale badge sits top-end.
  Widget _badge(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.text(size: 11, weight: FontWeight.w600, color: onColor(color))),
      );

  /// ⓘ on the image's top-end corner, as on the web.
  Widget _detailsButton(String label) => PositionedDirectional(
        top: 0,
        end: 0,
        child: Semantics(
          container: true,
          button: true,
          label: label,
          excludeSemantics: true,
          child: InkWell(
            onTap: onDetails,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Center(
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), shape: BoxShape.circle),
                  child: Icon(Icons.info_outline_rounded, size: 18, color: theme.primary),
                ),
              ),
            ),
          ),
        ),
      );
}

class _AddButton extends StatelessWidget {
  const _AddButton(
      {required this.theme, required this.label, required this.semanticLabel, this.onTap, this.spinning = false});
  final SunonoTheme theme;
  final String label;
  final String semanticLabel;
  final VoidCallback? onTap;
  final bool spinning;

  /// 40 dp to see, 48 dp to touch: the 4 dp above and below are the gap to
  /// the price and the card's bottom padding.
  @override
  Widget build(BuildContext context) {
    final (fill, text) = _filled(theme, theme.surface);
    return Semantics(
      container: true,
      button: true,
      enabled: onTap != null,
      label: semanticLabel,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Opacity(
            opacity: onTap == null ? 0.5 : 1,
            child: Material(
              color: Colors.transparent,
              child: Ink(
                height: 40,
                decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(20)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: onTap,
                  child: Center(
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (spinning)
                        // Reduce motion: a still glyph instead of a spinner.
                        MediaQuery.disableAnimationsOf(context)
                            ? Icon(Icons.hourglass_top_rounded, size: 16, color: text)
                            : SizedBox.square(
                                dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: text))
                      else
                        Icon(Icons.add_shopping_cart_rounded, size: 16, color: text),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.text(size: 13, weight: FontWeight.w600, color: text)),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An outlined chip on the chat page (quick replies, show more, retry, order
/// details): 48 dp tall, a leading icon, one line of text.
class SunonoChip extends StatelessWidget {
  const SunonoChip({super.key, required this.theme, required this.label, required this.onTap, this.icon});
  final SunonoTheme theme;
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;

  static const _shape = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(24)));

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: onTap != null,
        child: Material(
          color: Colors.transparent,
          shape: _shape.copyWith(side: BorderSide(color: theme.chipOutline, width: 1.5)),
          child: InkWell(
            customBorder: _shape,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: 12, end: 14),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (icon != null) ...[Icon(icon, size: 20, color: theme.primaryText), const SizedBox(width: 6)],
                  Flexible(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.text(size: 15, weight: FontWeight.w600, color: theme.primaryText)),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
}

/// The filled call-to-action that hands checkout to the host.
class HandoffButton extends StatelessWidget {
  const HandoffButton({super.key, required this.theme, required this.label, required this.onTap});
  final SunonoTheme theme;
  final String label;
  final VoidCallback onTap;

  /// On the chat page, so the user-bubble fill (stands out on any brand).
  /// The arrow follows the reading direction.
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: Material(
          color: theme.userBubble,
          borderRadius: BorderRadius.circular(24),
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(
                      child:
                          Text(label, style: theme.text(size: 15, weight: FontWeight.w700, color: theme.onUserBubble))),
                  const SizedBox(width: 8),
                  Icon(Icons.arrow_forward_rounded, size: 18, color: theme.onUserBubble),
                ]),
              ),
            ),
          ),
        ),
      );
}

/// The cart pill above the composer: the newest line (thumbnail + name), «+N»
/// for every other unit, the total unless the sync withheld it. [onTap] null =
/// disabled (a turn is running).
class CartBar extends StatelessWidget {
  const CartBar({super.key, required this.cart, required this.theme, required this.lang, required this.onTap});
  final Cart cart;
  final SunonoTheme theme;
  final String lang;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = SunonoCopy.of(lang);
    final last = cart.lines.isEmpty ? null : cart.lines.last;
    final name = last == null ? t.cart : last.name(lang);
    // Web CartCard: every unit but the featured one (a store-only cart has none).
    final more = last == null ? cart.count : cart.count - 1;
    final thumb = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(color: theme.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: last?.imageUrl == null
          ? Icon(Icons.shopping_cart_outlined, size: 18, color: theme.primaryText)
          : boundedNetworkImage(context, last!.imageUrl!,
              width: 32, fallback: () => Icon(Icons.shopping_cart_outlined, size: 18, color: theme.primaryText)),
    );
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: Opacity(
        opacity: onTap == null ? 0.6 : 1,
        child: Material(
          color: theme.surface,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: theme.outline),
              ),
              child: LayoutBuilder(
                  builder: (context, box) => Row(children: [
                        thumb,
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.text(size: 13, weight: FontWeight.w700)),
                        ),
                        if (more > 0) ...[
                          const SizedBox(width: 8),
                          _ltr(
                              Text('+$more', style: theme.text(size: 12, weight: FontWeight.w700, color: theme.muted))),
                        ],
                        // Its own width (at most 40%): the name gives way, the total
                        // stays pinned to the end instead of floating mid-bar.
                        if (cart.totalFils != null) ...[
                          const SizedBox(width: 8),
                          ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: box.maxWidth * 0.4),
                            child: _ltr(Text(formatFils(cart.totalFils, lang),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.text(size: 13, weight: FontWeight.w700, color: theme.primaryText))),
                          ),
                        ],
                        const SizedBox(width: 4),
                        Icon(Icons.chevron_right_rounded,
                            size: 18, color: theme.muted, textDirection: Directionality.of(context)),
                      ])),
            ),
          ),
        ),
      ),
    );
  }
}

/// Read-back for the in-chat checkout (PROTOCOL §5.3). Not a form: the
/// shopper answers in the chat.
class CheckoutCardView extends StatelessWidget {
  const CheckoutCardView(
      {super.key, required this.checkout, required this.theme, required this.lang, required this.contentLang});
  final Checkout checkout;
  final SunonoTheme theme;
  final String lang;
  final String contentLang;

  @override
  Widget build(BuildContext context) {
    final t = SunonoCopy.of(lang);
    final rows = <Widget>[];
    String title;
    switch (checkout) {
      case CheckoutCollect(:final known, :final missing):
        title = t.collectTitle;
        // Known: the value alone (the shopper just said it); missing: what's left.
        for (final f in known) {
          rows.add(_known(f.value ?? ''));
        }
        for (final f in missing) {
          rows.add(_row(f.label(contentLang), t.pending, note: f.note, pending: true));
        }
      case CheckoutReview(
          :final amend,
          :final details,
          :final totalText,
          :final vatText,
          :final savingsText,
          :final serviceFeeText
        ):
        title = amend ? t.amendTitle : t.confirmTitle;
        for (final d in details) {
          rows.add(_row(d.label(contentLang), d.value ?? '', note: amend ? d.note : null));
        }
        if (savingsText != null) rows.add(_row(t.savings, savingsText, accent: true, money: true));
        if (totalText != null) {
          rows.add(_total(t.total, totalText));
          if (serviceFeeText != null) rows.add(_small(t.serviceFeeIncluded(serviceFeeText)));
          if (vatText != null) rows.add(_small(t.vatIncluded(vatText)));
        }
      case final CheckoutPlaced p:
        title = t.placedTitle;
        if (p.orderNumber != null) rows.add(_row(t.orderNumber, p.orderNumber!));
        for (final l in p.lines) {
          // «× 2» is isolated and glued to the name: it never flips or wraps apart.
          rows.add(_row(
              '${l.name(contentLang)}\u00A0\u2066×\u00A0${l.qty}\u2069', formatFils(l.subtotalFils ?? 0, contentLang),
              money: true));
        }
        if (p.deliveryFeeFils != null) {
          rows.add(_row(
              t.delivery, p.deliveryFeeFils == 0 ? t.freeDelivery : formatFils(p.deliveryFeeFils, contentLang),
              accent: p.deliveryFeeFils == 0, money: p.deliveryFeeFils != 0));
        }
        if ((p.savingsFils ?? 0) > 0) {
          rows.add(_row(t.savings, formatFils(p.savingsFils, contentLang), accent: true, money: true));
        }
        if (p.totalFils != null) rows.add(_total(t.total, formatFils(p.totalFils, contentLang)));
        if ((p.serviceFeeFils ?? 0) > 0) {
          rows.add(_small(t.serviceFeeIncluded(formatFils(p.serviceFeeFils, contentLang))));
        }
        if ((p.vatFils ?? 0) > 0) rows.add(_small(t.vatIncluded(formatFils(p.vatFils, contentLang))));
    }
    final placed = checkout is CheckoutPlaced;
    final c = checkout;
    final amending = c is CheckoutReview && c.amend;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: placed ? theme.success.withValues(alpha: 0.4) : theme.outline),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(
              placed
                  ? Icons.check_circle_rounded
                  : amending
                      ? Icons.edit_outlined
                      : Icons.receipt_long_rounded,
              size: 18,
              color: placed ? theme.success : theme.primaryText),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: theme.text(size: 14, weight: FontWeight.w700))),
        ]),
        const SizedBox(height: 8),
        ...rows,
      ]),
    );
  }

  /// A value in its own direction: a phone, order number, email or Latin
  /// address stays left to right in an Arabic card (`+962…`, not `…962+`).
  /// [money] is always isolated, like the product cards' prices («12.5 د.أ»).
  /// [end] aligns it to the card's end side (else its start side).
  Widget _value(String value, TextStyle style, {bool end = true, bool money = false}) {
    if (!money && isRtlText(value, fallbackRtl: false)) {
      return Text(value, textAlign: end ? TextAlign.end : TextAlign.start, style: style);
    }
    return Builder(builder: (context) {
      final rtlCard = Directionality.of(context) == TextDirection.rtl;
      return _ltr(Text(value, textAlign: rtlCard == end ? TextAlign.left : TextAlign.right, style: style));
    });
  }

  Widget _known(String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.check_rounded, size: 15, color: theme.success),
          const SizedBox(width: 6),
          Expanded(child: _value(value, theme.text(size: 13, weight: FontWeight.w600), end: false)),
        ]),
      );

  Widget _row(String label, String value,
          {String? note, bool pending = false, bool accent = false, bool money = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (pending) ...[
              Icon(Icons.radio_button_unchecked_rounded, size: 14, color: theme.muted),
              const SizedBox(width: 6),
            ],
            Expanded(child: Text(label, style: theme.text(size: 13, color: theme.muted))),
            const SizedBox(width: 12),
            Expanded(
              child: _value(
                  value,
                  theme.text(
                      size: 13,
                      weight: FontWeight.w600,
                      color: pending ? theme.muted : (accent ? theme.success : theme.onSurface)),
                  money: money),
            ),
          ]),
          if (note != null) Text(note, style: theme.text(size: 12, color: theme.accentText)),
        ]),
      );

  Widget _total(String label, String value) => Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.only(top: 8),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: theme.outline))),
        child: Row(children: [
          Expanded(child: Text(label, style: theme.text(size: 14, weight: FontWeight.w700))),
          const SizedBox(width: 8),
          Expanded(
              child:
                  _value(value, theme.text(size: 15, weight: FontWeight.w800, color: theme.primaryText), money: true)),
        ]),
      );

  Widget _small(String text) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(text, textAlign: TextAlign.end, style: theme.text(size: 11, color: theme.muted)),
      );
}
