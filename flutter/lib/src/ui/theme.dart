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
    this.danger = const Color(0xFFD83A5F),
    this.fontFamily,
    this.radius = 20,
  });

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
    );
  }

  /// The shop's dashboard look over [fallback]: `primary_color` as [primary],
  /// and dark surfaces when `color_scheme` is `dark`. Used when the host
  /// passes no theme; anything the dashboard leaves unset keeps [fallback].
  factory SunonoTheme.fromConfig(ShopConfig config, {required SunonoTheme fallback}) {
    final primary = config.primaryColor ?? fallback.primary;
    final dark = config.colorScheme == 'dark';
    return SunonoTheme(
      primary: primary,
      accent: fallback.accent,
      background:
          dark ? Color.alphaBlend(primary.withValues(alpha: 0.05), const Color(0xFF131218)) : fallback.background,
      surface: dark ? const Color(0xFF1F1D26) : fallback.surface,
      onSurface: dark ? const Color(0xFFECEAF2) : fallback.onSurface,
      muted: dark ? const Color(0xFFA9A5B4) : fallback.muted,
      success: dark ? const Color(0xFF3DD69A) : fallback.success,
      danger: dark ? const Color(0xFFFF7A93) : fallback.danger,
      fontFamily: fallback.fontFamily,
      radius: fallback.radius,
    );
  }

  final Color primary;
  final Color accent;
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

  SunonoTheme copyWith({Color? primary, Color? accent, Color? background, Color? surface, String? fontFamily}) =>
      SunonoTheme(
        primary: primary ?? this.primary,
        accent: accent ?? this.accent,
        background: background ?? this.background,
        surface: surface ?? this.surface,
        onSurface: onSurface,
        muted: muted,
        success: success,
        danger: danger,
        fontFamily: fontFamily ?? this.fontFamily,
        radius: radius,
      );
}
