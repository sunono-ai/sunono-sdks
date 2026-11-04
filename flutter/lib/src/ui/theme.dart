import 'package:flutter/material.dart';

import '../core/models.dart';

/// Colors and type for the assistant: a flat look (no gradients, no glows).
/// Start from the host's Material theme with [SunonoTheme.fromMaterial], or
/// from one brand color with [SunonoTheme.flat]; every field can be overridden.
///
/// The chat tokens ([chatBackground], [headerBackground], [botBubble],
/// [userBubble], [onUserBubble], [outline], [online], [chipOutline]) derive
/// from the base colors unless passed.
@immutable
class SunonoTheme {
  const SunonoTheme({
    this.primary = const Color(0xFF6C4BFF),
    this.accent = const Color(0xFF00C2FF),
    this.background = const Color(0xFFF7F7FB),
    this.surface = Colors.white,
    this.onSurface = const Color(0xFF1C1B22),
    this.muted = const Color(0xFF6E6B78),
    this.success = const Color(0xFF078B5B),
    this.danger = const Color(0xFFD6365C),
    this.fontFamily,
    this.fontFamilyFallback,
    this.radius = 18,
    this.onPrimary = Colors.white,
    Color? primaryText,
    Color? chatBackground,
    Color? headerBackground,
    Color? botBubble,
    Color? userBubble,
    Color? onUserBubble,
    Color? outline,
    Color? online,
    Color? chipOutline,
  })  : primaryText = primaryText ?? primary,
        _chatBackground = chatBackground,
        _headerBackground = headerBackground,
        _botBubble = botBubble,
        _userBubble = userBubble,
        _onUserBubble = onUserBubble,
        _outline = outline,
        _online = online,
        _chipOutline = chipOutline;

  /// The flat default from one brand color: white header and bot bubbles on a
  /// [primary]-tinted (6%) background, light or [dark].
  factory SunonoTheme.flat(
          {Color primary = const Color(0xFF6C4BFF),
          bool dark = false,
          String? fontFamily,
          List<String>? fontFamilyFallback}) =>
      SunonoTheme.fromConfig(ShopConfig(primaryColor: primary, colorScheme: dark ? 'dark' : null),
          fallback: SunonoTheme(fontFamily: fontFamily, fontFamilyFallback: fontFamilyFallback));

  /// Derive from the host app's theme: `primary` fills the user bubble, send
  /// and chips; `surface` is the header and bot bubbles; the chat background
  /// is `primary` at 6% over it; `outlineVariant` draws hairlines. The text
  /// theme's `fontFamily` and `fontFamilyFallback` carry over. [accent]
  /// (badges) defaults to the scheme's tertiary color.
  factory SunonoTheme.fromMaterial(ThemeData t, {Color? accent}) {
    final c = t.colorScheme;
    final dark = t.brightness == Brightness.dark;
    // Bubbles sit one step above the page in dark mode, and are the lightest
    // surface in light mode.
    final surface = dark ? c.surfaceContainerHigh : c.surfaceContainerLowest;
    final chat = Color.alphaBlend(c.primary.withValues(alpha: 0.06), dark ? c.surface : surface);
    final background = Color.alphaBlend(c.primary.withValues(alpha: 0.03), c.surface);
    return SunonoTheme(
      primary: c.primary,
      accent: accent ?? c.tertiary,
      background: background,
      surface: surface,
      onSurface: c.onSurface,
      muted: readableOn(c.onSurfaceVariant, [chat, surface]),
      // The light-mode green is 3:1 on a dark page: use the dark-mode one.
      success: dark ? const Color(0xFF3DD69A) : const Color(0xFF078B5B),
      danger: c.error,
      fontFamily: t.textTheme.bodyMedium?.fontFamily,
      fontFamilyFallback: t.textTheme.bodyMedium?.fontFamilyFallback,
      onPrimary: c.onPrimary,
      primaryText: readableOn(c.primary, [surface, chat, background]),
      chatBackground: chat,
      outline: c.outlineVariant,
    );
  }

  /// The shop's dashboard look over [fallback]: `primary_color` as [primary],
  /// and dark surfaces when `color_scheme` is `dark`. Used when the host
  /// passes no theme; anything the dashboard leaves unset keeps [fallback].
  factory SunonoTheme.fromConfig(ShopConfig config, {required SunonoTheme fallback}) {
    final primary = config.primaryColor ?? fallback.primary;
    final dark = config.colorScheme == 'dark';
    final surface = dark ? const Color(0xFF1F1D26) : fallback.surface;
    final chat = dark
        ? Color.alphaBlend(primary.withValues(alpha: 0.06), const Color(0xFF14121A))
        : config.primaryColor == null
            ? fallback.chatBackground
            : Color.alphaBlend(primary.withValues(alpha: 0.06), fallback.surface);
    // Dark bubbles sit one step above the page whatever the brand's tint
    // (#211E29 on a plain page; a light brand tints the page more).
    final botBubble = dark ? Color.alphaBlend(Colors.white.withValues(alpha: 0.06), chat) : fallback.botBubble;
    final background =
        dark ? Color.alphaBlend(primary.withValues(alpha: 0.05), const Color(0xFF131218)) : fallback.background;
    final onSurface = dark ? const Color(0xFFECEAF2) : fallback.onSurface;
    return SunonoTheme(
      primary: primary,
      onPrimary: config.primaryColor == null ? fallback.onPrimary : onColor(primary),
      primaryText: readableOn(primary, [surface, background, chat, botBubble]),
      accent: fallback.accent,
      background: background,
      surface: surface,
      onSurface: onSurface,
      muted: readableOn(dark ? const Color(0xFFA9A5B4) : fallback.muted, [chat, botBubble, surface]),
      success: dark ? const Color(0xFF3DD69A) : fallback.success,
      danger: dark ? const Color(0xFFFF7A93) : fallback.danger,
      fontFamily: fallback.fontFamily,
      fontFamilyFallback: fallback.fontFamilyFallback,
      radius: fallback.radius,
      chatBackground: chat,
      headerBackground: surface,
      botBubble: botBubble,
      outline: dark ? Color.alphaBlend(onSurface.withValues(alpha: 0.24), surface) : fallback.outline,
      online: dark ? const Color(0xFF3DD69A) : fallback.online,
    );
  }

  final Color primary;

  /// Text and icons on [primary] fills.
  final Color onPrimary;

  /// [primary] as text or an icon on [surface]/[background]: the brand color,
  /// shifted only as far as it must be to read (4.5:1).
  final Color primaryText;

  /// The second brand color, for badges (e.g. Sale).
  final Color accent;

  /// Text on [accent] fills (badges).
  Color get onAccent => onColor(accent);

  /// [accent] as text on [surface]/[background], shifted to 4.5:1.
  Color get accentText => readableOn(accent, [surface, background]);

  /// The page behind the thread before 0.3; [chatBackground] defaults to it.
  final Color background;
  final Color surface;
  final Color onSurface;
  final Color muted;
  final Color success;
  final Color danger;
  final String? fontFamily;

  /// Fonts tried after [fontFamily] (e.g. an Arabic brand font after a Latin one).
  final List<String>? fontFamilyFallback;

  /// Bubble and card corner radius; a bubble's tail corner is 4.
  final double radius;

  final Color? _chatBackground,
      _headerBackground,
      _botBubble,
      _userBubble,
      _onUserBubble,
      _outline,
      _online,
      _chipOutline;

  /// The flat page behind the thread.
  Color get chatBackground => _chatBackground ?? background;

  /// The header bar.
  Color get headerBackground => _headerBackground ?? surface;

  /// Bot and staff bubbles.
  Color get botBubble => _botBubble ?? surface;

  /// The shopper's bubble and the send button: [primary], lifted toward
  /// white (dark page) or black (light page) only as far as it must be to
  /// stand out from [chatBackground] (3:1, e.g. a black brand in dark mode).
  Color get userBubble => _userBubble ?? readableOn(primary, [chatBackground], min: 3);

  /// Text on [userBubble] (4.5:1).
  Color get onUserBubble {
    if (_onUserBubble != null) return _onUserBubble;
    final bubble = userBubble;
    return bubble == primary ? onPrimary : onColor(bubble);
  }

  /// Hairlines and borders (header bottom, composer, cards).
  Color get outline => _outline ?? Color.alphaBlend(onSurface.withValues(alpha: 0.12), surface);

  /// Whether the page is dark (the chat page, not the host chrome around it).
  bool get isDark => chatBackground.computeLuminance() < 0.5;

  /// The border of inputs and round buttons: [outline], and in dark mode
  /// lifted to 3:1 so a field's edge is visible (WCAG 1.4.11).
  Color get controlOutline => isDark ? readableOn(outline, [surface, chatBackground], min: 3) : outline;

  /// The "online" status dot.
  Color get online => _online ?? success;

  /// The border of outlined chips (quick replies, show more).
  Color get chipOutline => _chipOutline ?? primaryText;

  @Deprecated('The 0.3 design is flat: fill with userBubble or primary. Removed in 1.0.')
  LinearGradient get brandGradient => LinearGradient(
        begin: AlignmentDirectional.topStart,
        end: AlignmentDirectional.bottomEnd,
        colors: [primary, Color.lerp(primary, accent, 0.55)!],
      );

  TextStyle text({double size = 15, FontWeight weight = FontWeight.w400, Color? color, double? height}) => TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSize: size,
      fontWeight: weight,
      color: color ?? onSurface,
      height: height);

  @Deprecated('The 0.3 design has no shadows: use outline for borders. Removed in 1.0.')
  List<BoxShadow> get glow => [
        BoxShadow(color: primary.withValues(alpha: 0.10), blurRadius: 18, offset: const Offset(0, 6)),
      ];

  /// A new [primary] recomputes [onPrimary] and [primaryText] (as does a new
  /// surface or background for [primaryText]) unless they are passed too.
  SunonoTheme copyWith({
    Color? primary,
    Color? accent,
    Color? background,
    Color? surface,
    String? fontFamily,
    List<String>? fontFamilyFallback,
    Color? onPrimary,
    Color? primaryText,
    Color? chatBackground,
    Color? headerBackground,
    Color? botBubble,
    Color? userBubble,
    Color? onUserBubble,
    Color? outline,
    Color? online,
    Color? chipOutline,
  }) {
    final p = primary ?? this.primary, bg = background ?? this.background, sf = surface ?? this.surface;
    return SunonoTheme(
      primary: p,
      accent: accent ?? this.accent,
      background: bg,
      surface: sf,
      onSurface: onSurface,
      muted: muted,
      success: success,
      danger: danger,
      fontFamily: fontFamily ?? this.fontFamily,
      fontFamilyFallback: fontFamilyFallback ?? this.fontFamilyFallback,
      radius: radius,
      onPrimary: onPrimary ?? (primary == null ? this.onPrimary : onColor(p)),
      primaryText: primaryText ??
          (primary == null && background == null && surface == null ? this.primaryText : readableOn(p, [sf, bg])),
      chatBackground: chatBackground ?? _chatBackground,
      headerBackground: headerBackground ?? _headerBackground,
      botBubble: botBubble ?? _botBubble,
      userBubble: userBubble ?? _userBubble,
      onUserBubble: onUserBubble ?? _onUserBubble,
      outline: outline ?? _outline,
      online: online ?? _online,
      chipOutline: chipOutline ?? _chipOutline,
    );
  }
}

/// WCAG contrast ratio of two colors (1..21).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

/// White or near-black, whichever reads better on [fill]; pure black when
/// neither reaches 4.5:1 (a mid-tone; white or black always does).
Color onColor(Color fill) {
  const dark = Color(0xFF1C1B22);
  final white = contrastRatio(Colors.white, fill), near = contrastRatio(dark, fill);
  if (white >= 4.5 && white >= near) return Colors.white;
  if (near >= 4.5) return dark;
  return white >= contrastRatio(Colors.black, fill) ? Colors.white : Colors.black;
}

/// [color] moved toward white (dark backdrop) or black (light) just until it
/// reaches [min] (4.5:1 text; 3:1 for shapes) against every color in [on]
/// (the first decides the direction).
Color readableOn(Color color, List<Color> on, {double min = 4.5}) {
  final target = on.first.computeLuminance() < 0.5 ? Colors.white : Colors.black;
  for (var t = 0.0; t <= 1; t += 0.05) {
    final c = Color.lerp(color, target, t)!;
    if (on.every((b) => contrastRatio(c, b) >= min)) return c;
  }
  return target;
}
