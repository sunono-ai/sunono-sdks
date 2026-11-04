@Tags(['golden'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/sunono.dart';

import '../fake_server.dart';
import 'golden_harness.dart';

class _Recorder implements SunonoVoiceRecorder {
  final levelsCtl = StreamController<double>.broadcast();
  @override
  Future<bool> start() async => true;
  @override
  Stream<double> get levels => levelsCtl.stream;
  @override
  Future<SunonoAudio?> stop() async => SunonoAudio(Uint8List.fromList(List.filled(4000, 1)),
      mimeType: 'audio/mp4', duration: const Duration(seconds: 4));
  @override
  Future<void> cancel() async {}
}

class _Player implements SunonoAudioPlayer {
  @override
  Future<void> play({Uint8List? bytes, String? url}) async {}
  @override
  Future<void> stop() async {}
  @override
  Stream<Duration> get position => const Stream.empty();
  @override
  Stream<bool> get playing => const Stream.empty();
}

/// A sent voice note (play button, waveform, duration, «سمعناك: …») with the
/// reply, and the recording bar of the next note (timer, level bars, ✕, send).
/// Live (recorded and sent) and restored (the same turn as history rows)
/// must both match `voice_{ar,en}_{light,dark}.png`.
void main() {
  setUpAll(loadGoldenFonts);

  const copy = {
    'ar': (heard: 'عندكم قهوة عربية؟', reply: 'أكيد! عنا قهوة عربية بالهيل.'),
    'en': (heard: 'Do you have Arabic coffee?', reply: 'Yes! We have Arabic coffee with cardamom.'),
  };

  for (final lang in ['ar', 'en']) {
    for (final dark in [false, true]) {
      final name = 'voice_${lang}_${dark ? 'dark' : 'light'}';
      for (final restored in [false, true]) {
        testWidgets('$name ${restored ? 'restored' : 'live'}', (tester) async {
          goldenPhone(tester);
          final t = copy[lang]!;
          final today = DateTime.now();
          final at = DateTime(today.year, today.month, today.day, 12, 12);
          var now = at;
          final server = FakeServer()
            ..config = {'enabled': true, 'header_title_ar': 'مساعد المتجر', 'header_title_en': 'Shop Assistant'}
            ..audioTranscript = t.heard
            ..audioDurationMs = 4000
            ..streamReply = t.reply;
          if (restored) {
            server.historyRows = [
              {
                'role': 'user',
                'sender': 'user',
                'text': t.heard,
                'msg_ref': 'u0',
                'audio': {'url': 'https://api.test/media/v0.mp3', 'duration_ms': 4000},
              },
              {'role': 'bot', 'sender': 'bot', 'text': t.reply, 'msg_ref': 'b1', 'products': <Object>[]},
            ];
          }
          final rec = _Recorder();
          final c = SunonoChatController(
            api: SunonoApi(
              shopKey: 'pk_test',
              apiBase: 'https://api.test/api',
              appOrigin: 'https://shop.example',
              clientFactory: () => MockClient.streaming(server.handle),
            ),
            storage: MemoryStorage(),
            lang: lang,
            voiceRecorder: rec,
            audioPlayer: _Player(),
            recoveryChecks: const [Duration(milliseconds: 5)],
            clock: () => now,
          );
          Future<void> settle() async {
            for (var i = 0; i < 20; i++) {
              await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
              await tester.pump(const Duration(milliseconds: 20));
            }
          }

          await tester.pumpWidget(goldenApp(SunonoChatView(controller: c, onBack: () {}), dark: dark));
          await settle();
          if (!restored) {
            unawaited(c.startVoice());
            await settle();
            unawaited(c.stopVoice());
            await settle();
          }
          for (final m in c.messages) {
            m.ts = at;
          }
          c.notifyListeners();
          // The next note, 7 s in.
          unawaited(c.startVoice());
          await settle();
          for (final l in [0.2, 0.5, 0.8, 0.4, 0.9, 0.6, 0.3, 0.7]) {
            rec.levelsCtl.add(l);
          }
          now = at.add(const Duration(seconds: 7));
          await settle();
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('$name.png'));
          await tester.pumpWidget(const SizedBox());
          c.dispose();
          server.close();
        });
      }
    }
  }
}
