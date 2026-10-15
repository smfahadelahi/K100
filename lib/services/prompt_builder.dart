import 'package:k100/core/constants.dart';
import 'package:k100/models/learner_profile.dart';
import 'package:k100/models/model_catalog.dart';
import 'package:k100/models/scenario.dart';

/// One turn handed to the prompt builder.
class PromptTurn {
  const PromptTurn({required this.role, required this.content});

  /// `system`, `user` or `assistant`.
  final String role;

  final String content;

  bool get isUser => role == 'user';

  @override
  String toString() => 'PromptTurn($role, ${content.length} chars)';
}

/// Builds the single prompt that produces a *parseable* JSON turn.
///
/// Design notes, learned from running 0.5B–3B models on phones:
///
/// 1. **One instruction block, one example.** Small models follow a schema they
///    have *seen* far more reliably than a schema described in prose, so the
///    system prompt always ends with a complete worked example.
/// 2. **Field order is fixed** and matches the example — Qwen2.5-1.5B mirrors the
///    order it was shown, which makes the reply easier to parse when it drifts.
/// 3. **Values, not sentences, for the metadata fields.** A 1.5B model that has
///    to produce a nested object will produce invalid JSON; flat strings and one
///    integer it can do.
/// 4. **`null` is legal.** Telling the model it may answer `null` for
///    `grammar_correction` removes the pressure to invent a mistake, which is the
///    single biggest source of bad corrections in small models.
/// 5. **A repair reminder exists.** When the first attempt fails to parse, the
///    caller re-asks once with the reply prefix pre-filled (`{"reply_target_
///    language": "`), which turns a JSON task into a continuation task — models
///    fail the former and pass the latter.
class PromptBuilder {
  PromptBuilder({
    required this.profile,
    required this.scenario,
    required this.family,
    this.historyTurns = AppConfig.historyTurns,
  });

  final LearnerProfile profile;
  final LessonScenario scenario;
  final ModelFamily family;

  /// How many previous turns to include (user + assistant each count as one).
  final int historyTurns;

  // ── System prompt ─────────────────────────────────────────────────────────

  /// The instructions that define the tutor. Kept under ~700 tokens so a 2048
  /// context still has room for the conversation and the reply.
  String buildSystemPrompt({bool strictRepair = false}) {
    final StringBuffer out = StringBuffer();

    out.writeln(
      'You are K100, a patient ${profile.targetLanguage.englishName} speaking '
      'tutor for a learner whose native language is '
      '${profile.nativeLanguage.englishName}.',
    );

    out.writeln();
    out.writeln('SCENE');
    out.writeln('${scenario.roleBrief} ${scenario.systemInjector}');

    out.writeln();
    out.writeln('HOW YOU SPEAK');
    out.writeln('- Speak ONLY ${profile.targetLanguage.englishName} in '
        '"reply_target_language".');
    out.writeln('- ${profile.proficiency.promptInstruction}');
    out.writeln('- At most ${profile.proficiency.sentenceBudget} sentences and '
        '${profile.proficiency.maxWords} words.');
    out.writeln('- Always end your turn with a question or an invitation to '
        'speak, so the learner keeps talking.');
    out.writeln('- Never use markdown, emoji, asterisks or stage directions.');

    if (profile.proficiency.explainInNative) {
      out.writeln('- Write "explanation" in '
          '${profile.nativeLanguage.englishName} — the learner is a beginner.');
    } else {
      out.writeln('- Write "explanation" in '
          '${profile.nativeLanguage.englishName}, in one short sentence.');
    }

    out.writeln();
    out.writeln('HOW YOU CORRECT');
    if (profile.grammarFocusPoints.isNotEmpty) {
      out.writeln('- Watch these first: '
          '${profile.grammarFocusPoints.join('; ')}.');
    }
    out.writeln('- "grammar_correction" is the learner\'s sentence rewritten '
        'correctly. If it was already correct, use null.');
    out.writeln('- NEVER invent a mistake. Copying the learner\'s sentence into '
        '"grammar_correction" is wrong — use null instead.');
    out.writeln('- "explanation" explains the ONE most important fix, in at most '
        'two short clauses. Use null when there was nothing to fix.');
    out.writeln('- "fluency_score" is an integer 0-100 for THIS sentence: '
        'accuracy and naturalness. Do not always give the same number.');

    out.writeln();
    out.writeln('OUTPUT FORMAT — ONE JSON OBJECT, NOTHING ELSE');
    out.writeln('{"reply_target_language": string, "reply_translation": string, '
        '"grammar_correction": string|null, "explanation": string|null, '
        '"fluency_score": integer, "key_phrase": string|null, '
        '"key_phrase_translation": string|null}');
    out.writeln('- "reply_translation" is the meaning of your reply in '
        '${profile.nativeLanguage.englishName}.');
    out.writeln('- "key_phrase" is one useful short expression from your reply '
        'that the learner should memorise, or null.');
    out.writeln('- Start with { and end with }. No text before or after. No '
        'code fences. No comments.');

    if (family == ModelFamily.gemma2) {
      out.writeln('- Do not add any other keys.');
    }

    out.writeln();
    out.writeln('EXAMPLE');
    out.writeln(_example);

    if (strictRepair) {
      out.writeln();
      out.writeln(strictJsonReminder);
    }

    // Hard stop on prompt bloat: an over-long system prompt is the fastest way
    // to make a 1.5B model ignore the schema.
    String text = out.toString().trim();
    if (text.length > 4200) {
      text = '${text.substring(0, 4200)}\n}\n';
    }
    return text;
  }

  /// The worked example. Deliberately about a mundane topic so the model does not
  /// get creative and imitate the *content* instead of the format.
  static const String _example = '''
Learner says: "I go yesterday to the market with my sister."
You answer:
{"reply_target_language": "That sounds nice! What did you buy at the market?", "reply_translation": "¡Qué bien! ¿Qué compraste en el mercado?", "grammar_correction": "I went to the market with my sister yesterday.", "explanation": "Use the past simple "went" for a finished action, and put the time at the end.", "fluency_score": 55, "key_phrase": "go to the market", "key_phrase_translation": "ir al mercado"}''';

  /// Re-ask template used when the first attempt did not parse. Short, and worded
  /// as a repair request rather than a fresh instruction — models handle "finish
  /// this" better than "do it again".
  static const String strictJsonReminder = '''
Your previous answer was not valid JSON. Answer ONLY with a single JSON object.
No prose, no code fences, no trailing commas, all keys and string values in
double quotes, grammar_correction and explanation may be null.''';

  /// Prefix used to force a valid continuation on the repair pass. The model sees
  /// `{` already open and completes the object.
  static const String repairPrefill = '{"reply_target_language": "';

  // ── Rendering ─────────────────────────────────────────────────────────────

  /// Renders the full prompt in the model's native template.
  ///
  /// [history] must be oldest-first and should contain only `user`/`assistant`
  /// turns. [userText] is appended as the final user turn when present.
  String render({
    List<PromptTurn> history = const <PromptTurn>[],
    String? userText,
    bool strictRepair = false,
    bool prefill = false,
  }) {
    final String system = buildSystemPrompt(strictRepair: strictRepair);
    final List<PromptTurn> turns = _budget(_trim(history), system, userText);

    final StringBuffer out = StringBuffer();

    switch (family) {
      case ModelFamily.gemma2:
        // Gemma 2 has no system role: the instructions ride on the first user
        // turn, and the template requires strict user/model alternation.
        final List<PromptTurn> seq = <PromptTurn>[];
        for (final PromptTurn turn in turns) {
          // Drop leading assistant turns — the template must open with a user.
          if (seq.isEmpty && !turn.isUser) continue;
          seq.add(turn);
        }
        if (userText != null) {
          seq.add(PromptTurn(role: 'user', content: userText));
        }
        final List<PromptTurn> mergedTurns = _mergeConsecutive(seq);
        if (mergedTurns.isEmpty) {
          mergedTurns.add(PromptTurn(role: 'user', content: 'Hello!'));
        }
        mergedTurns[0] = PromptTurn(
          role: 'user',
          content: '${system}\n\n---\n\n${mergedTurns.first.content}',
        );
        for (final PromptTurn turn in mergedTurns) {
          out.write('<start_of_turn>${turn.isUser ? 'user' : 'model'}\n'
              '${_condense(turn.content)}<end_of_turn>\n');
        }
        out.write('<start_of_turn>model\n${prefill ? repairPrefill : ''}');
        break;

      case ModelFamily.llama3:
        out.write('<|start_header_id|>system<|end_header_id|>\n\n$system<|eot_id|>');
        for (final PromptTurn turn in turns) {
          out.write('<|start_header_id|>${turn.isUser ? 'user' : 'assistant'}'
              '<|end_header_id|>\n\n${_condense(turn.content)}<|eot_id|>');
        }
        if (userText != null) {
          out.write('<|start_header_id|>user<|end_header_id|>\n\n'
              '$userText<|eot_id|>');
        }
        out.write('<|start_header_id|>assistant<|end_header_id|>\n\n'
            '${prefill ? repairPrefill : ''}');
        break;

      case ModelFamily.qwen2:
        out.write('<|im_start|>system\n$system<|im_end|>\n');
        for (final PromptTurn turn in turns) {
          out.write('<|im_start|>${turn.isUser ? 'user' : 'assistant'}\n'
              '${_condense(turn.content)}<|im_end|>\n');
        }
        if (userText != null) {
          out.write('<|im_start|>user\n$userText<|im_end|>\n');
        }
        out.write('<|im_start|>assistant\n${prefill ? repairPrefill : ''}');
        break;
    }

    return out.toString();
  }

  /// The stop sequences generation must honour for this template.
  List<String> get stopSequences => <String>[
        family.endToken,
        '<|im_end|>',
        '<|im_start|>',
        '<|eot_id|>',
        '<|start_header_id|>',
        '<end_of_turn>',
        '<start_of_turn>',
        '\n{"reply_target_language"', // a second object means the first is done
        'Learner says:',
        'Example:',
      ];

  /// The assistant-turn close token, appended by the caller if it wants to keep
  /// the conversation in-template (not needed for generation, only for logs).
  String get assistantCloseToken => family.assistantCloseToken;

  // ── Budgeting ─────────────────────────────────────────────────────────────

  List<PromptTurn> _trim(List<PromptTurn> history) {
    if (history.length <= historyTurns) return history;
    return history.sublist(history.length - historyTurns);
  }

  /// Drops the oldest turns until the prompt fits [AppConfig.maxPromptChars].
  /// The system prompt and the newest turn are never dropped.
  List<PromptTurn> _budget(List<PromptTurn> history, String system, String? userText) {
    int estimate(List<PromptTurn> turns) {
      int total = system.length + (userText?.length ?? 0);
      for (final PromptTurn turn in turns) {
        total += turn.content.length + 40; // template overhead
      }
      return total;
    }

    final List<PromptTurn> working = List<PromptTurn>.from(history);
    while (working.isNotEmpty && estimate(working) > AppConfig.maxPromptChars) {
      working.removeAt(0);
    }
    return working;
  }

  /// Condenses long turns so a chatty model cannot eat the context. Assistant
  /// turns are stored as their raw JSON; we re-emit only the spoken line to keep
  /// the prompt small and the style consistent.
  String _condense(String content) {
    final String text = content.trim();
    if (text.length <= 400) return text;
    return '${text.substring(0, 400)}…';
  }

  /// Folds consecutive same-role turns into one, which keeps the Gemma and
  /// ChatML templates legal when a turn was dropped by history trimming.
  static List<PromptTurn> _mergeConsecutive(List<PromptTurn> turns) {
    final List<PromptTurn> merged = <PromptTurn>[];
    for (final PromptTurn turn in turns) {
      if (merged.isNotEmpty && merged.last.isUser == turn.isUser) {
        merged[merged.length - 1] = PromptTurn(
          role: merged.last.role,
          content: '${merged.last.content} ${turn.content}',
        );
      } else {
        merged.add(turn);
      }
    }
    return merged;
  }
}

/// Convenience helpers used by the pipeline and the diagnostics screen.
extension PromptBuilderDiagnostics on PromptBuilder {
  /// Approximate token count of a rendered prompt. Only used to display a budget
  /// warning — llama.cpp does the real tokenisation.
  int estimateTokens(String prompt) =>
      (prompt.length / AppConfig.charsPerToken).ceil();

  /// True when the prompt is dangerously close to the context window.
  bool isPromptTooLong(String prompt) =>
      estimateTokens(prompt) > AppConfig.contextSize - AppConfig.minTokensPerTurn;
}
