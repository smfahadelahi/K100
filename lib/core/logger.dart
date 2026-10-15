import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Minimal, dependency-free logger.
///
/// Why not `package:logger`? Every dependency in this app is a liability —
/// K100 is meant to be auditable end-to-end, and a 60-line logger is auditable.
///
/// Behaviour:
///  * `debug`/`info` lines are dropped in release builds (`kDebugMode`).
///  * `warn`/`error` always print: they are the only signal available when the
///    app misbehaves on a user's phone with no debugger attached.
///  * The last [maxHistory] lines are kept in memory and mirrored through
///    [stream], which powers the in-app diagnostics view.
class Log {
  Log._();

  static const int maxHistory = 400;

  /// Lines are tagged so `adb logcat -s flutter` stays readable.
  static const String _tag = 'K100';

  static final Queue<String> _history = Queue<String>();
  static final StreamController<String> _controller =
      StreamController<String>.broadcast();

  /// Recent lines, oldest first. Snapshot — mutating it does nothing.
  static List<String> get history => List<String>.unmodifiable(_history);

  /// Live line feed for the diagnostics screen.
  static Stream<String> get stream => _controller.stream;

  static void debug(String message) {
    if (!kDebugMode) return;
    _emit('DEBUG', message, printToConsole: true);
  }

  static void info(String message) => _emit('INFO ', message, printToConsole: kDebugMode);

  static void warn(String message, [Object? error, StackTrace? stack]) {
    _emit('WARN ', message, printToConsole: true);
    _emitDetail(error, stack);
  }

  static void error(String message, [Object? error, StackTrace? stack]) {
    _emit('ERROR', message, printToConsole: true);
    _emitDetail(error, stack);
  }

  /// Wraps an async operation so a failure is logged in context instead of
  /// silently swallowing the future. Returns [fallback] when [body] throws.
  static Future<T?> guard<T>(
    String label,
    Future<T> Function() body, {
    T? fallback,
  }) async {
    try {
      return await body();
    } catch (error, stack) {
      Log.error(label, error, stack);
      return fallback;
    }
  }

  static void _emit(String level, String message, {required bool printToConsole}) {
    final String line = '[$level] $_tag ${_timestamp()} $message';
    _history.addLast(line);
    while (_history.length > maxHistory) {
      _history.removeFirst();
    }
    if (!_controller.isClosed) _controller.add(line);
    if (printToConsole) {
      // ignore: avoid_print
      print(line);
    }
  }

  static void _emitDetail(Object? error, StackTrace? stack) {
    if (error != null) _emit('TRACE', '↳ $error', printToConsole: true);
    if (stack != null) {
      final List<String> frames = stack.toString().split('\n').take(6).toList();
      for (final String frame in frames) {
        if (frame.trim().isEmpty) continue;
        _emit('TRACE', '  $frame', printToConsole: false);
      }
    }
  }

  static String _timestamp() {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.${three(now.millisecond)}';
  }

  /// Flushes the in-memory history. Used by tests.
  @visibleForTesting
  static void clear() => _history.clear();
}
