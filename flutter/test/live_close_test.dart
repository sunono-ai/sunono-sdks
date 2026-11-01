import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sunono/sunono.dart';
import 'package:sunono/src/core/live.dart';
import 'package:sunono/src/core/session.dart';

// A real socket: closing the client mid-stream makes the response stream
// error, which in-memory fakes never do.
void main() {
  test('stopping a live connection leaks no uncaught error', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final opened = Completer<void>();
    server.listen((req) async {
      final path = req.uri.path;
      final res = req.response..headers.contentType = ContentType.json;
      if (path.endsWith('/shops/init')) {
        res.write(jsonEncode({'access_token': 'tok', 'user_id': '00000000-0000-4000-8000-000000000001'}));
      } else if (path.endsWith('/chat/subscribe-ticket')) {
        res.write(jsonEncode({'ticket': 't'}));
      } else if (path.endsWith('/chat/subscribe')) {
        res
          ..headers.contentType = ContentType('text', 'event-stream')
          ..bufferOutput = false
          ..write('data: {"type":"ping"}\n\n');
        await res.flush();
        if (!opened.isCompleted) opened.complete();
        return; // hold the stream open
      }
      await res.close();
    });

    final uncaught = <Object>[];
    await runZonedGuarded(() async {
      final api = SunonoApi(shopKey: 'pk_test', apiBase: 'http://127.0.0.1:${server.port}/api', platform: 'android');
      final live = LiveConnection(
        api: api,
        session: Session(api, MemoryStorage()),
        onEvent: (_, __) {},
        beforeConnect: () async {},
      );
      live.start();
      await opened.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      live.stop();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }, (e, _) => uncaught.add(e));

    await server.close(force: true);
    expect(uncaught, isEmpty);
  });
}
