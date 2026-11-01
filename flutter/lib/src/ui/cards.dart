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
          child: Builder(builder: (context) {
            // Image + padding are fixed; the text block grows with the font.
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            return SizedBox(
              height: 232 + 140 * scale,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsetsDirectional.only(start: 4, end: 16, top: 4, bottom: 8),
                itemCount: products.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (_, i) {
                  final p = products[i];
                  return ProductTile(
                    product: p,
                    theme: theme,
                    lang: lang,
                    uiLang: uiLang,
                    onOpen: () => onOpen(p),
                    onAdd: () {
                      if (!busy) onAdd(p);
                    },
                    onDetails: () {
                      if (!busy) onDetails(p);
                    },
                    adding: addingRef == p.publicId,
                  );
                },
              ),
            );
          }),
        ),
      );
}

/// A remote image decoded no larger than it is shown ([width] logical px at
/// the device's pixel ratio), so a huge or hostile image can't balloon memory.
/// A failed load shows [fallback], or a neutral broken-image icon.
Widget boundedNetworkImage(BuildContext context, String url, {required double width, Widget Function()? fallback}) =>
    Image.network(
      url,
      fit: BoxFit.cover,
      cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).ceil(),
      errorBuilder: (_, __, ___) =>
          fallback?.call() ?? const SizedBox(height: 80, child: Center(child: Icon(Icons.broken_image_outlined))),
    );

/// Prices, percentages and SKUs read left to right inside Arabic text.
Widget _ltr(Widget child) => Directionality(textDirection: TextDirection.ltr, child: child);

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
        : p.lowStockQty != null
            ? (t.lowStock(p.lowStockQty!), theme.danger)
            : null;

    return Semantics(
      button: true,
      label: title,
      child: Container(
        width: 164,
        decoration: BoxDecoration(
          color: theme.surface,
          borderRadius: BorderRadius.circular(theme.radius - 4),
          boxShadow: theme.glow,
          border: Border.all(color: theme.primary.withValues(alpha: 0.08)),
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
                    boundedNetworkImage(context, image, width: 164, fallback: _noImage)
                  else
                    _noImage(),
                  if (stockBadge != null || (from && p.onSale))
                    PositionedDirectional(
                      top: 8,
                      start: 8,
                      end: 8,
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (stockBadge != null) Flexible(child: _badge(stockBadge.$1, stockBadge.$2)),
                        const Spacer(),
                        if (from && p.onSale) Flexible(child: _badge(t.sale, theme.accent)),
                      ]),
                    ),
                  if (onDetails != null) _detailsButton(t.detailsOf(title)),
                ]),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
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
                          style: theme.text(size: 14, weight: FontWeight.w700, color: theme.primary))),
                      if (struck != null)
                        _ltr(Text(formatJod(struck, lang),
                            maxLines: 1,
                            style: theme
                                .text(size: 11, color: theme.muted)
                                .copyWith(decoration: TextDecoration.lineThrough))),
                      if (pct != null)
                        _ltr(Text('-$pct%',
                            maxLines: 1, style: theme.text(size: 11, weight: FontWeight.w700, color: theme.danger))),
                    ]),
                    const SizedBox(height: 6),
                    _AddButton(
                        theme: theme,
                        label: p.inStock ? t.addToCart : t.unavailable,
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
        decoration: BoxDecoration(gradient: theme.brandGradient.scale(0.15)),
        child: Icon(Icons.shopping_bag_outlined, color: theme.primary.withValues(alpha: 0.5)),
      );

  /// Stock status sits top-start; the sale badge sits top-end.
  Widget _badge(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.text(size: 11, weight: FontWeight.w600, color: Colors.white)),
      );

  /// ⓘ on the image's bottom-end corner (the badges own the top).
  Widget _detailsButton(String label) => PositionedDirectional(
        bottom: 0,
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
  const _AddButton({required this.theme, required this.label, this.onTap, this.spinning = false});
  final SunonoTheme theme;
  final String label;
  final VoidCallback? onTap;
  final bool spinning;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Material(
          color: Colors.transparent,
          child: Ink(
            height: 32,
            decoration: BoxDecoration(gradient: theme.brandGradient, borderRadius: BorderRadius.circular(16)),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onTap,
              child: Center(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (spinning)
                    // Reduce motion: a still glyph instead of a spinner.
                    MediaQuery.disableAnimationsOf(context)
                        ? const Icon(Icons.hourglass_top_rounded, size: 15, color: Colors.white)
                        : const SizedBox.square(
                            dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  else
                    const Icon(Icons.add_shopping_cart_rounded, size: 15, color: Colors.white),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.text(size: 12, weight: FontWeight.w600, color: Colors.white)),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
}

/// A rounded outline chip (show more, retry, starter prompts).
class SunonoChip extends StatelessWidget {
  const SunonoChip({super.key, required this.theme, required this.label, required this.onTap, this.icon});
  final SunonoTheme theme;
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Material(
        color: theme.surface,
        shape: StadiumBorder(side: BorderSide(color: theme.primary.withValues(alpha: 0.35))),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[Icon(icon, size: 16, color: theme.primary), const SizedBox(width: 6)],
              Flexible(child: Text(label, style: theme.text(size: 13, weight: FontWeight.w600, color: theme.primary))),
            ]),
          ),
        ),
      );
}

/// The gradient call-to-action that hands checkout to the host.
class HandoffButton extends StatelessWidget {
  const HandoffButton({super.key, required this.theme, required this.label, required this.onTap});
  final SunonoTheme theme;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            gradient: theme.brandGradient,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(color: theme.primary.withValues(alpha: 0.3), blurRadius: 16, offset: const Offset(0, 6))
            ],
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(child: Text(label, style: theme.text(size: 14, weight: FontWeight.w700, color: Colors.white))),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_forward_rounded, size: 18, color: Colors.white),
              ]),
            ),
          ),
        ),
      );
}

/// The cart pill above the composer.
class CartBar extends StatelessWidget {
  const CartBar({super.key, required this.cart, required this.theme, required this.lang, required this.onTap});
  final Cart cart;
  final SunonoTheme theme;
  final String lang;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = SunonoCopy.of(lang);
    return Semantics(
      button: true,
      child: Material(
        color: theme.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.primary.withValues(alpha: 0.15)),
            ),
            child: Row(children: [
              Icon(Icons.shopping_cart_outlined, size: 18, color: theme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: t.cart, style: theme.text(size: 13, weight: FontWeight.w700)),
                    // The two numbers add up to the badge (cart.count).
                    if (cart.count > cart.extraQty)
                      TextSpan(
                          text: '  · ${t.items(cart.count - cart.extraQty)}',
                          style: theme.text(size: 13, color: theme.muted)),
                    if (cart.extraQty > 0)
                      TextSpan(
                          text: '  ${t.otherStoreItems(cart.extraQty)}',
                          style: theme.text(size: 12, color: theme.muted)),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (cart.totalFils != null)
                Flexible(
                  child: Text(formatFils(cart.totalFils, lang),
                      textAlign: TextAlign.end,
                      style: theme.text(size: 13, weight: FontWeight.w700, color: theme.primary)),
                ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: theme.muted, textDirection: Directionality.of(context)),
            ]),
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
        for (final f in known) {
          rows.add(_row(f.label(contentLang), f.value ?? '', note: f.note, done: true));
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
          rows.add(_row(d.label(contentLang), d.value ?? '', note: d.note));
        }
        if (savingsText != null) rows.add(_row(t.savings, savingsText, accent: true));
        if (totalText != null) {
          rows.add(_total(t.total, totalText));
          if (serviceFeeText != null) rows.add(_small(t.serviceFeeIncluded(serviceFeeText)));
          if (vatText != null) rows.add(_small(t.vatIncluded(vatText)));
        }
      case final CheckoutPlaced p:
        title = t.placedTitle;
        if (p.orderNumber != null) rows.add(_row(t.orderNumber, p.orderNumber!));
        for (final l in p.lines) {
          rows.add(_row('${l.name(contentLang)} × ${l.qty}', formatFils(l.subtotalFils ?? 0, contentLang)));
        }
        if (p.deliveryFeeFils != null) {
          rows.add(_row(
              t.delivery, p.deliveryFeeFils == 0 ? t.freeDelivery : formatFils(p.deliveryFeeFils, contentLang),
              accent: p.deliveryFeeFils == 0));
        }
        if ((p.savingsFils ?? 0) > 0) rows.add(_row(t.savings, formatFils(p.savingsFils, contentLang), accent: true));
        if (p.totalFils != null) rows.add(_total(t.total, formatFils(p.totalFils, contentLang)));
        if ((p.serviceFeeFils ?? 0) > 0) {
          rows.add(_small(t.serviceFeeIncluded(formatFils(p.serviceFeeFils, contentLang))));
        }
        if ((p.vatFils ?? 0) > 0) rows.add(_small(t.vatIncluded(formatFils(p.vatFils, contentLang))));
    }
    final placed = checkout is CheckoutPlaced;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.surface,
        borderRadius: BorderRadius.circular(theme.radius - 4),
        boxShadow: theme.glow,
        border: Border.all(color: (placed ? theme.success : theme.primary).withValues(alpha: 0.25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(placed ? Icons.check_circle_rounded : Icons.receipt_long_rounded,
              size: 18, color: placed ? theme.success : theme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: theme.text(size: 14, weight: FontWeight.w700))),
        ]),
        const SizedBox(height: 8),
        ...rows,
      ]),
    );
  }

  Widget _row(String label, String value,
          {String? note, bool done = false, bool pending = false, bool accent = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (done) Icon(Icons.check_rounded, size: 15, color: theme.success),
            if (pending) Icon(Icons.radio_button_unchecked_rounded, size: 14, color: theme.muted),
            if (done || pending) const SizedBox(width: 6),
            Expanded(child: Text(label, style: theme.text(size: 13, color: theme.muted))),
            const SizedBox(width: 12),
            Flexible(
              child: Text(value,
                  textAlign: TextAlign.end,
                  style: theme.text(
                      size: 13,
                      weight: FontWeight.w600,
                      color: pending ? theme.muted : (accent ? theme.success : theme.onSurface))),
            ),
          ]),
          if (note != null) Text(note, style: theme.text(size: 11, color: theme.accent)),
        ]),
      );

  Widget _total(String label, String value) => Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.only(top: 8),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: theme.primary.withValues(alpha: 0.12)))),
        child: Row(children: [
          Expanded(child: Text(label, style: theme.text(size: 14, weight: FontWeight.w700))),
          const SizedBox(width: 8),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.end, style: theme.text(size: 15, weight: FontWeight.w800, color: theme.primary)),
          ),
        ]),
      );

  Widget _small(String text) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(text, textAlign: TextAlign.end, style: theme.text(size: 11, color: theme.muted)),
      );
}
