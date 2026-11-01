// Display rules shared by every client (PROTOCOL §0, §4.2, §4.3).

/// «12.5 د.أ» / "12.5 JOD": at most 2 decimals, half-up on exact fils,
/// Latin digits in every language, comma thousands grouping.
String formatJod(num? amount, String lang) {
  if (amount == null || !amount.isFinite) return '—';
  // Round via integer fils first so 6.845 can't round down as a double.
  final cents = ((amount * 1000).round() / 10).round();
  final whole = cents ~/ 100;
  final frac = cents % 100;
  var digits = whole.abs().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  if (cents < 0) digits = '-$digits';
  if (frac != 0) {
    digits += '.${frac.toString().padLeft(2, '0').replaceFirst(RegExp(r'0$'), '')}';
  }
  return lang == 'en' ? '$digits JOD' : '$digits د.أ';
}

String formatFils(int? fils, String lang) => fils == null ? '—' : formatJod(fils / 1000, lang);

/// Defensive cleanup of stray Markdown the model sometimes leaves.
String sanitizeReply(String text) => text
    .replaceAll('**', '')
    .replaceAll(RegExp(r'^#+\s*', multiLine: true), '')
    .replaceAll(RegExp(r'^\s*-\s+', multiLine: true), '');

final _arabic = RegExp('[؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻿]');
final _latin = RegExp('[A-Za-z]');

/// Dominant script decides; neutral text (digits/emoji) returns [fallbackRtl].
bool isRtlText(String text, {required bool fallbackRtl}) {
  final ar = _arabic.allMatches(text).length;
  final la = _latin.allMatches(text).length;
  if (ar == 0 && la == 0) return fallbackRtl;
  return ar > la;
}

const _stageAr = {
  'understand': 'بفكر…',
  'classify': 'بفكر…',
  'search': 'بدور على المنتجات…',
  'search_rewrite': 'بدور على المنتجات…',
  'action': 'بنفذ الطلب…',
  'extract_cart_items': 'بنفذ الطلب…',
  'remove_from_cart': 'بنفذ الطلب…',
  'order_slots': 'بنفذ الطلب…',
  'generate': 'بجهّز الرد…',
};

const _stageEn = {
  'understand': 'Thinking...',
  'classify': 'Thinking...',
  'search': 'Searching products...',
  'search_rewrite': 'Searching products...',
  'action': 'Executing...',
  'extract_cart_items': 'Executing...',
  'remove_from_cart': 'Executing...',
  'order_slots': 'Executing...',
  'generate': 'Generating reply...',
};

/// Label for a pipeline stage; null [stage] = generic "thinking".
String stageLabel(String? stage, String lang) {
  if (stage == null) return lang == 'en' ? 'Thinking...' : 'بفكر…';
  return (lang == 'en' ? _stageEn[stage] ?? 'Working on it...' : _stageAr[stage] ?? 'بشتغل عليها…');
}

/// Synthetic messages a tap sends (PROTOCOL §5.1, §4.1 has_more).
String addToCartPhrase(String title, String lang) => lang == 'ar' ? 'ضيف "$title" للسلة' : 'Add "$title" to my cart';

String detailsPhrase(String title, String lang) =>
    lang == 'ar' ? 'احكيلي أكثر عن "$title"' : 'Tell me more about "$title"';

String cartPhrase(String lang) => lang == 'en' ? "What's in my cart?" : 'شو يلي بالسلة؟';

String orderStatusPhrase(String? number, String lang) => lang == 'en'
    ? (number == null ? 'Where is my order?' : 'Where is my order $number?')
    : (number == null ? 'وين صار طلبي؟' : 'وين صار طلبي $number؟');

String showMorePhrase(String lang) => lang == 'en' ? 'Show me more' : 'ورجيني كمان';

/// «09:05»: local time, 24 h, Latin digits in every language (no `intl`).
String formatTime(DateTime t, String lang) {
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

// Unicode format characters (category Cf): bidi controls, zero-width, joiners.
const _formatChars =
    '\u00AD\u0600-\u0605\u061C\u06DD\u070F\u180E\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u206F\uFEFF';
final _format = RegExp('[$_formatChars]');
final _linkTail = RegExp('[.,;:!?)\\]}»؟،؛$_formatChars]+\$');

/// [url] without the prose punctuation and invisible format characters that
/// trail it in running text («…/p؟», «(…/p)», «…/p» + RLM).
String trimLinkTail(String url) => url.replaceFirst(_linkTail, '');

/// A link worth making tappable: `https://`, an ASCII host, no userinfo, and no
/// hidden format characters (a bidi override can make `evil.com` read as another site).
bool isSafeLink(String url) {
  if (!url.startsWith('https://') || _format.hasMatch(url)) return false;
  // Check the raw authority: Uri.host would percent-encode a non-ASCII name.
  final authority = url.substring('https://'.length).split(RegExp('[/?#]')).first;
  return authority.isNotEmpty &&
      !authority.contains('@') &&
      authority.codeUnits.every((c) => c < 128) &&
      Uri.tryParse(url)?.host.isNotEmpty == true;
}
