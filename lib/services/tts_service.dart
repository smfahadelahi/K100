import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:k100/core/constants.dart';
import 'package:k100/core/logger.dart';

/// Why an utterance ended. The controller treats these very differently: only
/// [TtsStopReason.completed] re-arms the microphone after the 300 ms grace
/// period; everything else returns the pipeline to `idle` immediately.
enum TtsStopReason {
  /// The engine fired its completion handler — the natural end of a sentence.
  completed,

  /// The learner interrupted (stop button, new turn, screen closed).
  interrupted,

  /// The watchdog fired: an Android TTS engine that never calls back. Treated
  /// like a completion for lock-release purposes (a stuck mic is worse than a
  /// truncated sentence) but reported as degraded in the log.
  watchdog,

  /// The engine reported an error mid-utterance.
  error,

  /// Nothing was ever spoken (empty text).
  skipped,
}

/// One installed voice.
@immutable
class TtsVoice {
  const TtsVoice({required this.name, required this.locale});

  final String name;

  /// Full locale tag as reported by the engine, e.g. `en-US`.
  final String locale;

  String get language => locale.replaceAll('_', '-').split('-').first.toLowerCase();

  /// Pretty label for the voice picker: "English (US) · en-us-x-sfg#female_1".
  String get label {
    final String prettyLocale = locale.replaceAll('_', '-').replaceAll('-', ' ');
    final String shortName = name.length > 28 ? '${name.substring(0, 28)}…' : name;
    return '$prettyLocale · $shortName';
  }

  @override
  bool operator ==(Object other) =>
      other is TtsVoice && other.name == name && other.locale == locale;

  @override
  int get hashCode => Object.hash(name, locale);

  @override
  String toString() => 'TtsVoice($locale, $name)';
}

class TtsException implements Exception {
  TtsException(this.message);

  final String message;

  @override
  String toString() => 'TtsException: $message';
}

/// Wraps `flutter_tts` with the exact completion semantics the anti-loop
/// controller needs.
///
/// The critical contract: **[speak] only completes when the engine says the
/// utterance is finished, when the caller interrupts it, or when the watchdog
/// fires.** It never completes early, and it never hangs:
///
///  * `awaitSpeakCompletion(true)` makes the plugin surface the completion
///    callback as a future;
///  * the watchdog is derived from the text length
///    ([AppConfig.ttsWatchdogPerChar] × characters, clamped) because several OEM
///    engines simply never call back when audio focus is taken away;
///  * [stop] deliberately **completes the future itself** — Android TTS does
///    *not* fire the completion handler for a cancelled utterance, and waiting
///    for one would deadlock the pipeline with the microphone locked forever.
class TtsService {
  TtsService({FlutterTts? engine}) : _tts = engine ?? FlutterTts();

  final FlutterTts _tts;

  bool _initialized = false;
  bool _speaking = false;
  String? _language;
  double _rate = 0.5;
  double _pitch = 1.0;
  double _volume = 1.0;
  TtsVoice? _voice;

  Completer<TtsStopReason>? _completer;
  Timer? _watchdog;
  TtsStopReason? _pendingReason;

  /// Called when speech starts — the controller uses it to flip the UI into
  /// `aiSpeaking` at the exact moment audio begins.
  void Function()? onStart;

  /// Called when the utterance ends, with the reason. **This is the hook the
  /// microphone unlock is built on.**
  void Function(TtsStopReason reason)? onComplete;

  bool get isSpeaking => _speaking;

  String? get language => _language;

  double get rate => _rate;

  TtsVoice? get voice => _voice;

  // ── Initialisation ────────────────────────────────────────────────────────

  /// Wires up the handlers once. Cheap to call repeatedly.
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      await _tts.awaitSpeakCompletion(true);
      _tts.setStartHandler(() {
        _speaking = true;
        Log.debug('TTS started');
        onStart?.call();
      });
      _tts.setCompletionHandler(() {
        Log.debug('TTS completed');
        _finish(TtsStopReason.completed);
      });
      _tts.setCancelHandler(() {
        // Android does not call the completion handler for a cancelled
        // utterance — route it through the same completion path so nothing can
        // ever wait forever.
        Log.debug('TTS cancelled by the engine');
        _finish(TtsStopReason.interrupted);
      });
      _tts.setErrorHandler((dynamic message) {
        Log.warn('TTS engine error: $message');
        _finish(TtsStopReason.error);
      });
      _initialized = true;
    } catch (error, stack) {
      Log.error('TTS initialisation failed', error, stack);
      _initialized = false;
    }
  }

  // ── Configuration ─────────────────────────────────────────────────────────

  Future<void> setLanguage(String localeTag) async {
    await initialize();
    final String normalised = _normaliseLocale(localeTag);
    try {
      final dynamic result = await _tts.setLanguage(normalised);
      _language = normalised;
      if (result == 0) {
        Log.warn('TTS language $normalised is not installed');
      }
    } catch (error) {
      Log.warn('setLanguage($normalised) failed', error);
      throw TtsException('The voice for $normalised is not installed. '
          'Install it in Android Settings → System → Languages & input → '
          'Text-to-speech.');
    }
  }

  Future<void> setRate(double value) async {
    await initialize();
    _rate = value.clamp(0.1, 1.5);
    try {
      await _tts.setSpeechRate(_rate);
    } catch (error) {
      Log.warn('setSpeechRate failed', error);
    }
  }

  Future<void> setPitch(double value) async {
    await initialize();
    _pitch = value.clamp(0.5, 1.5);
    try {
      await _tts.setPitch(_pitch);
    } catch (error) {
      Log.warn('setPitch failed', error);
    }
  }

  Future<void> setVolume(double value) async {
    await initialize();
    _volume = value.clamp(0.0, 1.0);
    try {
      await _tts.setVolume(_volume);
    } catch (error) {
      Log.warn('setVolume failed', error);
    }
  }

  Future<void> setVoice(TtsVoice value) async {
    await initialize();
    try {
      final dynamic ok = await _tts.setVoice(
        <String, String>{'name': value.name, 'locale': value.locale},
      );
      if (ok == 1 || ok == true) {
        _voice = value;
      } else {
        Log.warn('setVoice rejected ${value.label}');
      }
    } catch (error) {
      Log.warn('setVoice failed', error);
    }
  }

  /// Installed voices, filtered to the target language by the caller.
  Future<List<TtsVoice>> voices() async {
    await initialize();
    try {
      final dynamic raw = await _tts.getVoices;
      if (raw is! List) return <TtsVoice>[];
      return raw
          .whereType<Map>()
          .map((Map<dynamic, dynamic> map) => TtsVoice(
                name: '${map['name'] ?? ''}',
                locale: '${map['locale'] ?? ''}',
              ))
          .where((TtsVoice v) => v.name.isNotEmpty && v.locale.isNotEmpty)
          .toList();
    } catch (error) {
      Log.warn('getVoices failed', error);
      return <TtsVoice>[];
    }
  }

  /// The engine's own locale list (`getLanguages`).
  Future<List<String>> languages() async {
    await initialize();
    try {
      final dynamic raw = await _tts.getLanguages;
      if (raw is List) return raw.map((dynamic e) => '$e').toList();
      return <String>[];
    } catch (error) {
      Log.warn('getLanguages failed', error);
      return <String>[];
    }
  }

  Future<bool> isLanguageAvailable(String localeTag) async {
    final List<String> available = await languages();
    final String needle = _normaliseLocale(localeTag).toLowerCase();
    final String family = needle.split('-').first;
    return available.any((String tag) {
      final String normalised = tag.replaceAll('_', '-').toLowerCase();
      return normalised == needle || normalised.split('-').first == family;
    });
  }

  // ── Speaking ──────────────────────────────────────────────────────────────

  /// Speaks [text] and completes when the utterance ends.
  ///
  /// Always returns a [TtsStopReason] instead of throwing for engine hiccups: a
  /// missing voice or an engine error must still release the microphone.
  Future<TtsStopReason> speak(
    String text, {
    double? rate,
    String? localeTag,
    bool interruptCurrent = true,
  }) async {
    final String spoken = text.trim();
    if (spoken.isEmpty) return TtsStopReason.skipped;

    await initialize();

    if (_speaking) {
      if (!interruptCurrent) {
        throw TtsException('Already speaking.');
      }
      await stop();
    }

    if (rate != null && (rate - _rate).abs() > 0.001) await setRate(rate);
    if (localeTag != null && _language != localeTag) {
      try {
        await setLanguage(localeTag);
      } on TtsException catch (error) {
        Log.warn(error.message);
        // Keep going: the current voice may still pronounce it acceptably, and
        // failing here would leave the mic locked.
      }
    }

    _pendingReason = null;
    final Completer<TtsStopReason> completer = Completer<TtsStopReason>();
    _completer = completer;
    _watchdog?.cancel();
    _watchdog = Timer(_watchdogDelay(spoken), () {
      Log.warn('TTS watchdog fired after ${_watchdogDelay(spoken).inSeconds}s — '
          'the engine never reported completion');
      _finish(TtsStopReason.watchdog);
    });

    try {
      final dynamic result = await _tts.speak(spoken);
      if (result == 0) {
        Log.warn('TTS engine refused the utterance');
        _finish(TtsStopReason.error);
      }
    } catch (error, stack) {
      Log.error('TTS speak() threw', error, stack);
      _finish(TtsStopReason.error);
    }

    final TtsStopReason reason = await completer.future;
    return reason;
  }

  /// Interrupts the current utterance. Completes the pending [speak] future with
  /// [TtsStopReason.interrupted] — Android will not.
  Future<void> stop() async {
    _watchdog?.cancel();
    _watchdog = null;
    try {
      await _tts.stop();
    } catch (error) {
      Log.warn('TTS stop() threw', error);
    }
    _finish(TtsStopReason.interrupted);
  }

  void _finish(TtsStopReason reason) {
    _watchdog?.cancel();
    _watchdog = null;
    _speaking = false;
    _pendingReason = reason;

    final Completer<TtsStopReason>? completer = _completer;
    _completer = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(reason);
    }
    // The controller owns the unlock timing; this callback is fired synchronously
    // so it can start its 300 ms timer without an extra event-loop hop.
    onComplete?.call(reason);
  }

  TtsStopReason? get lastStopReason => _pendingReason;

  /// Length-derived watchdog. ~85 ms per character covers slow-speaking voices,
  /// with a 4 s floor and a 60 s ceiling.
  Duration _watchdogDelay(String text) {
    final int millis = text.length * AppConfig.ttsWatchdogPerChar.inMilliseconds;
    final int clamped = millis.clamp(
      AppConfig.ttsWatchdogMin.inMilliseconds,
      AppConfig.ttsWatchdogMax.inMilliseconds,
    );
    return Duration(milliseconds: clamped);
  }

  String _normaliseLocale(String tag) => tag.replaceAll('_', '-');

  Future<void> dispose() async {
    _watchdog?.cancel();
    _watchdog = null;
    await stop();
    _initialized = false;
  }
}
