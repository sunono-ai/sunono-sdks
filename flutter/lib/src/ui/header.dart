import 'package:flutter/material.dart';

import 'copy.dart';
import 'theme.dart';

/// A host entry in the chat header's ⋮ menu (e.g. "Help center").
@immutable
class SunonoMenuItem {
  const SunonoMenuItem({required this.label, this.icon, required this.onTap});

  /// In the UI language: pick it from the locale you pass to the SDK.
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
}

/// What the header's status row says.
enum HeaderStatus { online, team, unavailable }

/// White bar: back, avatar, title, live status and the ⋮ menu.
class ChatHeader extends StatelessWidget {
  const ChatHeader({
    super.key,
    required this.theme,
    required this.copy,
    required this.title,
    required this.status,
    this.avatarUrl,
    this.onBack,
    this.backIsClose = false,
    this.onTalkToTeam,
    this.menuItems = const [],
  });

  final SunonoTheme theme;
  final SunonoCopy copy;
  final String title;
  final HeaderStatus status;

  /// The shop's avatar; the monogram shows while it loads or when it fails.
  final String? avatarUrl;
  final VoidCallback? onBack;

  /// [onBack] closes a sheet: the button reads "Close".
  final bool backIsClose;

  /// The built-in "Talk to our team" item; null hides it (e.g. while paused).
  final VoidCallback? onTalkToTeam;
  final List<SunonoMenuItem> menuItems;

  @override
  Widget build(BuildContext context) {
    final items = [
      if (onTalkToTeam != null)
        SunonoMenuItem(label: copy.talkToTeam, icon: Icons.headset_mic_outlined, onTap: onTalkToTeam!),
      ...menuItems,
    ];
    final dir = Directionality.of(context);
    final (statusText, dot) = switch (status) {
      HeaderStatus.online => (copy.online, theme.online),
      HeaderStatus.team => (copy.humanOnline, theme.online),
      HeaderStatus.unavailable => (copy.offline, theme.muted),
    };
    return DecoratedBox(
      decoration:
          BoxDecoration(color: theme.headerBackground, border: Border(bottom: BorderSide(color: theme.outline))),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(onBack == null ? 16 : 4, 8, 4, 8),
          child: Row(children: [
            if (onBack != null)
              IconButton(
                onPressed: onBack,
                color: theme.onSurface,
                icon: const BackButtonIcon(),
                tooltip: backIsClose ? copy.close : copy.back,
              ),
            ShopAvatar(theme: theme, title: title, url: avatarUrl, size: 44, on: theme.headerBackground),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.text(size: 17, weight: FontWeight.w700)),
                const SizedBox(height: 2),
                Row(children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(statusText,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.text(size: 13, color: theme.muted)),
                  ),
                ]),
              ]),
            ),
            if (items.isNotEmpty)
              PopupMenuButton<VoidCallback>(
                tooltip: copy.moreOptions,
                icon: Icon(Icons.more_vert_rounded, color: theme.onSurface),
                color: theme.surface,
                onSelected: (onTap) => onTap(),
                itemBuilder: (_) => [
                  for (final item in items)
                    PopupMenuItem(
                      value: item.onTap,
                      // The menu opens in the app's overlay: keep the chat's direction.
                      child: Directionality(
                        textDirection: dir,
                        child: Row(children: [
                          if (item.icon != null) ...[
                            Icon(item.icon, size: 20, color: theme.primaryText),
                            const SizedBox(width: 12),
                          ],
                          Flexible(
                              child:
                                  Text(item.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.text())),
                        ]),
                      ),
                    ),
                ],
              ),
          ]),
        ),
      ),
    );
  }
}

/// The shop's avatar ([url]), decorative. The flat monogram (the shop's
/// initial on a [SunonoTheme.primary] tint over [on]) shows while it loads,
/// when it fails, or when the shop has none. In the header and beside bot bubbles.
class ShopAvatar extends StatelessWidget {
  const ShopAvatar(
      {super.key, required this.theme, required this.title, required this.url, required this.size, required this.on});
  final SunonoTheme theme;
  final String title;
  final String? url;
  final double size;
  final Color on;

  @override
  Widget build(BuildContext context) {
    final monogram = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration:
          BoxDecoration(color: Color.alphaBlend(theme.primary.withValues(alpha: 0.12), on), shape: BoxShape.circle),
      child: ExcludeSemantics(
        child: Text(title.trim().characters.firstOrNull ?? '',
            // The circle is fixed-size: the initial doesn't scale with text.
            textScaler: TextScaler.noScaling,
            style: theme.text(size: size * 0.45, weight: FontWeight.w700, color: theme.primaryText)),
      ),
    );
    if (url == null) return monogram;
    return ClipOval(
      child: Image.network(
        url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
        excludeFromSemantics: true,
        loadingBuilder: (_, child, progress) => progress == null ? child : monogram,
        errorBuilder: (_, __, ___) => monogram,
      ),
    );
  }
}

/// The card at the top of the thread: a sparkle, a title and a subtitle.
class WelcomeCard extends StatelessWidget {
  const WelcomeCard({super.key, required this.theme, required this.title, required this.subtitle});
  final SunonoTheme theme;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 4, bottom: 12),
        padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 16, 16),
        decoration: BoxDecoration(
          color: Color.alphaBlend(theme.primary.withValues(alpha: 0.06), theme.chatBackground),
          borderRadius: BorderRadius.circular(16),
        ),
        child: IntrinsicHeight(
          child: Row(children: [
            Icon(Icons.auto_awesome, size: 28, color: theme.primaryText),
            const SizedBox(width: 16),
            Container(width: 1, margin: const EdgeInsets.symmetric(vertical: 4), color: theme.outline),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Semantics(header: true, child: Text(title, style: theme.text(size: 17, weight: FontWeight.w700))),
                const SizedBox(height: 4),
                Text(subtitle, style: theme.text(size: 14, color: theme.muted)),
              ]),
            ),
          ]),
        ),
      );
}
