import 'package:flutter/material.dart';

import '../core/controller.dart';
import '../core/format.dart';
import '../core/host.dart';
import '../core/models.dart';
import 'cards.dart';
import 'copy.dart';
import 'orb.dart';
import 'theme.dart';

/// The full assistant screen. Put it in a tab body or a route; it opens the
/// controller, follows app lifecycle (live connection off in background) and
/// renders everything the protocol sends.
class SunonoChatView extends StatefulWidget {
  const SunonoChatView({
    super.key,
    required this.controller,
    this.theme,
    this.pickImage,
    this.initialMessage,
    this.productId,
    this.productSku,
    this.showHeader = true,
    this.onClose,
  });

  final SunonoChatController controller;

  /// Defaults to [SunonoTheme.fromMaterial] of the ambient theme.
  final SunonoTheme? theme;

  /// Enables the photo button. Return an already-resized JPEG.
  final Future<SunonoImage?> Function()? pickImage;

  /// Sent once when the view opens (e.g. "Is this available in 42?").
  final String? initialMessage;

  /// Scopes [initialMessage] to a product (a card's `public_id`).
  final String? productId;

  /// Scopes [initialMessage] to a product by SKU; [productId] wins if both are set.
  final String? productSku;
  final bool showHeader;

  /// Shows a close button in the header (used by the bottom sheet).
  final VoidCallback? onClose;

  @override
  State<SunonoChatView> createState() => _SunonoChatViewState();
}

class _SunonoChatViewState extends State<SunonoChatView> with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _focus = FocusNode();
  SunonoImage? _photo;
  bool _sentInitial = false;

  SunonoChatController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _c.addListener(_onChange);
    _c.attach();
    _input.addListener(() => setState(() {}));
    // The controller may already be live (e.g. a sheet over the chat tab):
    // no change notification would come to send the initial message.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onChange());
  }

  @override
  void didUpdateWidget(SunonoChatView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller
        ..removeListener(_onChange)
        ..detach();
      widget.controller
        ..addListener(_onChange)
        ..attach();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _c.resume();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _c.suspend();
    }
  }

  void _onChange() {
    if (!_sentInitial && widget.initialMessage != null && _c.status == ChatStatus.ready && !_c.busy) {
      _sentInitial = true;
      _c.send(widget.initialMessage!, productId: widget.productId, productSku: widget.productSku);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _c
      ..removeListener(_onChange)
      ..detach();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _attach() async {
    final picked = await widget.pickImage?.call();
    if (picked != null && mounted) setState(() => _photo = picked);
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || _c.busy) return;
    _c.send(text, image: _photo);
    _input.clear();
    setState(() => _photo = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme ?? SunonoTheme.fromMaterial(Theme.of(context));
    final lang = _c.lang;
    final t = SunonoCopy.of(lang);
    final rtl = lang == 'ar';

    Widget body;
    if (_c.status == ChatStatus.disabled || _c.updateRequired) {
      body = Center(
          child: Text(_c.status == ChatStatus.disabled ? t.disabled : t.updateApp,
              textAlign: TextAlign.center, style: theme.text(color: theme.muted)));
    } else {
      final msgs = _c.messages;
      final lastBot = msgs.lastIndexWhere((m) => m.role == ChatRole.bot && m.state == MessageState.done);
      body = Column(children: [
        Expanded(
          child: msgs.isEmpty
              ? _Welcome(
                  theme: theme, text: _c.config.welcome(lang) ?? t.welcome, loading: _c.status != ChatStatus.ready)
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) {
                    final index = msgs.length - 1 - i;
                    return _MessageItem(
                      key: ValueKey(msgs[index].id),
                      message: msgs[index],
                      controller: _c,
                      theme: theme,
                      lang: lang,
                      isLatestBot: index == lastBot,
                    );
                  },
                ),
        ),
        if (_c.cart != null && _c.cart!.count > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: CartBar(cart: _c.cart!, theme: theme, lang: lang, onTap: _c.openCart),
          ),
        _Composer(
          theme: theme,
          controller: _input,
          focus: _focus,
          hint: _photo != null ? t.photoCaptionHint : t.inputHint,
          canSend: _input.text.trim().isNotEmpty && !_c.busy && _c.status == ChatStatus.ready,
          onSend: _send,
          onAttach: widget.pickImage == null ? null : _attach,
          photo: _photo,
          onRemovePhoto: () => setState(() => _photo = null),
          copy: t,
        ),
      ]);
    }

    return Directionality(
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color.alphaBlend(theme.primary.withValues(alpha: 0.07), theme.background), theme.background],
          ),
        ),
        child: SafeArea(
          top: widget.showHeader,
          child: Column(children: [
            if (widget.showHeader)
              _Header(
                theme: theme,
                title: _c.config.title(lang) ?? t.title,
                subtitle: _c.paused ? t.humanOnline : t.online,
                thinking: _c.busy,
                onClose: widget.onClose,
              ),
            Expanded(child: body),
          ]),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(
      {required this.theme, required this.title, required this.subtitle, required this.thinking, this.onClose});
  final SunonoTheme theme;
  final String title;
  final String subtitle;
  final bool thinking;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(children: [
          PresenceOrb(theme: theme, size: 40, thinking: thinking),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: theme.text(size: 17, weight: FontWeight.w700)),
              Row(children: [
                Container(width: 7, height: 7, decoration: BoxDecoration(color: theme.success, shape: BoxShape.circle)),
                const SizedBox(width: 5),
                Text(subtitle, style: theme.text(size: 12, color: theme.muted)),
              ]),
            ]),
          ),
          if (onClose != null)
            IconButton(
              onPressed: onClose,
              icon: Icon(Icons.close_rounded, color: theme.muted),
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            ),
        ]),
      );
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.theme, required this.text, required this.loading});
  final SunonoTheme theme;
  final String text;
  final bool loading;

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            PresenceOrb(theme: theme, size: 112, thinking: loading),
            const SizedBox(height: 20),
            Text(text, textAlign: TextAlign.center, style: theme.text(size: 17, weight: FontWeight.w600, height: 1.4)),
          ]),
        ),
      );
}

/// One message plus whatever rides on it (cards, checkout, chips).
class _MessageItem extends StatefulWidget {
  const _MessageItem({
    super.key,
    required this.message,
    required this.controller,
    required this.theme,
    required this.lang,
    required this.isLatestBot,
  });

  final ChatMessage message;
  final SunonoChatController controller;
  final SunonoTheme theme;
  final String lang;
  final bool isLatestBot;

  @override
  State<_MessageItem> createState() => _MessageItemState();
}

class _MessageItemState extends State<_MessageItem> with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _in.value = 1;
    } else if (!_in.isAnimating && _in.value == 0) {
      _in.forward();
    }
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _in, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.12), end: Offset.zero).animate(curve),
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: _content()),
      ),
    );
  }

  /// A card tap: the visible synthetic phrase plus the structured action.
  Future<void> _cardTap(ProductCard p, String action, String Function(String, String) phrase, String lang) => widget
      .controller
      .send(phrase(p.title(lang), lang), synthetic: true, productSku: p.sku, tap: (action: action, ref: p.publicId));

  Widget _content() {
    final m = widget.message;
    final theme = widget.theme;
    final c = widget.controller;
    final t = SunonoCopy.of(widget.lang);
    final contentLang = m.replyLang ?? widget.lang;

    if (m.role == ChatRole.system) {
      return Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration:
              BoxDecoration(color: theme.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(20)),
          child: Text(m.text == 'paused' ? t.paused : t.resumed, style: theme.text(size: 12, color: theme.muted)),
        ),
      );
    }

    if (m.role == ChatRole.user) {
      return Align(
        alignment: AlignmentDirectional.centerEnd,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (m.localImage != null || m.imageUrl != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    width: 180,
                    child: m.localImage != null
                        ? Image.memory(m.localImage!, fit: BoxFit.cover)
                        : boundedNetworkImage(context, m.imageUrl!, width: 180),
                  ),
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: theme.brandGradient,
                borderRadius: BorderRadiusDirectional.only(
                  topStart: Radius.circular(theme.radius),
                  topEnd: Radius.circular(theme.radius),
                  bottomStart: Radius.circular(theme.radius),
                  bottomEnd: const Radius.circular(6),
                ),
              ),
              child: _BubbleText(
                  text: m.text, theme: theme, color: Colors.white, uiRtl: widget.lang == 'ar', onLink: c.openUrl),
            ),
          ]),
        ),
      );
    }

    // Bot / staff.
    final children = <Widget>[];
    if (m.state == MessageState.thinking || m.state == MessageState.recovering) {
      children.add(Row(mainAxisSize: MainAxisSize.min, children: [
        PresenceOrb(theme: theme, size: 26, thinking: true),
        const SizedBox(width: 8),
        Flexible(
          child: Text(m.state == MessageState.recovering ? t.recovering : stageLabel(m.stage, widget.lang),
              style: theme.text(size: 13, color: theme.muted)),
        ),
      ]));
    } else if (m.state == MessageState.failed) {
      children.add(Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.error_outline_rounded, size: 18, color: theme.danger),
        const SizedBox(width: 6),
        Flexible(child: Text(t.error(m.errorCode), style: theme.text(size: 13, color: theme.danger))),
      ]));
      children.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: SunonoChip(
            theme: theme, label: t.retry, icon: Icons.refresh_rounded, onTap: c.busy ? null : () => c.retry(m)),
      ));
    } else {
      if (m.role == ChatRole.staff) {
        children.add(Padding(
          padding: const EdgeInsetsDirectional.only(start: 6, bottom: 3),
          child: Text(t.storeTeam, style: theme.text(size: 11, weight: FontWeight.w700, color: theme.accent)),
        ));
      }
      if (m.imageUrl != null) {
        children.add(ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(width: 200, child: boundedNetworkImage(context, m.imageUrl!, width: 200)),
        ));
      }
      if (m.text.trim().isNotEmpty) {
        children.add(Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: theme.surface,
            boxShadow: theme.glow,
            border: Border.all(color: theme.primary.withValues(alpha: m.role == ChatRole.staff ? 0.3 : 0.08)),
            borderRadius: BorderRadiusDirectional.only(
              topStart: Radius.circular(theme.radius),
              topEnd: Radius.circular(theme.radius),
              bottomEnd: Radius.circular(theme.radius),
              bottomStart: const Radius.circular(6),
            ),
          ),
          child: _BubbleText(text: sanitizeReply(m.text), theme: theme, uiRtl: widget.lang == 'ar', onLink: c.openUrl),
        ));
      }
      if (m.products.isNotEmpty) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 6),
          child: ProductCarousel(
            products: m.products,
            theme: theme,
            uiLang: widget.lang,
            lang: contentLang,
            busy: c.busy,
            addingRef: c.addingRef,
            onOpen: (p) {
              if (!c.openProduct(p)) _cardTap(p, 'product_detail', detailsPhrase, contentLang);
            },
            onAdd: (p) => _cardTap(p, 'add_to_cart', addToCartPhrase, contentLang),
            onDetails: (p) => _cardTap(p, 'product_detail', detailsPhrase, contentLang),
          ),
        ));
      }
      if (m.hasMore && widget.isLatestBot) {
        children.add(SunonoChip(
          theme: theme,
          label: t.showMore,
          icon: Icons.expand_more_rounded,
          onTap: c.busy ? null : () => c.send(showMorePhrase(widget.lang), synthetic: true),
        ));
      }
      if (m.checkout != null) {
        children
            .add(CheckoutCardView(checkout: m.checkout!, theme: theme, lang: widget.lang, contentLang: contentLang));
      }
      if (m.handoffUrl != null) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 10),
          child: HandoffButton(theme: theme, label: t.completeOrder, onTap: () => c.checkout(m.handoffUrl)),
        ));
      }
    }
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: m.products.isEmpty ? MediaQuery.sizeOf(context).width * 0.82 : double.infinity),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      ),
    );
  }
}

/// Message text with its own direction and tappable links.
class _BubbleText extends StatelessWidget {
  const _BubbleText({required this.text, required this.theme, required this.uiRtl, required this.onLink, this.color});
  final String text;
  final SunonoTheme theme;
  final bool uiRtl;
  final void Function(String url) onLink;
  final Color? color;

  static final _url = RegExp(r'https?://[^\s<>"]+');
  static final _trailing = RegExp(r'[.,;:!?)\]}»؟،؛]+$');

  @override
  Widget build(BuildContext context) {
    final style = theme.text(size: 15, height: 1.45, color: color);
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _url.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      // Prose punctuation right after a link isn't part of it («…/p؟», «(…/p)»).
      final url = m.group(0)!.replaceFirst(_trailing, '');
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: () => onLink(url),
          child: Text(url,
              textDirection: TextDirection.ltr,
              style: style.copyWith(decoration: TextDecoration.underline, color: color ?? theme.primary)),
        ),
      ));
      last = m.start + url.length;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(
      TextSpan(style: style, children: spans),
      textDirection: isRtlText(text, fallbackRtl: uiRtl) ? TextDirection.rtl : TextDirection.ltr,
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.theme,
    required this.controller,
    required this.focus,
    required this.hint,
    required this.canSend,
    required this.onSend,
    required this.onAttach,
    required this.photo,
    required this.onRemovePhoto,
    required this.copy,
  });

  final SunonoTheme theme;
  final TextEditingController controller;
  final FocusNode focus;
  final String hint;
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback? onAttach;
  final SunonoImage? photo;
  final VoidCallback onRemovePhoto;
  final SunonoCopy copy;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: theme.surface,
          borderRadius: BorderRadius.circular(28),
          boxShadow: theme.glow,
          border: Border.all(color: theme.primary.withValues(alpha: 0.12)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (photo != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Stack(clipBehavior: Clip.none, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(photo!.bytes, width: 64, height: 64, fit: BoxFit.cover),
                  ),
                  PositionedDirectional(
                    top: -8,
                    end: -8,
                    child: IconButton.filledTonal(
                      visualDensity: VisualDensity.compact,
                      iconSize: 14,
                      tooltip: copy.removePhoto,
                      onPressed: onRemovePhoto,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ]),
              ),
            ),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (onAttach != null)
              IconButton(
                onPressed: onAttach,
                tooltip: copy.attachPhoto,
                icon: Icon(Icons.add_photo_alternate_outlined, color: theme.primary),
              ),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focus,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                style: theme.text(size: 15),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: theme.text(size: 15, color: theme.muted),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
              ),
            ),
            Semantics(
              button: true,
              label: copy.send,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: canSend ? 1 : 0.4,
                child: GestureDetector(
                  onTap: canSend ? onSend : null,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(gradient: theme.brandGradient, shape: BoxShape.circle),
                    child: Icon(Icons.arrow_upward_rounded, color: Colors.white, textDirection: TextDirection.ltr),
                  ),
                ),
              ),
            ),
          ]),
        ]),
      );
}
