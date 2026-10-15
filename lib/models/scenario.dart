import 'package:flutter/material.dart';
import 'package:k100/models/learner_profile.dart';

/// What kind of practice a scenario represents. Drives grouping in the UI and
/// how much prompting the tutor receives.
enum ScenarioKind {
  freeTalk('Free talk'),
  roleplay('Roleplay'),
  curriculum('Course');

  const ScenarioKind(this.label);

  final String label;
}

/// A practice scenario: a role the tutor plays plus the constraints that make
/// the conversation productive for a specific level.
///
/// [systemInjector] is the important field — it is appended verbatim to the
/// system prompt, and it is written to *constrain* a 1.5B model rather than to
/// inspire it. Short, imperative, concrete beats paragraphs of role-play prose.
@immutable
class LessonScenario {
  const LessonScenario({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.emoji,
    required this.kind,
    required this.goal,
    required this.roleBrief,
    required this.systemInjector,
    required this.starterPrompts,
    this.vocabulary = const <String>[],
    this.minLevel = ProficiencyLevel.beginner,
    this.icon = Icons.chat_bubble_outline,
    this.color = const Color(0xFF7C8CF8),
    this.order = 0,
  });

  final String id;
  final String title;
  final String subtitle;
  final String emoji;
  final ScenarioKind kind;

  /// One-sentence mission shown to the learner ("Order a coffee and ask for the
  /// wifi password").
  final String goal;

  /// The role the AI plays, in plain language, shown in the scenario briefing
  /// sheet.
  final String roleBrief;

  /// Verbatim prompt injection.
  final String systemInjector;

  /// Two or three things the learner can say to get going. Shown as tappable
  /// suggestions in the empty conversation state.
  final List<String> starterPrompts;

  /// Target-language words the scenario should naturally elicit. Used for the
  /// briefing sheet and as vocabulary hints to the model.
  final List<String> vocabulary;

  /// Levels below this one see the scenario greyed out with an explanation.
  final ProficiencyLevel minLevel;

  final IconData icon;
  final Color color;

  /// Sort order inside its group.
  final int order;

  bool isAvailableFor(ProficiencyLevel level) => level.index >= minLevel.index;

  String get levelBadge => minLevel.cefr;
}

/// The complete scenario catalogue: 1 free-talk mode, 8 roleplays and a
/// 5-stage curriculum ladder.
class Scenarios {
  Scenarios._();

  // ── Free talk ─────────────────────────────────────────────────────────────

  static const LessonScenario freeTalk = LessonScenario(
    id: 'free_talk',
    title: 'Free Talk',
    subtitle: 'Unscripted conversation with your AI partner',
    emoji: '💬',
    kind: ScenarioKind.freeTalk,
    goal: 'Talk about anything you like and get corrected after every sentence.',
    roleBrief: 'A friendly conversation partner who is curious about your day, '
        'your opinions and your plans.',
    systemInjector: 'No fixed scene. Follow the learner’s lead: ask one '
        'follow-up question per turn about what they just said. Start by '
        'asking how their day is going.',
    starterPrompts: <String>[
      'Hi! I want to practise speaking today.',
      'Let me tell you about my day.',
      'What should we talk about?',
    ],
    vocabulary: <String>[],
    icon: Icons.forum_outlined,
    color: Color(0xFFC084FC),
    order: 0,
  );

  // ── Roleplays ─────────────────────────────────────────────────────────────

  static const LessonScenario cafe = LessonScenario(
    id: 'cafe',
    title: 'Ordering Coffee',
    subtitle: 'Café counter, sizes, milk, to-go',
    emoji: '☕',
    kind: ScenarioKind.roleplay,
    order: 1,
    goal: 'Order a drink exactly how you like it, then ask for the wifi password.',
    roleBrief: 'A barista at a busy café who is friendly but efficient.',
    systemInjector: 'You are a barista. Insist on size and milk type before '
        'taking the order, then ask for here-or-takeaway. Finally the learner '
        'must ask for the wifi password or a receipt.',
    starterPrompts: <String>[
      'Hi, can I get a large latte please?',
      'What do you recommend today?',
      'Do you have oat milk?',
    ],
    vocabulary: <String>['large', 'takeaway', 'receipt', 'wifi password', 'decaf'],
    icon: Icons.local_cafe_outlined,
    color: Color(0xFFFBBF24),
  );

  static const LessonScenario airport = LessonScenario(
    id: 'airport',
    title: 'Airport Check-in',
    subtitle: 'Tickets, baggage, seat choice',
    emoji: '✈️',
    kind: ScenarioKind.roleplay,
    order: 2,
    goal: 'Check in for a flight, ask about baggage fees and pick a seat.',
    roleBrief: 'An airline check-in agent working through a queue.',
    systemInjector: 'You are a check-in agent. Ask for passport and '
        'destination, then raise one problem (overweight bag or a seat that is '
        'taken) that the learner must solve with a question or a request.',
    starterPrompts: <String>[
      'Hello, checking in for the flight to Madrid.',
      'How much is the extra baggage?',
      'Could I have an aisle seat, please?',
    ],
    vocabulary: <String>['boarding pass', 'window seat', 'overweight', 'gate', 'delay'],
    minLevel: ProficiencyLevel.intermediate,
    icon: Icons.flight_takeoff_outlined,
    color: Color(0xFF38BDF8),
  );

  static const LessonScenario hotel = LessonScenario(
    id: 'hotel',
    title: 'Hotel Reception',
    subtitle: 'Reservations, complaints, requests',
    emoji: '🏨',
    kind: ScenarioKind.roleplay,
    order: 3,
    goal: 'Check in, then politely complain about a problem in your room.',
    roleBrief: 'A hotel receptionist who is apologetic but needs details.',
    systemInjector: 'You are a receptionist. After check-in, reveal that the '
        'room has a problem (no hot water or a noisy neighbour) and require the '
        'learner to complain politely and ask for a solution.',
    starterPrompts: <String>[
      'I have a reservation under my name.',
      'Could I have a late check-out?',
      'Is breakfast included?',
    ],
    vocabulary: <String>['reservation', 'available', 'complain', 'maintenance', 'refund'],
    minLevel: ProficiencyLevel.intermediate,
    icon: Icons.hotel_outlined,
    color: Color(0xFF4ADE80),
  );

  static const LessonScenario doctor = LessonScenario(
    id: 'doctor',
    title: "Doctor's Visit",
    subtitle: 'Symptoms, duration, advice',
    emoji: '🩺',
    kind: ScenarioKind.roleplay,
    order: 4,
    goal: 'Describe symptoms clearly and understand the doctor’s advice.',
    roleBrief: 'A general practitioner asking structured diagnostic questions.',
    systemInjector: 'You are a doctor. Ask where it hurts, how long it has '
        'been going on and whether there is a fever. Then give one simple '
        'instruction using an imperative (rest, take this twice a day).',
    starterPrompts: <String>[
      'I have a sore throat and a headache.',
      'It started three days ago.',
      'Do I need antibiotics?',
    ],
    vocabulary: <String>['symptom', 'fever', 'prescription', 'twice a day', 'allergy'],
    icon: Icons.medical_services_outlined,
    color: Color(0xFFF87171),
  );

  static const LessonScenario interview = LessonScenario(
    id: 'interview',
    title: 'Job Interview',
    subtitle: 'Experience, strengths, questions',
    emoji: '💼',
    kind: ScenarioKind.roleplay,
    order: 5,
    goal: 'Answer three interview questions with a concrete example in each.',
    roleBrief: 'A hiring manager for a role you actually want.',
    systemInjector: 'You are an interviewer. Ask exactly one question per '
        'turn: experience, a strength with a concrete example, then a '
        'weakness. Push back once with "Can you give me an example?".',
    starterPrompts: <String>[
      'Thanks for meeting me today.',
      'I have three years of experience in this field.',
      'Could you tell me about the team?',
    ],
    vocabulary: <String>['experience', 'strength', 'challenge', 'teamwork', 'responsible for'],
    minLevel: ProficiencyLevel.intermediate,
    icon: Icons.work_outline,
    color: Color(0xFFA78BFA),
  );

  static const LessonScenario market = LessonScenario(
    id: 'market',
    title: 'At the Market',
    subtitle: 'Prices, quantities, bargaining',
    emoji: '🛒',
    kind: ScenarioKind.roleplay,
    order: 6,
    goal: 'Buy three items, ask about prices and try to get a discount.',
    roleBrief: 'A market vendor who haggles cheerfully.',
    systemInjector: 'You are a market vendor. Quote prices in the local '
        'currency, offer a discount only if the learner asks for one, and ask '
        'how much they want of each item.',
    starterPrompts: <String>[
      'How much are these tomatoes?',
      'I’ll take two kilos, please.',
      'Could you make it cheaper?',
    ],
    vocabulary: <String>['how much', 'kilo', 'fresh', 'discount', 'cash'],
    icon: Icons.storefront_outlined,
    color: Color(0xFFFBBF24),
  );

  static const LessonScenario smallTalk = LessonScenario(
    id: 'small_talk',
    title: 'Meeting Someone New',
    subtitle: 'Introductions and small talk',
    emoji: '🤝',
    kind: ScenarioKind.roleplay,
    order: 7,
    goal: 'Introduce yourself, find two things in common and end politely.',
    roleBrief: 'Someone sitting next to you at a party who knows nobody either.',
    systemInjector: 'You are a stranger at a party. Introduce yourself, ask '
        'where the learner is from and what they do, and react with genuine '
        'interest. After four turns, end the conversation politely.',
    starterPrompts: <String>[
      'Hi, I don’t think we’ve met. I’m…',
      'I’m here with a friend, and you?',
      'What do you do for work?',
    ],
    vocabulary: <String>['nice to meet you', 'originally from', 'in common', 'take care'],
    icon: Icons.people_outline,
    color: Color(0xFF38BDF8),
  );

  static const LessonScenario directions = LessonScenario(
    id: 'directions',
    title: 'Asking for Directions',
    subtitle: 'Landmarks, turns, distances',
    emoji: '🧭',
    kind: ScenarioKind.roleplay,
    order: 8,
    goal: 'Get directions to a landmark while only speaking the target language.',
    roleBrief: 'A helpful local who gives directions with landmarks.',
    systemInjector: 'You are a local. Give directions using landmarks, not '
        'street names, and end with an approximate walking time. Then ask the '
        'learner to repeat the route back to you.',
    starterPrompts: <String>[
      'Excuse me, how do I get to the station?',
      'Is it far from here?',
      'Should I take the bus?',
    ],
    vocabulary: <String>['turn left', 'straight ahead', 'corner', 'block', 'ten minutes'],
    icon: Icons.explore_outlined,
    color: Color(0xFF4ADE80),
  );

  // ── Curriculum ladder ─────────────────────────────────────────────────────

  static const LessonScenario stageA1 = LessonScenario(
    id: 'stage_a1',
    title: 'Stage 1 · Survival Basics',
    subtitle: 'Introduce yourself, numbers, yes/no questions',
    emoji: '🌱',
    kind: ScenarioKind.curriculum,
    order: 10,
    goal: 'Say who you are, where you are from and what you want — in short sentences.',
    roleBrief: 'A patient teacher drilling the absolute basics.',
    systemInjector: 'Drill survival basics: name, nationality, job, numbers, '
        'and two polite requests. Use a single short question per turn and '
        'repeat the corrected sentence once. Maximum 6 words per sentence you '
        'speak.',
    starterPrompts: <String>[
      'My name is… and I’m from…',
      'I would like some water, please.',
      'I don’t understand. Can you repeat that?',
    ],
    vocabulary: <String>['my name is', 'I am from', 'please', 'thank you', 'sorry'],
    icon: Icons.spa_outlined,
    color: Color(0xFF4ADE80),
  );

  static const LessonScenario stageA2 = LessonScenario(
    id: 'stage_a2',
    title: 'Stage 2 · Daily Routines',
    subtitle: 'Present tense, time, habits',
    emoji: '⏰',
    kind: ScenarioKind.curriculum,
    order: 11,
    goal: 'Describe your whole day in order, with times and frequency words.',
    roleBrief: 'A teacher building present-tense fluency.',
    systemInjector: 'Focus on present-tense routines and time expressions. Ask '
        'what the learner does at a specific hour and follow up with "and '
        'after that?". Correct verb endings every turn.',
    starterPrompts: <String>[
      'I usually wake up at seven.',
      'In the morning I go to work by subway.',
      'After dinner I watch a series.',
    ],
    vocabulary: <String>['usually', 'sometimes', 'before', 'after', 'every day'],
    minLevel: ProficiencyLevel.beginner,
    icon: Icons.schedule_outlined,
    color: Color(0xFF38BDF8),
  );

  static const LessonScenario stageB1 = LessonScenario(
    id: 'stage_b1',
    title: 'Stage 3 · Telling Stories',
    subtitle: 'Past tense, sequencing, reactions',
    emoji: '📖',
    kind: ScenarioKind.curriculum,
    order: 12,
    goal: 'Tell one story from last week with a beginning, a problem and an end.',
    roleBrief: 'A teacher who pushes for narrative detail.',
    systemInjector: 'Focus on past-tense narration. Ask "what happened next?" '
        'and "how did you feel?" until the learner has told a three-part '
        'story. Correct tense slips every turn.',
    starterPrompts: <String>[
      'Last weekend something funny happened.',
      'First we went to…, then…',
      'In the end, everything worked out.',
    ],
    vocabulary: <String>['suddenly', 'in the end', 'fortunately', 'while', 'because of that'],
    minLevel: ProficiencyLevel.intermediate,
    icon: Icons.auto_stories_outlined,
    color: Color(0xFFA78BFA),
  );

  static const LessonScenario stageB2 = LessonScenario(
    id: 'stage_b2',
    title: 'Stage 4 · Opinions & Debate',
    subtitle: 'Agree, disagree, justify',
    emoji: '⚖️',
    kind: ScenarioKind.curriculum,
    order: 13,
    goal: 'Take a position, give two reasons, and answer one counter-argument.',
    roleBrief: 'A debate partner who politely disagrees.',
    systemInjector: 'Take the opposite side of whatever the learner argues. '
        'Require a reason for every claim, and challenge vague words like '
        '"good" or "bad" with "why exactly?".',
    starterPrompts: <String>[
      'I think remote work is better than office work.',
      'The main reason is that…',
      'I see your point, but…',
    ],
    vocabulary: <String>['in my opinion', 'on the other hand', 'I disagree', 'the main reason'],
    minLevel: ProficiencyLevel.intermediate,
    icon: Icons.balance_outlined,
    color: Color(0xFFFBBF24),
  );

  static const LessonScenario stageC1 = LessonScenario(
    id: 'stage_c1',
    title: 'Stage 5 · Nuance & Idioms',
    subtitle: 'Register, hedging, collocations',
    emoji: '🎭',
    kind: ScenarioKind.curriculum,
    order: 14,
    goal: 'Say the same idea three ways: casual, neutral and formal.',
    roleBrief: 'A demanding coach for near-native polish.',
    systemInjector: 'Push for register control. Ask the learner to rephrase '
        'their last sentence more formally, then more casually. Introduce one '
        'idiom per turn and require them to reuse it in the next answer.',
    starterPrompts: <String>[
      'Let me rephrase that more formally.',
      'That’s a bit of a grey area, isn’t it?',
      'Could you explain that idiom?',
    ],
    vocabulary: <String>['to be fair', 'in hindsight', 'a grey area', 'at the end of the day'],
    minLevel: ProficiencyLevel.advanced,
    icon: Icons.theater_comedy_outlined,
    color: Color(0xFFF472B6),
  );

  // ── Collections ───────────────────────────────────────────────────────────

  static const List<LessonScenario> roleplays = <LessonScenario>[
    cafe,
    airport,
    hotel,
    doctor,
    interview,
    market,
    smallTalk,
    directions,
  ];

  static const List<LessonScenario> curriculum = <LessonScenario>[
    stageA1,
    stageA2,
    stageB1,
    stageB2,
    stageC1,
  ];

  static List<LessonScenario> get all => <LessonScenario>[
        freeTalk,
        ...roleplays,
        ...curriculum,
      ];

  static List<LessonScenario> get allCourses => <LessonScenario>[
        ...roleplays,
        ...curriculum,
      ];

  /// Safe lookup: an unknown id (e.g. a scenario removed in an upgrade) falls
  /// back to Free Talk instead of crashing a history screen.
  static LessonScenario byId(String? id) {
    if (id == null || id.isEmpty) return freeTalk;
    for (final LessonScenario scenario in all) {
      if (scenario.id == id) return scenario;
    }
    return freeTalk;
  }

  /// Scenarios suitable for the learner's level, in display order.
  static List<LessonScenario> availableFor(ProficiencyLevel level) =>
      all.where((LessonScenario s) => s.isAvailableFor(level)).toList();

  /// "What should I do next?" — the next curriculum stage after the one that
  /// matches the level, or the first roleplay if the ladder is finished.
  static LessonScenario nextFor(ProficiencyLevel level) {
    switch (level) {
      case ProficiencyLevel.beginner:
        return stageA1;
      case ProficiencyLevel.intermediate:
        return stageB1;
      case ProficiencyLevel.advanced:
        return stageC1;
    }
  }
}
