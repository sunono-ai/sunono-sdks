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

/// Splits a UTF-8 byte stream into SSE frames (blank-line separated; a line
/// ends at `\n`, `\r` or `\r\n`, the last counting once even across chunks).
/// Comment lines and frames with no `data:` are dropped. A line over 256 KB or
/// a frame's data over 1 MB aborts with [SseTooLarge], checked as bytes arrive
/// so a hostile peer can't make us buffer more. Linear in the input size.
Stream<SseFrame> parseSse(Stream<List<int>> bytes) async* {
  String? event;
  final data = <String>[];
  var dataLen = 0;
  final tail = StringBuffer(); // the current unterminated line
  var skipLf = false; // the previous char was '\r': swallow a directly following '\n'
  // The trailing '\n' terminates a last unterminated line.
  Stream<String> chunks() async* {
    yield* bytes.transform(utf8.decoder);
    yield '\n';
  }

  await for (final chunk in chunks()) {
    var start = 0;
    for (var k = 0; k < chunk.length; k++) {
      final ch = chunk.codeUnitAt(k);
      if (ch == 10 && skipLf) {
        skipLf = false;
        start = k + 1;
        continue;
      }
      skipLf = false;
      if (ch != 10 && ch != 13) continue;
      skipLf = ch == 13;
      final line = tail.isEmpty ? chunk.substring(start, k) : (tail..write(chunk.substring(start, k))).toString();
      tail.clear();
      start = k + 1;
      if (line.length > _maxLine) throw const SseTooLarge('line');
      if (line.isEmpty) {
        if (data.isNotEmpty) yield SseFrame(event, data.join('\n'));
        event = null;
        data.clear();
        dataLen = 0;
        continue;
      }
      if (line.startsWith(':')) continue;
      final c = line.indexOf(':');
      final field = c == -1 ? line : line.substring(0, c);
      var value = c == -1 ? '' : line.substring(c + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      if (field == 'event') {
        event = value;
      } else if (field == 'data') {
        dataLen += value.length;
        if (dataLen > _maxFrameData) throw const SseTooLarge('frame');
        data.add(value);
      }
    }
    tail.write(chunk.substring(start));
    if (tail.length > _maxLine) throw const SseTooLarge('line');
  }
  if (data.isNotEmpty) yield SseFrame(event, data.join('\n'));
}
