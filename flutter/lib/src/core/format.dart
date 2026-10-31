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

String showMorePhrase(String lang) => lang == 'en' ? 'Show me more' : 'ورجيني كمان';
