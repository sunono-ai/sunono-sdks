import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sunono/sunono.dart';

import 'fake_server.dart';

Uint8List _jpeg([int n = 64]) => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(n, 7)]);
Uint8List _png() => Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]);
Uint8List _webp() => Uint8List.fromList([...'RIFF'.codeUnits, 1, 2, 3, 4, ...'WEBP'.codeUnits, 9]);

/// Records whether it carried an upload and whether it was closed (= aborted).
class _Tracked extends http.BaseClient {
  _Tracked(this.inner);
  final http.Client inner;
  bool upload = false;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.path.endsWith('/chat/upload')) upload = true;
    return inner.send(request);
  }

  @override
  void close() {
    closed = true;
    inner.close();
  }
}

void main() {
  late FakeServer server;
  late SunonoChatController c;
  late List<_Tracked> clients;

  _Tracked track(http.Client inner) {
    final k = _Tracked(inner);
    clients.add(k);
    return k;
  }

  bool uploadClientClosed() => clients.where((k) => k.upload).every((k) => k.closed) && clients.any((k) => k.upload);

  SunonoChatController make({Duration? timeout, DateTime Function()? clock}) => SunonoChatController(
        api: SunonoApi(
          shopKey: 'pk_test',
          apiBase: 'https://api.test/api',
          appOrigin: 'https://shop.example',
          clientFactory: () => track(MockClient.streaming(server.handle)),
          turnTimeout: timeout ?? const Duration(seconds: 90),
          requestTimeout: timeout ?? const Duration(seconds: 15),
        ),
        storage: MemoryStorage(),
        recoveryChecks: const [Duration(milliseconds: 5)],
        clock: clock ?? DateTime.now,
      );

  setUp(() {
    clients = [];
    server = FakeServer();
    c = make();
  });
  tearDown(() {
    c.dispose();
    server.close();
  });

  Future<void> ready() async {
    await c.attachPhoto(SunonoImage(_jpeg()));
    expect(c.photo.value, isA<PhotoReady>());
  }

  group('controller', () {
    test('attachPhoto uploads at once: uploading with rising progress, then ready(ref)', () async {
      await c.open();
      final seen = <PhotoState>[];
      c.photo.addListener(() => seen.add(c.photo.value));
      await c.attachPhoto(SunonoImage(_jpeg(100000)));
      expect(server.count('/chat/upload'), 1);
      final progress = [
        for (final s in seen)
          if (s is PhotoUploading) s.progress
      ];
      expect(progress.first, 0);
      expect(progress.length, greaterThan(2), reason: 'chunked, not one jump');
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
      expect(progress.every((p) => p >= 0 && p <= 1), isTrue);
      expect((c.photo.value as PhotoReady).ref, 'img_ref_1');
      expect(c.photoImage, isNotNull);
    });

    test('JPEG, PNG and WebP are accepted by magic bytes', () async {
      await c.open();
      for (final b in [_jpeg(), _png(), _webp()]) {
        await c.attachPhoto(SunonoImage(b));
        expect(c.photo.value, isA<PhotoReady>());
      }
      expect(server.count('/chat/upload'), 3);
    });

    test('anything else is invalid_image and never uploaded (GIF, text, empty)', () async {
      await c.open();
      for (final b in [
        Uint8List.fromList('GIF89a....'.codeUnits),
        Uint8List.fromList([1, 2, 3]),
        Uint8List(0),
        Uint8List.fromList('RIFF....WAVE'.codeUnits),
      ]) {
        await c.attachPhoto(SunonoImage(b));
        expect((c.photo.value as PhotoFailed).code, 'invalid_image');
      }
      expect(server.count('/chat/upload'), 0);
    });

    test('over 5 MB is image_too_large without uploading; exactly 5 MB goes through', () async {
      await c.open();
      await c.attachPhoto(SunonoImage(_jpeg(5 * 1024 * 1024)));
      expect((c.photo.value as PhotoFailed).code, 'image_too_large');
      expect(server.count('/chat/upload'), 0);
      await c.attachPhoto(SunonoImage(_jpeg(5 * 1024 * 1024 - 4)));
      expect(c.photo.value, isA<PhotoReady>());
    });

    test('server errors surface their code; retry re-uploads', () async {
      await c.open();
      for (final (status, code) in [
        (413, 'image_too_large'),
        (400, 'invalid_image'),
        (422, 'image_blocked'),
        (503, 'image_unavailable')
      ]) {
        server.failUploadOnce = (status, code);
        await c.attachPhoto(SunonoImage(_jpeg()));
        expect((c.photo.value as PhotoFailed).code, code);
      }
      expect(server.count('/chat/upload'), 4);
      await c.retryPhoto();
      expect(c.photo.value, isA<PhotoReady>());
      expect(server.count('/chat/upload'), 5);
    });

    test('a network failure is offline and retryable', () async {
      c.dispose();
      c = make(timeout: const Duration(milliseconds: 50));
      await c.open();
      final gate = Completer<void>();
      server.beforeUpload = () => gate.future;
      await c.attachPhoto(SunonoImage(_jpeg())).timeout(const Duration(seconds: 5));
      expect((c.photo.value as PhotoFailed).code, 'offline');
      gate.complete();
    });

    test('removing the photo mid-upload aborts it: the late result is ignored', () async {
      await c.open();
      final gate = Completer<void>();
      server.beforeUpload = () => gate.future;
      final up = c.attachPhoto(SunonoImage(_jpeg()));
      await server.until(() => server.count('/chat/upload') == 1);
      c.removePhoto();
      expect(c.photo.value, isA<PhotoIdle>());
      gate.complete();
      await up;
      expect(c.photo.value, isA<PhotoIdle>(), reason: 'the stale upload must not resurrect the photo');
      expect(c.photoImage, isNull);
    });

    test('attaching a second photo supersedes the first upload', () async {
      await c.open();
      final gate = Completer<void>();
      server.beforeUpload = () => gate.future;
      final first = c.attachPhoto(SunonoImage(_jpeg(10)));
      await server.until(() => server.count('/chat/upload') == 1);
      server.beforeUpload = null;
      await c.attachPhoto(SunonoImage(_png()));
      expect(c.photo.value, isA<PhotoReady>());
      gate.complete();
      await first;
      expect(c.photoImage!.bytes.length, _png().length);
      expect(c.photo.value, isA<PhotoReady>());
    });

    test('send uses the ready ref (no second upload) and clears the photo', () async {
      await c.open();
      await ready();
      await c.send('شو هاد؟');
      expect(server.count('/chat/upload'), 1);
      expect(server.count('/chat/stream'), 1);
      expect(jsonDecode(server.bodies['/chat/stream']!.last)['image_ref'], 'img_ref_1');
      expect(c.messages.first.localImage, isNotNull);
      expect(c.messages.last.text, 'هاي الصورة');
      expect(c.photo.value, isA<PhotoIdle>());
      expect(c.photoImage, isNull);
      await c.send('تاني');
      expect(server.count('/chat'), 1, reason: 'the next message is a plain text turn');
    });

    test('send holds back while a retryable failure (rate_limited) is on the photo', () async {
      await c.open();
      server.failUploadOnce = (429, 'rate_limited');
      await c.attachPhoto(SunonoImage(_jpeg()));
      expect((c.photo.value as PhotoFailed).retryable, isTrue);
      await c.send('شو هاد؟');
      expect(c.messages, isEmpty);
      expect(c.photo.value, isA<PhotoFailed>());
    });

    test('send holds back while the photo is uploading', () async {
      await c.open();
      final gate = Completer<void>();
      server.beforeUpload = () => gate.future;
      final up = c.attachPhoto(SunonoImage(_jpeg()));
      await server.until(() => server.count('/chat/upload') == 1);
      await c.send('شو هاد؟');
      expect(c.messages, isEmpty);
      gate.complete();
      await up;
    });

    test('a photo that can never upload is dropped: the typed text goes out alone', () async {
      await c.open();
      for (final (status, code) in [
        (503, 'image_unavailable'),
        (422, 'image_blocked'),
        (413, 'image_too_large'),
        (400, 'invalid_image'),
        (403, 'customer_blocked'),
      ]) {
        server.failUploadOnce = (status, code);
        await c.attachPhoto(SunonoImage(_jpeg()));
        expect((c.photo.value as PhotoFailed).retryable, isFalse, reason: code);
        await c.send('احكيلك بالكلام $code');
        expect(c.photo.value, isA<PhotoIdle>(), reason: code);
        expect(c.photoImage, isNull);
        expect(c.messages.last.text, 'تمام', reason: code);
        expect(c.messages.where((m) => m.localImage != null), isEmpty);
      }
      expect(server.count('/chat'), 5);
      expect(server.count('/chat/stream'), 0);
    });

    test('retry of the turn reuses the image_ref: no new upload', () async {
      await c.open();
      await ready();
      server.failStreamWith = 502; // may have run: recovery finds nothing, the bubble fails
      server.failStreamTimes = 1;
      await c.send('شو هاد؟');
      expect(c.messages.last.state, MessageState.failed);
      await c.retry(c.messages.last);
      expect(server.count('/chat/upload'), 1);
      expect(server.count('/chat/stream'), 2);
      expect(jsonDecode(server.bodies['/chat/stream']!.last)['image_ref'], 'img_ref_1');
      expect(c.messages.last.text, 'هاي الصورة');
    });

    test('a tap send while a photo is attached neither takes it nor waits for it', () async {
      await c.open();
      await ready();
      await c.send('ضيف', synthetic: true);
      expect(server.count('/chat/stream'), 0);
      expect(c.photo.value, isA<PhotoReady>());
    });

    test('reset drops the photo', () async {
      await c.open();
      await ready();
      await c.reset();
      expect(c.photo.value, isA<PhotoIdle>());
      expect(c.photoImage, isNull);
    });

    test('an expired image_ref (400, no error key): one re-upload, same client_message_id, turn succeeds', () async {
      await c.open();
      await ready();
      server
        ..failStreamWith = 400
        ..failStreamTimes = 1
        ..failStreamBody = {'message': 'image_ref is invalid or expired'};
      await c.send('شو هاد؟');
      expect(server.count('/chat/upload'), 2);
      expect(server.count('/chat/stream'), 2);
      final bodies = [for (final b in server.bodies['/chat/stream']!) jsonDecode(b) as Map];
      expect(bodies.map((b) => b['image_ref']).toList(), ['img_ref_1', 'img_ref_2']);
      expect(bodies[0]['client_message_id'], bodies[1]['client_message_id']);
      expect(c.messages.last.text, 'هاي الصورة');
    });

    test('a second 400 is final: no re-upload loop', () async {
      await c.open();
      await ready();
      server
        ..failStreamWith = 400
        ..failStreamTimes = 2
        ..failStreamBody = {'message': 'image_ref is invalid or expired'};
      await c.send('شو هاد؟');
      expect(server.count('/chat/upload'), 2);
      expect(server.count('/chat/stream'), 2);
      expect(c.messages.last.state, MessageState.failed);
      expect(c.messages.last.errorCode, 'http_400');
    });

    test('a ref older than 55 minutes is uploaded again at send time; a fresher one is not', () async {
      var now = DateTime(2026, 1, 1, 12);
      c.dispose();
      c = make(clock: () => now);
      await c.open();
      await ready();
      now = now.add(const Duration(minutes: 54));
      await c.send('شو هاد؟');
      expect(server.count('/chat/upload'), 1);
      await ready(); // upload #2 at t = 54 min
      now = now.add(const Duration(minutes: 56));
      await c.send('وهاد؟');
      expect(server.count('/chat/upload'), 3);
      expect(server.count('/chat/stream'), 2);
      expect(jsonDecode(server.bodies['/chat/stream']!.last)['image_ref'], 'img_ref_3');
    });

    test('a stale-ref re-upload that a reset overtakes never streams the old photo as the new shopper', () async {
      var now = DateTime(2026, 1, 1, 12);
      c.dispose();
      c = make(clock: () => now);
      await c.open();
      await ready();
      now = now.add(const Duration(minutes: 56));
      final gate = Completer<void>();
      server.beforeUpload = () => gate.future;
      final sending = c.send('old shopper photo');
      await server.until(() => server.count('/chat/upload') == 2);
      final resetting = c.reset();
      gate.complete();
      await Future.wait([sending, resetting]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.count('/chat/stream'), 0);
      expect(c.messages, isEmpty);
    });

    test('a 400 after a reset never re-uploads the old photo as the new shopper', () async {
      await c.open();
      await ready();
      final gate = Completer<void>();
      server
        ..beforeStream = (() => gate.future)
        ..failStreamWith = 400
        ..failStreamTimes = 1
        ..failStreamBody = {'message': 'image_ref is invalid or expired'};
      final sending = c.send('old shopper photo');
      await server.until(() => server.count('/chat/stream') == 1);
      final resetting = c.reset();
      gate.complete();
      await Future.wait([sending, resetting]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.count('/chat/upload'), 1, reason: 'only the original attach');
      expect(server.count('/chat/stream'), 1);
      expect(c.messages, isEmpty);
    });

    test('reset during an upload: the old shopper\'s photo never lands, the upload client is closed', () async {
      await c.open();
      final gate = Completer<void>();
      server.beforeUpload = () => gate.future;
      final up = c.attachPhoto(SunonoImage(_jpeg()));
      await server.until(() => server.count('/chat/upload') == 1);
      final reset = c.reset();
      expect(c.photo.value, isA<PhotoIdle>(), reason: 'cleared before the first await');
      await reset;
      expect(uploadClientClosed(), isTrue);
      gate.complete();
      await up;
      expect(c.photo.value, isA<PhotoIdle>());
      expect(c.photoImage, isNull);
    });

    test('dispose during an upload: no state after dispose, the upload client is closed', () async {
      final d = make();
      await d.open();
      final gate = Completer<void>();
      server.beforeUpload = () => gate.future;
      final up = d.attachPhoto(SunonoImage(_jpeg()));
      await server.until(() => server.count('/chat/upload') == 1);
      d.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(uploadClientClosed(), isTrue);
      gate.complete();
      await up; // would throw on a disposed notifier if it still wrote
    });

    test('platform_disabled during an upload clears the photo (the chat is off), not "offline"', () async {
      await c.open();
      server.failUploadOnce = (403, 'platform_disabled');
      await c.attachPhoto(SunonoImage(_jpeg()));
      expect(c.photo.value, isA<PhotoIdle>());
      expect(c.status, ChatStatus.disabled);
    });

    test('customer_blocked (403) is its own code', () async {
      await c.open();
      server.failUploadOnce = (403, 'customer_blocked');
      await c.attachPhoto(SunonoImage(_jpeg()));
      expect((c.photo.value as PhotoFailed).code, 'customer_blocked');
    });
  });

  group('composer', () {
    Widget app(Widget child, {double scale = 1}) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
                disableAnimations: true, size: const Size(400, 800), textScaler: TextScaler.linear(scale)),
            child: Scaffold(body: child),
          ),
        );

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<void> pump(WidgetTester tester, {String lang = 'ar', double scale = 1}) async {
      c.dispose();
      c = SunonoChatController(
        api: SunonoApi(
          shopKey: 'pk_test',
          apiBase: 'https://api.test/api',
          appOrigin: 'https://shop.example',
          clientFactory: () => MockClient.streaming(server.handle),
        ),
        storage: MemoryStorage(),
        lang: lang,
        recoveryChecks: const [Duration(milliseconds: 5)],
      );
      await tester
          .pumpWidget(app(SunonoChatView(controller: c, pickImage: () async => SunonoImage(_jpeg())), scale: scale));
      await settle(tester);
    }

    Future<void> tapSend(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await settle(tester);
    }

    testWidgets('empty caption: Send is tappable, shows the inline hint and sends nothing', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('أرفق صورة'));
      await settle(tester);
      expect(c.photo.value, isA<PhotoReady>());
      expect(find.text('اكتب سؤالك عن الصورة…'), findsOneWidget, reason: 'placeholder only');
      await tapSend(tester);
      expect(server.count('/chat/stream'), 0);
      expect(c.messages.where((m) => m.role == ChatRole.user), isEmpty);
      expect(find.text('اكتب سؤالك عن الصورة…'), findsNWidgets(2), reason: 'placeholder + inline hint');
      await tester.enterText(find.byType(TextField), 'شو هاد');
      await tester.pump();
      expect(find.text('اكتب سؤالك عن الصورة…'), findsOneWidget,
          reason: 'the inline hint is gone (placeholder fades in place)');
      await tapSend(tester);
      expect(server.count('/chat/stream'), 1);
      expect(server.count('/chat/upload'), 1);
      await tester.pumpWidget(const SizedBox());
      c.suspend(); // the live connection outlives the view
    });

    testWidgets('image_unavailable shows the per-code copy without Retry; picking again uploads anew', (tester) async {
      await pump(tester);
      server.failUploadOnce = (503, 'image_unavailable');
      await tester.tap(find.byTooltip('أرفق صورة'));
      await settle(tester);
      expect(find.text('الصور مش متاحة هلّق، احكيلي شو بدك بالكلام'), findsOneWidget);
      expect(find.text('أعد المحاولة'), findsNothing);
      await tester.tap(find.byTooltip('أرفق صورة'));
      await settle(tester);
      expect(find.text('الصور مش متاحة هلّق، احكيلي شو بدك بالكلام'), findsNothing);
      expect(c.photo.value, isA<PhotoReady>());
      expect(server.count('/chat/upload'), 2);
      await tester.pumpWidget(const SizedBox());
      c.suspend(); // the live connection outlives the view
    });

    testWidgets('a retryable failure shows Retry, which re-uploads', (tester) async {
      await pump(tester);
      server.failUploadOnce = (429, 'rate_limited');
      await tester.tap(find.byTooltip('أرفق صورة'));
      await settle(tester);
      await tester.tap(find.text('أعد المحاولة'));
      await settle(tester);
      expect(c.photo.value, isA<PhotoReady>());
      expect(server.count('/chat/upload'), 2);
      await tester.pumpWidget(const SizedBox());
      c.suspend(); // the live connection outlives the view
    });

    testWidgets('customer_blocked copy; a failed unusable photo: Send is tappable, no Retry, text goes alone',
        (tester) async {
      await pump(tester, lang: 'en');
      server.failUploadOnce = (403, 'customer_blocked');
      await tester.tap(find.byTooltip('Attach a photo'));
      await settle(tester);
      expect(find.text("We can't accept photos right now"), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      await tapSend(tester); // empty text: nothing to send
      expect(server.count('/chat'), 0);
      await tester.enterText(find.byType(TextField), 'what do you have?');
      await tester.pump();
      await tapSend(tester);
      expect(server.count('/chat'), 1);
      expect(server.count('/chat/stream'), 0);
      expect(c.photo.value, isA<PhotoIdle>());
      expect(find.text("We can't accept photos right now"), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.suspend(); // the live connection outlives the view
    });

    testWidgets('a retryable failure keeps Send inert until Retry works', (tester) async {
      await pump(tester, lang: 'en');
      server.failUploadOnce = (429, 'rate_limited');
      await tester.tap(find.byTooltip('Attach a photo'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'what is this');
      await tester.pump();
      await tapSend(tester);
      expect(server.count('/chat'), 0);
      expect(c.photo.value, isA<PhotoFailed>());
      await tester.tap(find.text('Retry'));
      await settle(tester);
      await tapSend(tester);
      expect(server.count('/chat/stream'), 1);
      await tester.pumpWidget(const SizedBox());
      c.suspend(); // the live connection outlives the view
    });

    testWidgets('initialMessage never takes the photo: a ready one stays, the text goes alone', (tester) async {
      await tester.runAsync(() async {
        await c.open();
        await c.attachPhoto(SunonoImage(_jpeg()));
      });
      await tester.pumpWidget(app(SunonoChatView(controller: c, initialMessage: 'hi there')));
      await settle(tester);
      expect(server.bodies['/chat']!.single, contains('hi there'));
      expect(server.count('/chat/stream'), 0);
      expect(c.photo.value, isA<PhotoReady>());
      await tester.pumpWidget(const SizedBox());
      c.suspend();
    });

    testWidgets('initialMessage goes out while a photo is still uploading', (tester) async {
      final gate = Completer<void>();
      server.beforeUpload = () => gate.future;
      await tester.runAsync(c.open);
      unawaited(c.attachPhoto(SunonoImage(_jpeg())));
      await tester.pumpWidget(app(SunonoChatView(controller: c, initialMessage: 'hi there')));
      await settle(tester);
      expect(server.bodies['/chat']!.single, contains('hi there'));
      expect(c.photo.value, isA<PhotoUploading>());
      gate.complete();
      await settle(tester);
      expect(c.photo.value, isA<PhotoReady>());
      await tester.pumpWidget(const SizedBox());
      c.suspend();
    });

    testWidgets('remove-photo has a 48 dp target around its small button', (tester) async {
      await pump(tester, lang: 'en');
      await tester.tap(find.byTooltip('Attach a photo'));
      await settle(tester);
      expect(c.photo.value, isA<PhotoReady>());
      final button = find.byTooltip('Remove photo');
      final visual = tester.getRect(button);
      expect(visual.height, lessThanOrEqualTo(40), reason: 'the visible button stays small');
      await tester.tapAt(visual.bottomCenter + const Offset(0, 8)); // below the visible circle
      await settle(tester);
      expect(c.photo.value, isA<PhotoIdle>());
      await tester.pumpWidget(const SizedBox());
      c.suspend();
    });

    testWidgets('English copy, remove button aborts, 320 px at 200% lays out', (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await pump(tester, lang: 'en', scale: 2);
      server.failUploadOnce = (503, 'image_unavailable');
      await tester.tap(find.byTooltip('Attach a photo'));
      await settle(tester);
      expect(find.text("Photos aren't available right now — tell me in words"), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Remove photo'));
      await settle(tester);
      expect(c.photo.value, isA<PhotoIdle>());
      expect(find.text("Photos aren't available right now — tell me in words"), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.suspend(); // the live connection outlives the view
    });

    testWidgets('a too-large photo shows no Retry (same bytes would fail again)', (tester) async {
      c.dispose();
      c = SunonoChatController(
        api: SunonoApi(
          shopKey: 'pk_test',
          apiBase: 'https://api.test/api',
          clientFactory: () => MockClient.streaming(server.handle),
        ),
        storage: MemoryStorage(),
        lang: 'en',
      );
      await tester.pumpWidget(
          app(SunonoChatView(controller: c, pickImage: () async => SunonoImage(_jpeg(5 * 1024 * 1024 + 1)))));
      await settle(tester);
      await tester.tap(find.byTooltip('Attach a photo'));
      await settle(tester);
      expect(find.text('That photo is too large'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(server.count('/chat/upload'), 0);
      await tester.pumpWidget(const SizedBox());
      c.suspend(); // the live connection outlives the view
    });
  });
}
