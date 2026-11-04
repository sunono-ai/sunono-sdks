import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sunono/sunono.dart';
import 'package:sunono/src/ui/composer.dart';
import 'package:sunono/src/ui/copy.dart';

import 'fake_server.dart';

void main() {
  late FakeServer server;
  late SunonoChatController c;

  setUp(() => server = FakeServer());

  SunonoChatController make(String lang) => c = SunonoChatController(
        api: SunonoApi(
          shopKey: 'pk_test',
          apiBase: 'https://api.test/api',
          appOrigin: 'https://shop.example',
          clientFactory: () => MockClient.streaming(server.handle),
        ),
        storage: MemoryStorage(),
        lang: lang,
        onIntent: (_) => true,
      );

  Widget app(Widget child, {double textScale = 1}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true, textScaler: TextScaler.linear(textScale)),
          child: Scaffold(body: child),
        ),
      );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    server.close();
  }

  final send = find.byIcon(Icons.arrow_upward_rounded);

  testWidgets('send is a 48 dp button, focusable, and Enter on focus sends', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
    await settle(tester);
    expect(tester.getSize(find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded)), const Size(48, 48));
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(
        tester.getSemantics(find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded)),
        // isSemantics replaces it from Flutter 3.40; the floor is 3.27.
        // ignore: deprecated_member_use
        containsSemantics(tooltip: 'Send', isButton: true, isEnabled: true));
    Focus.of(tester.element(send)).requestFocus();
    await tester.pump();
    expect(Focus.of(tester.element(send)).hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(server.bodies['/chat']!.single, contains('hello'));
    await finish(tester);
    semantics.dispose();
  });

  testWidgets('no pickImage: no + at all; with one, + opens the sheet with Photo', (tester) async {
    await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
    await settle(tester);
    expect(find.byIcon(Icons.add_rounded), findsNothing);
    expect(find.byTooltip('Attach'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();

    var picks = 0;
    await tester.pumpWidget(app(SunonoChatView(
        controller: make('ar'),
        pickImage: () async {
          picks++;
          return null;
        })));
    await settle(tester);
    expect(tester.getSize(find.widgetWithIcon(IconButton, Icons.add_rounded)), const Size(48, 48));
    // RTL: + at the start (right), send at the end (left).
    expect(tester.getCenter(find.byTooltip('إرفاق')).dx, greaterThan(tester.getCenter(send).dx));
    await tester.tap(find.byTooltip('إرفاق'));
    await settle(tester);
    expect(find.text('صورة'), findsOneWidget);
    expect(picks, 0, reason: 'the sheet first, the picker on Photo');
    await tester.tap(find.text('صورة'));
    await settle(tester);
    expect(picks, 1);
    expect(find.text('صورة'), findsNothing, reason: 'the sheet is closed before the picker');
    await finish(tester);
  });

  group('mic slot', () {
    Widget composer({required String text, PhotoState photo = const PhotoIdle(), VoidCallback? onMic}) => app(
          Align(
            alignment: Alignment.bottomCenter,
            child: Composer(
              theme: const SunonoTheme(),
              controller: TextEditingController(text: text),
              focus: FocusNode(),
              hint: 'Type a message…',
              canSend: text.isNotEmpty,
              onSend: () {},
              onPickPhoto: null,
              photo: photo,
              image: photo is PhotoIdle ? null : SunonoImage(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0])),
              needCaption: false,
              onRemovePhoto: () {},
              onRetryPhoto: () {},
              copy: SunonoCopy.of('en'),
              onMic: onMic,
            ),
          ),
        );
    final mic = find.byTooltip('Record a voice message');

    testWidgets('empty input + a recorder: the mic (48 dp) takes the send slot', (tester) async {
      var taps = 0;
      await tester.pumpWidget(composer(text: '', onMic: () => taps++));
      expect(mic, findsOneWidget);
      expect(send, findsNothing);
      expect(tester.getSize(find.widgetWithIcon(IconButton, Icons.mic_none_rounded)), const Size(48, 48));
      await tester.tap(mic);
      expect(taps, 1);
    });

    testWidgets('typed text or an attached photo: send again; no recorder: never a mic', (tester) async {
      await tester.pumpWidget(composer(text: 'hi', onMic: () {}));
      expect(mic, findsNothing);
      expect(send, findsOneWidget);
      await tester.pumpWidget(composer(text: '', photo: const PhotoReady('r'), onMic: () {}));
      expect(mic, findsNothing);
      expect(send, findsOneWidget);
      await tester.pumpWidget(composer(text: ''));
      expect(mic, findsNothing);
      expect(send, findsOneWidget);
    });
  });

  for (final lang in ['ar', 'en']) {
    testWidgets('320 dp at 200% ($lang): the hint stays on one line, nothing overflows', (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(SunonoChatView(controller: make(lang), pickImage: () async => null), textScale: 2));
      await settle(tester);
      expect(tester.takeException(), isNull);
      final hint = find.text(SunonoCopy.of(lang).inputHint);
      expect(hint, findsOneWidget);
      // One line of 15 sp at 200% is ~35-45 dp; two would be ~80.
      expect(tester.getSize(hint).height, lessThan(55));
      expect(tester.getSize(send).width, lessThanOrEqualTo(48), reason: 'icons do not scale with text');
      await finish(tester);
    });
  }

  testWidgets('the input grows with lines up to a cap, then scrolls', (tester) async {
    await tester.pumpWidget(app(SunonoChatView(controller: make('en'))));
    await settle(tester);
    final one = tester.getSize(find.byType(TextField)).height;
    await tester.enterText(find.byType(TextField), 'a\nb\nc');
    await tester.pump();
    final three = tester.getSize(find.byType(TextField)).height;
    expect(three, greaterThan(one));
    await tester.enterText(find.byType(TextField), List.filled(20, 'line').join('\n'));
    await tester.pump();
    final many = tester.getSize(find.byType(TextField)).height;
    expect(many, lessThan(one * 4), reason: 'capped at 5 lines');
    expect(tester.getBottomLeft(find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded)).dy,
        closeTo(tester.getBottomLeft(find.byType(TextField)).dy, 1),
        reason: 'send stays at the bottom as the input grows');
    await finish(tester);
  });
}
