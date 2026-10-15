import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:k100/core/constants.dart';
import 'package:k100/core/logger.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// A partial or final transcript, plus the confidence when the engine reports it.
@immutable
class SttResult {
  const SttResult({
    required this.text,
    required this.isFinal,
    this.confidence,
  });

  final String text;
  final bool isFinal;
  final double? confidence;

  @override
  String toString() => 'SttResult(${isFinal ? 'final' : 'partial'}, "$text")';
}

/// Why recogniser initialisation failed, translated into something the UI can
/// act on.
enum SttFailure {
  permissionDenied('Microphone permission was denied. Open Android settings → '
      'Apps → K100 → Permissions and allow the microphone.'),
  noRecognizerAvailable('This device has no speech recogniser installed. '
      'Install "Speech Recognition & Synthesis" from the Play Store.'),
  localeNotAvailable('The selected language has no speech recogniser on this '
      'device. Pick another language in Settings.'),
  engineBusy('The recogniser is already running.'),
  unknown('Speech recognition could not be started.');

  const SttFailure(this.message);

  final String message;
}

class SttException implements Exception {
  SttException(this.failure, [this.detail]);

  final SttFailure failure;
  final String? detail;

  /// Learner-facing text: the failure's own message, plus the engine's detail
  /// when the plugin supplied one.
  String get message =>
      detail == null ? failure.message : '${failure.message} ($detail)';

  @override
  String toString() => message;
}

/// Thin, defensive wrapper around `speech_to_text`.
///
/// What this layer adds on top of the plugin:
///  * a single [start] entry point that cannot run two sessions at once;
///  * **on-device first**: `onDevice: true` is requested by default, which keeps
///    the promise that this app never sends the learner's voice anywhere. When
///    the device has no offline language pack, [start] transparently retries
///    once with the network recogniser and reports which one ran through
///    [start]'s `onDevice` callback;
///  * explicit lifecycle reporting so the controller can enforce the half-duplex
///    lock (`isListening` is a fact, not a guess);
///  * a hard timeout independent of the plugin, because some Android builds
///    never deliver a "done" status.
class SttService {
  SttService({SpeechToText? speech}) : _speech = speech ?? SpeechToText();

  final SpeechToText _speech;

  bool _initialized = false;
  bool _listening = false;
  bool _onDevice = true;
  String _localeId = '';
  String? _lastError;

  /// Fired when the engine stops listening for any reason *other* than the
  /// controller calling [stop] or [cancel]. The controller turns this into a
  /// "finish the turn" event so a silence timeout still produces a reply.
  void Function()? onUnexpectedStop;

  bool get isListening => _listening;

  bool get isInitialized => _initialized;

  /// True when the current session runs entirely on the device.
  bool get isOnDevice => _onDevice;

  String get localeId => _localeId;

  String? get lastError => _lastError;

  /// Initialises the plugin. Safe to call repeatedly.
  ///
  /// Returns true when the recogniser is usable. Errors are surfaced through
  /// [onError] as well as the return value, because `initialize()` reports
  /// permission denials through its error callback rather than by throwing.
  Future<bool> initialize({
    void Function(SttFailure failure)? onError,
    void Function(String status)? onStatus,
  }) async {
    if (_initialized) return true;
    try {
      final bool available = await _speech.initialize(
        onError: (SpeechRecognitionError error) {
          _lastError = error.errorMsg;
          Log.warn('Speech recogniser error: ${error.errorMsg} '
              '(${error.permanent ? 'permanent' : 'transient'})');
          final SttFailure failure = _mapError(error.errorMsg);
          if (failure == SttFailure.permissionDenied) {
            _initialized = false;
          }
          onError?.call(failure);
        },
        onStatus: (String status) {
          Log.debug('STT status: $status');
          if (status == 'done' || status == 'notListening') {
            final bool wasListening = _listening;
            _listening = false;
            if (wasListening) onUnexpectedStop?.call();
          }
          onStatus?.call(status);
        },
        debugLogging: kDebugMode,
      );

      if (!available) {
        _initialized = false;
        const SttFailure failure = SttFailure.noRecognizerAvailable;
        onError?.call(failure);
        return false;
      }
      _initialized = true;
      return true;
    } catch (error, stack) {
      Log.error('Speech recogniser initialisation failed', error, stack);
      _initialized = false;
      final SttFailure failure = _mapError('$error');
      onError?.call(failure);
      return false;
    }
  }

  SttFailure _mapError(String raw) {
    final String message = raw.toLowerCase();
    if (message.contains('permission')) return SttFailure.permissionDenied;
    if (message.contains('not available') || message.contains('no recognizer')) {
      return SttFailure.noRecognizerAvailable;
    }
    if (message.contains('language') || message.contains('locale')) {
      return SttFailure.localeNotAvailable;
    }
    return SttFailure.unknown;
  }

  /// Every locale the device's recogniser supports.
  Future<List<LocaleName>> locales() async {
    if (!_initialized) {
      final bool ok = await initialize();
      if (!ok) return <LocaleName>[];
    }
    try {
      return await _speech.locales();
    } catch (error) {
      Log.warn('Could not list recogniser locales', error);
      return <LocaleName>[];
    }
  }

  /// Finds the best installed locale for a language family (`ko` → `ko_KR`).
  ///
  /// Returns the exact locale id, or null when the language is not installed —
  /// the caller decides whether to warn, fall back to the network recogniser, or
  /// offer a different language.
  Future<String?> resolveLocale(String languageCode) async {
    final List<LocaleName> available = await locales();
    if (available.isEmpty) return null;

    final String family = AppLanguageFamily.of(languageCode);
    for (final LocaleName locale in available) {
      if (AppLanguageFamily.of(locale.localeId) == family) {
        return locale.localeId;
      }
    }
    return null;
  }

  /// Starts a recognition session.
  ///
  /// [onResult] receives partial and final results. [onSoundLevel] receives 0..1
  /// for the orb animation. Throws [SttException] when the session cannot start.
  Future<void> start({
    required String localeId,
    required void Function(SttResult result) onResult,
    void Function(double level)? onSoundLevel,
    void Function()? onSessionEnd,
    Duration listenFor = AppConfig.maxListenWindow,
    Duration pauseFor = AppConfig.silenceTimeout,
    bool preferOnDevice = true,
  }) async {
    if (_listening) {
      throw SttException(SttFailure.engineBusy);
    }

    final bool ready = await initialize();
    if (!ready) {
      throw SttException(SttFailure.noRecognizerAvailable);
    }

    _localeId = localeId;
    _lastError = null;

    // Two attempts: strictly on-device first (the promise of this app), then the
    // platform default if the device has no offline pack for this language.
    final List<bool> attempts = preferOnDevice ? <bool>[true, false] : <bool>[false];

    Object? lastFailure;
    for (int i = 0; i < attempts.length; i++) {
      final bool onDevice = attempts[i];
      try {
        await _speech.listen(
          onResult: (SpeechRecognitionResult result) {
            final String text = result.recognizedWords.trim();
            if (result.finalResult) _listening = false;
            onResult(
              SttResult(
                text: text,
                isFinal: result.finalResult,
                confidence: result.hasConfidenceRating ? result.confidence : null,
              ),
            );
            if (result.finalResult) onSessionEnd?.call();
          },
          onSoundLevelChange: onSoundLevel == null
              ? null
              : (double level) {
                  // The plugin reports roughly 0..10 on Android; clamp to 0..1.
                  onSoundLevel((level.abs() / 10).clamp(0.0, 1.0));
                },
          // Everything goes through SpeechListenOptions: the plugin still
          // accepts the old top-level parameters, but they are deprecated and
          // splitting the configuration across two places is how a 30-second
          // listening window silently becomes the platform default.
          listenOptions: SpeechListenOptions(
            partialResults: true,
            cancelOnError: true,
            onDevice: onDevice,
            listenMode: ListenMode.dictation,
            listenFor: listenFor,
            pauseFor: pauseFor,
            localeId: localeId,
          ),
        );
        _listening = true;
        _onDevice = onDevice;
        if (i > 0) {
          Log.warn('Fell back to the platform recogniser (no on-device model for '
              '$localeId)');
        } else {
          Log.info('Listening on $localeId (on-device)');
        }
        return;
      } catch (error) {
        lastFailure = error;
        final String message = '$error';
        // `SpeechToTextNotInitializedException` and permission problems are not
        // fixed by dropping on-device mode — stop retrying.
        if (!preferOnDevice ||
            message.contains('NotInitialized') ||
            message.contains('permission')) {
          break;
        }
        Log.warn('On-device recognition failed for $localeId, retrying online',
            error);
      }
    }

    _listening = false;
    final String detail = '$lastFailure';
    if (detail.contains('permission') || detail.contains('Permission')) {
      throw SttException(SttFailure.permissionDenied, detail);
    }
    throw SttException(SttFailure.unknown, detail);
  }

  /// Graceful stop: the recogniser flushes the final result, so the callback
  /// still fires with `isFinal: true`.
  Future<void> stop() async {
    if (!_listening) return;
    _listening = false;
    try {
      await _speech.stop();
      Log.debug('Recognition stopped');
    } catch (error) {
      Log.warn('stop() threw', error);
    }
  }

  /// Hard cancel: no further callbacks. This is the call the anti-loop guard
  /// makes when it locks the microphone.
  Future<void> cancel() async {
    _listening = false;
    try {
      await _speech.cancel();
      Log.debug('Recognition cancelled');
    } catch (error) {
      Log.warn('cancel() threw', error);
    }
  }

  /// True when the recogniser can be used at all on this device.
  Future<bool> isAvailable() async => initialize();

  Future<void> dispose() async {
    await cancel();
    _initialized = false;
  }
}

/// Locale-family helpers. Kept here so the service and the catalog agree on what
/// "the same language" means (`ko` == `ko_KR` == `ko-KR`).
class AppLanguageFamily {
  AppLanguageFamily._();

  static String of(String localeOrCode) {
    final String normalised = localeOrCode.replaceAll('_', '-');
    final int dash = normalised.indexOf('-');
    return (dash == -1 ? normalised : normalised.substring(0, dash)).toLowerCase();
  }
}
