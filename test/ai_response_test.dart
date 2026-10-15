import 'package:flutter_test/flutter_test.dart';

import 'package:k100/models/ai_response.dart';

/// The parser is the single most important piece of defensive code in K100: a
/// 1.5B model *will* eventually emit a stray comma, and a speaking tutor that
/// dies on one is worthless. These tests pin the four stages of the pipeline —
/// strict decode → mechanical repair → regex recovery → plain text — plus the
/// speech sanitiser that decides what the learner actually hears.
void main() {
  group('AiResponse.parse', () {
    const String strict = '''
{"reply_target_language": "Hola, ¿qué tal?", "reply_translation": "Hi, how are you?",
 "grammar_correction": null, "explanation": null, "fluency_score": 88}''';

    test('decodes a clean object as strict JSON', () {
      final AiResponse response = AiResponse.parse(strict);

      expect(response.mode, AiParseMode.strictJson);
      expect(response.isDegraded, isFalse);
      expect(response.replyTargetLanguage, 'Hola, ¿qué tal?');
      expect(response.replyTranslation, 'Hi, how are you?');
      expect(response.fluencyScore, 88);
      expect(response.isUsable, isTrue);
      expect(response.hasCorrection, isFalse);
    });

    test('unwraps a fenced code block', () {
      final AiResponse response =
          AiResponse.parse('```json\n${strict.trim()}\n```');

      expect(response.isUsable, isTrue);
      expect(response.fluencyScore, 88);
    });

    test('repairs single quotes and a trailing comma', () {
      final AiResponse response = AiResponse.parse(
        "{'reply_target_language': 'Je voudrais un café', "
        "'reply_translation': 'I would like a coffee', "
        "'grammar_correction': null, 'explanation': null, 'fluency_score': 74,}",
      );

      expect(response.isUsable, isTrue);
      expect(response.replyTargetLanguage, contains('café'));
      expect(response.fluencyScore, 74);
    });

    test('closes a truncated object', () {
      final AiResponse response = AiResponse.parse(
        '{"reply_target_language": "Ich heiße Ana", "reply_translation": "My name '
        'is Ana", "fluency_score": 61',
      );

      expect(response.isUsable, isTrue);
      expect(response.replyTargetLanguage, contains('Ana'));
    });

    test('recovers the fields with regexes when the JSON is beyond repair', () {
      final AiResponse response = AiResponse.parse(
        'sure! here is my answer "reply_target_language": "¿Dónde está el baño?" '
        '"reply_translation": "Where is the bathroom?" "fluency_score": 5/10 oops',
      );

      expect(response.isUsable, isTrue);
      expect(response.replyTargetLanguage, contains('baño'));
    });

    test('never throws, whatever the model emits', () {
      const List<String> garbage = <String>[
        '',
        '   ',
        '{}',
        'null',
        'not json at all, just a sentence',
        '{"unterminated": ',
        '```json\n{ broken\n```',
        '\u0000\u0001',
      ];
      for (final String input in garbage) {
        final AiResponse response = AiResponse.parse(input);
        expect(response.mode, isA<AiParseMode>(), reason: 'input: "$input"');
        expect(response.ttsText, isA<String>(), reason: 'input: "$input"');
      }
    });

    test('an empty generation is never usable', () {
      expect(AiResponse.parse('').isUsable, isFalse);
      expect(AiResponse.parse('   ').isUsable, isFalse);
    });

    test('failure() carries the reason so the UI can show it', () {
      final AiResponse failure = AiResponse.failure('engine unavailable');
      expect(failure.isUsable, isFalse);
      expect(failure.explanation, 'engine unavailable');
      expect(failure.mode, AiParseMode.rawText);
    });
  });

  group('AiResponse.cleanup', () {
    test('drops a "correction" that merely repeats the learner', () {
      const AiResponse response = AiResponse(
        replyTargetLanguage: 'That sounds good to me.',
        replyTranslation: '',
        grammarCorrection: 'that sounds good to me',
        explanation: 'this is a useful phrase',
        fluencyScore: 70,
        mode: AiParseMode.strictJson,
      );

      final AiResponse cleaned =
          response.cleanup(learnerText: 'That sounds good to me');

      expect(cleaned.hasCorrection, isFalse);
    });

    test('drops placeholder values models emit for optional fields', () {
      const AiResponse response = AiResponse(
        replyTargetLanguage: 'Great, let us go.',
        replyTranslation: '',
        grammarCorrection: 'null',
        explanation: 'n/a',
        keyPhrase: 'null',
        fluencyScore: 65,
        mode: AiParseMode.strictJson,
      );

      final AiResponse cleaned = response.cleanup();

      expect(cleaned.hasCorrection, isFalse);
      expect(cleaned.explanation, isNull);
      expect(cleaned.hasKeyPhrase, isFalse);
    });
  });

  group('AiResponse.sanitizeForSpeech', () {
    test('strips emoji and speaker prefixes', () {
      final String spoken = AiResponse.sanitizeForSpeech('🎉 AI: Hola amigo 👋');
      expect(spoken, contains('Hola amigo'));
      expect(spoken.contains('🎉'), isFalse);
      expect(spoken.contains('👋'), isFalse);
      expect(spoken.startsWith('AI'), isFalse);
    });

    test('removes markdown emphasis but keeps the words', () {
      final String spoken =
          AiResponse.sanitizeForSpeech('**Bien** hecho, *amigo* — ¡genial!');
      expect(spoken.contains('Bien'), isTrue);
      expect(spoken.contains('**'), isFalse);
      expect(spoken.contains('*'), isFalse);
    });

    test('is empty for empty input', () {
      expect(AiResponse.sanitizeForSpeech('   ').trim(), isEmpty);
    });
  });

  group('AiParseMode', () {
    test('only strict JSON is considered clean', () {
      expect(AiParseMode.strictJson.isDegraded, isFalse);
      expect(AiParseMode.strictJson.badge, isNull);
      for (final AiParseMode mode in <AiParseMode>[
        AiParseMode.repairedJson,
        AiParseMode.regexRecovered,
        AiParseMode.rawText,
      ]) {
        expect(mode.isDegraded, isTrue);
        expect(mode.badge, isNotNull);
        expect(mode.explanation, isNotEmpty);
      }
    });
  });
}
