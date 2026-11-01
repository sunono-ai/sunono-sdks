import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import 'api.dart';
import 'format.dart';
import 'host.dart';
import 'live.dart';
import 'models.dart';
import 'session.dart';
import 'sse.dart';

/// The server refuses larger photos (`413 image_too_large`).
const _maxPhotoBytes = 10 * 1024 * 1024;

/// The server signs an `image_ref` for about an hour; refresh before that.
const _imageRefMaxAge = Duration(minutes: 55);

/// JPEG, PNG or WebP by magic bytes (the filename and the host's word don't count).
bool _isSupportedImage(List<int> b) {
  bool at(int i, List<int> sig) {
    if (b.length < i + sig.length) return false;
    for (var k = 0; k < sig.length; k++) {
      if (b[i + k] != sig[k]) return false;
    }
    return true;
  }

  return at(0, [0xFF, 0xD8, 0xFF]) ||
      at(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) ||
      (at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50]));
}

enum ChatRole { user, bot, staff, system }

enum MessageState {
  /// Bot placeholder waiting on the turn.
  thinking,

  /// The request may have reached the server; checking history (PROTOCOL §10).
  recovering,

  /// Failed for sure, or recovery found nothing: show a retry chip.
  failed,
  done,
}

enum ChatStatus { idle, loading, ready, disabled }

/// One bubble on screen.
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    this.text = '',
    this.imageUrl,
    this.localImage,
    this.products = const [],
    this.hasMore = false,
    this.checkout,
    this.handoffUrl,
    this.orderIds,
    this.msgRef,
    this.clientRef,
    DateTime? ts,
    this.state = MessageState.done,
    this.stage,
    this.replyLang,
    this.errorCode,
  }) : ts = ts ?? DateTime.now();

  final String id;
  final ChatRole role;
  String text;
  String? imageUrl;
  Uint8List? localImage;
  List<ProductCard> products;
  bool hasMore;
  Checkout? checkout;
  String? handoffUrl;

  /// Ids of the order this reply is about (placed, or its status).
  OrderIds? orderIds;
  String? msgRef;

  /// The staff composer's `client_ref` from a live `message.new` (live dedupe).
  String? clientRef;
  DateTime ts;
  MessageState state;
  String? stage;
  String? replyLang;

  /// Why a send failed (`image_too_large`, `rate_limited`, `offline`, …).
  String? errorCode;

  /// For a retry: what was sent.
  _Outgoing? _outgoing;
}

class _Outgoing {
  _Outgoing(this.text, this.synthetic, this.image, this.imageRef, this.imageReadyAt, this.productId, this.productSku,
      this.tap, this.user);

  /// Minted once per message and reused by every retry, so the server can
  /// answer a repeat with the stored reply instead of running the turn twice.
  final String clientMessageId = uuidV4();
  final String text;
  final bool synthetic;

  /// The photo, kept so an expired `image_ref` can be re-uploaded.
  final SunonoImage? image;

  /// The uploaded photo's `image_ref`; a retry of the turn reuses it while it
  /// is fresh (the server signs refs for about an hour).
  String? imageRef;
  DateTime? imageReadyAt;
  final String? productId;
  final String? productSku;
  final ({String action, String ref})? tap;

  /// The shopper's bubble for this send.
  final ChatMessage user;
}

/// The chat state machine. UI-free: a host can drive its own UI from it.
///
/// Once a view [attach]es, the controller follows the app lifecycle itself:
/// the live connection runs while it is open and the app is in the
/// foreground, whether or not a view is showing, so [unread] keeps counting.
/// A host that drives it headless ([open] without [attach]) must call
/// [suspend] and [resume] on the app lifecycle itself.
class SunonoChatController extends ChangeNotifier with WidgetsBindingObserver {
  /// [lang] null follows the shop's `default_language` once config loads.
  SunonoChatController({
    required SunonoApi api,
    required SunonoStorage storage,
    String? lang,
    this.cartBridge,
    this.nativeCheckout = false,
    this.onIntent,
    this.starterPrompts,
    this.recoveryChecks = const [Duration(seconds: 4), Duration(seconds: 8), Duration(seconds: 18)],
    DateTime Function() clock = DateTime.now,
  })  : _api = api,
        _storage = storage,
        _clock = clock,
        _lang = lang ?? 'ar',
        _langPinned = lang != null {
    _session = Session(api, storage,
        onPlatformDisabled: () => _disable('platform_disabled'), onStorageError: (e, s) => _emit(ErrorEvent(e, s)));
    _live = LiveConnection(
      api: api,
      session: _session,
      onEvent: _onLive,
      beforeConnect: refreshHistory,
      onError: (e, s) => _emit(ErrorEvent(e, s)),
    );
  }

  final SunonoApi _api;
  final SunonoStorage _storage;
  late final Session _session;
  late final LiveConnection _live;
  final SunonoCartBridge? cartBridge;

  /// The host finishes checkout in its own screen (`CheckoutIntent`): the
  /// handoff button says so. False = the web checkout.
  final bool nativeCheckout;

  /// Returns true when the host handled the intent.
  bool Function(SunonoIntent intent)? onIntent;

  /// Host override of the empty-thread starter chips, by language (`ar` / `en`).
  /// A language that is missing uses the SDK defaults; an empty list shows none.
  final Map<String, List<String>>? starterPrompts;

  /// Delays between history checks while recovering (cumulative waits).
  final List<Duration> recoveryChecks;

  /// The shopper a [reset] still has to detach on the server (written before
  /// the forget is sent, removed once it lands); [open] retries it.
  String get _pendingForgetKey => 'sunono.pending_forget.${_api.shopKey}';
  Future<void>? _forgetting;

  final DateTime Function() _clock;

  /// Config older than this is re-fetched on [resume].
  static const _configMaxAge = Duration(seconds: 60);

  /// The newest messages kept on screen (and in memory).
  static const _maxMessages = 300;

  final _events = StreamController<SunonoEvent>.broadcast();
  final List<ChatMessage> _messages = [];

  /// msg_refs trimmed off the top of [_messages] (grows only as the thread does).
  final Set<String> _trimmed = {};
  String _lang;

  /// The host chose the language: the shop's default no longer applies.
  bool _langPinned;
  ChatStatus _status = ChatStatus.idle;
  ShopConfig _config = const ShopConfig();
  DateTime? _configAt;
  String? _disabledReason;
  Cart? _cart;
  bool _paused = false;
  bool _typingHint = true;
  bool _busy = false;
  _Outgoing? _running;
  bool _bound = false;
  bool _ensureTried = false;

  /// Cart write ordering. Every pull or history fetch takes a ticket
  /// (`++_cartReq`) when it STARTS; a turn or live write takes the next one
  /// when applied. A response applies only if its ticket is newer than the last
  /// applied one, so an older snapshot never overwrites a newer one.
  int _cartReq = 0;
  int _cartApplied = 0;

  /// Bumped when the link is dropped: a bind that started before can't re-mark it linked.
  int _linkGen = 0;
  bool _disposed = false;
  int _seq = 0;

  /// Bumped by reset()/dispose(): late results for an old shopper are dropped.
  int _epoch = 0;

  /// Attached views currently on screen (see [setVisible]).
  final Set<Object> _visible = {};
  final _unread = ValueNotifier<int>(0);
  final _cartCount = ValueNotifier<int>(0);
  bool _observing = false;
  bool _background = false;
  bool _updateReported = false;
  Completer<String?>? _recoverWake;
  DateTime? _photoReadyAt;
  final _photo = ValueNotifier<PhotoState>(const PhotoIdle());
  SunonoImage? _photoImage;
  int _photoGen = 0;
  Completer<void>? _abortUpload;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  String get lang => _lang;
  ChatStatus get status => _status;
  ShopConfig get config => _config;
  Cart? get cart => _cart;

  /// Why the chat is [ChatStatus.disabled] (`platform_disabled`), when known.
  String? get disabledReason => _disabledReason;

  /// This SDK is older than the shop's `app.min_sdk_version`: show an update notice.
  bool get updateRequired => _versionBelow(sdkVersion, _config.minSdkVersion);

  /// A human currently owns the conversation.
  bool get paused => _paused;

  /// Bot and staff messages that arrived while no attached view was visible;
  /// back to 0 when one becomes visible. For a tab or launcher badge.
  ValueListenable<int> get unread => _unread;

  /// Items in the shopper's cart, for a badge; follows every cart change.
  ValueListenable<int> get cartCount => _cartCount;

  /// A turn is in flight; the composer should not send.
  bool get busy => _busy;

  /// The card (`public_id`) whose Add started the running turn, if any.
  String? get addingRef => _busy && _running?.tap?.action == 'add_to_cart' ? _running!.tap!.ref : null;
  Stream<SunonoEvent> get events => _events.stream;
  String? get userId => _session.userId;

  String _id() => 'm${++_seq}';

  void _emit(SunonoEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _changed() {
    final over = _messages.length - _maxMessages;
    if (over > 0) {
      // Remember what fell off: a history row for any of them is old news, not
      // a new row to append or a turn to adopt.
      for (final m in _messages.take(over)) {
        if (m.msgRef != null) _trimmed.add(m.msgRef!);
      }
      _messages.removeRange(0, over);
    }
    if (_disposed) return;
    _cartCount.value = _cart?.count ?? 0;
    notifyListeners();
  }

  set lang(String value) {
    _langPinned = true;
    if (value == _lang) return;
    _lang = value == 'en' ? 'en' : 'ar';
    _changed();
  }

  // ---------------------------------------------------------------- lifecycle

  /// A view started showing this controller (a tab and a sheet may both).
  /// From here on the controller follows the app lifecycle itself.
  void attach() {
    if (!_observing && !_disposed) {
      final binding = WidgetsBinding.instance..addObserver(this);
      _observing = true;
      final state = binding.lifecycleState;
      if (state != null) _background = _isBackground(state);
    }
    _emit(const AnalyticsEvent('assistant_opened'));
    open();
  }

  /// A view went away. The live connection keeps running (and [unread]
  /// counting) until the app goes to the background.
  void detach([Object? view]) {
    if (view != null) setVisible(view, false);
  }

  /// Whether [view] is on screen now (a hidden tab, a covered route are not).
  /// Becoming visible clears [unread].
  void setVisible(Object view, bool visible) {
    if (visible) {
      _visible.add(view);
      if (!_disposed) _unread.value = 0;
    } else {
      _visible.remove(view);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _background = false;
      resume();
    } else if (_isBackground(state)) {
      _background = true;
      suspend();
    }
  }

  static bool _isBackground(AppLifecycleState s) =>
      s == AppLifecycleState.hidden || s == AppLifecycleState.paused || s == AppLifecycleState.detached;

  /// The live connection runs only in the foreground, and never for an SDK
  /// the shop no longer supports.
  void _goLive() {
    if (!_background && !updateRequired) _live.start();
  }

  /// A bot or staff message landed: a badge count while nothing shows the
  /// chat, else a polite screen-reader announcement.
  void _arrived(ChatMessage m) {
    if (_disposed || updateRequired) return;
    if (_visible.isEmpty) {
      _unread.value++;
      return;
    }
    final text = sanitizeReply(m.text).trim();
    if (text.isEmpty) return;
    // ponytail: SemanticsService.sendAnnouncement needs Flutter 3.35; the floor is 3.27.
    // ignore: deprecated_member_use
    unawaited(SemanticsService.announce(
        text, isRtlText(text, fallbackRtl: _lang != 'en') ? TextDirection.rtl : TextDirection.ltr));
  }

  /// Apply a fetched config: typing hint, the shop's default language (until
  /// the host picks one), and one `assistant_update_required` per controller.
  void _applyConfig(ShopConfig fresh) {
    _config = fresh;
    _configAt = _clock();
    _typingHint = fresh.typingHint;
    if (!_langPinned) {
      _langPinned = true;
      _lang = fresh.defaultLanguage;
    }
    if (!_updateReported && updateRequired) {
      _updateReported = true;
      _emit(const AnalyticsEvent('assistant_update_required'));
    }
  }

  /// Load config and history, bind the cart, go live. Safe to call again.
  Future<void> open() async {
    if (_status == ChatStatus.ready || _status == ChatStatus.loading) {
      resume();
      return;
    }
    final epoch = _epoch;
    _status = ChatStatus.loading;
    _changed();
    try {
      _applyConfig(await _api.config());
    } catch (e, s) {
      _emit(ErrorEvent(e, s)); // keep defaults: config is presentation only
    }
    if (epoch != _epoch) return;
    if (!_config.enabled) {
      _disable(_config.disabledReason);
      return;
    }
    _disabledReason = null;
    _status = ChatStatus.ready;
    _ensureTried = false;
    _changed();
    _forgetPending();
    if (updateRequired) return; // the update notice only: no cart link, no live
    unawaited(_bind(ensure: false));
    _goLive(); // fetches history first
  }

  /// App went to background: drop the live connection.
  void suspend() => _live.stop();

  /// The kill switch (config or a `403 platform_disabled`): stop everything.
  void _disable(String? reason) {
    if (_disposed) return;
    _status = ChatStatus.disabled;
    _disabledReason = reason;
    _live.stop();
    _changed();
  }

  /// Re-fetch the config, applying the kill switch and `typing_hint`. A failed
  /// fetch keeps the old config and is retried on the next resume.
  Future<void> _refreshConfig() async {
    final epoch = _epoch;
    final previous = _configAt;
    _configAt = _clock(); // claimed up front: resume bursts don't fan out
    try {
      final fresh = await _api.config();
      if (epoch != _epoch || _disposed) return;
      final wasBlocked = updateRequired;
      _applyConfig(fresh);
      if (!fresh.enabled) {
        _disable(fresh.disabledReason);
        return;
      }
      if (updateRequired) {
        _live.stop();
      } else if (wasBlocked) {
        unawaited(_bind(ensure: false)); // the shop lowered its minimum: carry on
        _goLive();
      }
      _changed();
    } catch (e, s) {
      if (epoch == _epoch) _configAt = previous;
      _emit(ErrorEvent(e, s));
    }
  }

  /// App came back: config if stale, history first, then live again; re-check
  /// the cart link.
  void resume() {
    final at = _configAt;
    final stale = at == null || _clock().difference(at) > _configMaxAge;
    if (_status == ChatStatus.disabled) {
      // A shop that switched chat back on returns without re-attaching the view.
      if (stale) unawaited(open());
      return;
    }
    if (_status != ChatStatus.ready) return;
    if (stale) unawaited(_refreshConfig());
    if (updateRequired) return;
    unawaited(_bind(ensure: false));
    _goLive();
  }

  /// Forget this shopper (logout / account switch). Everything local is
  /// cleared at once, so nothing of the old shopper can show or be sent
  /// again; the server-side detach (`/chat/forget`) runs in the background
  /// with the old shopper's own credentials and is retried on a later [open]
  /// if it fails. Anything still in flight for the old shopper is dropped
  /// when it lands.
  Future<void> reset() async {
    _epoch++;
    removePhoto();
    _live.stop();
    final wasOpen = _status == ChatStatus.ready;
    final oldId = _session.userId, oldToken = _session.currentToken;
    final cleared = _session.reset(); // memory now, storage below
    _messages.clear();
    _trimmed.clear();
    _cart = null;
    _paused = false;
    _unbind();
    _busy = false;
    _running = null;
    _status = ChatStatus.idle;
    if (!_disposed) _unread.value = 0;
    _changed();
    final id = oldId ?? await cleared; // the in-memory id even when storage failed
    if (id != null) {
      try {
        await _storage.write(_pendingForgetKey, id).timeout(storageTimeout);
      } catch (e, s) {
        _emit(ErrorEvent(e, s)); // no retry later, but the forget still goes out now
      }
      _forgetPending(id: id, token: oldToken);
    }
    if (wasOpen && !_disposed) await open();
  }

  /// Send the forget for [id] (from a reset; queued behind one in flight) or
  /// for the stored pending shopper (skipped while one is in flight). [token]
  /// is [id]'s; anyone else is re-inited by their own id.
  void _forgetPending({String? id, String? token}) {
    final prev = _forgetting;
    if (prev != null && id == null) return;
    late final Future<void> f;
    f = _forgetting = (prev ?? Future<void>.value()).then((_) => _runForget(id, token)).whenComplete(() {
      if (identical(_forgetting, f)) _forgetting = null;
    });
  }

  Future<void> _runForget(String? id, String? token) async {
    try {
      final old = id ?? await _storage.read(_pendingForgetKey).timeout(storageTimeout);
      if (old == null) return;
      try {
        // Never through the session: its token and re-init are the NEW shopper's.
        var done = false;
        if (old == id && token != null) {
          try {
            await _api.forget(token);
            done = true;
          } on SunonoHttpException catch (e) {
            if (!e.isAuth) rethrow; // an expired token: re-init as the old shopper below
          }
        }
        if (!done) await _api.forget((await _api.init(old)).token);
      } on SunonoHttpException catch (e) {
        // 429 or 5xx: try on a later open. Any other refusal won't change.
        if (e.status == 429 || e.status >= 500) return;
      }
      // A newer reset may have queued another shopper meanwhile: keep that one.
      if (await _storage.read(_pendingForgetKey).timeout(storageTimeout) == old) {
        await _storage.delete(_pendingForgetKey).timeout(storageTimeout);
      }
    } catch (_) {
      // offline: try on a later open
    }
  }

  /// Re-run the cart binding (after host login/logout/cart replacement).
  Future<void> refreshCartBinding() {
    _unbind();
    return _bind(ensure: false);
  }

  /// The link is gone (or must be remade): the next send ensures again.
  void _unbind() {
    _linkGen++;
    _bound = false;
    _ensureTried = false;
  }

  /// Follow the server's word on the link. A link that drops re-arms the
  /// once-per-open ensure.
  /// [gen] is the [_linkGen] when the answer was asked for: a "linked" that
  /// predates a drop is stale.
  void _setBound(bool linked, int gen) {
    if (linked && gen != _linkGen) return;
    if (!linked && _bound) _ensureTried = false;
    _bound = linked;
  }

  /// A turn or live push wrote the cart: it is newer than any request in flight.
  void _cartWritten() => _cartApplied = ++_cartReq;

  /// Whether a response to request [ticket] may still be applied.
  bool _cartFresh(int ticket) {
    if (ticket <= _cartApplied) return false;
    _cartApplied = ticket;
    return true;
  }

  /// Pull the cart from the server. The host calls this after its own cart
  /// edits so the bot sees them; a pull that a newer live write overtakes is dropped.
  Future<void> refreshCart() async {
    final epoch = _epoch, ticket = ++_cartReq, gen = _linkGen;
    try {
      final c = await _session.authed(_api.cart);
      if (epoch != _epoch || _disposed || !_cartFresh(ticket)) return;
      _setBound(c.linked, gen);
      _setCart(c.cart, fromSync: c.linked && _cartSig(c.cart) != _cartSig(_cart));
      _changed();
    } catch (e, s) {
      _emit(ErrorEvent(e, s));
    }
  }

  /// Replace the cart; tell the host when it changed (or [fromSync]).
  void _setCart(Cart? next, {bool fromSync = false}) {
    final changed = _cartSig(next) != _cartSig(_cart);
    _cart = next;
    if (changed || fromSync) _emit(CartChangedEvent(next, fromSync: fromSync));
  }

  static String _cartSig(Cart? c) => c == null
      ? ''
      : '${c.count}|${c.totalFils}|${c.extraLineCount}|'
          '${c.lines.map((l) => '${l.productId}:${l.variantLabel}:${l.qty}').join(',')}';

  Future<void> _bind({required bool ensure}) async {
    final bridge = cartBridge;
    if (bridge == null || (_bound && ensure)) return;
    final epoch = _epoch, gen = _linkGen;
    try {
      final uid = await _session.ensureUserId();
      final proof = ensure ? await bridge.ensureBind(uid) : await bridge.probe(uid);
      if (proof == null || epoch != _epoch) return;
      final bound = await _api.bindCart(uid, proof);
      if (epoch == _epoch) _setBound(bound, gen);
    } catch (e, s) {
      if (e is SunonoHttpException && e.isPlatformDisabled) _disable('platform_disabled');
      _emit(ErrorEvent(e, s)); // never loops: next open/resume/refresh tries again
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _photoGen++;
    _abortUpload?.complete();
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    _photo.dispose();
    _unread.dispose();
    _cartCount.dispose();
    _live.stop();
    _api.close();
    _events.close();
    super.dispose();
  }

  // ---------------------------------------------------------------- sending

  /// Send a message. [synthetic]: generated by a tap, not typed. [productId]
  /// (a card's public id) wins over [productSku]. [tap] is a card tap's
  /// structured `(action, ref)` (`add_to_cart` / `product_detail`, PROTOCOL §4).
  ///
  /// A typed message carries the attached photo once it is [PhotoReady]; while
  /// the photo is uploading or failed nothing is sent (the caption would lose
  /// its picture). A tap never takes the photo.
  Future<void> send(String text,
      {bool synthetic = false, String? productId, String? productSku, ({String action, String ref})? tap}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _busy || _status != ChatStatus.ready || updateRequired) return;
    final state = _photo.value;
    final typed = !synthetic && tap == null;
    if (typed && (state is PhotoUploading || (state is PhotoFailed && state.retryable))) return;
    final image = typed && state is PhotoReady ? _photoImage : null;
    final ref = typed && state is PhotoReady ? state.ref : null;
    final readyAt = _photoReadyAt;
    // The photo is consumed by a send; one that can never upload is dropped
    // (the shopper typed the question anyway: "tell me in words").
    if (typed && state is! PhotoIdle) _clearPhoto();
    final user = ChatMessage(id: _id(), role: ChatRole.user, text: trimmed, localImage: image?.bytes);
    _messages.add(user);
    _emit(AnalyticsEvent('assistant_message_sent', {'synthetic': synthetic, 'photo': ref != null}));
    await _run(_Outgoing(trimmed, synthetic, image, ref, readyAt, productId, productSku, tap, user));
  }

  // ------------------------------------------------------------------ photo

  /// Where the composer's photo is: idle, uploading, ready or failed.
  ValueListenable<PhotoState> get photo => _photo;

  /// The attached photo's bytes (for a preview) while [photo] is not idle.
  SunonoImage? get photoImage => _photoImage;

  /// Attach [image] and start uploading it now (PROTOCOL §9). Resolves when
  /// the upload ends; [photo] carries the outcome. Replaces any earlier photo.
  /// A ref older than 55 minutes is uploaded again at send time.
  Future<void> attachPhoto(SunonoImage image) {
    _photoImage = image;
    return _uploadPhoto();
  }

  /// Re-upload after a [PhotoFailed].
  Future<void> retryPhoto() => _photoImage == null || _photo.value is! PhotoFailed ? Future.value() : _uploadPhoto();

  /// Drop the photo; an upload in flight is aborted and its result ignored.
  void removePhoto() {
    _photoGen++;
    _abortUpload?.complete();
    _abortUpload = null;
    _clearPhoto();
  }

  void _clearPhoto() {
    _photoImage = null;
    _photo.value = const PhotoIdle();
  }

  Future<void> _uploadPhoto() async {
    final image = _photoImage!, gen = ++_photoGen;
    _abortUpload?.complete();
    final abort = _abortUpload = Completer<void>();
    bool current() => gen == _photoGen && !_disposed;
    // The server's own limits, checked first so a bad pick costs no bandwidth.
    if (image.bytes.length > _maxPhotoBytes) {
      _photo.value = const PhotoFailed('image_too_large');
      return;
    }
    if (!_isSupportedImage(image.bytes)) {
      _photo.value = const PhotoFailed('invalid_image');
      return;
    }
    _photo.value = const PhotoUploading(0);
    try {
      final ref = await _session
          .authed((t) => _api.upload(t, image.bytes, filename: image.filename, abort: abort.future, onProgress: (p) {
                if (current()) _photo.value = PhotoUploading(p);
              }));
      if (!current()) return;
      _photoReadyAt = _clock();
      _photo.value = PhotoReady(ref);
    } catch (e, s) {
      if (!current()) return; // removed or replaced meanwhile
      if (e is SunonoHttpException && e.isPlatformDisabled) {
        _clearPhoto(); // the session already switched the chat off
      } else if (e is SunonoHttpException) {
        _photo.value = PhotoFailed(switch (e.status) { 429 => 'rate_limited', _ => e.code ?? 'http_${e.status}' });
      } else {
        _emit(ErrorEvent(e, s));
        _photo.value = const PhotoFailed('offline');
      }
    }
  }

  /// Retry a failed bot bubble's turn.
  Future<void> retry(ChatMessage failed) async {
    final out = failed._outgoing;
    if (out == null || _busy || !_messages.contains(failed) || !_messages.contains(out.user)) return;
    _messages.remove(failed);
    await _run(out);
  }

  Future<void> _run(_Outgoing out) async {
    final epoch = _epoch;
    _busy = true;
    _running = out;
    final bot = ChatMessage(id: _id(), role: ChatRole.bot, state: MessageState.thinking).._outgoing = out;
    if (_typingHint) _messages.add(bot);
    _changed();
    try {
      // One storefront-cart ensure per open: the bot may add this turn.
      if (cartBridge != null && !_bound && !_ensureTried) {
        _ensureTried = true;
        await _bind(ensure: true);
      }
      final result = out.imageRef == null
          ? await _session.authed((t) => _api.chat(t, out.text,
              lang: _lang,
              synthetic: out.synthetic,
              productId: out.productId,
              productSku: out.productSku,
              tap: out.tap,
              clientMessageId: out.clientMessageId))
          : await _photoTurn(out, bot);
      if (epoch == _epoch) _apply(bot, result);
    } on SunonoHttpException catch (e) {
      if (epoch != _epoch) return;
      if (e.isPlatformDisabled) {
        _messages.remove(bot); // the session already switched us to disabled
      } else if (e.isTurnInProgress) {
        // The turn is running server-side: wait for it, never resend.
        await _recover(bot, out, epoch);
      } else if (e.status < 500) {
        // 4xx (rate limit, origin, bad photo…) is refused before any work.
        _fail(bot, switch (e.status) { 429 => 'rate_limited', _ => e.code ?? 'http_${e.status}' });
      } else {
        // A 5xx (e.g. a gateway timeout) may arrive after the turn ran.
        _emit(ErrorEvent(e));
        await _recover(bot, out, epoch);
      }
    } catch (e, s) {
      if (epoch != _epoch) return;
      _emit(ErrorEvent(e, s));
      await _recover(bot, out, epoch);
    } finally {
      if (epoch == _epoch) {
        _busy = false;
        _running = null;
        _changed();
      }
    }
  }

  Future<TurnResult> _photoTurn(_Outgoing out, ChatMessage bot) async {
    if (_clock().difference(out.imageReadyAt!) > _imageRefMaxAge) await _reupload(out);
    try {
      return await _photoStream(out, bot);
    } on SunonoHttpException catch (e) {
      // 400 is refused before any work (an expired or unknown image_ref): the
      // same client_message_id is safe to send again with a fresh upload.
      if (e.status != 400) rethrow;
      await _reupload(out);
      return _photoStream(out, bot);
    }
  }

  Future<void> _reupload(_Outgoing out) async {
    out.imageRef = await _session.authed((t) => _api.upload(t, out.image!.bytes, filename: out.image!.filename));
    out.imageReadyAt = _clock();
  }

  Future<TurnResult> _photoStream(_Outgoing out, ChatMessage bot) {
    return _session.authed((t) async {
      TurnResult? done;
      await for (final SseFrame f in _api.chatStream(t, out.text,
          lang: _lang,
          synthetic: out.synthetic,
          productId: out.productId,
          productSku: out.productSku,
          tap: out.tap,
          imageRef: out.imageRef,
          clientMessageId: out.clientMessageId)) {
        final j = f.json;
        if (j == null) continue;
        switch (j['type']) {
          case 'stage':
            bot.stage = j['stage'] as String?;
            _changed();
          case 'done':
            done = TurnResult.fromJson(j);
          case 'error':
            throw StateError('turn error: ${j['message']}');
        }
      }
      return done ?? (throw StateError('stream ended without done'));
    });
  }

  void _fail(ChatMessage bot, String code) {
    bot
      ..state = MessageState.failed
      ..errorCode = code;
    if (!_messages.contains(bot)) _messages.add(bot);
    _changed();
  }

  void _apply(ChatMessage bot, TurnResult r) {
    if (r.typingHint != null) _typingHint = r.typingHint!;
    // ponytail: turn vs live cart order has no server version; a late turn snapshot can overwrite a newer live one - needs a server cart version
    if (r.cartPresent || r.cartMutated) _cartWritten();
    if (r.cartPresent) {
      _setCart(r.cart, fromSync: r.cartMutated);
    } else if (r.cartMutated) {
      _emit(CartChangedEvent(_cart, fromSync: true));
    }
    if (r.relink) _unbind(); // the server dropped the link: ensure again next send
    if (r.silent && r.checkout == null && r.products.isEmpty) {
      _messages.remove(bot); // paused / blocked / silenced: say nothing
      return;
    }
    // A live message.new for the same reply may have landed first (and was counted).
    final liveFirst = r.msgRef != null && _messages.any((m) => !identical(m, bot) && m.msgRef == r.msgRef);
    if (liveFirst) _messages.removeWhere((m) => !identical(m, bot) && m.msgRef == r.msgRef);
    bot
      ..text = r.reply
      ..products = r.products
      ..hasMore = r.hasMore
      ..checkout = r.checkout
      ..handoffUrl = r.handoffUrl
      ..orderIds = r.orderIds
      ..msgRef = r.msgRef
      ..replyLang = r.replyLang
      ..ts = DateTime.now()
      ..state = MessageState.done
      ..stage = null;
    if (!_messages.contains(bot)) _messages.add(bot);
    if (!liveFirst) _arrived(bot);
    if (r.checkout is CheckoutPlaced) _emit(const AnalyticsEvent('assistant_order_placed'));
  }

  /// The send may or may not have reached the server (PROTOCOL §10). A live
  /// bot message cuts the wait short.
  Future<void> _recover(ChatMessage bot, _Outgoing out, int epoch) async {
    // A history merge may already have matched our user bubble to its
    // server row (and appended the reply): then the turn happened.
    bool merged() => out.user.msgRef != null;

    if (merged()) {
      _messages.remove(bot);
      _changed();
      return;
    }
    bot.state = MessageState.recovering;
    if (!_messages.contains(bot)) _messages.add(bot);
    _changed();
    String? liveRef; // msg_ref of a bot reply that arrived live meanwhile
    for (final wait in recoveryChecks) {
      final wake = _recoverWake = Completer<String?>();
      await Future.any([Future<void>.delayed(wait), wake.future]);
      if (wake.isCompleted) liveRef = await wake.future;
      if (_disposed || epoch != _epoch || !_messages.contains(bot) || bot.state != MessageState.recovering) return;
      if (merged()) {
        _messages.remove(bot);
        _changed();
        return;
      }
      final History h;
      final ticket = ++_cartReq, gen = _linkGen;
      try {
        h = await _session.authed(_api.history);
      } catch (_) {
        if (epoch != _epoch) return;
        if (liveRef != null) {
          _messages.remove(bot); // the reply already arrived live
          _changed();
        } else {
          _fail(bot, 'offline'); // can't reach the server: the shopper decides
        }
        return;
      }
      if (epoch != _epoch) return;
      final rows = h.rows;
      final repliedLive = liveRef != null &&
          [for (var i = 0; i + 1 < rows.length; i++) i]
              .any((i) => rows[i].role == 'user' && rows[i].text == out.text && rows[i + 1].msgRef == liveRef);
      if (repliedLive || _unknownUserRows(h).any((r) => r.text == out.text)) {
        // The turn happened: the server's thread is the truth now.
        final pills = _messages.where((m) => m.role == ChatRole.system).toList();
        _messages
          ..clear()
          ..addAll(h.rows.map(_fromRow));
        for (final p in pills) {
          _insertPill(p);
        }
        _syncPausePill(h.pausedAt);
        _applyHistoryMeta(h, ticket, gen);
        _changed();
        return;
      }
    }
    _fail(bot, 'not_delivered');
  }

  // ---------------------------------------------------------------- history + live

  ChatMessage _fromRow(HistoryRow r) => ChatMessage(
        id: _id(),
        role: switch (r.role) { 'user' => ChatRole.user, 'staff' => ChatRole.staff, _ => ChatRole.bot },
        text: r.text,
        imageUrl: r.imageUrl,
        products: r.products,
        hasMore: r.hasMore,
        handoffUrl: r.handoffUrl,
        msgRef: r.msgRef,
        ts: r.ts,
      );

  /// History user rows this screen doesn't account for. A user row is
  /// accounted for when its own msg_ref is on screen, or when the reply right
  /// after it is (local user bubbles never learn their msg_ref from /chat).
  List<HistoryRow> _unknownUserRows(History h) {
    final known = {
      for (final m in _messages)
        if (m.msgRef != null) m.msgRef!
    };
    return [
      for (var i = 0; i < h.rows.length; i++)
        if (h.rows[i].role == 'user' &&
            !_trimmed.contains(h.rows[i].msgRef) &&
            !known.contains(h.rows[i].msgRef) &&
            !(i + 1 < h.rows.length && h.rows[i + 1].role != 'user' && known.contains(h.rows[i + 1].msgRef)))
          h.rows[i],
    ];
  }

  /// Merge the server thread into the screen. Rows already shown are
  /// skipped: by msg_ref; user rows also by their known reply, or by the
  /// oldest unmatched local bubble with the same text (which adopts the
  /// row's msg_ref, so device-vs-server clock skew never matters).
  Future<void> refreshHistory() async {
    final epoch = _epoch;
    final ticket = ++_cartReq, gen = _linkGen;
    final h = await _session.authed(_api.history);
    if (epoch != _epoch || _disposed) return;
    if (_messages.isEmpty) {
      _messages.addAll(h.rows.map(_fromRow));
    } else {
      final unknownUsers = _unknownUserRows(h).toSet();
      final onScreen = {
        for (final m in _messages)
          if (m.msgRef != null) m.msgRef!
      };
      for (final r in h.rows) {
        if (r.msgRef != null && (onScreen.contains(r.msgRef) || _trimmed.contains(r.msgRef))) continue;
        if (r.role == 'user') {
          if (!unknownUsers.contains(r)) continue;
          final local =
              _messages.where((m) => m.role == ChatRole.user && m.msgRef == null && m.text == r.text).firstOrNull;
          if (local != null) {
            local.msgRef = r.msgRef ?? '_local_${local.id}';
            continue;
          }
        } else if (r.msgRef == null && _sameRecentBubble(r)) {
          continue;
        }
        final m = _fromRow(r);
        _messages.add(m);
        if (m.role != ChatRole.user) _arrived(m); // e.g. a staff reply while live was down
      }
      // A recovering send whose user row just showed up did happen: its
      // reply rows were appended above, so the placeholder goes.
      _messages.removeWhere((m) {
        return m.state == MessageState.recovering && m._outgoing?.user.msgRef != null;
      });
    }
    _syncPausePill(h.pausedAt);
    _applyHistoryMeta(h, ticket, gen);
    _changed();
    if (h.cartLinked) await refreshCart();
  }

  /// Legacy rows without msg_ref: same role + text within 15 s.
  bool _sameRecentBubble(HistoryRow r) => _messages.any((m) =>
      m.role.name == r.role &&
      m.text == r.text &&
      (r.ts == null || m.ts.difference(r.ts!).abs() < const Duration(seconds: 15)));

  /// [ticket]/[gen]: when [h] was asked for. A newer cart write makes its cart
  /// stale; a legacy bare array says nothing about the cart or the link.
  void _applyHistoryMeta(History h, int ticket, int gen) {
    _paused = h.pausedAt != null;
    if (!h.hasCartKey) return;
    _setBound(h.cartLinked, gen);
    if (_cartFresh(ticket)) _setCart(h.cart); // the server's cart row is the truth, empty included
  }

  /// A live message already on screen: by msg_ref, then client_ref, then the
  /// same role + text within 15 s (a repeated «تمام» a minute later is new).
  bool _isDuplicateLive(ChatRole role, String text, String? ref, String? clientRef, DateTime? ts) {
    if (ref != null && (_trimmed.contains(ref) || _messages.any((m) => m.msgRef == ref))) return true;
    if (clientRef != null && _messages.any((m) => m.role == role && m.clientRef == clientRef)) return true;
    final at = ts ?? DateTime.now();
    return _messages.any((m) =>
        m.role == role &&
        m.text == text &&
        (ref == null || m.msgRef == null) &&
        m.ts.difference(at).abs() < const Duration(seconds: 15));
  }

  /// Put a pill in time order. A tie with a staff bubble goes before it.
  /// Returns false when the same pill (ts + text) is already there.
  bool _insertPill(ChatMessage pill) {
    if (_messages.any((m) => m.role == ChatRole.system && m.text == pill.text && m.ts.isAtSameMomentAs(pill.ts))) {
      return false;
    }
    var i = _messages.length;
    while (i > 0 &&
        (_messages[i - 1].ts.isAfter(pill.ts) ||
            (_messages[i - 1].ts.isAtSameMomentAs(pill.ts) && _messages[i - 1].role == ChatRole.staff))) {
      i--;
    }
    _messages.insert(i, pill);
    return true;
  }

  /// The "handed to our team" pill for a pause at [at]. The dashboard saves the
  /// staff row first and sets bot_paused_at slightly later, so the pill goes
  /// right BEFORE the first staff row at or after `at - 60 s` when that row
  /// precedes [at]; otherwise in time order at [at]. Idempotent.
  void _syncPausePill(DateTime? at) {
    if (at == null) return;
    final old = _messages
        .where((m) => m.role == ChatRole.system && m.text == 'paused' && m.ts.isAtSameMomentAs(at))
        .firstOrNull;
    if (old != null) _messages.remove(old);
    final pill = old ?? ChatMessage(id: _id(), role: ChatRole.system, text: 'paused', ts: at);
    final from = at.subtract(const Duration(seconds: 60));
    final staff = _messages.indexWhere((m) => m.role == ChatRole.staff && !m.ts.isBefore(from));
    if (staff >= 0 && _messages[staff].ts.isBefore(at)) {
      _messages.insert(staff, pill);
    } else {
      _insertPill(pill);
    }
  }

  void _onLive(String type, Map<String, dynamic> data) {
    switch (type) {
      case 'message.new':
        final text = data['body_text'] is String ? data['body_text'] as String : '';
        final ref = data['msg_ref'] is String ? data['msg_ref'] as String : null;
        final clientRef = data['client_ref'] is String ? data['client_ref'] as String : null;
        final ts = DateTime.tryParse('${data['ts']}');
        final role = data['sent_by'] == 'owner' ? ChatRole.staff : ChatRole.bot;
        if (_isDuplicateLive(role, text, ref, clientRef, ts)) return;
        final media = data['media_stored'];
        var image = media is Map && media['kind'] == 'image' && media['url'] is String ? media['url'] as String : null;
        if (image != null && image.startsWith('/')) image = '${_api.apiOrigin}$image';
        if (image != null && !image.startsWith('https://') && !image.startsWith('http://')) image = null;
        final m =
            ChatMessage(id: _id(), role: role, text: text, msgRef: ref, clientRef: clientRef, ts: ts, imageUrl: image);
        _messages.add(m);
        _arrived(m);
        if (role == ChatRole.bot && _recoverWake?.isCompleted == false) _recoverWake!.complete(ref ?? '');
        _recoverWake = null;
      case 'conversation.paused':
        _paused = true;
        _syncPausePill(DateTime.tryParse('${data['bot_paused_at']}') ?? _clock());
      case 'conversation.resumed':
        _paused = false;
        // A live event is "now"; never sort it before what is already shown.
        final now = _clock();
        final newest = _messages.fold<DateTime>(now, (t, m) => m.ts.isAfter(t) ? m.ts : t);
        final at = newest.isAfter(now) ? newest.add(const Duration(milliseconds: 1)) : now;
        _insertPill(ChatMessage(id: _id(), role: ChatRole.system, text: 'resumed', ts: at));
      case 'assistant.state':
        _typingHint = data['typing_hint'] != false;
      case 'cart.updated':
        _cartWritten();
        _setCart(Cart.fromJson(data['cart']), fromSync: true);
      default:
        return; // forward compatibility: unknown events are ignored
    }
    _changed();
  }

  // ---------------------------------------------------------------- intents

  bool _hand(SunonoIntent intent) => onIntent?.call(intent) ?? false;

  /// Whether the host handled it; when false the UI asks the assistant instead.
  bool openProduct(ProductCard p) {
    _emit(AnalyticsEvent('assistant_product_tapped', {'product_id': p.publicId, 'sku': p.sku}));
    return _hand(OpenProductIntent(productId: p.publicId, sku: p.sku, url: p.externalUrl, title: p.title(_lang)));
  }

  /// Hand [intent] to the host; with no handler there is no fallback, so say so.
  void _handOrReport(SunonoIntent intent) {
    if (!_hand(intent)) _emit(ErrorEvent(UnhandledIntent(intent)));
  }

  /// View the cart: the host's cart screen while it shares the shopper's
  /// storefront cart, otherwise (or when the host declines) ask the assistant.
  Future<void> openCart() async {
    if (_bound && _hand(const OpenCartIntent())) return;
    await send(cartPhrase(_lang), synthetic: true);
  }

  /// Order details: the host's order screen; a declined chat order asks the
  /// assistant, a declined storefront order is reported.
  Future<void> openOrder(OrderIds ids) async {
    final intent =
        OpenOrderIntent(number: ids.number, storeOrderId: ids.storeOrderId, publicId: ids.publicId, source: ids.source);
    if (_hand(intent)) return;
    if (ids.source == 'chat') {
      await send(orderStatusPhrase(ids.number, _lang), synthetic: true);
    } else {
      _emit(ErrorEvent(UnhandledIntent(intent)));
    }
  }

  /// Whether the host handled it (the sheet may close).
  bool checkout(String? url) {
    _emit(const AnalyticsEvent('assistant_checkout_tapped'));
    final intent = CheckoutIntent(url: url);
    final handled = _hand(intent);
    if (!handled) _emit(ErrorEvent(UnhandledIntent(intent)));
    _unbind(); // the order completes on the storefront and rotates its cart
    return handled;
  }

  void openUrl(String url) {
    if (isSafeLink(url)) _handOrReport(OpenUrlIntent(url));
  }
}

/// Whether [have] is older than [min] (`x.y.z`; a pre-release suffix is ignored).
bool _versionBelow(String have, String? min) {
  List<int>? parse(String v) {
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(v);
    return m == null ? null : [for (var i = 1; i <= 3; i++) int.parse(m[i]!)];
  }

  final a = parse(have), b = min == null ? null : parse(min);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] < b[i];
  }
  return false;
}
