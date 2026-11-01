import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/sunono.dart';

import 'fake_server.dart';

Uint8List _jpeg([int n = 64]) => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(n, 7)]);
Uint8List _png() => Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]);
Uint8List _webp() => Uint8List.fromList([...'RIFF'.codeUnits, 1, 2, 3, 4, ...'WEBP'.codeUnits, 9]);

void main() {
  late FakeServer server;
  late SunonoChatController c;

  SunonoChatController make({Duration? timeout}) => SunonoChatController(
        api: SunonoApi(
          shopKey: 'pk_test',
          apiBase: 'https://api.test/api',
          appOrigin: 'https://shop.example',
          clientFactory: () => MockClient.streaming(server.handle),
          turnTimeout: timeout ?? const Duration(seconds: 90),
          requestTimeout: timeout ?? const Duration(seconds: 15),
        ),
        storage: MemoryStorage(),
        recoveryChecks: const [Duration(milliseconds: 5)],
      );

  setUp(() {
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

    test('over 10 MB is image_too_large without uploading; exactly 10 MB goes through', () async {
      await c.open();
      await c.attachPhoto(SunonoImage(_jpeg(10 * 1024 * 1024)));
      expect((c.photo.value as PhotoFailed).code, 'image_too_large');
      expect(server.count('/chat/upload'), 0);
      await c.attachPhoto(SunonoImage(_jpeg(10 * 1024 * 1024 - 4)));
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

    test('send holds back while the photo is uploading or failed (nothing is dropped silently)', () async {
      await c.open();
      server.failUploadOnce = (503, 'image_unavailable');
      await c.attachPhoto(SunonoImage(_jpeg()));
      await c.send('شو هاد؟');
      expect(c.messages, isEmpty);
      expect(c.photo.value, isA<PhotoFailed>());
    });

    test('retry of the turn reuses the image_ref: no new upload', () async {
      await c.open();
      await ready();
      server.failStreamOnce = 400;
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
    });

    testWidgets('image_unavailable shows the per-code copy under the preview; Retry re-uploads', (tester) async {
      await pump(tester);
      server.failUploadOnce = (503, 'image_unavailable');
      await tester.tap(find.byTooltip('أرفق صورة'));
      await settle(tester);
      expect(find.text('الصور مش متاحة هلّق، احكيلي شو بدك بالكلام'), findsOneWidget);
      await tester.tap(find.text('أعد المحاولة'));
      await settle(tester);
      expect(find.text('الصور مش متاحة هلّق، احكيلي شو بدك بالكلام'), findsNothing);
      expect(c.photo.value, isA<PhotoReady>());
      expect(server.count('/chat/upload'), 2);
      await tester.pumpWidget(const SizedBox());
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
          app(SunonoChatView(controller: c, pickImage: () async => SunonoImage(_jpeg(10 * 1024 * 1024 + 1)))));
      await settle(tester);
      await tester.tap(find.byTooltip('Attach a photo'));
      await settle(tester);
      expect(find.text('That photo is too large'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(server.count('/chat/upload'), 0);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
