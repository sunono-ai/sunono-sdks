import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

/// Goldens render with real glyphs: Roboto and Material Icons from the
/// Flutter SDK cache, Noto Sans Arabic from `test/fonts` (OFL, see OFL.txt).
/// They are pinned to one Flutter version in CI (`--tags golden`).
Future<void> loadGoldenFonts() async {
  final sdk = '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';
  ByteData read(String path) => ByteData.sublistView(File(path).readAsBytesSync());
  final roboto = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold']) {
    roboto.addFont(Future.value(read('$sdk/Roboto-$w.ttf')));
  }
  await roboto.load();
  await (FontLoader('MaterialIcons')..addFont(Future.value(read('$sdk/MaterialIcons-Regular.otf')))).load();
  final arabic = FontLoader('NotoSansArabic');
  for (final w in ['Regular', 'Bold']) {
    arabic.addFont(Future.value(read('test/fonts/NotoSansArabic-$w.ttf')));
  }
  await arabic.load();
}

/// The brand used in goldens (a generic purple).
const goldenBrand = Color(0xFF7B1F8C);

/// A 390×844 phone at 2×, no animations, under a host Material theme.
Widget goldenApp(Widget child, {bool dark = false}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: goldenBrand,
        brightness: dark ? Brightness.dark : Brightness.light,
        fontFamily: 'Roboto',
        fontFamilyFallback: const ['NotoSansArabic'],
      ),
      home: MediaQuery(
        data: const MediaQueryData(
            disableAnimations: true, size: Size(390, 844), devicePixelRatio: 2, padding: EdgeInsets.only(top: 47)),
        child: Scaffold(body: child),
      ),
    );

/// Sizes the test view to the phone; reset on teardown.
void goldenPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}
