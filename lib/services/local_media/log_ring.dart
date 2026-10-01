import 'dart:collection';

/// Dart-side error ring buffer (requirement §2.6).
///
/// Collects Dart errors/exceptions (wired through Catcher2 / FlutterError /
/// PlatformDispatcher) and notable local-module events. Combined with the
/// native logcat ring (LocalMediaChannel.logGet) it forms the diagnostic
/// export.
class LocalLogRing {
  LocalLogRing._();

  static final LocalLogRing instance = LocalLogRing._();

  static const int maxLines = 1500;
  final ListQueue<String> _lines = ListQueue<String>();

  void add(String level, String tag, String message) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final ts =
        '${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}:${two(now.second)}.${now.millisecond.toString().padLeft(3, '0')}';
    _lines.addLast('$ts $level/$tag: $message');
    while (_lines.length > maxLines) {
      _lines.removeFirst();
    }
  }

  void e(String tag, Object error, [StackTrace? stack]) {
    add('E', tag, stack == null ? '$error' : '$error\n$stack');
  }

  void w(String tag, String message) => add('W', tag, message);
  void i(String tag, String message) => add('I', tag, message);

  List<String> snapshot() => _lines.toList();

  void clear() => _lines.clear();
}
