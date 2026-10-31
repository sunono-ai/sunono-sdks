import 'dart:convert';

/// One Server-Sent Events frame.
class SseFrame {
  const SseFrame(this.event, this.data);

  /// The `event:` name, or null when the frame had none.
  final String? event;
  final String data;

  /// The data parsed as a JSON object, or null when it isn't one.
  Map<String, dynamic>? get json {
    try {
      final v = jsonDecode(data);
      return v is Map ? v.cast<String, dynamic>() : null;
    } on FormatException {
      return null;
    }
  }
}

/// Splits a UTF-8 byte stream into SSE frames (blank-line separated, `\n` or
/// `\r\n`). Comment lines and frames with no `data:` are dropped.
Stream<SseFrame> parseSse(Stream<List<int>> bytes) async* {
  String? event;
  final data = <String>[];
  await for (final line in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) yield SseFrame(event, data.join('\n'));
      event = null;
      data.clear();
      continue;
    }
    if (line.startsWith(':')) continue;
    final i = line.indexOf(':');
    final field = i == -1 ? line : line.substring(0, i);
    var value = i == -1 ? '' : line.substring(i + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') {
      event = value;
    } else if (field == 'data') {
      data.add(value);
    }
  }
  if (data.isNotEmpty) yield SseFrame(event, data.join('\n'));
}
