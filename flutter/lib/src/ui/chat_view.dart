import 'package:flutter/material.dart';

import '../core/controller.dart';
import '../core/format.dart';
import '../core/host.dart';
import '../core/models.dart';
import 'cards.dart';
import 'copy.dart';
import 'header.dart';
import 'theme.dart';

/// The full assistant screen. Put it in a tab body or a route; it opens the
/// controller (which then follows the app lifecycle: live connection off in
/// background), reports whether it is on screen (a hidden tab or a covered
/// route is not, so [SunonoChatController.unread] counts) and renders
/// everything the protocol sends.
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
    this.onBack,
    this.menuItems = const [],
    this.welcomeTitle,
    this.welcomeSubtitle,
    this.autofocus = false,
  });

  final SunonoChatController controller;

  /// Defaults to the shop's dashboard color and scheme
  /// ([SunonoTheme.fromConfig]) over [SunonoTheme.fromMaterial] of the ambient theme.
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

  /// Closes the bottom sheet; the header's back button calls it when there is no [onBack].
  final VoidCallback? onClose;

  /// Shows the header's back button (e.g. pop your route) when the chat is a full screen.
  final VoidCallback? onBack;

  /// Extra entries in the header's ⋮ menu, after "Talk to our team".
  final List<SunonoMenuItem> menuItems;

  /// Replaces the welcome card's title / subtitle per language, e.g. `{'ar': '…', 'en': '…'}`.
  final Map<String, String>? welcomeTitle, welcomeSubtitle;

  /// Focus the composer (and raise the keyboard) when the view opens. Off by
  /// default so switching to a Chat tab doesn't pop the keyboard.
  final bool autofocus;

  @override
  State<SunonoChatView> createState() => _SunonoChatViewState();
}

class _SunonoChatViewState extends State<SunonoChatView> {
  final _input = TextEditingController();
  final _focus = FocusNode();

  /// The shopper tapped Send on a photo with no caption: say what is missing.
  bool _needCaption = false;
  bool _sentInitial = false;
  bool _visible = false;

  SunonoChatController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChange);
    _c.attach();
    _input.addListener(() => setState(() {
          if (_input.text.trim().isNotEmpty) _needCaption = false;
        }));
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
        ..detach(this);
      widget.controller
        ..addListener(_onChange)
        ..attach();
      if (_visible) widget.controller.setVisible(this, true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A StatefulShellRoute keeps hidden tabs mounted with tickers off; a
    // route pushed on top makes this one not current.
    // ponytail: TickerMode.valuesOf needs Flutter 3.35; the floor is 3.27.
    // ignore: deprecated_member_use
    final visible = TickerMode.of(context) && ModalRoute.of(context)?.isCurrent != false;
    if (visible == _visible) return;
    _visible = visible;
    // After the frame: clearing unread notifies host badges, never mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _visible == visible) _c.setVisible(this, visible);
    });
  }

  void _onChange() {
    if (!_sentInitial && widget.initialMessage != null && _c.status == ChatStatus.ready && !_c.busy) {
      _sentInitial = true;
      // The host's message, not the composer's: it never takes or drops the shopper's photo.
      _c.send(widget.initialMessage!, productId: widget.productId, productSku: widget.productSku, withPhoto: false);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c
      ..removeListener(_onChange)
      ..detach(this);
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _attach() async {
    final picked = await widget.pickImage?.call();
    if (picked != null && mounted) {
      setState(() => _needCaption = false);
      await _c.attachPhoto(picked);
    }
  }

  void _removePhoto() {
    _c.removePhoto();
    setState(() => _needCaption = false);
  }

  void _send() {
    final text = _input.text.trim();
    if (_c.busy || _c.status != ChatStatus.ready) return;
    final photo = _c.photo.value;
    // Uploading, or failed in a way a retry can fix: wait (the error is under the preview).
    if (photo is PhotoUploading || (photo is PhotoFailed && photo.retryable)) return;
    if (photo is PhotoReady && text.isEmpty) {
      setState(() => _needCaption = true);
      return;
    }
    if (text.isEmpty) return;
    _c.send(text);
    _input.clear();
    setState(() => _needCaption = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme =
        widget.theme ?? SunonoTheme.fromConfig(_c.config, fallback: SunonoTheme.fromMaterial(Theme.of(context)));
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
      final starters = msgs.isEmpty && _c.status == ChatStatus.ready ? (_c.starterPrompts?[lang] ?? t.starters) : null;
      // The welcome is a permanent first bot bubble, not a message from the server.
      final welcome = ChatMessage(id: 'welcome', role: ChatRole.bot, text: _c.config.welcome(lang) ?? t.welcome);
      body = Column(children: [
        Expanded(
          child: ListView.builder(
            // Bottom-anchored once there are messages; an empty thread starts
            // under the header (welcome card first), like the mockup.
            reverse: msgs.isNotEmpty,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            itemCount: msgs.length + 2,
            itemBuilder: (_, row) {
              final i = msgs.isNotEmpty ? row : 1 - row; // [card, welcome] top-down when empty
              final index = msgs.length - 1 - i;
              if (index < -1) {
                return WelcomeCard(
                  theme: theme,
                  title: widget.welcomeTitle?[lang] ?? t.welcomeTitle,
                  subtitle: widget.welcomeSubtitle?[lang] ?? t.welcomeSubtitle,
                );
              }
              if (index < 0) {
                return _MessageItem(
                  key: const ValueKey('welcome'),
                  message: welcome,
                  controller: _c,
                  theme: theme,
                  lang: lang,
                  isLast: false,
                  timed: false,
                  footer: starters == null || starters.isEmpty
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Wrap(spacing: 8, runSpacing: 8, children: [
                            for (final p in starters)
                              SunonoChip(
                                  theme: theme, label: p, onTap: _c.busy ? null : () => _c.send(p, synthetic: true)),
                          ]),
                        ),
                );
              }
              return _MessageItem(
                key: ValueKey(msgs[index].id),
                message: msgs[index],
                controller: _c,
                theme: theme,
                lang: lang,
                isLast: index == msgs.length - 1,
                onClose: widget.onClose,
              );
            },
          ),
        ),
        if (_c.cart != null && _c.cart!.count > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: CartBar(
              cart: _c.cart!,
              theme: theme,
              // The line name and money follow the latest bot reply's language.
              lang: msgs.reversed.where((m) => m.role == ChatRole.bot && m.replyLang != null).firstOrNull?.replyLang ??
                  lang,
              onTap: _c.busy ? null : _c.openCart,
            ),
          ),
        ValueListenableBuilder<PhotoState>(
          valueListenable: _c.photo,
          builder: (context, photo, _) => _Composer(
            theme: theme,
            controller: _input,
            focus: _focus,
            hint: photo is PhotoIdle ? t.inputHint : t.photoCaptionHint,
            canSend: !_c.busy &&
                _c.status == ChatStatus.ready &&
                switch (photo) {
                  PhotoReady() => true, // an empty caption shows the hint instead of sending
                  PhotoUploading() => false,
                  PhotoFailed(:final retryable) => !retryable && _input.text.trim().isNotEmpty,
                  PhotoIdle() => _input.text.trim().isNotEmpty,
                },
            onSend: _send,
            onAttach: widget.pickImage == null ? null : _attach,
            photo: photo,
            image: _c.photoImage,
            needCaption: _needCaption,
            onRemovePhoto: _removePhoto,
            onRetryPhoto: _c.retryPhoto,
            copy: t,
            autofocus: widget.autofocus,
          ),
        ),
      ]);
    }

    return Directionality(
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
      child: ColoredBox(
        color: theme.chatBackground,
        child: SafeArea(
          top: false, // the header pads under the status bar on its own color
          child: Column(children: [
            if (widget.showHeader)
              ChatHeader(
                theme: theme,
                copy: t,
                title: _c.config.title(lang) ?? t.title,
                avatarUrl: _c.config.avatarUrl,
                status: _c.status == ChatStatus.disabled || _c.updateRequired
                    ? HeaderStatus.unavailable
                    : _c.paused
                        ? HeaderStatus.team
                        : HeaderStatus.online,
                onBack: widget.onBack ?? widget.onClose,
                backIsClose: widget.onBack == null,
                onTalkToTeam: _c.paused || _c.busy || _c.status != ChatStatus.ready || _c.updateRequired
                    ? null
                    : () => _c.send(t.escalatePhrase, synthetic: true),
                menuItems: widget.menuItems,
              ),
            Expanded(child: body),
          ]),
        ),
      ),
    );
  }
}

/// The assistant's flat stand-in avatar: a sparkle on a [SunonoTheme.primary]
/// tint (shown when the shop has no avatar, and beside "thinking").
class _FlatAvatar extends StatelessWidget {
  const _FlatAvatar({required this.theme, required this.size});
  final SunonoTheme theme;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
            color: Color.alphaBlend(theme.primary.withValues(alpha: 0.12), theme.surface), shape: BoxShape.circle),
        child: Icon(Icons.auto_awesome, size: size * 0.5, color: theme.primaryText),
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
    required this.isLast,
    this.timed = true,
    this.footer,
    this.onClose,
  });

  final ChatMessage message;
  final SunonoChatController controller;
  final SunonoTheme theme;
  final String lang;

  /// The last message overall: the only one that offers Show more.
  final bool isLast;

  /// Whether the time shows under the bubble (not for the welcome).
  final bool timed;

  /// Extra content under the bubble (the starter chips).
  final Widget? footer;

  /// Closes the sheet after the host takes over checkout.
  final VoidCallback? onClose;

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
    final footer = widget.footer;
    final timed = widget.timed;
    final t = SunonoCopy.of(widget.lang);
    final contentLang = m.replyLang ?? widget.lang;
    Widget time(AlignmentGeometry align) => Padding(
          padding: const EdgeInsets.only(top: 2, left: 6, right: 6),
          child: Align(
            alignment: align,
            child: Text(formatTime(m.ts, widget.lang),
                textDirection: TextDirection.ltr, style: theme.text(size: 10, color: theme.muted)),
          ),
        );

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
                child: _Zoomable(
                  label: t.viewImage,
                  onTap: () => _openLightbox(context, m, t, widget.lang),
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
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: theme.userBubble,
                borderRadius: BorderRadiusDirectional.only(
                  topStart: Radius.circular(theme.radius),
                  topEnd: Radius.circular(theme.radius),
                  bottomStart: Radius.circular(theme.radius),
                  bottomEnd: const Radius.circular(4),
                ),
              ),
              child: _BubbleText(
                  text: m.text, theme: theme, color: theme.onUserBubble, uiRtl: widget.lang == 'ar', onLink: c.openUrl),
            ),
            time(AlignmentDirectional.centerEnd),
          ]),
        ),
      );
    }

    // Bot / staff.
    final children = <Widget>[];
    if (m.state == MessageState.thinking || m.state == MessageState.recovering) {
      children.add(Row(mainAxisSize: MainAxisSize.min, children: [
        _FlatAvatar(theme: theme, size: 26),
        const SizedBox(width: 8),
        Flexible(
          child: Text(m.state == MessageState.recovering ? t.recovering : stageLabel(m.stage, widget.lang),
              style: theme.text(size: 13, color: theme.muted)),
        ),
      ]));
    } else if (m.state == MessageState.failed) {
      children.add(Semantics(
        liveRegion: true,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline_rounded, size: 18, color: theme.danger),
          const SizedBox(width: 6),
          Flexible(child: Text(t.error(m.errorCode), style: theme.text(size: 13, color: theme.danger))),
        ]),
      ));
      children.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: SunonoChip(
            theme: theme, label: t.retry, icon: Icons.refresh_rounded, onTap: c.busy ? null : () => c.retry(m)),
      ));
    } else {
      if (m.role == ChatRole.staff) {
        children.add(Padding(
          padding: const EdgeInsetsDirectional.only(start: 6, bottom: 3),
          child: Text(t.storeTeam, style: theme.text(size: 11, weight: FontWeight.w700, color: theme.accentText)),
        ));
      }
      if (m.imageUrl != null) {
        children.add(_Zoomable(
          label: t.viewImage,
          onTap: () => _openLightbox(context, m, t, widget.lang),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(width: 200, child: boundedNetworkImage(context, m.imageUrl!, width: 200)),
          ),
        ));
      }
      if (m.text.trim().isNotEmpty) {
        children.add(Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: theme.botBubble,
            border: m.role == ChatRole.staff ? Border.all(color: theme.primary.withValues(alpha: 0.3)) : null,
            borderRadius: BorderRadiusDirectional.only(
              topStart: Radius.circular(theme.radius),
              topEnd: Radius.circular(theme.radius),
              bottomEnd: Radius.circular(theme.radius),
              bottomStart: const Radius.circular(4),
            ),
          ),
          child: _BubbleText(text: sanitizeReply(m.text), theme: theme, uiRtl: widget.lang == 'ar', onLink: c.openUrl),
        ));
      }
      if (timed && (m.text.trim().isNotEmpty || m.imageUrl != null)) {
        children.add(time(AlignmentDirectional.centerStart));
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
      if (m.hasMore && m.products.isNotEmpty && widget.isLast) {
        children.add(SunonoChip(
          theme: theme,
          label: t.showMore,
          icon: Icons.expand_more_rounded,
          onTap: c.busy ? null : () => c.send(showMorePhrase(widget.lang), synthetic: true),
        ));
      }
      if (m.checkout != null) {
        children.add(
            CheckoutCardView(checkout: m.checkout!, theme: theme, lang: widget.lang, contentLang: m.replyLang ?? 'ar'));
      }
      if (m.orderIds != null) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SunonoChip(
              theme: theme,
              label: t.orderDetails,
              icon: Icons.receipt_long_rounded,
              onTap: c.busy ? null : () => c.openOrder(m.orderIds!)),
        ));
      }
      if (m.handoffUrl != null) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 10),
          child: HandoffButton(
            theme: theme,
            label: t.completeOrder(c.nativeCheckout),
            onTap: () {
              if (c.checkout(m.handoffUrl)) widget.onClose?.call();
            },
          ),
        ));
      }
      if (footer != null) children.add(footer);
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

  static final _url = RegExp(r'https://[^\s<>"]+');

  @override
  Widget build(BuildContext context) {
    final style = theme.text(size: 15, height: 1.45, color: color);
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _url.allMatches(text)) {
      // Prose punctuation right after a link isn't part of it («…/p؟», «(…/p)»).
      final url = trimLinkTail(m.group(0)!);
      // Unsafe (hidden format chars, non-ASCII host): stays plain text.
      if (!isSafeLink(url)) continue;
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: Semantics(
          container: true, // its own node: only the URL is the link, not the whole bubble
          link: true,
          child: GestureDetector(
            onTap: () => onLink(url),
            child: Text(url,
                textDirection: TextDirection.ltr,
                style: style.copyWith(decoration: TextDecoration.underline, color: color ?? theme.primaryText)),
          ),
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

/// Wraps a bubble image so a tap opens it full screen.
class _Zoomable extends StatelessWidget {
  const _Zoomable({required this.label, required this.onTap, required this.child});
  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: child));
}

void _openLightbox(BuildContext context, ChatMessage m, SunonoCopy t, String lang) {
  final image = m.localImage != null
      ? Image.memory(m.localImage!, fit: BoxFit.contain)
      : Image.network(
          m.imageUrl!,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) =>
              const Center(child: Icon(Icons.broken_image_outlined, color: Colors.white70, size: 48)),
        );
  Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => Directionality(
      textDirection: lang == 'ar' ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(children: [
          Positioned.fill(child: InteractiveViewer(minScale: 1, maxScale: 5, child: Center(child: image))),
          PositionedDirectional(
            top: 0,
            end: 0,
            child: SafeArea(
              child: Builder(
                builder: (ctx) => IconButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  tooltip: t.close,
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
              ),
            ),
          ),
        ]),
      ),
    ),
  ));
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
    required this.image,
    required this.needCaption,
    required this.onRemovePhoto,
    required this.onRetryPhoto,
    required this.copy,
    required this.autofocus,
  });

  final SunonoTheme theme;
  final bool autofocus;
  final TextEditingController controller;
  final FocusNode focus;
  final String hint;
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback? onAttach;
  final PhotoState photo;
  final SunonoImage? image;
  final bool needCaption;
  final VoidCallback onRemovePhoto;
  final VoidCallback onRetryPhoto;
  final SunonoCopy copy;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: theme.surface,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: theme.outline),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (photo is! PhotoIdle && image != null) ...[
            Align(
              alignment: AlignmentDirectional.centerStart,
              // The 6 dp margin is inside the Stack so the remove button's
              // 48 dp target (which overhangs the preview) is hit-testable.
              child: Stack(children: [
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(
                      image!.bytes,
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                      // Magic bytes pass but the pixels may not decode: still removable.
                      errorBuilder: (_, __, ___) =>
                          SizedBox(width: 64, height: 64, child: Icon(Icons.broken_image_outlined, color: theme.muted)),
                    ),
                  ),
                ),
                if (photo case PhotoUploading(:final progress))
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: ColoredBox(
                          color: Colors.black38,
                          child: Center(
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                value: progress,
                                strokeWidth: 3,
                                color: Colors.white,
                                semanticsLabel: copy.uploadingPhoto((progress * 100).round()),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                PositionedDirectional(
                  top: 0,
                  end: 0,
                  // 48 dp to touch, the same small circle to see.
                  child: Semantics(
                    button: true,
                    label: copy.removePhoto,
                    onTap: onRemovePhoto,
                    excludeSemantics: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onRemovePhoto,
                      child: SizedBox.square(
                        dimension: 48,
                        child: Align(
                          alignment: AlignmentDirectional.topEnd,
                          child: Padding(
                            padding: const EdgeInsetsDirectional.only(top: 2, end: 2),
                            child: IconButton.filledTonal(
                              visualDensity: VisualDensity.compact,
                              style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                              iconSize: 14,
                              tooltip: copy.removePhoto,
                              onPressed: onRemovePhoto,
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
            if (photo case PhotoFailed(:final code, :final retryable))
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(10, 0, 10, 4),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Semantics(
                    liveRegion: true,
                    child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
                      Text(copy.photoError(code), style: theme.text(size: 13, color: theme.danger)),
                      if (retryable) TextButton(onPressed: onRetryPhoto, child: Text(copy.retry)),
                    ]),
                  ),
                ),
              ),
            if (needCaption)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(10, 0, 10, 4),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Semantics(
                    liveRegion: true,
                    child: Text(copy.photoCaptionHint, style: theme.text(size: 13, color: theme.danger)),
                  ),
                ),
              ),
          ],
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (onAttach != null)
              IconButton(
                onPressed: onAttach,
                tooltip: copy.attachPhoto,
                icon: Icon(Icons.add_photo_alternate_outlined, color: theme.primaryText),
              ),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focus,
                autofocus: autofocus,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                style: theme.text(size: 15),
                decoration: InputDecoration(
                  hintText: hint,
                  hintMaxLines: 1, // a wrapped hint at 200% text would eat the screen
                  hintStyle: theme.text(size: 15, color: theme.muted),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
              ),
            ),
            Semantics(
              button: true,
              enabled: canSend,
              label: copy.send,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: canSend ? 1 : 0.4,
                child: GestureDetector(
                  onTap: canSend ? onSend : null,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: theme.userBubble, shape: BoxShape.circle),
                    child:
                        Icon(Icons.arrow_upward_rounded, color: theme.onUserBubble, textDirection: TextDirection.ltr),
                  ),
                ),
              ),
            ),
          ]),
        ]),
      );
}
