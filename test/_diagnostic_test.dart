// TEMPORARY diagnostic harness. It exists only to surface values that cannot be
// observed locally (there is no Dart toolchain in the development sandbox), so
// it fails on purpose with its findings in the failure message, which CI turns
// into a GitHub annotation. Delete after use.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:k100/models/ai_response.dart';

void main() {
  test('diagnostic: single-quote + trailing-comma repair', () {
    const String input = "{'reply_target_language': 'Je voudrais un café', "
        "'reply_translation': 'I would like a coffee', "
        "'grammar_correction': null, 'explanation': null, 'fluency_score': 74,}";

    final String repaired = AiResponse.repairJson(input);
    Object? decoded;
    try {
      decoded = jsonEncode(jsonDecode(repaired));
    } catch (error) {
      decoded = 'THREW $error';
    }
    final AiResponse parsed = AiResponse.parse(input);

    fail('DIAG1 mode=${parsed.mode.name} score=${parsed.fluencyScore} '
        'usable=${parsed.isUsable} decoded=$decoded repaired=$repaired');
  });
}
