import 'dart:math';

import 'api.dart';
import 'host.dart';

/// The anonymous shopper (durable `user_id`) and its short-lived token
/// (PROTOCOL §2). Token fetches are single-flight.
class Session {
  Session(this._api, this._storage, {this.onPlatformDisabled, this.onStorageError});

  final SunonoApi _api;
  final SunonoStorage _storage;

  /// Called when any authed call is answered `403 platform_disabled`.
  final void Function()? onPlatformDisabled;

  /// Called when storage fails or hangs past [storageTimeout]; chat goes on
  /// with the id in memory.
  final void Function(Object error, StackTrace stack)? onStorageError;

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
    // Never read back the id a reset is deleting. If that delete failed or
    // hung, the key may still hold the old shopper: mint a fresh one instead
    // and overwrite the key as best we can. A read that fails or hangs mints
    // one for this process too, so chat never waits on a broken keychain.
    final clean = await (_clearing ?? Future.value(true));
    String? id;
    var readFailed = false;
    if (clean) {
      try {
        id = await _storage.read(_key).timeout(storageTimeout);
      } catch (e, s) {
        readFailed = true;
        onStorageError?.call(e, s);
      }
    }
    if (id == null || !_uuid.hasMatch(id)) {
      id = uuidV4();
      // A failed read may be transient (a keychain before first unlock): never
      // overwrite the stored shopper with this process-only id.
      if (!readFailed) await _save(id);
    }
    if (gen == _gen) _userId = id;
    return id;
  }

  /// Best effort: a failed or hung write keeps the id in memory only.
  Future<void> _save(String id) async {
    try {
      await _storage.write(_key, id).timeout(storageTimeout);
    } catch (e, s) {
      onStorageError?.call(e, s);
    }
  }

  /// The current token, if one was fetched (for a forget after [reset]).
  String? get currentToken => _token;

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
      await _save(res.userId);
    }
    return _token = res.token;
  }

  /// Runs [call] with a token, re-initing once on an auth failure. A call
  /// that started before a [reset] is never replayed as the new shopper.
  Future<T> authed<T>(Future<T> Function(String token) call) async {
    final gen = _gen;
    try {
      try {
        return await call(await token());
      } on SunonoHttpException catch (e) {
        if (!e.isAuth) rethrow;
        if (gen != _gen) throw StateError('shopper was reset during the call');
        return await call(await token(force: true));
      }
    } on SunonoHttpException catch (e) {
      if (e.isPlatformDisabled) onPlatformDisabled?.call();
      rethrow;
    }
  }

  /// Forget the shopper (logout / account switch): next use mints a new one.
  /// Memory is cleared before this returns; the future resolves to the id that
  /// was stored once it is deleted, or null (none stored, or storage failed or
  /// hung past [storageTimeout]). It never throws.
  Future<String?> reset() {
    _gen++;
    _userId = null;
    _token = null;
    _pending = null;
    _idPending = null;
    final clear = _clear().timeout(storageTimeout);
    _clearing = clear.then((_) => true, onError: (Object _) => false);
    return clear.then<String?>((id) => id, onError: (Object _) => null);
  }

  /// Whether the last reset's delete went through.
  Future<bool>? _clearing;

  Future<String?> _clear() async {
    final id = await _storage.read(_key);
    await _storage.delete(_key);
    return id != null && _uuid.hasMatch(id) ? id : null;
  }
}

/// The longest a reset waits on storage before treating it as failed.
const storageTimeout = Duration(seconds: 5);

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

String uuidV4([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}
