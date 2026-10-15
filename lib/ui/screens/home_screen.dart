import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:k100/core/constants.dart';
import 'package:k100/core/theme.dart';
import 'package:k100/models/chat_message.dart';
import 'package:k100/models/learner_profile.dart';
import 'package:k100/models/scenario.dart';
import 'package:k100/models/tutor_state.dart';
import 'package:k100/providers/app_providers.dart';
import 'package:k100/services/database_service.dart';
import 'package:k100/ui/screens/chat_tutor_screen.dart';
import 'package:k100/ui/screens/history_screen.dart';
import 'package:k100/ui/screens/settings_screen.dart';
import 'package:k100/ui/screens/vocabulary_screen.dart';
import 'package:k100/ui/widgets/model_card.dart';

/// The hub. Four tabs, and the only screen a returning learner ever needs to
/// touch: practice, history, vocabulary, settings.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // Warm the pipeline (permission, locale, TTS voice, model weights) so that
    // tapping the orb does not pay the model-load cost.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(tutorControllerProvider.notifier).bootstrap();
    });
  }

  @override
  Widget build(BuildContext context) {
    const List<Widget> pages = <Widget>[
      _PracticeTab(),
      HistoryScreen(),
      VocabularyScreen(),
      SettingsScreen(),
    ];

    return Container(
      decoration: const BoxDecoration(gradient: AppColors.screenGradient),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: IndexedStack(index: _tab, children: pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (int index) => setState(() => _tab = index),
          backgroundColor: AppColors.surface,
          indicatorColor: AppColors.primary.withValues(alpha: 0.22),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: const <NavigationDestination>[
            NavigationDestination(
              icon: Icon(Icons.record_voice_over_outlined),
              selectedIcon: Icon(Icons.record_voice_over),
              label: 'Practice',
            ),
            NavigationDestination(
              icon: Icon(Icons.history_outlined),
              selectedIcon: Icon(Icons.history),
              label: 'History',
            ),
            NavigationDestination(
              icon: Icon(Icons.menu_book_outlined),
              selectedIcon: Icon(Icons.menu_book),
              label: 'Words',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
//  PRACTICE TAB
// ══════════════════════════════════════════════════════════════════════════════

class _PracticeTab extends ConsumerWidget {
  const _PracticeTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final LearnerProfile profile = ref.watch(profileProvider);
    final TutorRuntimeState runtime = ref.watch(tutorControllerProvider);
    final AsyncValue<List<DailyProgress>> week = ref.watch(weeklyStatsProvider);
    final AsyncValue<double> average = ref.watch(averageScoreProvider);

    final List<DailyProgress> days = week.asData?.value ?? <DailyProgress>[];
    final String todayKey = DatabaseService.dayKey();
    final DailyProgress today = days.isNotEmpty && days.last.day == todayKey
        ? days.last
        : DailyProgress(day: todayKey);

    return CustomScrollView(
      slivers: <Widget>[
        SliverAppBar(
          floating: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          titleSpacing: 20,
          title: Row(
            children: <Widget>[
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  gradient: AppColors.auraGradient,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(Icons.graphic_eq, size: 17, color: Colors.white),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    AppConfig.appName,
                    style: theme.textTheme.titleMedium?.copyWith(letterSpacing: 0.4),
                  ),
                  Text(AppConfig.tagline, style: theme.textTheme.labelSmall),
                ],
              ),
            ],
          ),
          actions: <Widget>[
            if (profile.streakCount > 0)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(child: _streakChip(theme, profile.streakCount)),
              ),
          ],
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          sliver: SliverList(
            delegate: SliverChildListDelegate(<Widget>[
              _greeting(theme, profile),
              const SizedBox(height: 14),
              _engineBanner(theme, profile, runtime),
              const SizedBox(height: 14),
              _todayCard(theme, today, days, profile, average.asData?.value),
              const SizedBox(height: 18),
              _freeTalkCard(context, theme, runtime),
              const SizedBox(height: 22),
              _sectionTitle(theme, 'Role-play', 'Pick a situation and act it out'),
              const SizedBox(height: 10),
              _roleplayGrid(theme, profile, runtime),
              const SizedBox(height: 22),
              _sectionTitle(theme, 'Guided course',
                  'Structured stages that get harder as you improve'),
              const SizedBox(height: 10),
              ...Scenarios.curriculum.map((LessonScenario scenario) =>
                  _curriculumRow(context, theme, scenario, profile, runtime)),
              const SizedBox(height: 18),
              Text(
                'Everything runs on this device. No account, no API key, no '
                'per-token billing — your conversations never leave the phone.',
                style: theme.textTheme.labelSmall?.copyWith(height: 1.5),
              ),
            ]),
          ),
        ),
      ],
    );
  }

  // ── Header pieces ─────────────────────────────────────────────────────────

  Widget _greeting(ThemeData theme, LearnerProfile profile) {
    final int hour = DateTime.now().hour;
    final String part = hour < 5
        ? 'Still up'
        : hour < 12
            ? 'Good morning'
            : hour < 18
                ? 'Good afternoon'
                : 'Good evening';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('$part 👋', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'Ready to practise ${profile.targetLanguage.flag} '
          '${profile.targetLanguage.englishName}?',
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }

  Widget _streakChip(ThemeData theme, int streak) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: <Widget>[
            const Icon(Icons.local_fire_department, size: 15, color: AppColors.warning),
            const SizedBox(width: 5),
            Text(
              '$streak day${streak == 1 ? '' : 's'}',
              style: const TextStyle(
                color: AppColors.warning,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );

  /// The honest status line: which model is resident, and what its state is.
  Widget _engineBanner(
    ThemeData theme,
    LearnerProfile profile,
    TutorRuntimeState runtime,
  ) {
    final bool ready = runtime.modelLoaded;
    final bool loading = runtime.engineLoading;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: ready
              ? AppColors.secondary.withValues(alpha: 0.3)
              : AppColors.warning.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                ready ? Icons.memory : Icons.download_for_offline_outlined,
                size: 18,
                color: ready ? AppColors.secondary : AppColors.warning,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  ready
                      ? '${profile.modelDisplayName} · ready'
                      : loading
                          ? 'Loading ${runtime.modelDisplayName}…'
                          : 'No model loaded',
                  style: theme.textTheme.labelLarge,
                ),
              ),
              if (loading)
                Text(
                  '${(runtime.engineLoadProgress * 100).round()}%',
                  style: theme.textTheme.labelSmall,
                ),
              if (ready)
                Text(
                  runtime.engineLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    color: AppColors.textTertiary,
                  ),
                ),
            ],
          ),
          if (loading) ...<Widget>[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: runtime.engineLoadProgress,
                minHeight: 5,
                backgroundColor: AppColors.outline,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Reading the weights into memory. This happens once per launch.',
              style: theme.textTheme.labelSmall,
            ),
          ] else if (!ready) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              'Download a model once and it runs offline forever. The 1.5B '
              'Qwen model is the recommended balance of quality and speed.',
              style: theme.textTheme.labelSmall?.copyWith(height: 1.4),
            ),
            const SizedBox(height: 10),
            const StorageSummary(),
          ],
          if (runtime.errorMessage != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              runtime.errorMessage!,
              style: theme.textTheme.labelSmall?.copyWith(color: AppColors.danger),
            ),
          ],
        ],
      ),
    );
  }

  Widget _todayCard(
    ThemeData theme,
    DailyProgress today,
    List<DailyProgress> week,
    LearnerProfile profile,
    double? average,
  ) {
    final double goal = today.goalFraction(profile.dailyGoalMinutes);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.card(radius: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('Today', style: theme.textTheme.titleMedium),
              const Spacer(),
              Text(
                '${today.minutes} / ${profile.dailyGoalMinutes} min',
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: goal,
              minHeight: 8,
              backgroundColor: AppColors.outline,
              valueColor: AlwaysStoppedAnimation<Color>(
                goal >= 1 ? AppColors.secondary : AppColors.primary,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              _metric(theme, '${today.messages}', 'replies'),
              _metric(theme, '${today.newWords}', 'new words'),
              _metric(
                theme,
                today.avgScore > 0 ? today.avgScore.round().toString() : '—',
                'today avg',
              ),
              _metric(
                theme,
                average == null || average <= 0 ? '—' : average.round().toString(),
                '30-day avg',
              ),
            ],
          ),
          if (week.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            SizedBox(
              height: 46,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: week.map((DailyProgress day) {
                  final double fraction = day.goalFraction(profile.dailyGoalMinutes);
                  return Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        Container(
                          height: 4 + (26 * fraction),
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            color: fraction >= 1
                                ? AppColors.secondary
                                : AppColors.primary.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          day.weekdayShort,
                          style: theme.textTheme.labelSmall?.copyWith(fontSize: 9.5),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _metric(ThemeData theme, String value, String label) => Expanded(
        child: Column(
          children: <Widget>[
            Text(value, style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(label, style: theme.textTheme.labelSmall?.copyWith(fontSize: 10)),
          ],
        ),
      );

  Widget _sectionTitle(ThemeData theme, String title, String subtitle) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 3),
          Text(subtitle, style: theme.textTheme.labelSmall),
        ],
      );

  // ── Launchers ─────────────────────────────────────────────────────────────

  Widget _freeTalkCard(
    BuildContext context,
    ThemeData theme,
    TutorRuntimeState runtime,
  ) {
    final LessonScenario scenario = Scenarios.freeTalk;
    return GestureDetector(
      onTap: () => _open(context, scenario),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: AppColors.auraGradient,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.mic, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Free talk',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    runtime.modelLoaded
                        ? 'Start a conversation about anything'
                        : 'You will be asked to download a model first',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_rounded, color: Colors.white),
          ],
        ),
      ),
    );
  }

  Widget _roleplayGrid(
    ThemeData theme,
    LearnerProfile profile,
    TutorRuntimeState runtime,
  ) {
    final List<LessonScenario> scenarios = Scenarios.roleplays;
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.45,
      ),
      itemCount: scenarios.length,
      itemBuilder: (BuildContext context, int index) {
        final LessonScenario scenario = scenarios[index];
        final bool locked = !scenario.isAvailableFor(profile.proficiency);
        return GestureDetector(
          onTap: () => locked
              ? _explainLock(context, scenario, profile)
              : _open(context, scenario),
          child: Opacity(
            opacity: locked ? 0.55 : 1,
            child: Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.outline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(scenario.emoji, style: const TextStyle(fontSize: 20)),
                      const Spacer(),
                      if (locked)
                        const Icon(Icons.lock_outline,
                            size: 14, color: AppColors.textTertiary)
                      else
                        Container(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: scenario.color.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            scenario.levelBadge,
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              color: scenario.color,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    scenario.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    scenario.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(fontSize: 10),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _curriculumRow(
    BuildContext context,
    ThemeData theme,
    LessonScenario scenario,
    LearnerProfile profile,
    TutorRuntimeState runtime,
  ) {
    final bool locked = !scenario.isAvailableFor(profile.proficiency);
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: GestureDetector(
        onTap: () => locked
            ? _explainLock(context, scenario, profile)
            : _open(context, scenario),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: AppTheme.card(),
          child: Row(
            children: <Widget>[
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: scenario.color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Center(
                  child: Text(scenario.levelBadge,
                      style: TextStyle(
                        color: scenario.color,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      )),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(scenario.title, style: theme.textTheme.labelLarge),
                    const SizedBox(height: 2),
                    Text(scenario.goal, style: theme.textTheme.labelSmall),
                  ],
                ),
              ),
              Icon(
                locked ? Icons.lock_outline : Icons.play_circle_outline,
                size: 20,
                color: locked ? AppColors.textTertiary : AppColors.secondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _explainLock(
    BuildContext context,
    LessonScenario scenario,
    LearnerProfile profile,
  ) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${scenario.title} is designed for ${scenario.minLevel.cefr} '
          'and above. You are on ${profile.proficiency.cefr} — open it anyway '
          'and it will still work, just expect more corrections.',
        ),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  void _open(BuildContext context, LessonScenario scenario) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatTutorScreen(scenario: scenario),
      ),
    );
  }
}
