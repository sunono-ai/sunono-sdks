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

/// A single line or one frame's data exceeded the size caps.
class SseTooLarge implements Exception {
  const SseTooLarge(this.what);
  final String what;
  @override
  String toString() => 'SseTooLarge($what)';
}

const _maxLine = 256 * 1024;
const _maxFrameData = 1024 * 1024;

/// Splits a UTF-8 byte stream into SSE frames (blank-line separated, `\n` or
/// `\r\n`). Comment lines and frames with no `data:` are dropped. A line over
/// 256 KB or a frame's data over 1 MB aborts with [SseTooLarge], checked as
/// bytes arrive so a hostile peer can't make us buffer more.
Stream<SseFrame> parseSse(Stream<List<int>> bytes) async* {
  String? event;
  final data = <String>[];
  var dataLen = 0;
  var pending = '';
  // The trailing '\n' terminates a last unterminated line, as the old splitter did.
  Stream<String> chunks() async* {
    yield* bytes.transform(utf8.decoder);
    yield '\n';
  }

  await for (final chunk in chunks()) {
    pending += chunk;
    var nl = pending.indexOf('\n');
    while (nl != -1) {
      var line = pending.substring(0, nl);
      pending = pending.substring(nl + 1);
      nl = pending.indexOf('\n');
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      if (line.length > _maxLine) throw const SseTooLarge('line');
      if (line.isEmpty) {
        if (data.isNotEmpty) yield SseFrame(event, data.join('\n'));
        event = null;
        data.clear();
        dataLen = 0;
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
        dataLen += value.length;
        if (dataLen > _maxFrameData) throw const SseTooLarge('frame');
        data.add(value);
      }
    }
    if (pending.length > _maxLine) throw const SseTooLarge('line');
  }
  if (data.isNotEmpty) yield SseFrame(event, data.join('\n'));
}
