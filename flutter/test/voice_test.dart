import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sunono/sunono.dart';

import 'package:sunono/src/ui/copy.dart';

import 'fake_server.dart';

/// An m4a-ish note (the server judges the bytes; the SDK only counts them).
Uint8List _note([int n = 2000]) => Uint8List.fromList([0, 0, 0, 0x18, ...'ftypM4A '.codeUnits, ...List.filled(n, 1)]);

class FakeRecorder implements SunonoVoiceRecorder {
  bool allow = true;
  Completer<bool>? gate;
  Object? startError;
  Completer<void>? stopGate;
  SunonoAudio? next = SunonoAudio(_note(), mimeType: 'audio/mp4', duration: const Duration(seconds: 4));
  final levelsCtl = StreamController<double>.broadcast();
  int starts = 0, stops = 0, cancels = 0;

  @override
  Future<bool> start() async {
    starts++;
    if (startError != null) throw startError!;
    return gate != null ? gate!.future : allow;
  }

  @override
  Stream<double> get levels => levelsCtl.stream;

  @override
  Future<SunonoAudio?> stop() async {
    stops++;
    await stopGate?.future;
    return next;
  }

  @override
  Future<void> cancel() async => cancels++;
}

class FakePlayer implements SunonoAudioPlayer {
  final played = <({Uint8List? bytes, String? url})>[];
  int stops = 0;

  /// just_audio-like: `playing` is false while the new source loads.
  bool falseWhileLoading = false;
  final playingCtl = StreamController<bool>.broadcast();
  final positionCtl = StreamController<Duration>.broadcast();

  @override
  Future<void> play({Uint8List? bytes, String? url}) async {
    played.add((bytes: bytes, url: url));
    if (falseWhileLoading) {
      playingCtl.add(false);
      await Future<void>.delayed(Duration.zero);
    }
    playingCtl.add(true);
  }

  @override
  Future<void> stop() async {
    stops++;
    playingCtl.add(false);
  }

  @override
  Stream<Duration> get position => positionCtl.stream;

  @override
  Stream<bool> get playing => playingCtl.stream;
}

/// Fails the next [n] uploads with no HTTP response.
class _Flaky extends http.BaseClient {
  _Flaky(this.inner, this.fails);
  final http.Client inner;
  final List<int> fails;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.path.endsWith('/chat/upload') && fails[0] > 0) {
      fails[0]--;
      throw http.ClientException('Network is unreachable');
    }
    return inner.send(request);
  }
}

void main() {
  late FakeServer server;
  late FakeRecorder rec;
  late FakePlayer player;
  late SunonoChatController c;
  late DateTime now;
  final uploadFails = [0];

  SunonoChatController make({String? lang}) => SunonoChatController(
        api: SunonoApi(
          shopKey: 'pk_test',
          apiBase: 'https://api.test/api',
          appOrigin: 'https://shop.example',
          clientFactory: () => _Flaky(MockClient.streaming(server.handle), uploadFails),
        ),
        storage: MemoryStorage(),
        lang: lang,
        voiceRecorder: rec,
        audioPlayer: player,
        recoveryChecks: const [Duration(milliseconds: 5)],
        clock: () => now,
      );

  setUp(() {
    uploadFails[0] = 0;
    now = DateTime(2026, 11, 4, 12);
    server = FakeServer();
    rec = FakeRecorder();
    player = FakePlayer();
    c = make();
  });
  tearDown(() {
    c.dispose();
    server.close();
  });

  Map<String, dynamic> streamBody([int i = 0]) => jsonDecode(server.bodies['/chat/stream']![i]) as Map<String, dynamic>;

  Future<void> record() async {
    await c.startVoice();
    expect(c.voice.value, isA<VoiceRecording>());
  }

  group('controller', () {
    test('record → levels → stop: multipart audio upload, then a stream turn with audio_ref and no text', () async {
      await c.open();
      await record();
      rec.levelsCtl
        ..add(0.2)
        ..add(0.9);
      await Future<void>.delayed(Duration.zero);
      now = now.add(const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final r = c.voice.value as VoiceRecording;
      expect(r.level, 0.9);
      expect(r.levels, [0.2, 0.9]);
      expect(r.elapsed, const Duration(seconds: 3));

      await c.stopVoice();
      expect(rec.stops, 1);
      expect(server.count('/chat/upload'), 1);
      final upload = server.bodies['/chat/upload']!.single;
      expect(upload, contains('name="audio"; filename="voice.m4a"'));
      expect(server.count('/chat'), 0, reason: 'a voice turn streams');
      final body = streamBody();
      expect(body['message'], '');
      expect(body['audio_ref'], 'aud_ref_1');
      expect(body.containsKey('image_ref'), isFalse);
      expect(body['client_message_id'], isA<String>());

      final user = c.messages.first;
      expect(user.isVoice, isTrue);
      expect(user.localAudio, isNotNull);
      expect(user.text, 'عندكم قهوة؟', reason: 'the transcript');
      expect(user.audioDuration, const Duration(milliseconds: 4000), reason: "the server's measure");
      expect(user.delivered, isTrue);
      expect(c.messages.last.text, 'هاي الصورة');
      expect(c.voice.value, isA<VoiceIdle>());
    });

    test('progress: uploading rises to the end, then idle', () async {
      await c.open();
      rec.next = SunonoAudio(_note(200000), mimeType: 'audio/mp4', duration: const Duration(seconds: 9));
      final seen = <VoiceState>[];
      c.voice.addListener(() => seen.add(c.voice.value));
      await record();
      await c.stopVoice();
      final progress = [
        for (final s in seen)
          if (s is VoiceUploading) s.progress
      ];
      expect(progress.length, greaterThan(2));
      expect(progress.last, closeTo(1, 0.01));
      expect(c.voice.value, isA<VoiceIdle>());
    });

    test('cancel sends nothing', () async {
      await c.open();
      await record();
      c.cancelVoice();
      await Future<void>.delayed(Duration.zero);
      expect(rec.cancels, 1);
      expect(rec.stops, 0);
      expect(c.voice.value, isA<VoiceIdle>());
      expect(c.messages, isEmpty);
      expect(server.count('/chat/upload'), 0);
    });

    test('at 60 s the note stops and sends by itself', () async {
      await c.open();
      await record();
      now = now.add(const Duration(seconds: 59));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(c.voice.value, isA<VoiceRecording>());
      now = now.add(const Duration(seconds: 1));
      await server.until(() => server.count('/chat/stream') == 1);
      expect(rec.stops, 1);
    });

    test('under 1 s is discarded: never uploaded', () async {
      await c.open();
      rec.next = SunonoAudio(_note(), mimeType: 'audio/mp4', duration: const Duration(milliseconds: 600));
      await record();
      await c.stopVoice();
      expect((c.voice.value as VoiceFailed).code, 'voice_too_short');
      expect(server.count('/chat/upload'), 0);
      expect(c.messages, isEmpty);
      rec.next = null; // nothing recorded at all
      await record();
      await c.stopVoice();
      expect((c.voice.value as VoiceFailed).code, 'voice_too_short');
    });

    test('client caps: over 1.5 MB or over 60.5 s never upload; exactly 1.5 MB and 60.4 s do', () async {
      await c.open();
      for (final (bytes, secs, code) in [
        (1536 * 1024 + 1, 10.0, 'audio_too_large'),
        (5000, 60.6, 'audio_too_long'),
      ]) {
        rec.next = SunonoAudio(Uint8List(bytes),
            mimeType: 'audio/mp4', duration: Duration(milliseconds: (secs * 1000).round()));
        await record();
        await c.stopVoice();
        expect((c.voice.value as VoiceFailed).code, code);
      }
      expect(server.count('/chat/upload'), 0);
      rec.next =
          SunonoAudio(Uint8List(1536 * 1024), mimeType: 'audio/mp4', duration: const Duration(milliseconds: 60400));
      await record();
      await c.stopVoice();
      expect(server.count('/chat/upload'), 1);
    });

    test('server refusals show on the message, are final (no Retry) and never re-upload', () async {
      await c.open();
      for (final (status, code) in [
        (422, 'audio_unclear'),
        (413, 'audio_too_large'),
        (413, 'audio_too_long'),
        (400, 'invalid_audio'),
        (503, 'audio_unavailable'),
      ]) {
        final uploads = server.count('/chat/upload');
        server.failUploadOnce = (status, code);
        await record();
        await c.stopVoice();
        final failed = c.messages.last;
        expect(failed.state, MessageState.failed);
        expect(failed.errorCode, code);
        expect(failed.retryable, isFalse);
        expect(server.count('/chat/upload'), uploads + 1, reason: 'one paid call, no automatic retry');
        expect(c.voice.value, isA<VoiceIdle>());
      }
      expect(server.count('/chat/stream'), 0);
    });

    test('429 voice_busy is final (not rate_limited); 503 voice_unavailable also hides the mic', () async {
      await c.open();
      server.failUploadOnce = (429, 'voice_busy');
      await record();
      await c.stopVoice();
      expect(c.messages.last.errorCode, 'voice_busy');
      expect(c.messages.last.retryable, isFalse);
      expect(c.voiceAvailable, isTrue);
      server.failUploadOnce = (503, 'voice_unavailable');
      await record();
      await c.stopVoice();
      expect(c.messages.last.errorCode, 'voice_unavailable');
      expect(c.messages.last.retryable, isFalse);
      expect(c.voiceAvailable, isFalse);
      expect(c.canRecord, isFalse);
      await c.startVoice();
      expect(rec.starts, 2, reason: 'no third recording');
    });

    test('rate_limited is retryable by hand: Retry uploads again with the same client_message_id', () async {
      await c.open();
      server.failUploadOnce = (429, 'rate_limited');
      await record();
      await c.stopVoice();
      final failed = c.messages.last;
      expect(failed.errorCode, 'rate_limited');
      expect(failed.retryable, isTrue);
      expect(server.count('/chat/upload'), 1);
      await c.retry(failed);
      expect(server.count('/chat/upload'), 2);
      expect(server.count('/chat/stream'), 1);
      expect(c.messages.first.text, 'عندكم قهوة؟');
    });

    test('no HTTP response: one automatic re-upload; a second miss fails offline, Retry keeps the id', () async {
      await c.open();
      uploadFails[0] = 1;
      await record();
      await c.stopVoice();
      expect(server.count('/chat/stream'), 1, reason: 'the network blip was retried once');

      uploadFails[0] = 2;
      await record();
      await c.stopVoice();
      final failed = c.messages.last;
      expect(failed.errorCode, 'offline');
      expect(failed.retryable, isTrue);
      await c.retry(failed);
      expect(server.count('/chat/stream'), 2);
    });

    test('a stream 400 (expired audio_ref) waits for Retry, which re-uploads with the same client_message_id',
        () async {
      await c.open();
      server
        ..failStreamWith = 400
        ..failStreamTimes = 1
        ..failStreamBody = {'message': 'bad ref'};
      await record();
      await c.stopVoice();
      final failed = c.messages.last;
      expect(failed.state, MessageState.failed);
      expect(failed.retryable, isTrue);
      expect(server.count('/chat/upload'), 1, reason: 'no automatic paid re-upload');
      await c.retry(failed);
      expect(server.count('/chat/upload'), 2);
      expect(streamBody(1)['audio_ref'], 'aud_ref_2');
      expect(streamBody(1)['client_message_id'], streamBody(0)['client_message_id']);
    });

    test('a retry with a fresh ref reuses it; one older than 55 minutes uploads again', () async {
      await c.open();
      server
        ..failStreamWith = 500
        ..failStreamTimes = 2
        ..failStreamBody = {'error': 'oops'};
      await record();
      await c.stopVoice();
      final failed = c.messages.last;
      expect(failed.state, MessageState.failed);
      await c.retry(failed);
      expect(server.count('/chat/upload'), 1, reason: 'a fresh ref is reused');
      now = now.add(const Duration(minutes: 56));
      await c.retry(c.messages.last);
      expect(server.count('/chat/upload'), 2);
      expect(server.count('/chat/stream'), 3);
    });

    test('permission refused: mic_denied, nothing recorded or sent; a thrown start is voice_failed', () async {
      await c.open();
      rec.allow = false;
      await c.startVoice();
      expect((c.voice.value as VoiceFailed).code, 'mic_denied');
      rec.startError = StateError('no mic');
      await c.startVoice();
      expect((c.voice.value as VoiceFailed).code, 'voice_failed');
      expect(server.count('/chat/upload'), 0);
      expect(c.messages, isEmpty);
    });

    test('reset while recording cancels it; nothing is sent', () async {
      await c.open();
      await record();
      await c.reset();
      expect(rec.cancels, 1);
      expect(c.voice.value, isA<VoiceIdle>());
      await c.stopVoice(); // a late tap does nothing
      expect(server.count('/chat/upload'), 0);
      expect(c.messages, isEmpty);
    });

    test('reset while the permission prompt is open: a late yes is cancelled at once', () async {
      await c.open();
      rec.gate = Completer<bool>();
      final starting = c.startVoice();
      await c.reset();
      rec.gate!.complete(true);
      await starting;
      expect(rec.cancels, 1);
      expect(c.voice.value, isA<VoiceIdle>());
    });

    test('reset during the upload: nothing streams as anyone', () async {
      await c.open();
      final hold = Completer<void>();
      server.beforeUpload = () => hold.future;
      await record();
      final sending = c.stopVoice();
      await server.until(() => server.count('/chat/upload') == 1);
      await c.reset();
      hold.complete();
      await sending;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.count('/chat/stream'), 0);
      expect(c.messages, isEmpty);
    });

    test('app pause cancels the recording and stops playback; dispose cancels too', () async {
      await c.open();
      await record();
      c.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(rec.cancels, 1);
      expect(c.voice.value, isA<VoiceIdle>());
      await record();
      c.dispose();
      expect(rec.cancels, 2);
      c = make(); // tearDown disposes this one
    });

    test('while recording a typed or tapped send is held; the mic is off while a turn runs', () async {
      await c.open();
      await record();
      await c.send('hi', synthetic: true);
      expect(server.count('/chat'), 0);
      server.failChatOnceWith = 400;
      c.cancelVoice();
      await c.send('first');
      final failed = c.messages.last;
      expect(failed.state, MessageState.failed);
      await record();
      await c.retry(failed);
      expect(server.count('/chat'), 1, reason: 'no retry while recording');
      c.cancelVoice();
      final hold = Completer<void>();
      server.beforeChatReply = () => hold.future;
      final sending = c.send('hi');
      await Future<void>.delayed(Duration.zero);
      expect(c.canRecord, isFalse);
      await c.startVoice();
      expect(rec.starts, 2);
      hold.complete();
      await sending;
      expect(c.canRecord, isTrue);
    });

    test('playback: toggles the player with the local bytes; a restored note plays by url', () async {
      server.historyRows = [
        {
          'role': 'user',
          'sender': 'user',
          'text': 'بدي شاحن',
          'msg_ref': 'u1',
          'audio': {'url': 'https://api.test/media/v1.mp3', 'duration_ms': 2500},
        },
      ];
      await c.open();
      await server.until(() => c.messages.isNotEmpty);
      final restored = c.messages.single;
      expect(restored.isVoice, isTrue);
      expect(restored.text, 'بدي شاحن');
      expect(restored.audioDuration, const Duration(milliseconds: 2500));
      await c.toggleVoicePlayback(restored);
      expect(player.played.single.url, 'https://api.test/media/v1.mp3');
      expect(c.playingVoice.value, restored.id);
      await c.toggleVoicePlayback(restored);
      expect(player.stops, 1);
      expect(c.playingVoice.value, isNull);

      await record();
      await c.stopVoice();
      final live = c.messages.firstWhere((m) => m.localAudio != null);
      await c.toggleVoicePlayback(live);
      expect(player.played.last.bytes, live.localAudio);
      expect(player.played.last.url, isNull);
      player.playingCtl.add(false); // the note ended
      await Future<void>.delayed(Duration.zero);
      expect(c.playingVoice.value, isNull);
    });
  });

  group('fix round 1', () {
    test('reset while the recorder is stopping: the old note is never added or uploaded', () async {
      await c.open();
      rec.stopGate = Completer<void>();
      await record();
      final stopping = c.stopVoice();
      await Future<void>.delayed(Duration.zero);
      expect(c.canRecord, isFalse, reason: 'no second recording while the first stops');
      await c.reset();
      rec.stopGate!.complete();
      await stopping;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.count('/chat/upload'), 0);
      expect(c.messages.where((m) => m.isVoice), isEmpty);
      expect(c.voice.value, isA<VoiceIdle>());
    });

    test('dispose mid-upload: a network failure after dispose never uploads again', () async {
      await c.open();
      final hold = Completer<void>();
      server.beforeUpload = () async {
        await hold.future;
        throw http.ClientException('connection closed');
      };
      await record();
      final sending = c.stopVoice();
      await server.until(() => server.count('/chat/upload') == 1);
      c.dispose();
      hold.complete();
      await sending;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.count('/chat/upload'), 1);
      expect(server.count('/chat/stream'), 0);
      c = make(); // tearDown disposes this one
    });

    test('a player that reports false while loading keeps the note playing until it really ends', () async {
      player.falseWhileLoading = true;
      server.historyRows = [
        {
          'role': 'user',
          'sender': 'user',
          'text': 'بدي شاحن',
          'msg_ref': 'u1',
          'audio': {'url': 'https://api.test/media/v1.mp3', 'duration_ms': 2500},
        },
      ];
      await c.open();
      await server.until(() => c.messages.isNotEmpty);
      final m = c.messages.single;
      await c.toggleVoicePlayback(m);
      await Future<void>.delayed(Duration.zero);
      expect(c.playingVoice.value, m.id, reason: 'the loading false is not an end');
      player.playingCtl.add(false); // ended
      await Future<void>.delayed(Duration.zero);
      expect(c.playingVoice.value, isNull);
    });

    test('history audio: https only, and only on the shopper\'s own rows', () async {
      server.historyRows = [
        {
          'role': 'user',
          'sender': 'user',
          'text': 'a',
          'msg_ref': 'u1',
          'audio': {'url': 'http://api.test/media/v1.mp3', 'duration_ms': 1000},
        },
        {
          'role': 'bot',
          'sender': 'bot',
          'text': 'b',
          'msg_ref': 'b1',
          'audio': {'url': 'https://api.test/media/v2.mp3', 'duration_ms': 1000},
        },
        {
          'role': 'user',
          'sender': 'user',
          'text': 'c',
          'msg_ref': 'u2',
          'audio': {'url': 'https://api.test/media/v3.mp3', 'duration_ms': 1000},
        },
      ];
      await c.open();
      await server.until(() => c.messages.length == 3);
      expect([for (final m in c.messages) m.audioUrl], [null, null, 'https://api.test/media/v3.mp3']);
    });

    test('customer_blocked on a voice note reads as messages, not photos', () async {
      await c.open();
      server.failUploadOnce = (403, 'customer_blocked');
      await record();
      await c.stopVoice();
      expect(c.messages.last.errorCode, 'customer_blocked');
      expect(c.messages.last.retryable, isFalse);
      expect(SunonoCopy.of('ar').error('customer_blocked'), 'ما بنقدر نستقبل رسائلك هلّق');
      expect(SunonoCopy.of('en').photoError('customer_blocked'), "We can't accept photos right now");
    });

    test('the kill switch stops playback', () async {
      await c.open();
      server.historyRows = [];
      await record();
      await c.stopVoice();
      final note = c.messages.firstWhere((m) => m.isVoice);
      await c.toggleVoicePlayback(note);
      server.config = {'enabled': false};
      now = now.add(const Duration(minutes: 5));
      c.resume();
      await server.until(() => c.status == ChatStatus.disabled);
      expect(player.stops, 1);
    });
  });

  group('view', () {
    Widget app(Widget child, {double scale = 1, double width = 390}) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: Size(width, 800), textScaler: TextScaler.linear(scale), disableAnimations: true),
            child: Scaffold(body: child),
          ),
        );

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 120)); // the recording ticker
      }
    }

    Future<void> pumpView(WidgetTester tester,
        {double scale = 1, double width = 390, VoidCallback? settings, String? lang, bool voice = true}) async {
      c.dispose();
      // Made inside the test zone, so its timers are the test's fake ones.
      c = SunonoChatController(
        api: SunonoApi(
          shopKey: 'pk_test',
          apiBase: 'https://api.test/api',
          appOrigin: 'https://shop.example',
          clientFactory: () => MockClient.streaming(server.handle),
        ),
        storage: MemoryStorage(),
        lang: lang,
        voiceRecorder: voice ? rec : null,
        audioPlayer: voice ? player : null,
        onOpenSettings: settings,
        recoveryChecks: const [Duration(milliseconds: 5)],
        clock: () => now,
      );
      tester.view.physicalSize = Size(width * 3, 800 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(SunonoChatView(controller: c), scale: scale, width: width));
      await settle(tester);
    }

    Future<void> done(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      c.suspend(); // the live connection outlives the view
    }

    testWidgets('mic → recording bar (48 dp cancel/send, labels, timer live region) → send → voice bubble',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpView(tester);
      final mic = find.byTooltip('سجّل رسالة صوتية');
      expect(tester.getSize(mic), const Size(48, 48));
      await tester.tap(mic);
      await settle(tester);
      expect(c.voice.value, isA<VoiceRecording>());
      final cancel = find.byTooltip('إلغاء التسجيل'), send = find.byTooltip('ابعث الرسالة الصوتية');
      expect(tester.getSize(cancel), const Size(48, 48));
      expect(tester.getSize(send), const Size(48, 48));
      expect(find.bySemanticsLabel('عم نسجّل'), findsOneWidget);
      expect(find.text('0:00'), findsOneWidget);
      now = now.add(const Duration(seconds: 12));
      await settle(tester);
      expect(find.text('0:12'), findsOneWidget);
      expect(find.bySemanticsLabel('عم نسجّل، 10 ثانية'), findsOneWidget, reason: 'announced per 10 s');

      await tester.tap(send);
      await settle(tester);
      expect(server.count('/chat/stream'), 1);
      expect(find.bySemanticsLabel('رسالة صوتية، 4 ثانية: عندكم قهوة؟'), findsOneWidget);
      expect(find.text('سمعناك: عندكم قهوة؟'), findsOneWidget);
      final play = find.byTooltip('شغّل الرسالة الصوتية');
      expect(tester.getSize(play), const Size(48, 48));
      await tester.tap(play);
      await settle(tester);
      expect(player.played, hasLength(1));
      expect(find.byTooltip('وقّف الرسالة الصوتية'), findsOneWidget);
      handle.dispose();
      await done(tester);
    });

    testWidgets('leaving the chat (pop) mid-recording cancels the mic; nothing uploads at 60 s', (tester) async {
      await pumpView(tester);
      await tester.tap(find.byTooltip('سجّل رسالة صوتية'));
      await settle(tester);
      expect(c.voice.value, isA<VoiceRecording>());
      await tester.pumpWidget(const SizedBox()); // the route popped
      await settle(tester);
      expect(rec.cancels, 1);
      now = now.add(const Duration(seconds: 61));
      await settle(tester);
      expect(rec.stops, 0);
      expect(server.count('/chat/upload'), 0);
      c.suspend();
    });

    testWidgets('a route pushed over the chat mid-recording cancels the mic', (tester) async {
      await pumpView(tester);
      await tester.tap(find.byTooltip('سجّل رسالة صوتية'));
      await settle(tester);
      Navigator.of(tester.element(find.byType(SunonoChatView)))
          .push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('product'))));
      await settle(tester);
      expect(rec.cancels, 1);
      expect(c.voice.value, isA<VoiceIdle>());
      await done(tester);
    });

    testWidgets('cancel from the bar returns to the composer and sends nothing', (tester) async {
      await pumpView(tester);
      await tester.tap(find.byTooltip('سجّل رسالة صوتية'));
      await settle(tester);
      await tester.tap(find.byTooltip('إلغاء التسجيل'));
      await settle(tester);
      expect(find.byTooltip('سجّل رسالة صوتية'), findsOneWidget);
      expect(rec.cancels, 1);
      expect(server.count('/chat/upload'), 0);
      await done(tester);
    });

    testWidgets('mic denied: the hint, and Settings when the host offers it', (tester) async {
      var opened = 0;
      rec.allow = false;
      await pumpView(tester, settings: () => opened++);
      await tester.tap(find.byTooltip('سجّل رسالة صوتية'));
      await settle(tester);
      expect(find.text('اسمح للتطبيق يستخدم المايكروفون عشان تسجّل'), findsOneWidget);
      await tester.tap(find.text('الإعدادات'));
      expect(opened, 1);
      await done(tester);
    });

    testWidgets('audio_unclear shows its copy without Retry', (tester) async {
      server.failUploadOnce = (422, 'audio_unclear');
      await pumpView(tester);
      await tester.tap(find.byTooltip('سجّل رسالة صوتية'));
      await settle(tester);
      await tester.tap(find.byTooltip('ابعث الرسالة الصوتية'));
      await settle(tester);
      expect(find.text('ما سمعت منيح، جرّب مرة ثانية'), findsOneWidget);
      expect(find.text('أعد المحاولة'), findsNothing);
      await done(tester);
    });

    testWidgets('voice_unavailable: its copy, and the mic is gone for the session', (tester) async {
      server.failUploadOnce = (503, 'voice_unavailable');
      await pumpView(tester);
      await tester.tap(find.byTooltip('سجّل رسالة صوتية'));
      await settle(tester);
      await tester.tap(find.byTooltip('ابعث الرسالة الصوتية'));
      await settle(tester);
      expect(find.text('الرسائل الصوتية مش متاحة بهالمتجر، اكتبلي'), findsOneWidget);
      expect(find.byTooltip('سجّل رسالة صوتية'), findsNothing);
      expect(find.byTooltip('إرسال'), findsOneWidget);
      await done(tester);
    });

    testWidgets('too short shows «سجّل رسالة أطول» in the composer', (tester) async {
      rec.next = SunonoAudio(_note(), mimeType: 'audio/mp4', duration: const Duration(milliseconds: 300));
      await pumpView(tester);
      await tester.tap(find.byTooltip('سجّل رسالة صوتية'));
      await settle(tester);
      await tester.tap(find.byTooltip('ابعث الرسالة الصوتية'));
      await settle(tester);
      expect(find.text('سجّل رسالة أطول'), findsOneWidget);
      await done(tester);
    });

    testWidgets('English copy; a restored voice bubble without a player shows a mic and its transcript',
        (tester) async {
      final handle = tester.ensureSemantics();
      server.historyRows = [
        {
          'role': 'user',
          'sender': 'user',
          'text': 'Do you have chargers?',
          'msg_ref': 'u1',
          'audio': {'url': '/media/v1.mp3', 'duration_ms': 12300},
        },
      ];
      await pumpView(tester, lang: 'en', voice: false);
      expect(find.bySemanticsLabel('Voice message, 12 seconds: Do you have chargers?'), findsOneWidget);
      expect(find.text('We heard: Do you have chargers?'), findsOneWidget);
      expect(find.text('0:12'), findsOneWidget);
      expect(find.byTooltip('Play voice message'), findsNothing);
      expect(find.byTooltip('Record a voice message'), findsNothing, reason: 'no recorder, no mic');
      handle.dispose();
      await done(tester);
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('320 px at ${scale}x: recording bar and voice bubble lay out', (tester) async {
        await pumpView(tester, scale: scale, width: 320);
        await tester.tap(find.byTooltip('سجّل رسالة صوتية'));
        await settle(tester);
        rec.levelsCtl.add(0.7);
        now = now.add(const Duration(seconds: 42));
        await settle(tester);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('ابعث الرسالة الصوتية'));
        await settle(tester);
        expect(find.text('سمعناك: عندكم قهوة؟'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await done(tester);
      });
    }
  });
}
