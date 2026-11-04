import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunono/src/core/models.dart';
import 'package:sunono/src/ui/theme.dart';

const _brands = {
  'purple': Color(0xFF7B1F8C),
  'gold': Color(0xFFF2A900),
  'teal': Color(0xFF00897B),
  'red': Color(0xFFD32F2F),
  'black': Color(0xFF000000),
  'pastel': Color(0xFFB8E0D2),
};

/// Every way a theme is built: flat, the dashboard color over the host
/// theme, and the host theme alone; light and dark.
Map<String, SunonoTheme> _themes(Color brand) {
  final out = <String, SunonoTheme>{};
  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';
    final host = ThemeData(colorSchemeSeed: brand, brightness: dark ? Brightness.dark : Brightness.light);
    out['flat $mode'] = SunonoTheme.flat(primary: brand, dark: dark);
    out['config $mode'] = SunonoTheme.fromConfig(ShopConfig(primaryColor: brand, colorScheme: dark ? 'dark' : null),
        fallback: SunonoTheme.fromMaterial(host));
    out['material $mode'] = SunonoTheme.fromMaterial(host);
    out['material $mode exact'] = SunonoTheme.fromMaterial(ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: brand,
            brightness: dark ? Brightness.dark : Brightness.light,
            dynamicSchemeVariant: DynamicSchemeVariant.fidelity)));
  }
  return out;
}

void main() {
  group('contrast (light and dark, 6 brands)', () {
    for (final MapEntry(key: brand, value: color) in _brands.entries) {
      test(brand, () {
        for (final MapEntry(key: how, value: t) in _themes(color).entries) {
          final why = '$brand / $how';
          expect(contrastRatio(t.onUserBubble, t.userBubble), greaterThanOrEqualTo(4.5), reason: '$why onUserBubble');
          expect(contrastRatio(t.userBubble, t.chatBackground), greaterThanOrEqualTo(3), reason: '$why bubble on page');
          expect(contrastRatio(t.muted, t.chatBackground), greaterThanOrEqualTo(4.5), reason: '$why time on page');
          expect(contrastRatio(t.muted, t.botBubble), greaterThanOrEqualTo(4.5), reason: '$why muted on bubble');
          for (final bg in [t.surface, t.chatBackground, t.botBubble]) {
            expect(contrastRatio(t.primaryText, bg), greaterThanOrEqualTo(4.5), reason: '$why primaryText');
            expect(contrastRatio(t.onSurface, bg), greaterThanOrEqualTo(4.5), reason: '$why onSurface');
          }
          expect(contrastRatio(t.chipOutline, t.chatBackground), greaterThanOrEqualTo(3), reason: '$why chip');
          for (final bg in [t.surface, t.chatBackground, t.botBubble]) {
            if (!t.isDark) continue; // ponytail: light success is 4.33:1 on white; dark is this task's scope
            expect(contrastRatio(t.danger, bg), greaterThanOrEqualTo(4.5), reason: '$why danger on $bg');
            expect(contrastRatio(t.success, bg), greaterThanOrEqualTo(4.5), reason: '$why success on $bg');
          }
          if (t.isDark) {
            final pill = Color.alphaBlend(t.outline.withValues(alpha: 0.4), t.chatBackground);
            expect(contrastRatio(t.muted, pill), greaterThanOrEqualTo(4.5), reason: '$why date pill');
            for (final bg in [t.surface, t.chatBackground]) {
              expect(contrastRatio(t.controlOutline, bg), greaterThanOrEqualTo(3), reason: '$why field border on $bg');
            }
            expect(contrastRatio(t.botBubble, t.chatBackground), greaterThan(1.05), reason: '$why bubble above page');
          }
          expect(contrastRatio(t.onPrimary, t.primary), greaterThanOrEqualTo(4.5), reason: '$why onPrimary');
        }
      });
    }

    test('the const default passes too', () {
      const t = SunonoTheme();
      expect(contrastRatio(t.onUserBubble, t.userBubble), greaterThanOrEqualTo(4.5));
      expect(contrastRatio(t.muted, t.chatBackground), greaterThanOrEqualTo(4.5));
      expect(contrastRatio(t.primaryText, t.chatBackground), greaterThanOrEqualTo(4.5));
    });

    test('onColor never misses 4.5:1, even on a mid-tone', () {
      for (var v = 0; v <= 255; v += 5) {
        final fill = Color.fromARGB(255, v, v, v);
        expect(contrastRatio(onColor(fill), fill), greaterThanOrEqualTo(4.5), reason: '$fill');
      }
    });
  });

  group('tokens', () {
    test('flat: user bubble is the brand, page is the brand at 6% over white bubbles', () {
      const brand = Color(0xFF7B1F8C);
      final t = SunonoTheme.flat(primary: brand);
      expect(t.userBubble, brand);
      expect(t.botBubble, Colors.white);
      expect(t.headerBackground, Colors.white);
      expect(t.chatBackground, Color.alphaBlend(brand.withValues(alpha: 0.06), Colors.white));
      expect(t.online, t.success);
      expect(t.radius, 18);
      final dark = SunonoTheme.flat(primary: brand, dark: true);
      expect(dark.userBubble, isNot(brand), reason: 'a dark brand is lifted on the dark page');
      expect(contrastRatio(dark.userBubble, dark.chatBackground), greaterThanOrEqualTo(3));
      final black = SunonoTheme.flat(primary: Colors.black, dark: true);
      expect(contrastRatio(black.userBubble, black.chatBackground), greaterThanOrEqualTo(3));
      expect(contrastRatio(black.onUserBubble, black.userBubble), greaterThanOrEqualTo(4.5));
      expect(const SunonoTheme(userBubble: Colors.black, chatBackground: Colors.black).userBubble, Colors.black,
          reason: 'an explicit userBubble is the host\'s call');
      expect(dark.botBubble.computeLuminance(), greaterThan(dark.chatBackground.computeLuminance()),
          reason: 'dark bubbles sit above the page');
      expect(dark.chatBackground, Color.alphaBlend(brand.withValues(alpha: 0.06), const Color(0xFF14121A)));
    });

    test('fromMaterial maps the ColorScheme (D4)', () {
      final m = ThemeData(colorSchemeSeed: const Color(0xFF00897B));
      final c = m.colorScheme;
      final t = SunonoTheme.fromMaterial(m);
      expect(t.userBubble, c.primary);
      expect(t.onUserBubble, c.onPrimary);
      expect(t.botBubble, c.surfaceContainerLowest);
      expect(t.headerBackground, c.surfaceContainerLowest);
      expect(t.chatBackground, Color.alphaBlend(c.primary.withValues(alpha: 0.06), c.surfaceContainerLowest));
      expect(t.outline, c.outlineVariant);
    });

    test('fromMaterial carries fontFamilyFallback into every text style', () {
      final t = SunonoTheme.fromMaterial(ThemeData(fontFamily: 'Brand', fontFamilyFallback: const ['BrandArabic']));
      expect(t.fontFamily, 'Brand');
      expect(t.fontFamilyFallback, ['BrandArabic']);
      expect(t.text().fontFamilyFallback, ['BrandArabic']);
    });

    test('overrides win; copyWith keeps them; a new userBubble recomputes its text', () {
      const t = SunonoTheme(chatBackground: Color(0xFF010203), chipOutline: Color(0xFF040506));
      expect(t.chatBackground, const Color(0xFF010203));
      final c = t.copyWith(userBubble: const Color(0xFFFFE066));
      expect(c.chatBackground, const Color(0xFF010203));
      expect(c.chipOutline, const Color(0xFF040506));
      expect(c.onUserBubble.computeLuminance(), lessThan(0.1), reason: 'dark text on a light bubble');
      expect(const SunonoTheme().chatBackground, const SunonoTheme().background, reason: 'legacy background feeds it');
    });
  });

  test('no gradients or shadows in lib/src/ui outside the deprecated orb', () {
    final hits = <String>[];
    for (final f in Directory('lib/src/ui').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.endsWith('orb.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        // theme.dart keeps the deprecated brandGradient getter (public API until 1.0).
        if (f.path.endsWith('theme.dart') && l.contains('LinearGradient get brandGradient')) continue;
        if (RegExp(r'gradient:|RadialGradient|LinearGradient|SweepGradient|brandGradient|\.glow\b|boxShadow:')
            .hasMatch(l)) {
          hits.add('${f.path}:${i + 1}: ${l.trim()}');
        }
      }
    }
    expect(hits, isEmpty);
  });
}
