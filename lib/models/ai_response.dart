import 'dart:convert';

import 'package:flutter/foundation.dart';

/// How a model reply was turned into fields. Surfaced in the UI as a subtle
/// badge, because a "repaired" answer is still useful but *is* a signal that the
/// model is drifting off the JSON contract.
enum AiParseMode {
  /// `jsonDecode` accepted the object as-is.
  strictJson('Strict JSON'),

  /// The object needed mechanical fixes (smart quotes, trailing comma, a
  /// truncated tail) before it would decode.
  repairedJson('Repaired JSON'),

  /// No decodable object: individual fields were recovered with regexes.
  regexRecovered('Field recovery'),

  /// Pure text reply with no JSON at all — shown as-is, no feedback card.
  rawText('Plain text');

  const AiParseMode(this.label);

  final String label;

  /// True for anything that is not a clean structured reply.
  bool get isDegraded => this != AiParseMode.strictJson;

  /// The badge shown next to the tutor's bubble. Null for clean responses.
  String? get badge => this == AiParseMode.strictJson ? null : label;

  /// Sentence the UI shows when explaining the badge to the learner.
  String get explanation {
    switch (this) {
      case AiParseMode.strictJson:
        return 'The model followed the response format exactly.';
      case AiParseMode.repairedJson:
        return 'The model’s JSON needed small fixes (quotes or a trailing '
            'comma) before it could be read.';
      case AiParseMode.regexRecovered:
        return 'The model’s JSON was broken, so the reply and the correction '
            'were recovered field by field. Nothing was lost, but the format '
            'drifted — the next turn re-asks more strictly.';
      case AiParseMode.rawText:
        return 'The model answered with plain text instead of JSON. It is shown '
            'as the reply, without grammar feedback.';
    }
  }
}

/// The tutor's structured turn.
///
/// This is the *only* shape the pipeline understands. The model is instructed to
/// emit exactly:
///
/// ```json
/// {
///   "reply_target_language": "…",   // spoken by TTS, shown as the bubble
///   "reply_translation": "…",       // native-language translation
///   "grammar_correction": "…",      // corrected learner sentence, or null
///   "explanation": "…",             // one line on why, or null
///   "fluency_score": 72             // 0-100
/// }
/// ```
///
/// Three optional extras are also honoured when the model volunteers them
/// (`reply_romanization`, `key_phrase`, `key_phrase_translation`); they power the
/// vocabulary bank and the romanisation line for non-Latin scripts. Their absence
/// never degrades [parseMode].
///
/// [parse] never throws and never returns null. A 1.5B model *will* eventually
/// emit something malformed, and a speaking tutor that crashes on a stray comma
/// is worthless.
@immutable
class AiResponse {
  const AiResponse({
    required this.replyTargetLanguage,
    required this.replyTranslation,
    this.replyRomanization,
    this.grammarCorrection,
    this.explanation,
    this.fluencyScore,
    this.keyPhrase,
    this.keyPhraseTranslation,
    required this.mode,
    this.latency,
    this.tokensPredicted,
    this.rawModelOutput,
  });

  /// The sentence the tutor speaks. `flutter_tts` receives **only** this field.
  final String replyTargetLanguage;

  /// Native-language translation of [replyTargetLanguage]. May be empty when the
  /// learner disabled translations — the pipeline then passes an empty string.
  final String replyTranslation;

  /// Romanisation of [replyTargetLanguage] for non-Latin scripts.
  final String? replyRomanization;

  /// The learner's sentence, corrected. Null when nothing needed fixing.
  final String? grammarCorrection;

  /// One-line explanation of the correction, in the explanation language.
  final String? explanation;

  /// 0–100. Null when the model declined to score the turn.
  final int? fluencyScore;

  /// A useful phrase mined from the reply, for the vocabulary bank.
  final String? keyPhrase;
  final String? keyPhraseTranslation;

  /// Legacy alias kept for the UI layer.
  AiParseMode get parseMode => mode;

  final AiParseMode mode;

  /// Wall-clock time from prompt to last token.
  final Duration? latency;

  final int? tokensPredicted;

  /// The untouched model output, kept for the diagnostics view.
  final String? rawModelOutput;

  // ── Derived ───────────────────────────────────────────────────────────────

  bool get hasCorrection => (grammarCorrection ?? '').trim().isNotEmpty;

  bool get hasExplanation => (explanation ?? '').trim().isNotEmpty;

  bool get hasTranslation => replyTranslation.trim().isNotEmpty;

  bool get hasRomanization => (replyRomanization ?? '').trim().isNotEmpty;

  bool get hasKeyPhrase =>
      (keyPhrase ?? '').trim().isNotEmpty && (keyPhrase ?? '').trim().length > 1;

  bool get isUsable => replyTargetLanguage.trim().length >= 2;

  bool get isDegraded => mode.isDegraded;

  int get replyWordCount =>
      replyTargetLanguage.trim().isEmpty
          ? 0
          : replyTargetLanguage.trim().split(RegExp(r'\s+')).length;

  /// Sentence-ish count that works for CJK too (where there are no spaces):
  /// counts terminal punctuation plus one.
  int get replySentenceCount {
    final String text = replyTargetLanguage.trim();
    if (text.isEmpty) return 0;
    final int stops = RegExp(r'[.!?。！？…]').allMatches(text).length;
    return stops == 0 ? 1 : stops;
  }

  /// Feedback strength shown as a 0–3 dot meter in the grammar card.
  int get correctionSeverity {
    if (!hasCorrection) return 0;
    final String a = _normalise(replyTargetLanguage);
    final String b = _normalise(grammarCorrection ?? '');
    if (a == b) return 0;
    final double ratio = _similarity(a, b);
    if (ratio > 0.85) return 1;
    if (ratio > 0.6) return 2;
    return 3;
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  PARSING
  // ══════════════════════════════════════════════════════════════════════════

  /// Parses a raw model completion into an [AiResponse]. **Never throws.**
  ///
  /// Pipeline: strict decode → mechanical repair → regex field recovery →
  /// plain-text fallback. [learnerText] is optional context used to suppress
  /// bogus "corrections" that merely repeat what the learner said.
  static AiResponse parse(
    String raw, {
    Duration? latency,
    int? tokensPredicted,
    String? learnerText,
    String? fallbackTranslation,
  }) {
    final String trimmedRaw = raw.trim();

    // 0. Empty generation — could be an aborted turn or a hard engine failure.
    if (trimmedRaw.isEmpty) {
      return AiResponse(
        replyTargetLanguage: '',
        replyTranslation: '',
        mode: AiParseMode.rawText,
        latency: latency,
        tokensPredicted: tokensPredicted,
        rawModelOutput: raw,
      );
    }

    // 1/2. Find and decode the first JSON object, repairing if necessary.
    final String? candidate = _extractJsonObject(trimmedRaw);
    if (candidate != null) {
      Map<String, dynamic>? map = _tryDecode(candidate);
      AiParseMode mode = AiParseMode.strictJson;
      if (map == null) {
        final String repaired = repairJson(candidate);
        map = _tryDecode(repaired);
        if (map != null) mode = AiParseMode.repairedJson;
      }
      if (map == null) {
        // The object was structurally broken (usually truncation). Try to close
        // it, then fall back to per-field regex recovery.
        final String closed = _closeUnterminated(candidate);
        map = _tryDecode(closed);
        map ??= _tryDecode(repairJson(closed));
        if (map != null) mode = AiParseMode.repairedJson;
      }

      if (map != null) {
        final AiResponse parsed = _fromMap(
          map,
          mode: mode,
          latency: latency,
          tokensPredicted: tokensPredicted,
          rawModelOutput: raw,
        );
        if (parsed.isUsable) {
          return parsed.cleanup(learnerText: learnerText);
        }
        // The object decoded but had no usable reply text (e.g. the model only
        // emitted feedback). Fall through to recovery so we still say something.
      }

      final AiResponse recovered = _regexRecover(
        candidate,
        latency: latency,
        tokensPredicted: tokensPredicted,
        rawModelOutput: raw,
        fallbackTranslation: fallbackTranslation,
      );
      if (recovered.isUsable) {
        return recovered.cleanup(learnerText: learnerText);
      }
    }

    // 3. Prose containing a JSON-ish fragment, or a fully malformed answer.
    final AiResponse regexOverWholeText = _regexRecover(
      trimmedRaw,
      latency: latency,
      tokensPredicted: tokensPredicted,
      rawModelOutput: raw,
      fallbackTranslation: fallbackTranslation,
    );
    if (regexOverWholeText.isUsable) {
      return regexOverWholeText.cleanup(learnerText: learnerText);
    }

    // 4. Plain text: strip obvious wrappers and treat it as the spoken reply.
    final String plain = sanitizeForSpeech(
      _stripWrappers(trimmedRaw),
    );
    return AiResponse(
      replyTargetLanguage: plain,
      replyTranslation: fallbackTranslation ?? '',
      mode: AiParseMode.rawText,
      latency: latency,
      tokensPredicted: tokensPredicted,
      rawModelOutput: raw,
    );
  }

  /// Convenience constructor for hard failures so callers never build a
  /// half-filled object by hand.
  static AiResponse failure(String message) => AiResponse(
        replyTargetLanguage: '',
        replyTranslation: '',
        explanation: message,
        mode: AiParseMode.rawText,
      );

  static Map<String, dynamic>? _tryDecode(String text) {
    if (text.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map<String, dynamic>(
          (Object? key, Object? value) => MapEntry<String, dynamic>('$key', value),
        );
      }
      // A bare string or list: wrap it so field extraction can use it.
      if (decoded is String) return <String, dynamic>{'reply_target_language': decoded};
      return null;
    } on FormatException {
      return null;
    } catch (_) {
      return null;
    }
  }

  // ── Field extraction ──────────────────────────────────────────────────────

  static AiResponse _fromMap(
    Map<String, dynamic> map, {
    required AiParseMode mode,
    Duration? latency,
    int? tokensPredicted,
    String? rawModelOutput,
  }) {
    final String reply = _readString(map, const <String>[
      'reply_target_language',
      'reply_in_target_language',
      'reply_target',
      'target_reply',
      'reply',
      'response',
      'answer',
      'ai_reply',
      'tutor_reply',
      'text',
      'sentence',
      'target_language',
    ]);

    final String translation = _readString(map, const <String>[
      'reply_translation',
      'translation',
      'reply_in_native_language',
      'native_translation',
      'english_translation',
      'translate',
    ]);

    final String romanization = _readString(map, const <String>[
      'reply_romanization',
      'romanization',
      'romanisation',
      'romanized',
      'transliteration',
      'pronunciation',
    ]);

    final String correction = _readString(map, const <String>[
      'grammar_correction',
      'corrected_sentence',
      'correction',
      'grammar_fix',
      'corrected',
      'grammar',
      'fix',
    ]);

    final String explanation = _readString(map, const <String>[
      'explanation',
      'grammar_explanation',
      'why',
      'reason',
      'note',
      'comment',
      'feedback',
    ]);

    final int? score = _readScore(map, const <String>[
      'fluency_score',
      'fluency',
      'score',
      'fluencyScore',
      'rating',
    ]);

    final String keyPhrase = _readString(map, const <String>[
      'key_phrase',
      'phrase',
      'useful_phrase',
      'vocabulary',
      'word',
    ]);

    final String keyPhraseTranslation = _readString(map, const <String>[
      'key_phrase_translation',
      'phrase_translation',
      'useful_phrase_translation',
      'vocabulary_translation',
      'word_translation',
    ]);

    return AiResponse(
      replyTargetLanguage: reply,
      replyTranslation: translation,
      replyRomanization: romanization.isEmpty ? null : romanization,
      grammarCorrection: correction.isEmpty ? null : correction,
      explanation: explanation.isEmpty ? null : explanation,
      fluencyScore: score,
      keyPhrase: keyPhrase.isEmpty ? null : keyPhrase,
      keyPhraseTranslation: keyPhraseTranslation.isEmpty ? null : keyPhraseTranslation,
      mode: mode,
      latency: latency,
      tokensPredicted: tokensPredicted,
      rawModelOutput: rawModelOutput,
    );
  }

  /// Reads the first non-empty string among [keys]. Tolerates the model putting
  /// numbers, nested objects or `null` where a string was requested.
  static String _readString(Map<String, dynamic> map, List<String> keys) {
    for (final String key in keys) {
      if (!map.containsKey(key)) continue;
      final Object? value = map[key];
      final String text = _stringify(value);
      if (text.isNotEmpty) return text;
    }
    // Case-insensitive second pass: models sometimes emit "Reply".
    final Map<String, Object?> lowered = <String, Object?>{
      for (final MapEntry<String, dynamic> e in map.entries) e.key.toLowerCase(): e.value,
    };
    for (final String key in keys) {
      final Object? value = lowered[key];
      final String text = _stringify(value);
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  static String _stringify(Object? value) {
    if (value == null) return '';
    if (value is String) return _cleanField(value);
    if (value is num || value is bool) return '$value';
    if (value is List) {
      // Some models emit a list of sentences for the reply.
      final String joined = value
          .map(_stringify)
          .where((String s) => s.isNotEmpty)
          .join(' ');
      return joined;
    }
    if (value is Map) {
      // `{"reply": {"target_language": "..."}}`
      for (final String nested in const <String>[
        'reply_target_language',
        'target_language',
        'text',
        'reply',
        'content',
        'value',
      ]) {
        final String inner = _stringify(value[nested]);
        if (inner.isNotEmpty) return inner;
      }
      return '';
    }
    return '';
  }

  /// Trims a decoded field and turns the usual "null-ish" placeholders into an
  /// empty string, so `hasCorrection` never lights up for `"none"`.
  static String _cleanField(String value) {
    String text = value.replaceAll(RegExp(r'\\n|\\r|\\t'), ' ').trim();
    text = text.replaceAll(RegExp(r'^["\u201C\u201D]|["\u201C\u201D]$'), '').trim();
    final String lowered = text.toLowerCase();
    if (lowered == 'null' ||
        lowered == 'none' ||
        lowered == 'n/a' ||
        lowered == 'na' ||
        lowered == 'nothing' ||
        lowered == 'no correction' ||
        lowered == '-' ||
        lowered == 'none needed') {
      return '';
    }
    // A correction identical to a "*no mistake*" style filler is not a correction.
    if (lowered == 'no correction needed' || lowered == 'correct as is') {
      return '';
    }
    return text.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  }

  /// Reads a score, normalising the two conventions models use: 0–10 and 0–100.
  static int? _readScore(Map<String, dynamic> map, List<String> keys) {
    for (final String key in keys) {
      final Object? value = map[key] ?? map[key.toLowerCase()];
      if (value == null) continue;
      double? raw;
      if (value is num) {
        raw = value.toDouble();
      } else if (value is String) {
        final RegExpMatch? match = RegExp(r'-?\d+(?:[.,]\d+)?').firstMatch(value);
        if (match == null) continue;
        raw = double.tryParse(match.group(0)!.replaceAll(',', '.'));
      }
      if (raw == null) continue;
      return _normaliseScore(raw);
    }
    return null;
  }

  /// 0–10 scales become 0–100; anything outside 0–100 is clamped; silly values
  /// (a 1000 "score") are rejected rather than clamped to 100, because a bogus
  /// 100% would read as flattery.
  static int? _normaliseScore(double raw) {
    if (raw.isNaN || raw.isInfinite) return null;
    if (raw < 0) return null;
    double score = raw;
    if (score <= 10) score *= 10;
    if (score < 5) return null;
    if (score > 100) return null;
    return score.round().clamp(0, 100);
  }

  // ── Regex field recovery ──────────────────────────────────────────────────

  /// Last-resort recovery: pull the fields out one by one without any JSON
  /// parser. This is what saves a turn when the model rambles, wraps its JSON in
  /// prose, or gets cut off mid-object by the token limit.
  static AiResponse _regexRecover(
    String text, {
    Duration? latency,
    int? tokensPredicted,
    String? rawModelOutput,
    String? fallbackTranslation,
  }) {
    String read(List<String> keys, {bool allowUnterminated = false}) {
      for (final String key in keys) {
        final String pattern = allowUnterminated
            ? '"?\\b${RegExp.escape(key)}\\b"?\\s*[:=\\-]\\s*"?([^"\\n{}]*)"?'
            : '"?\\b${RegExp.escape(key)}\\b"?\\s*[:=\\-]\\s*"((?:[^"\\\\]|\\\\.)*)"';
        final RegExpMatch? match = RegExp(
          pattern,
          caseSensitive: false,
          dotAll: true,
        ).firstMatch(text);
        if (match != null) {
          final String raw = match.group(1) ?? '';
          final String value = raw
              .replaceAll(r'\n', ' ')
              .replaceAll(r'\"', '"')
              .replaceAll(r'\\', r'\')
              .trim();
          if (value.isNotEmpty) return value;
        }
      }
      return '';
    }

    final String reply = read(const <String>[
      'reply_target_language',
      'reply_in_target_language',
      'reply_target',
      'target_reply',
      'reply',
      'response',
      'answer',
      'ai_reply',
      'tutor_reply',
      'sentence',
    ]);

    final String unterminatedReply = reply.isEmpty
        ? read(
            const <String>['reply_target_language', 'reply', 'response', 'answer'],
            allowUnterminated: true,
          )
        : reply;

    final String translation = read(const <String>[
      'reply_translation',
      'translation',
      'native_translation',
      'english_translation',
    ]);

    final String romanization = read(const <String>[
      'reply_romanization',
      'romanization',
      'romanized',
      'transliteration',
      'pronunciation',
    ]);

    final String correction = read(const <String>[
      'grammar_correction',
      'corrected_sentence',
      'correction',
      'grammar_fix',
      'grammar',
    ]);

    final String explanation = read(const <String>[
      'explanation',
      'grammar_explanation',
      'reason',
      'note',
      'feedback',
    ]);

    final String keyPhrase = read(const <String>['key_phrase', 'useful_phrase', 'phrase']);
    final String keyPhraseTranslation =
        read(const <String>['key_phrase_translation', 'useful_phrase_translation']);

    final String scoreText = read(const <String>['fluency_score', 'fluency', 'score']);
    int? score;
    if (scoreText.isNotEmpty) {
      final RegExpMatch? numeric = RegExp(r'-?\d+(?:[.,]\d+)?').firstMatch(scoreText);
      if (numeric != null) {
        score = _normaliseScore(
          double.tryParse(numeric.group(0)!.replaceAll(',', '.')) ?? 0,
        );
      }
    }

    // If the recovery produced nothing at all, salvage the most sentence-like
    // line of the raw output — better to speak something plausible than nothing.
    String sentence = _cleanField(unterminatedReply);
    if (sentence.isEmpty) {
      sentence = _salvageSentence(text);
    }

    return AiResponse(
      replyTargetLanguage: sentence,
      replyTranslation: _cleanField(translation).isNotEmpty
          ? _cleanField(translation)
          : (fallbackTranslation ?? ''),
      replyRomanization: _cleanField(romanization).isEmpty
          ? null
          : _cleanField(romanization),
      grammarCorrection: _cleanField(correction).isEmpty ? null : _cleanField(correction),
      explanation: _cleanField(explanation).isEmpty ? null : _cleanField(explanation),
      fluencyScore: score,
      keyPhrase: _cleanField(keyPhrase).isEmpty ? null : _cleanField(keyPhrase),
      keyPhraseTranslation: _cleanField(keyPhraseTranslation).isEmpty
          ? null
          : _cleanField(keyPhraseTranslation),
      mode: AiParseMode.regexRecovered,
      latency: latency,
      tokensPredicted: tokensPredicted,
      rawModelOutput: rawModelOutput,
    );
  }

  /// Picks the most sensible line out of unparseable output: the longest line
  /// that is not obviously metadata, a code fence or a JSON fragment.
  static String _salvageSentence(String text) {
    final List<String> lines = text
        .split(RegExp(r'[\n\r]+'))
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList();

    String best = '';
    for (final String line in lines) {
      final String candidate = line
          .replaceAll(RegExp(r'^[`*_>#\-\s]+'), '')
          .replaceAll(RegExp(r'[`*_]+$'), '')
          .trim();
      if (candidate.isEmpty) continue;
      if (candidate.startsWith('{') || candidate.startsWith('```')) continue;
      if (RegExp(r'^"?[a-z_]+"?\s*[:=]', caseSensitive: false).hasMatch(candidate)) {
        // Still a key/value line — strip the key and keep the value.
        final int colon = candidate.indexOf(RegExp(r'[:=]'));
        final String value = candidate.substring(colon + 1).replaceAll('"', '').trim();
        if (value.length > best.length) best = value;
        continue;
      }
      if (candidate.length > best.length) best = candidate;
    }
    return sanitizeForSpeech(best);
  }

  // ── Structural helpers ────────────────────────────────────────────────────

  /// Returns the first balanced `{...}` block in [text], or (if the object was
  /// truncated) everything from the first `{` to the end so the repair pass can
  /// try to close it.
  static String? _extractJsonObject(String text) {
    final int start = text.indexOf('{');
    if (start == -1) return null;

    int depth = 0;
    bool inString = false;
    bool escaped = false;

    for (int i = start; i < text.length; i++) {
      final String ch = text[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch == r'\') {
        escaped = true;
        continue;
      }
      if (ch == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }

    // Unterminated object (token limit reached mid-JSON).
    return text.substring(start);
  }

  /// Mechanically fixes the JSON mistakes small models actually make.
  ///
  /// Every transformation here was observed from Qwen2.5-1.5B-Instruct and
  /// Gemma-2-2B-It completions at temperature 0.6–0.7:
  /// smart quotes, `None`/`True`/`False`, unquoted keys, single-quoted strings,
  /// trailing commas, raw control characters inside strings, a JSON fragment
  /// padded with prose, and `"fluency_score": 8/10`.
  static String repairJson(String input) {
    String text = input.trim();

    // 1. Unicode punctuation → ASCII equivalents inside the document.
    text = text
        .replaceAll('\u201C', '"')
        .replaceAll('\u201D', '"')
        .replaceAll('\u2018', "'")
        .replaceAll('\u2019', "'")
        .replaceAll('\u00AB', '"')
        .replaceAll('\u00BB', '"')
        .replaceAll('\uFF02', '"')
        .replaceAll('\u2026', '...')
        .replaceAll('\u00A0', ' ');

    // 2. Python / JavaScript literals.
    text = text
        .replaceAll(RegExp(r'\bNone\b'), 'null')
        .replaceAll(RegExp(r'\bTrue\b'), 'true')
        .replaceAll(RegExp(r'\bFalse\b'), 'false')
        .replaceAll(RegExp(r'\bNaN\b'), 'null')
        .replaceAll(RegExp(r'\b-?Infinity\b'), 'null')
        .replaceAll(RegExp(r'\bundefined\b'), 'null');

    // 3. Trailing commas before a closing brace/bracket.
    text = text.replaceAll(RegExp(r',\s*([}\]])'), r'$1');

    // 4. Unquoted keys: { reply: "...", grammar_correction: null }
    text = text.replaceAllMapped(
      RegExp(r'([{,]\s*)([A-Za-z_][A-Za-z0-9_\- ]*)(\s*:)'),
      (Match m) => '${m.group(1)}"${m.group(2)!.trim()}"${m.group(3)}',
    );

    // 5. Single-quoted keys/strings → double-quoted (escape inner quotes).
    text = _normaliseSingleQuotes(text);

    // 6. Raw newlines/tabs inside string literals.
    text = _escapeRawControlChars(text);

    // 7. "fluency_score": 8/10 → 80
    text = text.replaceAllMapped(
      RegExp(r'("?\b(?:fluency_score|fluency|score)\b"?\s*:\s*)(\d+(?:\.\d+)?)\s*/\s*10'),
      (Match m) => '${m.group(1)}${(double.parse(m.group(2)!) * 10).round()}',
    );

    // 8. A leading/trailing prose wrapper ("Here is the JSON: {...} Done.").
    final int firstBrace = text.indexOf('{');
    final int lastBrace = text.lastIndexOf('}');
    if (firstBrace != -1 && lastBrace > firstBrace) {
      text = text.substring(firstBrace, lastBrace + 1);
    }

    return text.trim();
  }

  /// Converts `'value'` literals to `"value"` without touching apostrophes
  /// *inside* already double-quoted strings.
  static String _normaliseSingleQuotes(String input) {
    final StringBuffer out = StringBuffer();
    bool inDouble = false;
    bool inSingle = false;
    bool escaped = false;

    for (int i = 0; i < input.length; i++) {
      final String ch = input[i];
      if (escaped) {
        out.write(ch);
        escaped = false;
        continue;
      }
      if (ch == r'\') {
        out.write(ch);
        escaped = true;
        continue;
      }
      if (ch == '"' && !inSingle) {
        inDouble = !inDouble;
        out.write(ch);
        continue;
      }
      if (ch == "'" && !inDouble) {
        // Only treat as a quote when it looks like a delimiter: preceded by
        // `{`, `,`, `[`, `:` or whitespace, or followed by one of those.
        final String prev = i == 0 ? '' : input[i - 1];
        final String next = i + 1 >= input.length ? '' : input[i + 1];
        final bool delimiting = inSingle ||
            RegExp(r'[{,:\s\[]').hasMatch(prev) ||
            RegExp(r'[}\],:\s]').hasMatch(next) ||
            RegExp(r'[A-Za-z0-9\u00C0-\uFFFF]').hasMatch(next);
        if (delimiting) {
          inSingle = !inSingle;
          out.write('"');
          continue;
        }
        out.write(ch);
        continue;
      }
      if (ch == '"' && inSingle) {
        // A double quote inside a single-quoted string must be escaped.
        out.write(r'\"');
        continue;
      }
      out.write(ch);
    }
    return out.toString();
  }

  /// Replaces raw newlines, carriage returns and tabs *inside* strings with
  /// their escape sequences — `jsonDecode` rejects literal control characters.
  static String _escapeRawControlChars(String input) {
    final StringBuffer out = StringBuffer();
    bool inString = false;
    bool escaped = false;

    for (int i = 0; i < input.length; i++) {
      final String ch = input[i];
      if (escaped) {
        out.write(ch);
        escaped = false;
        continue;
      }
      if (ch == r'\') {
        out.write(ch);
        escaped = true;
        continue;
      }
      if (ch == '"') {
        inString = !inString;
        out.write(ch);
        continue;
      }
      if (inString) {
        switch (ch.codeUnitAt(0)) {
          case 0x0A:
            out.write(r'\n');
            continue;
          case 0x0D:
            out.write(r'\r');
            continue;
          case 0x09:
            out.write(r'\t');
            continue;
        }
        // Strip any other raw control character (model hallucination).
        if (ch.codeUnitAt(0) < 0x20) continue;
      }
      out.write(ch);
    }
    return out.toString();
  }

  /// Closes a JSON object that the token limit cut in half:
  /// unterminated string → add `"`, missing braces → add `}`.
  static String _closeUnterminated(String input) {
    String text = input.trimRight();

    // Count unescaped double quotes to detect an open string.
    bool inString = false;
    bool escaped = false;
    int openBraces = 0;
    for (int i = 0; i < text.length; i++) {
      final String ch = text[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch == r'\') {
        escaped = true;
        continue;
      }
      if (ch == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (ch == '{') openBraces++;
      if (ch == '}') openBraces--;
    }

    if (inString) text = '$text"';
    // Drop a dangling key/value separator: `..."key":` → `..."key": null`
    if (RegExp(r':\s*$').hasMatch(text)) text = '$text null';
    // Drop a dangling comma.
    text = text.replaceAll(RegExp(r',\s*$'), '');
    // Close a truncated trailing string before the final brace repair.
    if (openBraces > 0) {
      // A StringBuffer, not repeated concatenation: this runs on every malformed
      // 1.5B reply and the braces can number in the dozens.
      final StringBuffer buffer = StringBuffer(text);
      for (int i = 0; i < openBraces; i++) {
        buffer.write('}');
      }
      text = buffer.toString();
    }
    return text;
  }

  /// Removes the wrappers models like to add around their JSON
  /// ("Here is the JSON you requested:").
  static String _stripWrappers(String text) {
    String out = text.trim();
    out = out.replaceAll(RegExp(r'^```[a-zA-Z]*\s*'), '');
    out = out.replaceAll(RegExp(r'```$'), '');
    out = out.replaceAll(
      RegExp(
        r'^(here (is|are)[^:\n]*:|sure[,!]?\s*|certainly[,!]?\s*|'
        r'json\s*:|response\s*:|answer\s*:)',
        caseSensitive: false,
      ),
      '',
    );
    return out.trim();
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  POST-PROCESSING
  // ══════════════════════════════════════════════════════════════════════════

  /// Cleans the response for display and speech.
  ///
  /// If [learnerText] is supplied, a "correction" that is identical to what the
  /// learner said is dropped (`correctionSeverity == 0`): small models love to
  /// echo the input when they cannot find a real mistake, and showing "✔ you
  /// said the same thing" is worse than showing nothing.
  AiResponse cleanup({String? learnerText}) {
    final String reply = sanitizeForSpeech(replyTargetLanguage);

    String? correction = grammarCorrection;
    if (correction != null && learnerText != null && learnerText.trim().isNotEmpty) {
      if (_normalise(correction) == _normalise(learnerText)) correction = null;
    }
    if (correction != null && _normalise(correction) == _normalise(reply)) {
      correction = null;
    }
    if (correction != null && correction.trim().length < 2) correction = null;

    // Read the fields first: `String? explanation = _tidy(explanation)` would
    // reference the local being declared, not the field.
    String? cleanExplanation = _tidy(explanation);
    if (cleanExplanation != null && correction == null) {
      // A correction-less explanation is usually noise, unless it is about the
      // tutor's own reply.
      if (cleanExplanation.trim().length < 6) cleanExplanation = null;
    }

    String? cleanKeyPhrase = _tidy(keyPhrase);
    if (cleanKeyPhrase != null && _normalise(cleanKeyPhrase) == _normalise(reply)) {
      // The whole sentence is not a "phrase to learn".
      cleanKeyPhrase = null;
    }

    return AiResponse(
      replyTargetLanguage: reply,
      replyTranslation: sanitizeForSpeech(replyTranslation),
      replyRomanization: replyRomanization?.trim().isEmpty ?? true
          ? null
          : replyRomanization!.trim(),
      grammarCorrection: correction?.trim(),
      explanation: cleanExplanation,
      fluencyScore: fluencyScore,
      keyPhrase: cleanKeyPhrase,
      keyPhraseTranslation: keyPhraseTranslation?.trim(),
      mode: mode,
      latency: latency,
      tokensPredicted: tokensPredicted,
      rawModelOutput: rawModelOutput,
    );
  }

  /// Drops the `"none"` / `"n/a"` placeholders models emit for optional fields.
  static String? _tidy(String? value) {
    if (value == null) return null;
    final String trimmed = value.trim();
    if (trimmed.length < 2) return null;
    final String lowered = trimmed.toLowerCase();
    if (lowered == 'null' || lowered == 'none' || lowered == 'n/a') return null;
    return trimmed;
  }

  AiResponse copyWith({
    String? replyTargetLanguage,
    String? replyTranslation,
    String? replyRomanization,
    String? grammarCorrection,
    String? explanation,
    int? fluencyScore,
    String? keyPhrase,
    String? keyPhraseTranslation,
    AiParseMode? mode,
    Duration? latency,
    int? tokensPredicted,
    String? rawModelOutput,
  }) =>
      AiResponse(
        replyTargetLanguage: replyTargetLanguage ?? this.replyTargetLanguage,
        replyTranslation: replyTranslation ?? this.replyTranslation,
        replyRomanization: replyRomanization ?? this.replyRomanization,
        grammarCorrection: grammarCorrection ?? this.grammarCorrection,
        explanation: explanation ?? this.explanation,
        fluencyScore: fluencyScore ?? this.fluencyScore,
        keyPhrase: keyPhrase ?? this.keyPhrase,
        keyPhraseTranslation: keyPhraseTranslation ?? this.keyPhraseTranslation,
        mode: mode ?? this.mode,
        latency: latency ?? this.latency,
        tokensPredicted: tokensPredicted ?? this.tokensPredicted,
        rawModelOutput: rawModelOutput ?? this.rawModelOutput,
      );

  /// What the text-to-speech engine receives. Everything that is not spoken
  /// language is stripped: markdown, emoji, bracketed stage directions, JSON
  /// braces, speaker labels and URLs.
  String get ttsText => sanitizeForSpeech(replyTargetLanguage);

  /// Prepares a string for speech output.
  static String sanitizeForSpeech(String input) {
    String text = input.trim();
    if (text.isEmpty) return '';

    text = text
        // Markdown emphasis/headings/code fences.
        .replaceAll(RegExp(r'```[a-zA-Z]*'), ' ')
        .replaceAll(RegExp(r'[*_`#>]+'), ' ')
        // Bracketed stage directions: (smiling), [laughs], 【…】
        .replaceAll(RegExp(r'\([^)]{0,40}\)'), ' ')
        .replaceAll(RegExp(r'\[[^\]]{0,40}\]'), ' ')
        .replaceAll(RegExp(r'（[^）]{0,40}）'), ' ')
        // Speaker labels at line starts: "AI:", "Tutor:", "You:".
        .replaceAll(
          RegExp(r'^\s*(ai|tutor|assistant|you|user|learner|teacher|student)\s*[:：]',
              caseSensitive: false, multiLine: true),
          ' ',
        )
        // JSON punctuation that leaked in.
        .replaceAll(RegExp(r'^\s*[{}\[\],]+\s*|\s*[{}\[\],]+\s*$'), ' ')
        .replaceAll(RegExp(r'\s*"\s*$'), ' ')
        // URLs are never read aloud.
        .replaceAll(RegExp(r'https?://\S+'), ' ')
        // HTML-ish leftovers.
        .replaceAll(RegExp(r'<[^>]{1,30}>'), ' ')
        // Ideographic/full-width spaces → normal space.
        .replaceAll(RegExp(r'[\u3000\u00A0]'), ' ')
        // Emoji & pictographs (kept out of the spoken reply, but the chat bubble
        // renders the sanitised text too, so the two always match). CJK
        // punctuation (\u3000-\u303F) is deliberately NOT in this class: 。！？
        // are sentence terminators and the TTS engine needs them for prosody.
        .replaceAll(_emojiPattern, ' ')
        // Zero-width and bidi control characters can freeze some TTS engines.
        .replaceAll(RegExp(r'[\u200B-\u200F\u202A-\u202E\uFEFF]'), '')
        // Whitespace normalisation.
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // A reply of only punctuation is not a reply.
    if (RegExp(r'^[\s.,!?;:。、！？…\-–—]*$').hasMatch(text)) return '';

    return text;
  }

  static final RegExp _emojiPattern = RegExp(
    '['
    '\u2190-\u21FF' // arrows
    '\u2300-\u27BF' // misc symbols & dingbats (⌚ ✨ ✅ …)
    '\u2B00-\u2BFF'
    '\uFE0E-\uFE0F' // variation selectors
    '\u{1F000}-\u{1FAFF}' // emoji planes (😀 🚀 …)
    '\u{1F1E6}-\u{1F1FF}' // regional indicators (flags)
    ']',
    unicode: true,
  );

  // ── Comparison helpers ────────────────────────────────────────────────────

  /// Lower-cases, strips punctuation and collapses whitespace. Used for equality
  /// checks between the learner's sentence and a "correction".
  static String _normalise(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Character-level similarity (Sørensen–Dice on bigrams). Cheap, and good
  /// enough to grade "how big was this correction".
  static double _similarity(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 1;
    if (a.length < 2 || b.length < 2) return a == b ? 1 : 0;
    final Map<String, int> bigrams = <String, int>{};
    for (int i = 0; i < a.length - 1; i++) {
      final String gram = a.substring(i, i + 2);
      bigrams[gram] = (bigrams[gram] ?? 0) + 1;
    }
    int hits = 0;
    for (int i = 0; i < b.length - 1; i++) {
      final String gram = b.substring(i, i + 2);
      final int count = bigrams[gram] ?? 0;
      if (count > 0) {
        bigrams[gram] = count - 1;
        hits++;
      }
    }
    return (2 * hits) / ((a.length - 1) + (b.length - 1));
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  Map<String, Object?> toJson() => <String, Object?>{
        'reply_target_language': replyTargetLanguage,
        'reply_translation': replyTranslation,
        'reply_romanization': replyRomanization,
        'grammar_correction': grammarCorrection,
        'explanation': explanation,
        'fluency_score': fluencyScore,
        'key_phrase': keyPhrase,
        'key_phrase_translation': keyPhraseTranslation,
        'parse_mode': mode.name,
        'latency_ms': latency?.inMilliseconds,
        'tokens_predicted': tokensPredicted,
      };

  static AiResponse fromJson(Map<String, Object?> json) {
    final String rawMode = (json['parse_mode'] as String?) ?? AiParseMode.strictJson.name;
    final AiParseMode mode = AiParseMode.values.firstWhere(
      (AiParseMode m) => m.name == rawMode,
      orElse: () => AiParseMode.strictJson,
    );
    return AiResponse(
      replyTargetLanguage: (json['reply_target_language'] as String?) ?? '',
      replyTranslation: (json['reply_translation'] as String?) ?? '',
      replyRomanization: json['reply_romanization'] as String?,
      grammarCorrection: json['grammar_correction'] as String?,
      explanation: json['explanation'] as String?,
      fluencyScore: json['fluency_score'] as int?,
      keyPhrase: json['key_phrase'] as String?,
      keyPhraseTranslation: json['key_phrase_translation'] as String?,
      mode: mode,
      latency: json['latency_ms'] == null
          ? null
          : Duration(milliseconds: json['latency_ms']! as int),
      tokensPredicted: json['tokens_predicted'] as int?,
    );
  }

  @override
  String toString() =>
      'AiResponse(${mode.name}, ${replyTargetLanguage.length} chars, '
      'score=$fluencyScore)';
}

/// Test hook: exposes the normalisation used when comparing a "correction"
/// against the learner's original sentence.
@visibleForTesting
String normaliseForComparison(String value) => AiResponse._normalise(value);
