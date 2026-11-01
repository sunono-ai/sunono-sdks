import 'dart:math';

import 'api.dart';
import 'host.dart';

/// The anonymous shopper (durable `user_id`) and its short-lived token
/// (PROTOCOL §2). Token fetches are single-flight.
class Session {
  Session(this._api, this._storage, {this.onPlatformDisabled});

  final SunonoApi _api;
  final SunonoStorage _storage;

  /// Called when any authed call is answered `403 platform_disabled`.
  final void Function()? onPlatformDisabled;

  String get _key => 'sunono.user_id.${_api.shopKey}';

  String? _userId;
  String? _token;
  Future<String>? _pending;
  Future<String>? _idPending;

  /// Bumped by [reset]: an init or id read that started before it is dropped.
  int _gen = 0;

  String? get userId => _userId;

  /// The persisted shopper id, minted locally on first use. Single-flight,
  /// so concurrent first calls can't mint two different shoppers.
  Future<String> ensureUserId() {
    if (_userId != null) return Future.value(_userId!);
    final pending = _idPending;
    if (pending != null) return pending;
    late final Future<String> f;
    f = _idPending = _loadId(_gen).whenComplete(() {
      if (identical(_idPending, f)) _idPending = null;
    });
    return f;
  }

  Future<String> _loadId(int gen) async {
    var id = await _storage.read(_key);
    if (id == null || !_uuid.hasMatch(id)) {
      id = uuidV4();
      await _storage.write(_key, id);
    }
    if (gen == _gen) _userId = id;
    return id;
  }

  /// The shopper id in memory or storage, without minting one.
  Future<String?> storedUserId() async {
    if (_userId != null) return _userId;
    final id = await _storage.read(_key);
    return id != null && _uuid.hasMatch(id) ? id : null;
  }

  /// A valid token; [force] re-inits (after a 401/422).
  Future<String> token({bool force = false}) {
    if (!force && _token != null) return Future.value(_token!);
    final pending = _pending;
    if (pending != null) return pending;
    late final Future<String> f;
    f = _pending = _init(_gen).whenComplete(() {
      if (identical(_pending, f)) _pending = null;
    });
    return f;
  }

  Future<String> _init(int gen) async {
    final id = await ensureUserId();
    final res = await _api.init(id);
    if (gen != _gen) throw StateError('shopper was reset during init');
    if (res.userId != id) {
      // The server rejected our id and minted one: adopt it.
      _userId = res.userId;
      await _storage.write(_key, res.userId);
    }
    return _token = res.token;
  }

  /// Runs [call] with a token, re-initing once on an auth failure.
  Future<T> authed<T>(Future<T> Function(String token) call) async {
    try {
      try {
        return await call(await token());
      } on SunonoHttpException catch (e) {
        if (!e.isAuth) rethrow;
        return await call(await token(force: true));
      }
    } on SunonoHttpException catch (e) {
      if (e.isPlatformDisabled) onPlatformDisabled?.call();
      rethrow;
    }
  }

  /// Forget the shopper (logout / account switch): next use mints a new one.
  Future<void> reset() async {
    _gen++;
    _userId = null;
    _token = null;
    _pending = null;
    _idPending = null;
    await _storage.delete(_key);
  }
}

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

String uuidV4([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}
