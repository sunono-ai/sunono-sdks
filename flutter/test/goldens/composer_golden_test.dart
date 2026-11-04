@Tags(['golden'])
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sunono/sunono.dart';
import 'package:sunono/src/ui/composer.dart';
import 'package:sunono/src/ui/copy.dart';

import 'golden_harness.dart';

/// A real (decodable) photo: a two-tone square.
Future<Uint8List> _photo() async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 64, 64), Paint()..color = const Color(0xFFE0B080));
  canvas.drawCircle(const Offset(32, 36), 18, Paint()..color = const Color(0xFF8A5A2B));
  final image = await rec.endRecording().toImage(64, 64);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

/// The composer's states stacked: empty, empty with a recorder (mic), typed,
/// a photo attached, and disabled (a turn running), AR/EN, light/dark.
void main() {
  setUpAll(loadGoldenFonts);

  for (final lang in ['ar', 'en']) {
    for (final dark in [false, true]) {
      final name = 'composer_${lang}_${dark ? 'dark' : 'light'}';
      testWidgets(name, (tester) async {
        goldenPhone(tester);
        final bytes = (await tester.runAsync(_photo))!;
        final t = SunonoCopy.of(lang);
        final typed = lang == 'ar' ? 'عندكم قهوة عربية؟' : 'Do you have Arabic coffee?';
        Widget bar(String text, {bool canSend = true, PhotoState photo = const PhotoIdle(), VoidCallback? onMic}) =>
            Builder(
              builder: (context) => Composer(
                theme: SunonoTheme.fromMaterial(Theme.of(context)),
                controller: TextEditingController(text: text),
                focus: FocusNode(),
                hint: photo is PhotoIdle ? t.inputHint : t.photoCaptionHint,
                canSend: canSend,
                onSend: () {},
                onPickPhoto: () {},
                photo: photo,
                image: photo is PhotoIdle ? null : SunonoImage(bytes),
                needCaption: false,
                onRemovePhoto: () {},
                onRetryPhoto: () {},
                copy: t,
                onMic: onMic,
              ),
            );
        await tester.pumpWidget(goldenApp(
          Builder(
            builder: (context) => Directionality(
              textDirection: lang == 'ar' ? TextDirection.rtl : TextDirection.ltr,
              child: Center(
                child: RepaintBoundary(
                  key: const ValueKey('composers'),
                  child: ColoredBox(
                    color: SunonoTheme.fromMaterial(Theme.of(context)).chatBackground,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      for (final b in [
                        bar('', canSend: false),
                        bar('', canSend: false, onMic: () {}),
                        bar(typed),
                        bar('', photo: const PhotoReady('ref')),
                        bar(typed, canSend: false),
                      ]) ...[b, const SizedBox(height: 16)],
                    ]),
                  ),
                ),
              ),
            ),
          ),
          dark: dark,
        ));
        await tester.runAsync(() => precacheImage(MemoryImage(bytes), tester.element(find.byType(Composer).first)));
        await tester.pump();
        await expectLater(find.byKey(const ValueKey('composers')), matchesGoldenFile('$name.png'));
      });
    }
  }
}
