import 'package:flutter/material.dart';

import '../core/models.dart';

/// Colors and type for the assistant. Start from the host's Material theme
/// with [SunonoTheme.fromMaterial]; every field can be overridden.
@immutable
class SunonoTheme {
  const SunonoTheme({
    this.primary = const Color(0xFF6C4BFF),
    this.accent = const Color(0xFF00C2FF),
    this.background = const Color(0xFFF7F7FB),
    this.surface = Colors.white,
    this.onSurface = const Color(0xFF1C1B22),
    this.muted = const Color(0xFF75727F),
    this.success = const Color(0xFF078B5B),
    this.danger = const Color(0xFFD6365C),
    this.fontFamily,
    this.radius = 20,
    this.onPrimary = Colors.white,
    Color? primaryText,
  }) : primaryText = primaryText ?? primary;

  /// Derive from the host app's theme. [accent] defaults to the scheme's
  /// tertiary color (pass your brand's second color, e.g. gold).
  factory SunonoTheme.fromMaterial(ThemeData t, {Color? accent}) {
    final c = t.colorScheme;
    return SunonoTheme(
      primary: c.primary,
      accent: accent ?? c.tertiary,
      background: Color.alphaBlend(c.primary.withValues(alpha: 0.03), c.surface),
      surface: c.surfaceContainerLowest,
      onSurface: c.onSurface,
      muted: c.onSurfaceVariant,
      danger: c.error,
      fontFamily: t.textTheme.bodyMedium?.fontFamily,
      onPrimary: c.onPrimary,
    );
  }

  /// The shop's dashboard look over [fallback]: `primary_color` as [primary],
  /// and dark surfaces when `color_scheme` is `dark`. Used when the host
  /// passes no theme; anything the dashboard leaves unset keeps [fallback].
  factory SunonoTheme.fromConfig(ShopConfig config, {required SunonoTheme fallback}) {
    final primary = config.primaryColor ?? fallback.primary;
    final dark = config.colorScheme == 'dark';
    final surface = dark ? const Color(0xFF1F1D26) : fallback.surface;
    final background =
        dark ? Color.alphaBlend(primary.withValues(alpha: 0.05), const Color(0xFF131218)) : fallback.background;
    return SunonoTheme(
      primary: primary,
      onPrimary: config.primaryColor == null ? fallback.onPrimary : onColor(primary),
      primaryText: readableOn(primary, surface, background),
      accent: fallback.accent,
      background: background,
      surface: surface,
      onSurface: dark ? const Color(0xFFECEAF2) : fallback.onSurface,
      muted: dark ? const Color(0xFFA9A5B4) : fallback.muted,
      success: dark ? const Color(0xFF3DD69A) : fallback.success,
      danger: dark ? const Color(0xFFFF7A93) : fallback.danger,
      fontFamily: fallback.fontFamily,
      radius: fallback.radius,
    );
  }

  final Color primary;

  /// Text and icons on [primary] fills and the brand gradient.
  final Color onPrimary;

  /// [primary] as text or an icon on [surface]/[background]: the brand color,
  /// shifted only as far as it must be to read (4.5:1).
  final Color primaryText;
  final Color accent;

  /// Text on [accent] fills (badges).
  Color get onAccent => onColor(accent);

  /// [accent] as text on [surface]/[background], shifted to 4.5:1.
  Color get accentText => readableOn(accent, surface, background);
  final Color background;
  final Color surface;
  final Color onSurface;
  final Color muted;
  final Color success;
  final Color danger;
  final String? fontFamily;
  final double radius;

  LinearGradient get brandGradient => LinearGradient(
        begin: AlignmentDirectional.topStart,
        end: AlignmentDirectional.bottomEnd,
        colors: [primary, Color.lerp(primary, accent, 0.55)!],
      );

  TextStyle text({double size = 15, FontWeight weight = FontWeight.w400, Color? color, double? height}) =>
      TextStyle(fontFamily: fontFamily, fontSize: size, fontWeight: weight, color: color ?? onSurface, height: height);

  /// Soft brand glow used on cards and the composer.
  List<BoxShadow> get glow => [
        BoxShadow(color: primary.withValues(alpha: 0.10), blurRadius: 18, offset: const Offset(0, 6)),
      ];

  /// A new [primary] recomputes [onPrimary] and [primaryText] (as does a new
  /// surface or background for [primaryText]) unless they are passed too.
  SunonoTheme copyWith(
      {Color? primary,
      Color? accent,
      Color? background,
      Color? surface,
      String? fontFamily,
      Color? onPrimary,
      Color? primaryText}) {
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
      radius: radius,
      onPrimary: onPrimary ?? (primary == null ? this.onPrimary : onColor(p)),
      primaryText: primaryText ??
          (primary == null && background == null && surface == null ? this.primaryText : readableOn(p, sf, bg)),
    );
  }
}

/// WCAG contrast ratio of two colors (1..21).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

/// White or near-black, whichever reads better on [fill].
Color onColor(Color fill) {
  const dark = Color(0xFF1C1B22);
  return contrastRatio(Colors.white, fill) >= contrastRatio(dark, fill) ? Colors.white : dark;
}

/// [color] moved toward white (dark [surface]) or black (light) just until
/// it reaches 4.5:1 against [surface] and [background].
Color readableOn(Color color, Color surface, [Color? background]) {
  final target = surface.computeLuminance() < 0.5 ? Colors.white : Colors.black;
  for (var t = 0.0; t <= 1; t += 0.05) {
    final c = Color.lerp(color, target, t)!;
    if (contrastRatio(c, surface) >= 4.5 && (background == null || contrastRatio(c, background) >= 4.5)) return c;
  }
  return target;
}
