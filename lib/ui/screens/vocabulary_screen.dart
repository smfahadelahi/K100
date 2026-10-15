import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:k100/core/theme.dart';
import 'package:k100/models/chat_message.dart';
import 'package:k100/models/learner_profile.dart';
import 'package:k100/providers/app_providers.dart';

/// The vocabulary bank. Phrases are mined automatically from each reply
/// (`key_phrase`), so the learner builds a personal word list just by talking.
///
/// Review uses a Leitner schedule: a correct recall lengthens the interval
/// (10 min → 1 day → 3 → 7 → 14 → 30), a miss drops two levels.
class VocabularyScreen extends ConsumerWidget {
  const VocabularyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final LearnerProfile profile = ref.watch(profileProvider);
    final AsyncValue<List<VocabularyItem>> entries =
        ref.watch(vocabularyProvider(profile.targetLanguage.code));

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Vocabulary bank'),
        automaticallyImplyLeading: false,
      ),
      body: entries.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stack) => Center(
          child: Text('Could not open the vocabulary bank: $error'),
        ),
        data: (List<VocabularyItem> items) {
          if (items.isEmpty) return _empty(theme, profile);

          final List<VocabularyItem> due =
              items.where((VocabularyItem item) => item.isDue).toList();
          final int mastered =
              items.where((VocabularyItem item) => item.strength >= 4).length;

          return Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  children: <Widget>[
                    _stat(theme, '${items.length}', 'phrases'),
                    _stat(theme, '${due.length}', 'due now'),
                    _stat(theme, '$mastered', 'mastered'),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: due.isEmpty
                            ? null
                            : () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => _ReviewScreen(entries: due),
                                  ),
                                ),
                        icon: const Icon(Icons.school_outlined, size: 18),
                        label: Text(
                          due.isEmpty ? 'Nothing due — nicely done' : 'Review ${due.length}',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                  itemCount: items.length,
                  itemBuilder: (BuildContext context, int index) => _VocabTile(
                    item: items[index],
                    onDelete: () async {
                      final int? id = items[index].id;
                      if (id == null) return;
                      await ref.read(databaseServiceProvider).deleteVocabulary(id);
                      ref.invalidate(vocabularyProvider);
                      ref.invalidate(dataCountsProvider);
                    },
                    onSpeak: () =>
                        ref.read(ttsServiceProvider).speak(items[index].term),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _empty(ThemeData theme, LearnerProfile profile) => Center(
        child: Padding(
          padding: const EdgeInsets.all(30),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(Icons.menu_book_outlined, size: 42, color: AppColors.textTertiary),
              const SizedBox(height: 14),
              Text('Your word list is empty', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                'Every reply from the tutor carries one useful phrase in '
                '${profile.targetLanguage.englishName}. They land here automatically '
                'so you can review them later.',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(height: 1.5),
              ),
            ],
          ),
        ),
      );

  Widget _stat(ThemeData theme, String value, String label) => Expanded(
        child: Column(
          children: <Widget>[
            Text(value, style: theme.textTheme.titleLarge),
            const SizedBox(height: 2),
            Text(label, style: theme.textTheme.labelSmall),
          ],
        ),
      );
}

class _VocabTile extends StatelessWidget {
  const _VocabTile({required this.item, required this.onDelete, required this.onSpeak});

  final VocabularyItem item;
  final Future<void> Function() onDelete;
  final Future<void> Function() onSpeak;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: AppTheme.card(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(item.term, style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: 'Hear it',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onSpeak(),
                  icon: const Icon(Icons.volume_up_outlined, size: 18),
                ),
                IconButton(
                  tooltip: 'Remove',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onDelete(),
                  icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.textTertiary),
                ),
              ],
            ),
            if ((item.translation ?? '').isNotEmpty)
              Text(item.translation!, style: theme.textTheme.bodySmall),
            if ((item.example ?? '').isNotEmpty) ...<Widget>[
              const SizedBox(height: 7),
              Text(
                item.example!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(height: 1.4),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                _strength(item.strength),
                const SizedBox(width: 10),
                Text(
                  item.isDue ? 'Ready for review' : 'Next review scheduled',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: item.isDue ? AppColors.accent : AppColors.textTertiary,
                  ),
                ),
                const Spacer(),
                if (item.timesReviewed > 0)
                  Text(
                    '${item.timesCorrect}/${item.timesReviewed} correct',
                    style: theme.textTheme.labelSmall,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _strength(int value) => Row(
        children: List<Widget>.generate(5, (int index) {
          final bool filled = index < value;
          return Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(right: 3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: filled ? AppColors.secondary : AppColors.outline,
            ),
          );
        }),
      );
}

/// Flashcards: recall first, then reveal, then grade honestly. The grade feeds
/// the Leitner interval.
class _ReviewScreen extends ConsumerStatefulWidget {
  const _ReviewScreen({required this.entries});

  final List<VocabularyItem> entries;

  @override
  ConsumerState<_ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<_ReviewScreen> {
  late final List<VocabularyItem> _queue = List<VocabularyItem>.from(widget.entries);
  int _index = 0;
  bool _revealed = false;
  int _remembered = 0;

  bool get _finished => _index >= _queue.length;

  Future<void> _grade(bool remembered) async {
    final VocabularyItem item = _queue[_index];
    if (item.id != null) {
      await ref
          .read(databaseServiceProvider)
          .reviewVocabulary(item.id!, remembered: remembered);
    }
    setState(() {
      if (remembered) _remembered++;
      _index++;
      _revealed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (_finished) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: const Text('Review complete')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Icon(Icons.check_circle, size: 52, color: AppColors.secondary),
                const SizedBox(height: 16),
                Text(
                  '$_remembered of ${_queue.length} recalled',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  'Phrases you missed come back sooner.',
                  style: theme.textTheme.labelSmall,
                ),
                const SizedBox(height: 22),
                FilledButton(
                  onPressed: () {
                    ref.invalidate(vocabularyProvider);
                    Navigator.of(context).pop();
                  },
                  child: const Text('Done'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final VocabularyItem item = _queue[_index];
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text('Card ${_index + 1} of ${_queue.length}')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: <Widget>[
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _revealed = !_revealed),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        item.term,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 6),
                      IconButton(
                        onPressed: () => ref.read(ttsServiceProvider).speak(item.term),
                        icon: const Icon(Icons.volume_up_outlined),
                      ),
                      const SizedBox(height: 12),
                      if (_revealed) ...<Widget>[
                        Text(
                          item.translation ?? '—',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(color: AppColors.secondary),
                        ),
                        if ((item.example ?? '').isNotEmpty) ...<Widget>[
                          const SizedBox(height: 16),
                          Text(
                            item.example!,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: AppColors.textTertiary, height: 1.4),
                          ),
                        ],
                      ] else
                        Text('Tap to reveal', style: theme.textTheme.labelSmall),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: _revealed ? () => _grade(false) : null,
                    child: const Text('Not yet'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _revealed ? () => _grade(true) : null,
                    child: const Text('Got it'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
