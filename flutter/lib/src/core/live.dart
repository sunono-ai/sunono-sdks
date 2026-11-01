import 'dart:async';

import 'api.dart';
import 'session.dart';
import 'sse.dart';

/// The live subscription (PROTOCOL §7): ticket → SSE, reconnect with backoff,
/// a ping watchdog, and [beforeConnect] (history refetch) on every connect,
/// since the server keeps no replay.
class LiveConnection {
  LiveConnection({
    required SunonoApi api,
    required Session session,
    required this.onEvent,
    required this.beforeConnect,
    this.onError,
    this.backoff = const [Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 15)],
    this.staleAfter = const Duration(seconds: 60),
  })  : _api = api,
        _session = session;

  final SunonoApi _api;
  final Session _session;
  final void Function(String type, Map<String, dynamic> data) onEvent;
  final Future<void> Function() beforeConnect;
  final void Function(Object error, StackTrace stack)? onError;
  final List<Duration> backoff;
  final Duration staleAfter;

  bool _running = false;
  int _attempt = 0;
  int _generation = 0;
  Timer? _retry;
  Timer? _watchdog;
  StreamSubscription<SseFrame>? _sub;
  void Function()? _close;
  DateTime _lastFrame = DateTime.now();

  bool get running => _running;

  void start() {
    if (_running) return;
    _running = true;
    _attempt = 0;
    _connect();
  }

  void stop() {
    _running = false;
    _generation++;
    _teardown();
  }

  void _teardown() {
    _retry?.cancel();
    _watchdog?.cancel();
    // Closing the client errors the half-cancelled stream; that error lands in
    // the cancel future, so drop it (we closed on purpose) instead of leaking
    // an uncaught async error into the host's crash reporter.
    _sub?.cancel().ignore();
    _close?.call();
    _retry = _watchdog = null;
    _sub = null;
    _close = null;
  }

  Future<void> _connect() async {
    final gen = ++_generation;
    _teardown();
    try {
      await beforeConnect();
      if (gen != _generation) return;
      final ticket = await _session.authed(_api.subscribeTicket);
      if (gen != _generation) return;
      final live = await _api.subscribe(ticket);
      if (gen != _generation) {
        live.close();
        return;
      }
      _close = live.close;
      final connectedAt = _lastFrame = DateTime.now();
      _sub = live.frames.listen(
        (f) {
          _lastFrame = DateTime.now();
          // Reset the backoff only once the stream has proved stable, so a
          // proxy that drops us right after the first ping can't make a
          // 2-second reconnect (and history fetch) loop.
          if (_lastFrame.difference(connectedAt) > const Duration(seconds: 30)) _attempt = 0;
          final type = f.event ?? f.json?['type'] as String?;
          if (type == null || type == 'ping') return;
          final data = f.json?['data'];
          onEvent(type, data is Map ? data.cast<String, dynamic>() : const {});
        },
        onError: (Object e, StackTrace s) => _drop(gen, e, s),
        onDone: () => _drop(gen, null, null),
        cancelOnError: true,
      );
      _watchdog = Timer.periodic(staleAfter ~/ 4, (_) {
        if (DateTime.now().difference(_lastFrame) > staleAfter) _drop(gen, null, null);
      });
    } catch (e, s) {
      _drop(gen, e, s);
    }
  }

  void _drop(int gen, Object? error, StackTrace? stack) {
    if (gen != _generation || !_running) return;
    if (error != null) onError?.call(error, stack ?? StackTrace.current);
    _teardown();
    final delay = backoff[_attempt < backoff.length ? _attempt : backoff.length - 1];
    _attempt++;
    _retry = Timer(delay, () {
      if (_running && gen == _generation) _connect();
    });
  }
}
