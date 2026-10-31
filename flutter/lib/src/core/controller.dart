import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
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
  _Outgoing(this.text, this.synthetic, this.image, this.productId, this.user);
  final String text;
  final bool synthetic;
  final SunonoImage? image;
  final String? productId;

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
    this.recoveryChecks = const [Duration(seconds: 4), Duration(seconds: 8), Duration(seconds: 18)],
  })  : _api = api,
        _lang = lang {
    _session = Session(api, storage);
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

  /// Delays between history checks while recovering (cumulative waits).
  final List<Duration> recoveryChecks;

  final _events = StreamController<SunonoEvent>.broadcast();
  final List<ChatMessage> _messages = [];
  String _lang;
  ChatStatus _status = ChatStatus.idle;
  ShopConfig _config = const ShopConfig();
  Cart? _cart;
  bool _paused = false;
  bool _typingHint = true;
  bool _busy = false;
  bool _bound = false;
  bool _ensureTried = false;
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

  /// A human currently owns the conversation.
  bool get paused => _paused;

  /// A turn is in flight; the composer should not send.
  bool get busy => _busy;
  Stream<SunonoEvent> get events => _events.stream;
  String? get userId => _session.userId;

  String _id() => 'm${++_seq}';

  void _emit(SunonoEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _changed() {
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
    } catch (e, s) {
      _emit(ErrorEvent(e, s)); // keep defaults: config is presentation only
    }
    if (epoch != _epoch) return;
    if (!_config.enabled) {
      _status = ChatStatus.disabled;
      _changed();
      return;
    }
    _typingHint = _config.typingHint;
    _status = ChatStatus.ready;
    _ensureTried = false;
    _changed();
    _emit(const AnalyticsEvent('assistant_opened'));
    unawaited(_bind(ensure: false));
    _live.start(); // fetches history first
  }

  /// App went to background: drop the live connection.
  void suspend() => _live.stop();

  /// App came back: history first, then live again; re-check the cart link.
  void resume() {
    if (_status != ChatStatus.ready) return;
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
    _cart = null;
    _paused = false;
    _bound = false;
    _ensureTried = false;
    _busy = false;
    final wasOpen = _status == ChatStatus.ready;
    _status = ChatStatus.idle;
    _changed();
    if (wasOpen) await open();
  }

  /// Re-run the cart binding (after host login/logout/cart replacement).
  Future<void> refreshCartBinding() {
    _bound = false;
    _ensureTried = false;
    return _bind(ensure: false);
  }

  Future<void> _bind({required bool ensure}) async {
    final bridge = cartBridge;
    if (bridge == null || (_bound && ensure)) return;
    final epoch = _epoch;
    try {
      final uid = await _session.ensureUserId();
      final proof = ensure ? await bridge.ensureBind(uid) : await bridge.probe(uid);
      if (proof == null || epoch != _epoch) return;
      final bound = await _api.bindCart(uid, proof);
      if (epoch == _epoch) _bound = bound;
    } catch (e, s) {
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

  /// Send a message. [synthetic]: generated by a tap, not typed.
  Future<void> send(String text, {bool synthetic = false, SunonoImage? image, String? productId}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _busy || _status != ChatStatus.ready) return;
    final user = ChatMessage(id: _id(), role: ChatRole.user, text: trimmed, localImage: image?.bytes);
    _messages.add(user);
    _emit(AnalyticsEvent('assistant_message_sent', {'synthetic': synthetic, 'photo': image != null}));
    await _run(_Outgoing(trimmed, synthetic, image, productId, user));
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
          ? await _session
              .authed((t) => _api.chat(t, out.text, lang: _lang, synthetic: out.synthetic, productId: out.productId))
          : await _photoTurn(out, bot);
      if (epoch == _epoch) _apply(bot, result);
    } on SunonoHttpException catch (e) {
      if (epoch != _epoch) return;
      if (e.status < 500) {
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
        _changed();
      }
    }
  }

  Future<TurnResult> _photoTurn(_Outgoing out, ChatMessage bot) async {
    final ref = await _session.authed((t) => _api.upload(t, out.image!.bytes, filename: out.image!.filename));
    return _session.authed((t) async {
      TurnResult? done;
      await for (final SseFrame f in _api.chatStream(t, out.text,
          lang: _lang, synthetic: out.synthetic, productId: out.productId, imageRef: ref)) {
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
    if (r.cartPresent) {
      _cart = r.cart;
    }
    if (r.cartMutated) _emit(CartChangedEvent(_cart));
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
        _messages
          ..clear()
          ..addAll(h.rows.map(_fromRow));
        _applyHistoryMeta(h);
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
        if (r.msgRef != null && onScreen.contains(r.msgRef)) continue;
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
    _applyHistoryMeta(h);
    _changed();
    if (h.cartLinked) {
      try {
        final c = await _session.authed(_api.cart);
        if (epoch != _epoch) return;
        _cart = c.cart;
        _changed();
      } catch (e, s) {
        _emit(ErrorEvent(e, s));
      }
    }
  }

  /// Legacy rows without msg_ref: same role + text within 15 s.
  bool _sameRecentBubble(HistoryRow r) => _messages.any((m) =>
      m.role.name == r.role &&
      m.text == r.text &&
      (r.ts == null || m.ts.difference(r.ts!).abs() < const Duration(seconds: 15)));

  void _applyHistoryMeta(History h) {
    _paused = h.pausedAt != null;
    _cart = h.cart; // the server's cart row is the truth, empty included
  }

  void _onLive(String type, Map<String, dynamic> data) {
    switch (type) {
      case 'message.new':
        final text = data['body_text'] is String ? data['body_text'] as String : '';
        final ref = data['msg_ref'] is String ? data['msg_ref'] as String : null;
        final ts = DateTime.tryParse('${data['ts']}');
        final role = data['sent_by'] == 'owner' ? ChatRole.staff : ChatRole.bot;
        if (ref != null
            ? _messages.any((m) => m.msgRef == ref)
            : _messages.any((m) => m.role == role && m.text == text)) {
          return;
        }
        final media = data['media_stored'];
        var image = media is Map && media['kind'] == 'image' && media['url'] is String ? media['url'] as String : null;
        if (image != null && image.startsWith('/')) image = '${_api.apiOrigin}$image';
        if (image != null && !image.startsWith('https://') && !image.startsWith('http://')) image = null;
        _messages.add(ChatMessage(id: _id(), role: role, text: text, msgRef: ref, ts: ts, imageUrl: image));
        if (role == ChatRole.bot && _recoverWake?.isCompleted == false) _recoverWake!.complete(ref ?? '');
        _recoverWake = null;
      case 'conversation.paused':
        _paused = true;
        _messages.add(ChatMessage(id: _id(), role: ChatRole.system, text: 'paused'));
      case 'conversation.resumed':
        _paused = false;
        _messages.add(ChatMessage(id: _id(), role: ChatRole.system, text: 'resumed'));
      case 'assistant.state':
        _typingHint = data['typing_hint'] != false;
      case 'cart.updated':
        _cart = Cart.fromJson(data['cart']);
        _emit(CartChangedEvent(_cart));
      default:
        return; // forward compatibility: unknown events are ignored
    }
    _changed();
  }

  // ---------------------------------------------------------------- intents

  bool _hand(SunonoIntent intent) => onIntent?.call(intent) ?? false;

  void openProduct(ProductCard p) {
    _emit(AnalyticsEvent('assistant_product_tapped', {'product_id': p.publicId, 'sku': p.sku}));
    _hand(OpenProductIntent(productId: p.publicId, sku: p.sku, url: p.externalUrl, title: p.title(_lang)));
  }

  void openCart() => _hand(const OpenCartIntent());

  void checkout(String? url) {
    _emit(const AnalyticsEvent('assistant_checkout_tapped'));
    _hand(CheckoutIntent(url: url));
  }

  void openUrl(String url) => _hand(OpenUrlIntent(url));
}
