import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:k100/core/constants.dart';
import 'package:k100/core/theme.dart';
import 'package:k100/models/language.dart';
import 'package:k100/models/learner_profile.dart';
import 'package:k100/models/model_catalog.dart';
import 'package:k100/models/tutor_state.dart';
import 'package:k100/providers/app_providers.dart';
import 'package:k100/ui/screens/home_screen.dart';
import 'package:k100/ui/widgets/model_card.dart';

/// Onboarding (three steps) and the model manager.
///
/// Step 1 – who speaks what. Step 2 – how much support the tutor should give.
/// Step 3 – the one-time GGUF download, which is the **only** moment this app
/// ever needs the network.
///
/// The same screen doubles as the model manager: opened from Settings it starts
/// at step 3, shows a close button instead of a progress header, and pops instead
/// of replacing the navigator stack.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({
    super.key,
    this.isOnboarding = true,
    this.initialStep = 0,
  });

  final bool isOnboarding;
  final int initialStep;

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  static const int _stepCount = 3;

  late int _step = widget.initialStep.clamp(0, _stepCount - 1);
  bool _showAllNatives = false;
  bool _showAllTargets = false;
  bool _customUrlExpanded = false;
  bool _finishing = false;
  late final TextEditingController _urlController = TextEditingController(
    text: ref.read(profileProvider).customModelUrl ?? '',
  );
  late final TextEditingController _nameController = TextEditingController(
    text: ref.read(profileProvider).customModelName ?? '',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(tutorControllerProvider.notifier).bootstrap();
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  bool get _isLastStep => _step == _stepCount - 1;

  LearnerProfile get _profile => ref.watch(profileProvider);

  // ── Navigation ────────────────────────────────────────────────────────────

  Future<void> _next() async {
    if (_step < _stepCount - 1) {
      setState(() => _step++);
      return;
    }
    await _finish();
  }

  void _back() {
    if (_step > 0) {
      setState(() => _step--);
    } else if (!widget.isOnboarding) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    try {
      final LearnerProfile profile = _profile;
      if (profile.selectedModelId.isEmpty && !profile.isCustomModel) {
        // Nothing chosen yet: fall back to the recommended model so the learner
        // is never dropped into a dead app.
        await ref
            .read(profileProvider.notifier)
            .setModelId(ModelCatalog.recommended.id);
      }
      await ref.read(profileProvider.notifier).markOnboarded();
      await ref.read(tutorControllerProvider.notifier).bootstrap();

      if (!mounted) return;
      if (widget.isOnboarding) {
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const HomeScreen()),
        );
      } else {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) setState(() => _finishing = false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final LearnerProfile profile = _profile;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.screenGradient),
        child: SafeArea(
          child: Column(
            children: <Widget>[
              _header(theme, profile),
              if (widget.isOnboarding) _stepper(theme),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: switch (_step) {
                    0 => _languageStep(theme, profile),
                    1 => _levelStep(theme, profile),
                    _ => _modelStep(theme, profile),
                  },
                ),
              ),
              _footer(theme, profile),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, LearnerProfile profile) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
      child: Row(
        children: <Widget>[
          if (!widget.isOnboarding && _step == 0)
            IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close),
            )
          else
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                gradient: AppColors.auraGradient,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.school_outlined, color: Color(0xFF0B0D14)),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  widget.isOnboarding ? 'Welcome to ${AppConfig.appName}' : 'Model manager',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 2),
                Text(
                  widget.isOnboarding
                      ? 'Three quick questions, then you can start speaking.'
                      : '${profile.targetLanguage.flag} ${profile.targetLanguage.englishName} · '
                          '${profile.proficiency.label}',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepper(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
      child: Row(
        children: List<Widget>.generate(_stepCount, (int index) {
          final bool done = index < _step;
          final bool active = index == _step;
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: index == _stepCount - 1 ? 0 : 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    height: 4,
                    decoration: BoxDecoration(
                      color: done || active ? AppColors.primary : AppColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    switch (index) {
                      0 => 'Languages',
                      1 => 'Level',
                      _ => 'Model',
                    },
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: active ? AppColors.textPrimary : AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _footer(ThemeData theme, LearnerProfile profile) {
    final bool canContinue = switch (_step) {
      0 => !profile.isSameLanguagePair,
      1 => true,
      _ => profile.hasModel,
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
      child: Column(
        children: <Widget>[
          if (_step == 0 && profile.isSameLanguagePair)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Pick two different languages — the tutor explains new words in '
                'your native language.',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(color: AppColors.warning),
              ),
            ),
          Row(
            children: <Widget>[
              if (_step > 0 || !widget.isOnboarding)
                Expanded(
                  child: OutlinedButton(
                    onPressed: _finishing ? null : _back,
                    child: const Text('Back'),
                  ),
                ),
              if (_step > 0 || !widget.isOnboarding) const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: (!canContinue || _finishing) ? null : _next,
                  icon: _finishing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(_isLastStep ? Icons.check : Icons.arrow_forward, size: 18),
                  label: Text(
                    _isLastStep
                        ? (widget.isOnboarding ? 'Start practising' : 'Done')
                        : 'Continue',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  STEP 1 — LANGUAGES
  // ══════════════════════════════════════════════════════════════════════════

  Widget _languageStep(ThemeData theme, LearnerProfile profile) {
    final List<AppLanguage> natives = _showAllNatives
        ? Languages.recommendedNatives
        : Languages.recommendedNatives.take(5).toList();
    final List<AppLanguage> targets = _showAllTargets
        ? Languages.all
        : Languages.recommendedTargets;

    return ListView(
      key: const ValueKey<String>('step-languages'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: <Widget>[
        _sectionTitle(theme, 'I speak', 'Explanations and translations use this language.'),
        _languageWrap(
          natives,
          selected: profile.nativeLanguage,
          onPick: (AppLanguage value) async {
            await ref.read(profileProvider.notifier).setLanguages(
                  native: value,
                  target: profile.targetLanguage,
                );
          },
        ),
        TextButton(
          onPressed: () => setState(() => _showAllNatives = !_showAllNatives),
          child: Text(_showAllNatives ? 'Show fewer' : 'Show all ${Languages.all.length} languages'),
        ),
        const SizedBox(height: 10),
        _sectionTitle(theme, 'I want to learn', 'The tutor speaks and corrects in this language.'),
        _languageWrap(
          targets,
          selected: profile.targetLanguage,
          onPick: (AppLanguage value) async {
            final AppLanguage native = value.code == profile.nativeLanguage.code
                ? Languages.sensibleNativeFor(value)
                : profile.nativeLanguage;
            await ref.read(profileProvider.notifier).setLanguages(
                  native: native,
                  target: value,
                );
          },
        ),
        TextButton(
          onPressed: () => setState(() => _showAllTargets = !_showAllTargets),
          child: Text(_showAllTargets ? 'Show fewer' : 'Browse all ${Languages.all.length} languages'),
        ),
        const SizedBox(height: 14),
        if (profile.targetLanguage.needsRomanization)
          _note(
            theme,
            Icons.translate,
            'Because ${profile.targetLanguage.englishName} uses '
            '${profile.targetLanguage.script.label}, replies also include a '
            'romanisation line so you can read what you just heard.',
          ),
        if (!Languages.hasGoodVoiceCoverage(profile.targetLanguage))
          _note(
            theme,
            Icons.volume_up_outlined,
            'Android may not ship a ${profile.targetLanguage.englishName} voice by '
            'default. If the tutor stays silent, install one in Android settings → '
            'Text-to-speech.',
            warning: true,
          ),
      ],
    );
  }

  Widget _languageWrap(
    List<AppLanguage> languages, {
    required AppLanguage selected,
    required Future<void> Function(AppLanguage) onPick,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: languages.map((AppLanguage language) {
        final bool isSelected = language.code == selected.code;
        return GestureDetector(
          onTap: () => onPick(language),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: isSelected
                  ? AppColors.primary.withValues(alpha: 0.18)
                  : AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected ? AppColors.primary : AppColors.outline,
                width: isSelected ? 1.4 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(language.flag, style: const TextStyle(fontSize: 15)),
                const SizedBox(width: 7),
                Text(
                  language.englishName,
                  style: TextStyle(
                    color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  language.nativeName,
                  style: const TextStyle(color: AppColors.textTertiary, fontSize: 11),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  STEP 2 — LEVEL
  // ══════════════════════════════════════════════════════════════════════════

  Widget _levelStep(ThemeData theme, LearnerProfile profile) {
    return ListView(
      key: const ValueKey<String>('step-level'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: <Widget>[
        _sectionTitle(theme, 'How confident are you?',
            'You can change this at any time in Settings.'),
        ...ProficiencyLevel.values.map((ProficiencyLevel level) {
          final bool selected = level == profile.proficiency;
          return GestureDetector(
            onTap: () => ref.read(profileProvider.notifier).setLevel(level),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: selected ? AppColors.primary : AppColors.outline,
                  width: selected ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? AppColors.primary : Colors.transparent,
                      border: Border.all(
                        color: selected ? AppColors.primary : AppColors.outline,
                        width: 1.6,
                      ),
                    ),
                    child: selected
                        ? const Icon(Icons.check, size: 13, color: Color(0xFF0B0D14))
                        : null,
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Text(level.label, style: theme.textTheme.titleMedium),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceHigh,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                level.cefr,
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Text(
                          level.description,
                          style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 6),
        _note(
          theme,
          Icons.speed,
          'Speaking pace follows the level: '
          '${(ProficiencyLevel.beginner.speechRate * 100).round()}% for beginners up to '
          '${(ProficiencyLevel.advanced.speechRate * 100).round()}% for advanced learners.',
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  STEP 3 — MODEL
  // ══════════════════════════════════════════════════════════════════════════

  Widget _modelStep(ThemeData theme, LearnerProfile profile) {
    final AsyncValue<Set<String>> installed = ref.watch(installedModelsProvider);
    final Set<String> installedIds = installed.asData?.value ?? <String>{};
    final ModelEntry? selected = ref.watch(selectedModelProvider);
    final TutorRuntimeState runtime = ref.watch(tutorControllerProvider);

    return ListView(
      key: const ValueKey<String>('step-model'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: <Widget>[
        _sectionTitle(
          theme,
          'Download a language model',
          'The model is a file, not an account: it is stored inside the app and '
          'used offline. Nothing is uploaded, ever.',
        ),
        const StorageSummary(),
        const SizedBox(height: 12),
        if (runtime.engineLoading)
          _loadBanner(theme, runtime.engineLoadProgress, runtime.modelDisplayName),
        if (runtime.errorMessage != null && !runtime.engineLoading)
          _note(theme, Icons.error_outline, runtime.errorMessage!, warning: true),
        if (installedIds.isNotEmpty && !profile.hasModel)
          _note(theme, Icons.info_outline,
              'You already have a model on this device. Tap "Use this model" on it.'),
        ...ModelCatalog.all.map((ModelEntry entry) {
          return ModelCard(
            entry: entry,
            isSelected: profile.selectedModelId == entry.id,
            isInstalled: installedIds.contains(entry.id),
            onSelect: (ModelEntry value) async {
              await ref.read(profileProvider.notifier).setModelId(value.id);
              await ref.read(tutorControllerProvider.notifier).onModelInstalled();
            },
            onInstalled: (ModelEntry value) async {
              await ref.read(profileProvider.notifier).setModelId(value.id);
              await ref.read(tutorControllerProvider.notifier).onModelInstalled();
            },
          );
        }),
        const SizedBox(height: 6),
        _customUrlSection(theme, profile),
        const SizedBox(height: 16),
        _note(
          theme,
          Icons.lock_outline,
          'Sizes are the real files on the Hugging Face Hub. The download is '
          'resumable, checksum-verified and can be paused at any time.',
        ),
        if (selected != null && installedIds.contains(selected.id))
          _note(
            theme,
            Icons.check_circle_outline,
            '${selected.displayName} is ready on this device.',
          ),
      ],
    );
  }

  Widget _loadBanner(ThemeData theme, double progress, String name) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 1.8),
              ),
              const SizedBox(width: 9),
              Text(
                'Loading ${name.isEmpty ? 'the model' : name} into memory…',
                style: theme.textTheme.labelLarge,
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress > 0 ? progress : null,
              minHeight: 5,
              backgroundColor: AppColors.surfaceHigh,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'This happens once per app launch and takes a few seconds. '
            'The screen stays responsive.',
            style: theme.textTheme.labelSmall?.copyWith(height: 1.35),
          ),
        ],
      ),
    );
  }

  Widget _customUrlSection(ThemeData theme, LearnerProfile profile) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        children: <Widget>[
          InkWell(
            onTap: () => setState(() => _customUrlExpanded = !_customUrlExpanded),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.link, size: 18, color: AppColors.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('Use your own GGUF file', style: theme.textTheme.labelLarge),
                        const SizedBox(height: 2),
                        Text(
                          profile.customModelUrl == null
                              ? 'Paste a direct link to any GGUF on the internet'
                              : 'Currently: ${profile.customModelName ?? profile.customModelUrl}',
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _customUrlExpanded ? Icons.expand_less : Icons.expand_more,
                    color: AppColors.textTertiary,
                  ),
                ],
              ),
            ),
          ),
          if (_customUrlExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextField(
                    controller: _urlController,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'GGUF URL',
                      hintText: 'https://huggingface.co/…/model-q4_k_m.gguf',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Display name (optional)',
                      hintText: 'My fine-tuned model',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () async {
                            final String url = _urlController.text.trim();
                            if (url.isEmpty || !url.startsWith('http')) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Paste a full https:// link to a .gguf file'),
                                ),
                              );
                              return;
                            }
                            final String name = _nameController.text.trim();
                            await ref.read(profileProvider.notifier).setCustomModel(
                                  url: url,
                                  name: name.isEmpty
                                      ? url.split('/').last.replaceAll('.gguf', '')
                                      : name,
                                );
                            if (!mounted) return;
                            final ModelEntry entry = ModelCatalog.custom(
                              url: url,
                              name: name.isEmpty ? null : name,
                            );
                            final String? path =
                                await ref.read(llmServiceProvider).downloader.download(entry);
                            if (path != null) {
                              await ref
                                  .read(tutorControllerProvider.notifier)
                                  .onModelInstalled();
                            }
                          },
                          icon: const Icon(Icons.download, size: 16),
                          label: const Text('Download & use'),
                        ),
                      ),
                      if (profile.isCustomModel) ...<Widget>[
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Forget this URL',
                          onPressed: () async {
                            await ref
                                .read(profileProvider.notifier)
                                .setModelId(ModelCatalog.recommended.id);
                            setState(() {});
                          },
                          icon: const Icon(Icons.close, color: AppColors.danger),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Any GGUF llama.cpp can read works. The app guesses the prompt '
                    'template from the file name (ChatML, Gemma or Llama-3). Public '
                    'repositories only — this build has no Hugging Face token.',
                    style: theme.textTheme.labelSmall?.copyWith(height: 1.4),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ── Small pieces ──────────────────────────────────────────────────────────

  Widget _sectionTitle(ThemeData theme, String title, String subtitle) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 3),
            Text(subtitle, style: theme.textTheme.labelSmall?.copyWith(height: 1.4)),
          ],
        ),
      );

  Widget _note(ThemeData theme, IconData icon, String text, {bool warning = false}) {
    final Color color = warning ? AppColors.warning : AppColors.textTertiary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.labelSmall?.copyWith(color: color, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}
