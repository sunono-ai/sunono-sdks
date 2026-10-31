import 'package:flutter/material.dart';

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
