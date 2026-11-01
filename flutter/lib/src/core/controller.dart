import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'format.dart';
import 'host.dart';
import 'live.dart';
import 'models.dart';
import 'session.dart';
import 'sse.dart';

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
  String? msgRef;

  /// The `client_message_id` of the turn that produced this bubble (live dedupe).
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
  _Outgoing(this.text, this.synthetic, this.image, this.productId, this.productSku, this.tap, this.user);

  /// Minted once per message and reused by every retry, so the server can
  /// answer a repeat with the stored reply instead of running the turn twice.
  final String clientMessageId = uuidV4();
  final String text;
  final bool synthetic;
  final SunonoImage? image;
  final String? productId;
  final String? productSku;
  final ({String action, String ref})? tap;

  /// The shopper's bubble for this send.
  final ChatMessage user;
}

/// The chat state machine. UI-free: a host can drive its own UI from it.
class SunonoChatController extends ChangeNotifier {
  SunonoChatController({
    required SunonoApi api,
    required SunonoStorage storage,
    String lang = 'ar',
    this.cartBridge,
    this.onIntent,
    this.starterPrompts,
    this.recoveryChecks = const [Duration(seconds: 4), Duration(seconds: 8), Duration(seconds: 18)],
    DateTime Function() clock = DateTime.now,
  })  : _api = api,
        _clock = clock,
        _lang = lang {
    _session = Session(api, storage, onPlatformDisabled: () => _disable('platform_disabled'));
    _live = LiveConnection(
      api: api,
      session: _session,
      onEvent: _onLive,
      beforeConnect: refreshHistory,
      onError: (e, s) => _emit(ErrorEvent(e, s)),
    );
  }

  final SunonoApi _api;
  late final Session _session;
  late final LiveConnection _live;
  final SunonoCartBridge? cartBridge;

  /// Returns true when the host handled the intent.
  bool Function(SunonoIntent intent)? onIntent;

  /// Host override of the empty-thread starter chips, by language (`ar` / `en`).
  /// A language that is missing uses the SDK defaults; an empty list shows none.
  final Map<String, List<String>>? starterPrompts;

  /// Delays between history checks while recovering (cumulative waits).
  final List<Duration> recoveryChecks;

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
  int _views = 0;
  Completer<String?>? _recoverWake;

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
    if (!_disposed) notifyListeners();
  }

  set lang(String value) {
    if (value == _lang) return;
    _lang = value == 'en' ? 'en' : 'ar';
    _changed();
  }

  // ---------------------------------------------------------------- lifecycle

  /// A view started showing this controller (a tab and a sheet may both).
  void attach() {
    _views++;
    open();
  }

  /// A view went away; the live connection stops when none are left.
  void detach() {
    if (_views > 0) _views--;
    if (_views == 0) suspend();
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
      _config = await _api.config();
      _configAt = _clock();
    } catch (e, s) {
      _emit(ErrorEvent(e, s)); // keep defaults: config is presentation only
    }
    if (epoch != _epoch) return;
    if (!_config.enabled) {
      _disable(_config.disabledReason);
      return;
    }
    _typingHint = _config.typingHint;
    _disabledReason = null;
    _status = ChatStatus.ready;
    _ensureTried = false;
    _changed();
    _emit(const AnalyticsEvent('assistant_opened'));
    unawaited(_bind(ensure: false));
    _live.start(); // fetches history first
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
      _config = fresh;
      _typingHint = fresh.typingHint;
      if (!fresh.enabled) {
        _disable(fresh.disabledReason);
        return;
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
    unawaited(_bind(ensure: false));
    _live.start();
  }

  /// Forget this shopper (logout / account switch). Anything still in
  /// flight for the old shopper is dropped when it lands.
  Future<void> reset() async {
    _epoch++;
    _live.stop();
    await _session.reset();
    _messages.clear();
    _trimmed.clear();
    _cart = null;
    _paused = false;
    _unbind();
    _busy = false;
    _running = null;
    final wasOpen = _status == ChatStatus.ready;
    _status = ChatStatus.idle;
    _changed();
    if (wasOpen) await open();
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
    _live.stop();
    _api.close();
    _events.close();
    super.dispose();
  }

  // ---------------------------------------------------------------- sending

  /// Send a message. [synthetic]: generated by a tap, not typed. [productId]
  /// (a card's public id) wins over [productSku]. [tap] is a card tap's
  /// structured `(action, ref)` (`add_to_cart` / `product_detail`, PROTOCOL §4).
  Future<void> send(String text,
      {bool synthetic = false,
      SunonoImage? image,
      String? productId,
      String? productSku,
      ({String action, String ref})? tap}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _busy || _status != ChatStatus.ready) return;
    final user = ChatMessage(id: _id(), role: ChatRole.user, text: trimmed, localImage: image?.bytes);
    _messages.add(user);
    _emit(AnalyticsEvent('assistant_message_sent', {'synthetic': synthetic, 'photo': image != null}));
    await _run(_Outgoing(trimmed, synthetic, image, productId, productSku, tap, user));
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
      final result = out.image == null
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
    final ref = await _session.authed((t) => _api.upload(t, out.image!.bytes, filename: out.image!.filename));
    return _session.authed((t) async {
      TurnResult? done;
      await for (final SseFrame f in _api.chatStream(t, out.text,
          lang: _lang,
          synthetic: out.synthetic,
          productId: out.productId,
          productSku: out.productSku,
          tap: out.tap,
          imageRef: ref,
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
    // A live message.new for the same reply may have landed first.
    if (r.msgRef != null) {
      _messages.removeWhere((m) => !identical(m, bot) && m.msgRef == r.msgRef);
    }
    bot
      ..text = r.reply
      ..products = r.products
      ..hasMore = r.hasMore
      ..checkout = r.checkout
      ..handoffUrl = r.handoffUrl
      ..msgRef = r.msgRef
      ..clientRef = bot._outgoing?.clientMessageId
      ..replyLang = r.replyLang
      ..ts = DateTime.now()
      ..state = MessageState.done
      ..stage = null;
    if (!_messages.contains(bot)) _messages.add(bot);
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
        _messages.add(_fromRow(r));
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

  /// The "handed to our team" pill for a pause at [at]: right before the first
  /// staff row within 60 s after it, else in time order at [at]. Idempotent.
  void _syncPausePill(DateTime? at) {
    if (at == null) return;
    final old = _messages
        .where((m) => m.role == ChatRole.system && m.text == 'paused' && m.ts.isAtSameMomentAs(at))
        .firstOrNull;
    if (old != null) _messages.remove(old);
    final pill = old ?? ChatMessage(id: _id(), role: ChatRole.system, text: 'paused', ts: at);
    final staff = _messages.indexWhere(
        (m) => m.role == ChatRole.staff && !m.ts.isBefore(at) && m.ts.difference(at) <= const Duration(seconds: 60));
    if (staff >= 0) {
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
        _messages.add(
            ChatMessage(id: _id(), role: role, text: text, msgRef: ref, clientRef: clientRef, ts: ts, imageUrl: image));
        if (role == ChatRole.bot && _recoverWake?.isCompleted == false) _recoverWake!.complete(ref ?? '');
        _recoverWake = null;
      case 'conversation.paused':
        _paused = true;
        _syncPausePill(DateTime.tryParse('${data['bot_paused_at']}') ?? _clock());
      case 'conversation.resumed':
        _paused = false;
        _insertPill(ChatMessage(
            id: _id(), role: ChatRole.system, text: 'resumed', ts: DateTime.tryParse('${data['ts']}') ?? _clock()));
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

  void openCart() => _handOrReport(const OpenCartIntent());

  void checkout(String? url) {
    _emit(const AnalyticsEvent('assistant_checkout_tapped'));
    _handOrReport(CheckoutIntent(url: url));
    _unbind(); // the order completes on the storefront and rotates its cart
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
