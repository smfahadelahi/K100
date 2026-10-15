import 'package:flutter/material.dart';

/// Writing system a language uses. Drives romanisation support and a few
/// typographic choices (line height, font fallbacks, whether the grammar card
/// shows a transliteration row).
enum LanguageScript {
  latin('Latin'),
  cyrillic('Cyrillic'),
  arabic('Arabic'),
  devanagari('Devanagari'),
  han('Han'),
  kana('Kana'),
  hangul('Hangul'),
  thai('Thai');

  const LanguageScript(this.label);

  final String label;

  /// True when a learner cannot sound the text out without reading romanisation
  /// (CJK, Arabic, Devanagari, Cyrillic, Thai).
  bool get needsRomanization => this != LanguageScript.latin;
}

/// A language the tutor can teach (target) or explain in (native).
///
/// [sttLocale] and [ttsLocale] are *defaults*: the real locale ids are resolved
/// at runtime from the device (`SpeechToText.locales()` and
/// `FlutterTts.getLanguages`), because Android ships wildly different locale
/// sets per OEM. These values are the sensible first guess.
@immutable
class AppLanguage {
  const AppLanguage({
    required this.code,
    required this.englishName,
    required this.nativeName,
    required this.flag,
    required this.script,
    required this.sttLocale,
    required this.ttsLocale,
    required this.grammarFocusPoints,
    this.rtl = false,
  });

  /// ISO-639-1 code (`en`, `ko`, …). Used as the DB key and in prefs.
  final String code;

  /// Name shown to an English-speaking user: "Korean".
  final String englishName;

  /// Endonym: "한국어". Shown next to the English name in pickers.
  final String nativeName;

  /// Emoji flag. Cheap, universally available, and instantly scannable.
  final String flag;

  final LanguageScript script;

  /// `speech_to_text` locale id, e.g. `ko_KR`.
  final String sttLocale;

  /// BCP-47 tag for `flutter_tts`, e.g. `ko-KR`.
  final String ttsLocale;

  /// Right-to-left scripts (Arabic) need `Directionality` overrides in bubbles.
  final bool rtl;

  /// The three-to-five structures learners of this language most often get
  /// wrong. Injected into the system prompt when grammar focus is enabled so the
  /// model corrects those *first* instead of nitpicking word order.
  final List<String> grammarFocusPoints;

  bool get needsRomanization => script.needsRomanization;

  /// Two-letter, uppercase, for compact chips ("KR" style labels).
  String get shortCode => code.toUpperCase();

  String get displayName => '$flag  $englishName';

  String get fullName => '$englishName · $nativeName';

  /// The locale family (`ko`) of a concrete device locale (`ko_KR`).
  static String familyOf(String locale) {
    final String normalised = locale.replaceAll('_', '-');
    final int dash = normalised.indexOf('-');
    return (dash == -1 ? normalised : normalised.substring(0, dash)).toLowerCase();
  }

  @override
  bool operator ==(Object other) =>
      other is AppLanguage && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'AppLanguage($code)';
}

/// The language catalogue.
///
/// Sixteen languages is a deliberate ceiling: each entry is a promise that STT
/// and TTS actually work, so every one of them is a language Android ships
/// recognisers and voices for in the default Google packages.
class Languages {
  Languages._();

  // ── The catalogue ─────────────────────────────────────────────────────────

  static const AppLanguage english = AppLanguage(
    code: 'en',
    englishName: 'English',
    nativeName: 'English',
    flag: '🇬🇧',
    script: LanguageScript.latin,
    sttLocale: 'en_US',
    ttsLocale: 'en-US',
    grammarFocusPoints: <String>[
      'articles (a / an / the)',
      'present perfect vs. past simple',
      'third-person -s agreement',
      'prepositions of time (in / on / at)',
    ],
  );

  static const AppLanguage spanish = AppLanguage(
    code: 'es',
    englishName: 'Spanish',
    nativeName: 'Español',
    flag: '🇪🇸',
    script: LanguageScript.latin,
    sttLocale: 'es_ES',
    ttsLocale: 'es-ES',
    grammarFocusPoints: <String>[
      'ser vs. estar',
      'gender and number agreement',
      'preterite vs. imperfect',
      'subjunctive after "que"',
    ],
  );

  static const AppLanguage french = AppLanguage(
    code: 'fr',
    englishName: 'French',
    nativeName: 'Français',
    flag: '🇫🇷',
    script: LanguageScript.latin,
    sttLocale: 'fr_FR',
    ttsLocale: 'fr-FR',
    grammarFocusPoints: <String>[
      'passé composé vs. imparfait',
      'noun gender and articles (le / la / les)',
      'liaison and elision (l’ami, j’ai)',
      'subjunctive after "il faut que"',
    ],
  );

  static const AppLanguage german = AppLanguage(
    code: 'de',
    englishName: 'German',
    nativeName: 'Deutsch',
    flag: '🇩🇪',
    script: LanguageScript.latin,
    sttLocale: 'de_DE',
    ttsLocale: 'de-DE',
    grammarFocusPoints: <String>[
      'verb-second word order',
      'cases (Nominativ / Akkusativ / Dativ)',
      'separable verbs (aufstehen → ich stehe auf)',
      'subordinate clauses sending the verb to the end',
    ],
  );

  static const AppLanguage italian = AppLanguage(
    code: 'it',
    englishName: 'Italian',
    nativeName: 'Italiano',
    flag: '🇮🇹',
    script: LanguageScript.latin,
    sttLocale: 'it_IT',
    ttsLocale: 'it-IT',
    grammarFocusPoints: <String>[
      'passato prossimo with essere vs. avere',
      'articulated prepositions (nel, sul, dal)',
      'noun–adjective agreement',
      'double negatives',
    ],
  );

  static const AppLanguage portuguese = AppLanguage(
    code: 'pt',
    englishName: 'Portuguese',
    nativeName: 'Português',
    flag: '🇧🇷',
    script: LanguageScript.latin,
    sttLocale: 'pt_BR',
    ttsLocale: 'pt-BR',
    grammarFocusPoints: <String>[
      'ser vs. estar vs. ficar',
      'personal infinitive',
      'future subjunctive',
      'noun gender and articles',
    ],
  );

  static const AppLanguage russian = AppLanguage(
    code: 'ru',
    englishName: 'Russian',
    nativeName: 'Русский',
    flag: '🇷🇺',
    script: LanguageScript.cyrillic,
    sttLocale: 'ru_RU',
    ttsLocale: 'ru-RU',
    grammarFocusPoints: <String>[
      'cases (падежи) and their endings',
      'verb aspect (совершенный / несовершенный)',
      'verbs of motion with prefixes',
      'gendered past tense',
    ],
  );

  static const AppLanguage arabic = AppLanguage(
    code: 'ar',
    englishName: 'Arabic',
    nativeName: 'العربية',
    flag: '🇸🇦',
    script: LanguageScript.arabic,
    sttLocale: 'ar_SA',
    ttsLocale: 'ar-SA',
    rtl: true,
    grammarFocusPoints: <String>[
      'root-and-pattern word formation',
      'definite article assimilation (الشمس)',
      'verb–subject agreement',
      'dual and plural forms',
    ],
  );

  static const AppLanguage hindi = AppLanguage(
    code: 'hi',
    englishName: 'Hindi',
    nativeName: 'हिन्दी',
    flag: '🇮🇳',
    script: LanguageScript.devanagari,
    sttLocale: 'hi_IN',
    ttsLocale: 'hi-IN',
    grammarFocusPoints: <String>[
      'postpositions and case marking (ने, को, से)',
      'verb agreement with gender and number',
      'compound verbs (करना constructions)',
      'respect register (तू / तुम / आप)',
    ],
  );

  static const AppLanguage chinese = AppLanguage(
    code: 'zh',
    englishName: 'Chinese (Mandarin)',
    nativeName: '中文',
    flag: '🇨🇳',
    script: LanguageScript.han,
    sttLocale: 'zh_CN',
    ttsLocale: 'zh-CN',
    grammarFocusPoints: <String>[
      'tone accuracy and tone change (一 / 不)',
      'measure words (个 / 只 / 张)',
      'aspect markers 了 / 过 / 着',
      '把 constructions',
    ],
  );

  static const AppLanguage japanese = AppLanguage(
    code: 'ja',
    englishName: 'Japanese',
    nativeName: '日本語',
    flag: '🇯🇵',
    script: LanguageScript.kana,
    sttLocale: 'ja_JP',
    ttsLocale: 'ja-JP',
    grammarFocusPoints: <String>[
      'particle choice (は / が / を / に)',
      'politeness level (です・ます vs. plain form)',
      'verb conjugation groups',
      'counters with numbers',
    ],
  );

  static const AppLanguage korean = AppLanguage(
    code: 'ko',
    englishName: 'Korean',
    nativeName: '한국어',
    flag: '🇰🇷',
    script: LanguageScript.hangul,
    sttLocale: 'ko_KR',
    ttsLocale: 'ko-KR',
    grammarFocusPoints: <String>[
      'speech levels (해요체 / 합니다체 / 반말)',
      'particle marking (은/는, 이/가, 을/를)',
      'verb endings and tense conjugation',
      'honorific vocabulary (드시다, 계시다)',
    ],
  );

  static const AppLanguage turkish = AppLanguage(
    code: 'tr',
    englishName: 'Turkish',
    nativeName: 'Türkçe',
    flag: '🇹🇷',
    script: LanguageScript.latin,
    sttLocale: 'tr_TR',
    ttsLocale: 'tr-TR',
    grammarFocusPoints: <String>[
      'vowel harmony in suffixes',
      'case suffixes and buffer letters',
      'agglutination of verbs',
      'no definite article — accusative marks definiteness',
    ],
  );

  static const AppLanguage dutch = AppLanguage(
    code: 'nl',
    englishName: 'Dutch',
    nativeName: 'Nederlands',
    flag: '🇳🇱',
    script: LanguageScript.latin,
    sttLocale: 'nl_NL',
    ttsLocale: 'nl-NL',
    grammarFocusPoints: <String>[
      'word order (SOFT: subject, object, finite verb, time)',
      'de vs. het words',
      'perfect tense with hebben vs. zijn',
      'diminutives and their plurals',
    ],
  );

  static const AppLanguage polish = AppLanguage(
    code: 'pl',
    englishName: 'Polish',
    nativeName: 'Polski',
    flag: '🇵🇱',
    script: LanguageScript.latin,
    sttLocale: 'pl_PL',
    ttsLocale: 'pl-PL',
    grammarFocusPoints: <String>[
      'seven-case declension',
      'verb aspect pairs',
      'directional prepositions with cases',
      'plurals with the masculine-personal gender',
    ],
  );

  static const AppLanguage vietnamese = AppLanguage(
    code: 'vi',
    englishName: 'Vietnamese',
    nativeName: 'Tiếng Việt',
    flag: '🇻🇳',
    script: LanguageScript.latin,
    sttLocale: 'vi_VN',
    ttsLocale: 'vi-VN',
    grammarFocusPoints: <String>[
      'tone accuracy across all six tones',
      'correct pronouns for relative age and status',
      'classifier nouns',
      'questions and negation with không',
    ],
  );

  // ── Collections ───────────────────────────────────────────────────────────

  /// Every language the tutor can teach.
  static const List<AppLanguage> all = <AppLanguage>[
    english,
    spanish,
    french,
    german,
    italian,
    portuguese,
    russian,
    arabic,
    hindi,
    chinese,
    japanese,
    korean,
    turkish,
    dutch,
    polish,
    vietnamese,
  ];

  /// First-run favourites: the languages with the best on-device STT/TTS
  /// coverage, shown in a "popular" row above the full list.
  static const List<AppLanguage> recommendedTargets = <AppLanguage>[
    spanish,
    french,
    german,
    japanese,
    korean,
    chinese,
  ];

  /// Languages that make sense as an *interface/explanation* language — i.e.
  /// widely-spoken natives. Used for the "explain in" picker.
  static const List<AppLanguage> recommendedNatives = <AppLanguage>[
    english,
    spanish,
    french,
    german,
    portuguese,
    russian,
    arabic,
    hindi,
    chinese,
    japanese,
    korean,
  ];

  static AppLanguage byCode(String? code) {
    if (code == null || code.isEmpty) return english;
    final String needle = code.toLowerCase();
    for (final AppLanguage language in all) {
      if (language.code == needle) return language;
    }
    // Tolerate full locales like `ko-KR` or `pt_BR` in stored preferences.
    final String family = AppLanguage.familyOf(needle);
    for (final AppLanguage language in all) {
      if (language.code == family) return language;
    }
    return english;
  }

  /// Language schools: does this pair make sense? Teaching you the language you
  /// already speak as a native is technically fine (monolingual mode) but the
  /// explanation language should default to something else.
  static AppLanguage sensibleNativeFor(AppLanguage target) {
    if (target.code != english.code) return english;
    // English speakers learning… English? Fall back to Spanish explanation so the
    // UI never shows English→English, which reads like a bug.
    return spanish;
  }

  /// Languages where at least one of the bundled catalogue voices is normally
  /// present on a stock Android image. Everything else still works, but the
  /// setup screen warns that the user may need to install a voice.
  static bool hasGoodVoiceCoverage(AppLanguage language) => const <String>[
        'en',
        'es',
        'fr',
        'de',
        'it',
        'pt',
        'ru',
        'zh',
        'ja',
        'ko',
      ].contains(language.code);
}
