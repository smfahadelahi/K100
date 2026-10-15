import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:k100/core/constants.dart';
import 'package:k100/core/logger.dart';
import 'package:k100/core/theme.dart';
import 'package:k100/models/language.dart';
import 'package:k100/models/learner_profile.dart';
import 'package:k100/models/model_catalog.dart';
import 'package:k100/providers/app_providers.dart';
import 'package:k100/services/llm_service.dart';
import 'package:k100/services/tts_service.dart';
import 'package:k100/ui/screens/setup_screen.dart';
import 'package:k100/ui/widgets/model_card.dart';

/// Everything configurable, plus the honest privacy statement: nothing leaves
/// the device except the one download the learner starts themselves.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final LearnerProfile profile = ref.watch(profileProvider);
    final ProfileNotifier notifier = ref.read(profileProvider.notifier);
    final ModelEntry? model = ref.watch(selectedModelProvider);
    final AsyncValue<Map<String, int>> counts = ref.watch(dataCountsProvider);
    final AsyncValue<List<TtsVoice>> voices = ref.watch(ttsVoicesProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Settings'),
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: <Widget>[
          _section(theme, 'Model'),
          _card(children: <Widget>[
            _actionRow(
              theme,
              icon: Icons.memory,
              title: model?.displayName ??
                  (profile.isCustomModel ? 'Custom GGUF model' : 'No model selected'),
              subtitle: model != null
                  ? '${model.parameters} · ${model.quant} · ${model.sizeLabel} · '
                      '${model.license}'
                  : 'Download a GGUF model to run offline',
              onTap: () => _openSetup(context, step: 2),
            ),
            const Divider(),
            _actionRow(
              theme,
              icon: Icons.tune,
              title: 'Manage models',
              subtitle: 'Download, pause, resume, verify or delete',
              onTap: () => _openSetup(context, step: 2),
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: StorageSummary(),
            ),
            const Divider(),
            _actionRow(
              theme,
              icon: Icons.speed,
              title: 'Check this device',
              subtitle: 'Engine report and a short decode benchmark',
              onTap: () => _runDiagnostics(context, ref),
            ),
            const Divider(),
            _actionRow(
              theme,
              icon: Icons.receipt_long,
              title: 'Engine log',
              subtitle: 'The last ${Log.maxHistory} lines, useful for bug reports',
              onTap: () => _showLog(context),
            ),
          ]),
          _section(theme, 'Speech'),
          _card(children: <Widget>[
            _switchRow(
              theme,
              title: 'Hands-free mode',
              subtitle: 'Re-open the microphone automatically after each reply',
              value: profile.autoListen,
              onChanged: (bool value) {
                notifier.setAutoListen(value);
                ref.read(tutorControllerProvider.notifier).setAutoListen(value);
              },
            ),
            const Divider(),
            _switchRow(
              theme,
              title: 'Prefer on-device recognition',
              subtitle: 'Never send your voice to a cloud recogniser',
              value: profile.sttOnDeviceOnly,
              onChanged: (bool value) async {
                await notifier.setSttOnDeviceOnly(value);
                await ref.read(tutorControllerProvider.notifier).applyProfileChanges();
              },
            ),
            const Divider(),
            _sliderRow(
              theme,
              title: 'Speaking speed',
              value: profile.effectiveTtsRate.clamp(0.2, 1.2),
              min: 0.2,
              max: 1.2,
              divisions: 20,
              label: '${(profile.effectiveTtsRate * 100).round()}%'
                  '${profile.ttsRateOverride == null ? ' (level default)' : ''}',
              onChanged: (double value) async {
                await notifier.setTtsRate(value);
                await ref.read(ttsServiceProvider).setRate(value);
              },
              trailing: TextButton(
                onPressed: () async {
                  await notifier.setTtsRate(null);
                  await ref
                      .read(ttsServiceProvider)
                      .setRate(profile.proficiency.speechRate);
                },
                child: const Text('Level default'),
              ),
            ),
            const Divider(),
            _voicePicker(theme, ref, profile, voices),
          ]),
          _section(theme, 'Tutor'),
          _card(children: <Widget>[
            _switchRow(
              theme,
              title: 'Show translations',
              subtitle: 'Native-language line under each reply',
              value: profile.showTranslations,
              onChanged: notifier.setShowTranslations,
            ),
            const Divider(),
            _switchRow(
              theme,
              title: 'Haptics',
              subtitle: 'Short vibration when a turn changes state',
              value: profile.haptics,
              onChanged: notifier.setHaptics,
            ),
            const Divider(),
            _sliderRow(
              theme,
              title: 'Daily goal',
              value: profile.dailyGoalMinutes.toDouble(),
              min: 5,
              max: 60,
              divisions: 11,
              label: '${profile.dailyGoalMinutes} minutes',
              onChanged: (double value) => notifier.setDailyGoal(value.round()),
            ),
            const Divider(),
            _actionRow(
              theme,
              icon: Icons.translate,
              title: 'Languages & level',
              subtitle:
                  '${profile.nativeLanguage.flag} ${profile.nativeLanguage.englishName} → '
                  '${profile.targetLanguage.flag} ${profile.targetLanguage.englishName} · '
                  '${profile.proficiency.label} (${profile.proficiency.cefr})',
              onTap: () => _openSetup(context, step: 0),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Grammar focus', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 3),
                  Text(
                    'The tutor pays extra attention to these '
                    '${profile.targetLanguage.englishName} structures:',
                    style: theme.textTheme.labelSmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: profile.targetLanguage.grammarFocusPoints
                        .map((String point) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 5),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceHigh,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                point,
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 10.5,
                                ),
                              ),
                            ))
                        .toList(),
                  ),
                ],
              ),
            ),
          ]),
          _section(theme, 'Data & privacy'),
          _card(children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Conversations, grammar feedback and vocabulary live in a local '
                'SQLite database inside this app. There are no accounts, no '
                'analytics and no inference API — the only network request K100 '
                'ever makes is the GGUF download you start yourself.',
                style: theme.textTheme.labelSmall?.copyWith(height: 1.5),
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: <Widget>[
                  _stat(theme, 'Sessions', counts.asData?.value?['sessions'] ?? 0),
                  _stat(theme, 'Messages', counts.asData?.value?['messages'] ?? 0),
                  _stat(theme, 'Phrases', counts.asData?.value?['vocabulary'] ?? 0),
                  _stat(theme, 'Days', counts.asData?.value?['days'] ?? 0),
                ],
              ),
            ),
            const Divider(),
            _actionRow(
              theme,
              icon: Icons.delete_sweep_outlined,
              title: 'Erase all learning data',
              subtitle: 'Sessions, feedback and the vocabulary bank',
              danger: true,
              onTap: () => _eraseData(context, ref),
            ),
            const Divider(),
            _actionRow(
              theme,
              icon: Icons.sd_storage_outlined,
              title: 'Delete downloaded models',
              subtitle: 'Frees 0.5-2 GB of storage',
              danger: true,
              onTap: () => _deleteModels(context, ref),
            ),
          ]),
          _section(theme, 'About'),
          _card(children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '${AppConfig.appName} ${AppConfig.version}',
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${AppConfig.tagline}\n'
                    'llama.cpp · GGUF · on-device speech recognition and '
                    'text-to-speech · Android 8.0+ (arm64-v8a)',
                    style: theme.textTheme.labelSmall?.copyWith(height: 1.5),
                  ),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Center(
            child: Text(
              'No cloud AI. No API keys. No subscription.',
              style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 0.3),
            ),
          ),
        ],
      ),
    );
  }

  void _openSetup(BuildContext context, {required int step}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SetupScreen(isOnboarding: false, initialStep: step),
      ),
    );
  }

  // ── Pieces ────────────────────────────────────────────────────────────────

  Widget _section(ThemeData theme, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(
          title.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.1),
        ),
      );

  Widget _card({required List<Widget> children}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: AppTheme.card(radius: 18),
        child: Column(children: children),
      );

  Widget _switchRow(
    ThemeData theme, {
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: value,
        onChanged: onChanged,
        title: Text(title, style: theme.textTheme.labelLarge),
        subtitle: Text(subtitle, style: theme.textTheme.labelSmall),
      );

  Widget _sliderRow(
    ThemeData theme, {
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required ValueChanged<double> onChanged,
    Widget? trailing,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(title, style: theme.textTheme.labelLarge),
                const Spacer(),
                Text(label, style: theme.textTheme.labelSmall),
                if (trailing != null) trailing,
              ],
            ),
            Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ],
        ),
      );

  Widget _actionRow(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool danger = false,
  }) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 13),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 19, color: danger ? AppColors.danger : AppColors.secondary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: danger ? AppColors.danger : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(subtitle, style: theme.textTheme.labelSmall?.copyWith(height: 1.4)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 18, color: AppColors.textTertiary),
            ],
          ),
        ),
      );

  Widget _stat(ThemeData theme, String label, int value) => Expanded(
        child: Column(
          children: <Widget>[
            Text('$value', style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(label, style: theme.textTheme.labelSmall),
          ],
        ),
      );

  Widget _voicePicker(
    ThemeData theme,
    WidgetRef ref,
    LearnerProfile profile,
    AsyncValue<List<TtsVoice>> voices,
  ) {
    final List<TtsVoice> matching = (voices.asData?.value ?? <TtsVoice>[])
        .where((TtsVoice voice) =>
            voice.language == profile.targetLanguage.code.toLowerCase())
        .toList();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Voice', style: theme.textTheme.labelLarge),
          const SizedBox(height: 3),
          Text(
            matching.isEmpty
                ? 'No ${profile.targetLanguage.englishName} voice is installed. Add '
                    'one in Android settings → System → Languages & input → '
                    'Text-to-speech.'
                : '${matching.length} voice(s) available for '
                    '${profile.targetLanguage.englishName}',
            style: theme.textTheme.labelSmall?.copyWith(height: 1.4),
          ),
          if (matching.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: matching.take(6).map((TtsVoice voice) {
                final bool selected = profile.ttsVoiceName == voice.name;
                return GestureDetector(
                  onTap: () async {
                    await ref.read(profileProvider.notifier).setVoiceName(voice.name);
                    await ref.read(ttsServiceProvider).setVoice(voice);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppColors.primary.withValues(alpha: 0.18)
                          : AppColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: selected ? AppColors.primary : AppColors.outline,
                      ),
                    ),
                    child: Text(
                      voice.label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: selected ? AppColors.textPrimary : AppColors.textSecondary,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () async {
              final TtsService tts = ref.read(ttsServiceProvider);
              final String? voiceName = profile.ttsVoiceName;
              if (voiceName != null) {
                final List<TtsVoice> all = await tts.voices();
                for (final TtsVoice voice in all) {
                  if (voice.name == voiceName) {
                    await tts.setVoice(voice);
                    break;
                  }
                }
              }
              await tts.setLanguage(profile.targetLanguage.ttsLocale);
              await tts.setRate(profile.effectiveTtsRate);
              await tts.speak(_sampleSentence(profile.targetLanguage.code));
            },
            icon: const Icon(Icons.volume_up, size: 18),
            label: const Text('Test the voice'),
          ),
        ],
      ),
    );
  }

  /// A short, language-appropriate sample. Deliberately everyday language, the
  /// same register the tutor uses.
  String _sampleSentence(String code) {
    switch (code) {
      case 'ko':
        return '안녕하세요! 오늘도 같이 연습해 봐요.';
      case 'ja':
        return 'こんにちは！今日も一緒に練習しましょう。';
      case 'zh':
        return '你好！我们今天一起练习吧。';
      case 'es':
        return '¡Hola! Vamos a practicar juntos hoy.';
      case 'fr':
        return 'Bonjour ! Entraînons-nous ensemble aujourd’hui.';
      case 'de':
        return 'Hallo! Lass uns heute zusammen üben.';
      case 'it':
        return 'Ciao! Oggi ci alleniamo insieme.';
      case 'pt':
        return 'Olá! Vamos praticar juntos hoje.';
      case 'ru':
        return 'Привет! Давай сегодня позанимаемся вместе.';
      case 'ar':
        return 'مرحبا! لنتدرب معا اليوم.';
      case 'hi':
        return 'नमस्ते! आइए आज साथ में अभ्यास करें।';
      case 'tr':
        return 'Merhaba! Bugün birlikte çalışalım.';
      default:
        return 'Hello! Let’s practise speaking together today.';
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _runDiagnostics(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final LlmService llm = ref.read(llmServiceProvider);
    if (!llm.isLoaded) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Download and load a model first.')),
      );
      return;
    }
    messenger.showSnackBar(
      const SnackBar(content: Text('Running the engine report and benchmark…')),
    );
    try {
      final Map<String, Object?> report = await llm.deviceReport();
      final String benchmark = await llm.benchmark();
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Device report'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final MapEntry<String, Object?> entry in report.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${entry.key}: ${entry.value}',
                      style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
                    ),
                  ),
                const Divider(height: 20),
                Text(
                  benchmark,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.secondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } on LlmException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  void _showLog(BuildContext context) {
    final List<String> lines = Log.history.reversed.take(120).toList();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      builder: (BuildContext context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: <Widget>[
                  Text('Engine log', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  Text('${lines.length} lines',
                      style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                itemCount: lines.length,
                itemBuilder: (BuildContext context, int index) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: SelectableText(
                    lines[index],
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                      color: AppColors.textSecondary,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _eraseData(BuildContext context, WidgetRef ref) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Erase all learning data?'),
        content: const Text(
          'Sessions, grammar feedback, the vocabulary bank and your stats will be '
          'deleted permanently. Downloaded model files stay on the device.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Erase', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await ref.read(databaseServiceProvider).wipeEverything();
    ref.invalidateHistoryProviders();
    ref.invalidate(vocabularyProvider);
    await ref.read(profileProvider.notifier).setStreak(0);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('All learning data erased.')));
    }
  }

  Future<void> _deleteModels(BuildContext context, WidgetRef ref) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete downloaded model files?'),
        content: const Text(
          'The GGUF weights will be removed from this device. You can download '
          'them again at any time. Conversations and vocabulary are not touched.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final LlmService llm = ref.read(llmServiceProvider);
    final LearnerProfile profile = ref.read(profileProvider);
    if (profile.selectedModelId.isNotEmpty && !profile.isCustomModel) {
      await llm.downloader.deleteModel(profile.selectedModelId);
    }
    await llm.downloader.deleteModel('custom');
    await llm.downloader.clearPartialFiles();
    await ref.read(tutorControllerProvider.notifier).unloadModel();
    ref.invalidate(installedModelsProvider);
    ref.invalidate(modelStorageProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Model files deleted.')));
    }
  }
}

/// Re-exported so the settings screen can show the language of the chosen voice
/// without importing the language model layer everywhere.
extension LanguageLabel on AppLanguage {
  String get shortLabel => '$flag $englishName';
}
