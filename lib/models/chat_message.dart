import 'package:flutter/foundation.dart';

import 'package:k100/models/ai_response.dart';

/// Who produced a message. Stored in SQLite as the enum name, so the column is
/// readable in a DB browser and stable across refactors.
enum MessageRole {
  user('user'),
  tutor('tutor'),
  system('system');

  const MessageRole(this.wireName);

  final String wireName;

  static MessageRole fromWire(String? value) {
    switch (value) {
      case 'tutor':
      case 'assistant':
        return MessageRole.tutor;
      case 'system':
        return MessageRole.system;
      default:
        return MessageRole.user;
    }
  }
}

/// A single line of a conversation, with the grammar feedback the tutor attached
/// to it.
///
/// The feedback fields are duplicated from [AiResponse] on purpose: the chat
/// screen must be able to render history without re-parsing JSON, and the
/// vocabulary miner needs the raw correction text even if the JSON repair logic
/// changes in a future release.
@immutable
class ChatMessage {
  const ChatMessage({
    this.id,
    this.sessionId,
    required this.role,
    required this.text,
    this.translation,
    this.romanization,
    this.correction,
    this.explanation,
    this.score,
    this.keyPhrase,
    this.keyPhraseTranslation,
    this.parseMode,
    this.latencyMs,
    this.tokensPredicted,
    this.recoveredFromMalformedJson = false,
    required this.createdAt,
  });

  /// SQLite rowid; null until the row has been inserted.
  final int? id;

  /// Owning session rowid.
  final int? sessionId;

  final MessageRole role;

  /// The sentence itself: for the learner's turns the *raw transcript*, for the
  /// tutor's turns the `reply_target_language` value (exactly what TTS spoke).
  final String text;

  /// Native-language translation. Present on tutor turns, and on user turns when
  /// the model echoed the learner's sentence back with a translation.
  final String? translation;

  /// Romanisation for non-Latin target languages (Korean, Japanese, Chinese…).
  final String? romanization;

  /// Corrected version of the learner's sentence (user turns only).
  final String? correction;

  /// One-line explanation of the correction (user turns only).
  final String? explanation;

  /// 0–100 fluency score (user turns only).
  final int? score;

  /// The phrase this turn contributed to the vocabulary bank.
  final String? keyPhrase;
  final String? keyPhraseTranslation;

  /// How the JSON was decoded — surfaced as a subtle "repaired" badge.
  final AiParseMode? parseMode;

  final int? latencyMs;
  final int? tokensPredicted;

  final bool recoveredFromMalformedJson;

  final DateTime createdAt;

  bool get isUser => role == MessageRole.user;

  bool get isTutor => role == MessageRole.tutor;

  bool get hasCorrection => (correction ?? '').trim().isNotEmpty;

  bool get hasExplanation => (explanation ?? '').trim().isNotEmpty;

  bool get hasFeedback => hasCorrection || hasExplanation || score != null;

  /// True when the tutor's JSON had to be repaired or regex-recovered.
  bool get isDegraded => recoveredFromMalformedJson || (parseMode?.isDegraded ?? false);

  Duration? get latency => latencyMs == null ? null : Duration(milliseconds: latencyMs!);

  // ── Construction helpers ──────────────────────────────────────────────────

  /// Builds the learner's turn from a raw transcript string.
  factory ChatMessage.fromUserTranscript({
    required String transcript,
    int? sessionId,
    DateTime? at,
  }) =>
      ChatMessage(
        sessionId: sessionId,
        role: MessageRole.user,
        text: transcript.trim(),
        createdAt: at ?? DateTime.now(),
      );

  /// Builds the tutor's turn from a parsed [AiResponse]. Only
  /// `replyTargetLanguage` becomes [text] — that is the invariant that keeps
  /// TTS and the transcript in sync.
  factory ChatMessage.fromAiResponse({
    required AiResponse response,
    int? sessionId,
    DateTime? at,
  }) =>
      ChatMessage(
        sessionId: sessionId,
        role: MessageRole.tutor,
        text: response.replyTargetLanguage,
        translation: response.replyTranslation,
        romanization: response.replyRomanization,
        keyPhrase: response.keyPhrase,
        keyPhraseTranslation: response.keyPhraseTranslation,
        parseMode: response.parseMode,
        latencyMs: response.latency?.inMilliseconds,
        tokensPredicted: response.tokensPredicted,
        recoveredFromMalformedJson: response.mode.isDegraded,
        createdAt: at ?? DateTime.now(),
      );

  ChatMessage copyWith({
    int? id,
    int? sessionId,
    MessageRole? role,
    String? text,
    String? translation,
    String? romanization,
    String? correction,
    String? explanation,
    int? score,
    String? keyPhrase,
    String? keyPhraseTranslation,
    AiParseMode? parseMode,
    int? latencyMs,
    int? tokensPredicted,
    bool? recoveredFromMalformedJson,
    DateTime? createdAt,
  }) =>
      ChatMessage(
        id: id ?? this.id,
        sessionId: sessionId ?? this.sessionId,
        role: role ?? this.role,
        text: text ?? this.text,
        translation: translation ?? this.translation,
        romanization: romanization ?? this.romanization,
        correction: correction ?? this.correction,
        explanation: explanation ?? this.explanation,
        score: score ?? this.score,
        keyPhrase: keyPhrase ?? this.keyPhrase,
        keyPhraseTranslation: keyPhraseTranslation ?? this.keyPhraseTranslation,
        parseMode: parseMode ?? this.parseMode,
        latencyMs: latencyMs ?? this.latencyMs,
        tokensPredicted: tokensPredicted ?? this.tokensPredicted,
        recoveredFromMalformedJson:
            recoveredFromMalformedJson ?? this.recoveredFromMalformedJson,
        createdAt: createdAt ?? this.createdAt,
      );

  /// Copies the feedback columns onto a learner message. Used after a response
  /// arrives: the transcript is written first (so it shows up instantly), the
  /// correction is attached when the model answers.
  ChatMessage withFeedback(AiResponse response) => ChatMessage(
        id: id,
        sessionId: sessionId,
        role: role,
        text: text,
        translation: translation,
        romanization: romanization,
        correction: response.grammarCorrection,
        explanation: response.explanation,
        score: response.fluencyScore,
        keyPhrase: keyPhrase,
        keyPhraseTranslation: keyPhraseTranslation,
        parseMode: response.parseMode,
        latencyMs: response.latency?.inMilliseconds ?? latencyMs,
        tokensPredicted: response.tokensPredicted ?? tokensPredicted,
        recoveredFromMalformedJson: response.mode.isDegraded,
        createdAt: createdAt,
      );

  // ── SQLite mapping ────────────────────────────────────────────────────────

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'session_id': sessionId,
        'role': role.wireName,
        'text': text,
        'translation': translation,
        'romanization': romanization,
        'correction': correction,
        'explanation': explanation,
        'score': score,
        'key_phrase': keyPhrase,
        'key_phrase_translation': keyPhraseTranslation,
        'parse_mode': parseMode?.name,
        'latency_ms': latencyMs,
        'tokens_predicted': tokensPredicted,
        'degraded': recoveredFromMalformedJson ? 1 : 0,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  static ChatMessage fromMap(Map<String, Object?> row) {
    final String? rawParseMode = row['parse_mode'] as String?;
    return ChatMessage(
      id: row['id'] as int?,
      sessionId: row['session_id'] as int?,
      role: MessageRole.fromWire(row['role'] as String?),
      text: (row['text'] as String?) ?? '',
      translation: row['translation'] as String?,
      romanization: row['romanization'] as String?,
      correction: row['correction'] as String?,
      explanation: row['explanation'] as String?,
      score: row['score'] as int?,
      keyPhrase: row['key_phrase'] as String?,
      keyPhraseTranslation: row['key_phrase_translation'] as String?,
      parseMode: rawParseMode == null
          ? null
          : AiParseMode.values.firstWhere(
              (AiParseMode mode) => mode.name == rawParseMode,
              orElse: () => AiParseMode.rawText,
            ),
      latencyMs: row['latency_ms'] as int?,
      tokensPredicted: row['tokens_predicted'] as int?,
      recoveredFromMalformedJson: (row['degraded'] as int? ?? 0) == 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (row['created_at'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'role': role.wireName,
        'text': text,
        'translation': translation,
        'romanization': romanization,
        'correction': correction,
        'explanation': explanation,
        'score': score,
        'parse_mode': parseMode?.name,
        'created_at': createdAt.toIso8601String(),
      };

  @override
  String toString() => 'ChatMessage(${role.wireName}, ${text.length} chars)';
}

/// A practice session row plus the aggregates the history list needs.
@immutable
class PracticeSession {
  const PracticeSession({
    this.id,
    required this.scenarioId,
    required this.scenarioTitle,
    required this.targetLanguageCode,
    required this.nativeLanguageCode,
    required this.levelName,
    required this.startedAt,
    this.endedAt,
    this.messageCount = 0,
    this.avgScore = 0,
    this.secondsSpent = 0,
  });

  final int? id;
  final String scenarioId;
  final String scenarioTitle;
  final String targetLanguageCode;
  final String nativeLanguageCode;
  final String levelName;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int messageCount;
  final double avgScore;
  final int secondsSpent;

  Duration get duration => (endedAt ?? DateTime.now()).difference(startedAt);

  String get durationLabel {
    final int minutes = duration.inMinutes;
    if (minutes < 1) return 'under a minute';
    if (minutes == 1) return '1 minute';
    if (minutes < 60) return '$minutes minutes';
    final int hours = minutes ~/ 60;
    return hours == 1 ? '1 hour' : '$hours hours';
  }

  int get minutesSpent => duration.inMinutes;

  PracticeSession copyWith({
    int? id,
    DateTime? endedAt,
    int? messageCount,
    double? avgScore,
    int? secondsSpent,
  }) =>
      PracticeSession(
        id: id ?? this.id,
        scenarioId: scenarioId,
        scenarioTitle: scenarioTitle,
        targetLanguageCode: targetLanguageCode,
        nativeLanguageCode: nativeLanguageCode,
        levelName: levelName,
        startedAt: startedAt,
        endedAt: endedAt ?? this.endedAt,
        messageCount: messageCount ?? this.messageCount,
        avgScore: avgScore ?? this.avgScore,
        secondsSpent: secondsSpent ?? this.secondsSpent,
      );

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'scenario_id': scenarioId,
        'scenario_title': scenarioTitle,
        'target_lang': targetLanguageCode,
        'native_lang': nativeLanguageCode,
        'level': levelName,
        'started_at': startedAt.millisecondsSinceEpoch,
        'ended_at': endedAt?.millisecondsSinceEpoch,
        'message_count': messageCount,
        'avg_score': avgScore,
        'seconds_spent': secondsSpent,
      };

  static PracticeSession fromMap(Map<String, Object?> row) => PracticeSession(
        id: row['id'] as int?,
        scenarioId: (row['scenario_id'] as String?) ?? 'free_talk',
        scenarioTitle: (row['scenario_title'] as String?) ?? 'Free Talk',
        targetLanguageCode: (row['target_lang'] as String?) ?? 'en',
        nativeLanguageCode: (row['native_lang'] as String?) ?? 'en',
        levelName: (row['level'] as String?) ?? 'beginner',
        startedAt: DateTime.fromMillisecondsSinceEpoch(
          (row['started_at'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
        ),
        endedAt: row['ended_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['ended_at']! as int),
        messageCount: (row['message_count'] as int?) ?? 0,
        avgScore: ((row['avg_score'] as num?) ?? 0).toDouble(),
        secondsSpent: (row['seconds_spent'] as int?) ?? 0,
      );
}

/// One day of aggregated practice. Feeds the weekly chart on the home screen.
@immutable
class DailyProgress {
  const DailyProgress({
    this.id,
    required this.day,
    this.messages = 0,
    this.minutes = 0,
    this.avgScore = 0,
    this.newWords = 0,
  });

  final int? id;

  /// `yyyy-MM-dd` in local time — sortable as a string, which keeps the SQL
  /// trivial.
  final String day;

  final int messages;
  final int minutes;
  final double avgScore;
  final int newWords;

  bool get hasActivity => messages > 0 || minutes > 0;

  DateTime? get asDate => DateTime.tryParse(day);

  String get weekdayShort {
    final DateTime? date = asDate;
    if (date == null) return '';
    const List<String> names = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return names[date.weekday - 1];
  }

  double get goalFraction(int goalMinutes) {
    if (goalMinutes <= 0) return 0;
    return (minutes / goalMinutes).clamp(0.0, 1.0);
  }

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'day': day,
        'messages': messages,
        'minutes': minutes,
        'avg_score': avgScore,
        'new_words': newWords,
      };

  static DailyProgress fromMap(Map<String, Object?> row) => DailyProgress(
        id: row['id'] as int?,
        day: (row['day'] as String?) ?? '',
        messages: (row['messages'] as int?) ?? 0,
        minutes: (row['minutes'] as int?) ?? 0,
        avgScore: ((row['avg_score'] as num?) ?? 0).toDouble(),
        newWords: (row['new_words'] as int?) ?? 0,
      );
}

/// A mined vocabulary item with a tiny spaced-repetition schedule.
@immutable
class VocabularyItem {
  const VocabularyItem({
    this.id,
    required this.term,
    required this.targetLanguageCode,
    this.translation,
    this.example,
    this.sourceScenarioId,
    this.strength = 0,
    this.timesReviewed = 0,
    this.timesCorrect = 0,
    required this.createdAt,
    this.lastReviewedAt,
    this.dueAt,
  });

  final int? id;
  final String term;
  final String targetLanguageCode;
  final String? translation;

  /// The sentence the term appeared in — context is what makes recall work.
  final String? example;

  final String? sourceScenarioId;

  /// 0–5. Grows with each correct recall; drives the dot meter in the UI.
  final int strength;

  final int timesReviewed;
  final int timesCorrect;

  final DateTime createdAt;
  final DateTime? lastReviewedAt;

  /// When the item should next be shown. Null means "brand new, review now".
  final DateTime? dueAt;

  bool get isDue {
    final DateTime? due = dueAt;
    if (due == null) return true;
    return !due.isAfter(DateTime.now());
  }

  double get accuracy => timesReviewed == 0 ? 0 : timesCorrect / timesReviewed;

  VocabularyItem copyWith({
    int? id,
    String? term,
    String? translation,
    String? example,
    int? strength,
    int? timesReviewed,
    int? timesCorrect,
    DateTime? lastReviewedAt,
    DateTime? dueAt,
  }) =>
      VocabularyItem(
        id: id ?? this.id,
        term: term ?? this.term,
        targetLanguageCode: targetLanguageCode,
        translation: translation ?? this.translation,
        example: example ?? this.example,
        sourceScenarioId: sourceScenarioId,
        strength: strength ?? this.strength,
        timesReviewed: timesReviewed ?? this.timesReviewed,
        timesCorrect: timesCorrect ?? this.timesCorrect,
        createdAt: createdAt,
        lastReviewedAt: lastReviewedAt ?? this.lastReviewedAt,
        dueAt: dueAt ?? this.dueAt,
      );

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'term': term,
        'target_lang': targetLanguageCode,
        'translation': translation,
        'example': example,
        'source_scenario_id': sourceScenarioId,
        'strength': strength,
        'times_reviewed': timesReviewed,
        'times_correct': timesCorrect,
        'created_at': createdAt.millisecondsSinceEpoch,
        'last_reviewed_at': lastReviewedAt?.millisecondsSinceEpoch,
        'due_at': dueAt?.millisecondsSinceEpoch,
      };

  static VocabularyItem fromMap(Map<String, Object?> row) => VocabularyItem(
        id: row['id'] as int?,
        term: (row['term'] as String?) ?? '',
        targetLanguageCode: (row['target_lang'] as String?) ?? 'en',
        translation: row['translation'] as String?,
        example: row['example'] as String?,
        sourceScenarioId: row['source_scenario_id'] as String?,
        strength: (row['strength'] as int?) ?? 0,
        timesReviewed: (row['times_reviewed'] as int?) ?? 0,
        timesCorrect: (row['times_correct'] as int?) ?? 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (row['created_at'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
        ),
        lastReviewedAt: row['last_reviewed_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['last_reviewed_at']! as int),
        dueAt: row['due_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['due_at']! as int),
      );

  /// Leitner-style interval: 0 → 10 min, 1 → 1 day, 2 → 3 days, 3 → 7 days,
  /// 4 → 14 days, 5 → 30 days.
  static Duration intervalFor(int strength) {
    switch (strength.clamp(0, 5)) {
      case 0:
        return const Duration(minutes: 10);
      case 1:
        return const Duration(days: 1);
      case 2:
        return const Duration(days: 3);
      case 3:
        return const Duration(days: 7);
      case 4:
        return const Duration(days: 14);
      default:
        return const Duration(days: 30);
    }
  }
}
