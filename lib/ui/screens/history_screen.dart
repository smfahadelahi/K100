import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:k100/core/theme.dart';
import 'package:k100/models/chat_message.dart';
import 'package:k100/models/scenario.dart';
import 'package:k100/providers/app_providers.dart';
import 'package:k100/ui/screens/chat_tutor_screen.dart';

/// Every past practice session, newest first, with the full transcript one tap
/// away. Stored locally in SQLite; nothing is uploaded.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<List<PracticeSession>> sessions = ref.watch(sessionsProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Practice history'),
        automaticallyImplyLeading: false,
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(sessionsProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: sessions.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not read your history: $error',
              style: theme.textTheme.labelSmall,
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (List<PracticeSession> items) {
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(30),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    const Icon(Icons.history, size: 40, color: AppColors.textTertiary),
                    const SizedBox(height: 14),
                    Text('No sessions yet', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      'Every conversation you have with K100 is stored on this '
                      'device only. Finish one session and it will appear here.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(height: 1.5),
                    ),
                  ],
                ),
              ),
            );
          }

          final int totalMinutes = items.fold<int>(
            0,
            (int sum, PracticeSession s) => sum + s.minutesSpent,
          );

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: <Widget>[
              Text(
                '${items.length} sessions · $totalMinutes minutes of speaking',
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(height: 12),
              ...items.map((PracticeSession session) => _SessionTile(session: session)),
            ],
          );
        },
      ),
    );
  }
}

class _SessionTile extends ConsumerWidget {
  const _SessionTile({required this.session});

  final PracticeSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final LessonScenario scenario = Scenarios.byId(session.scenarioId);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _SessionDetailScreen(session: session),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: AppTheme.card(),
          child: Row(
            children: <Widget>[
              Text(scenario.emoji, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(session.scenarioTitle, style: theme.textTheme.labelLarge),
                    const SizedBox(height: 3),
                    Text(
                      '${_relativeDate(session.startedAt)} · ${session.durationLabel} · '
                      '${session.messageCount} messages',
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
              if (session.avgScore > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.scoreColor(session.avgScore.round())
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    session.avgScore.round().toString(),
                    style: TextStyle(
                      color: AppTheme.scoreColor(session.avgScore.round()),
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right, color: AppColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }

  static String _relativeDate(DateTime date) {
    final Duration age = DateTime.now().difference(date);
    if (age.inMinutes < 1) return 'just now';
    if (age.inHours < 1) return '${age.inMinutes} min ago';
    if (age.inDays < 1) return '${age.inHours} h ago';
    if (age.inDays == 1) return 'yesterday';
    if (age.inDays < 30) return '${age.inDays} days ago';
    return '${date.year}-${_two(date.month)}-${_two(date.day)}';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}

class _SessionDetailScreen extends ConsumerWidget {
  const _SessionDetailScreen({required this.session});

  final PracticeSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final int? id = session.id;
    final AsyncValue<List<ChatMessage>> messages = id == null
        ? const AsyncValue<List<ChatMessage>>.data(<ChatMessage>[])
        : ref.watch(sessionMessagesProvider(id));

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(session.scenarioTitle),
        actions: <Widget>[
          IconButton(
            tooltip: 'Practise this scenario again',
            onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute<void>(
                builder: (_) => ChatTutorScreen(
                  scenario: Scenarios.byId(session.scenarioId),
                ),
              ),
            ),
            icon: const Icon(Icons.replay),
          ),
          IconButton(
            tooltip: 'Delete this session',
            onPressed: () async {
              final bool? confirmed = await showDialog<bool>(
                context: context,
                builder: (BuildContext context) => AlertDialog(
                  backgroundColor: AppColors.surface,
                  title: const Text('Delete this session?'),
                  content: const Text(
                    'The transcript and its grammar feedback will be removed from '
                    'this device permanently.',
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
              if (confirmed != true || id == null) return;
              await ref.read(databaseServiceProvider).deleteSession(id);
              ref.invalidateHistoryProviders();
              if (context.mounted) Navigator.of(context).pop();
            },
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: messages.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stack) => Center(child: Text('$error')),
        data: (List<ChatMessage> items) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: <Widget>[
            _summary(theme),
            const Divider(height: 24),
            ...items.map((ChatMessage message) => _TranscriptRow(message: message)),
          ],
        ),
      ),
    );
  }

  Widget _summary(ThemeData theme) => Row(
        children: <Widget>[
          _stat(theme, 'Duration', session.durationLabel),
          _stat(theme, 'Messages', '${session.messageCount}'),
          _stat(
            theme,
            'Avg. score',
            session.avgScore > 0 ? session.avgScore.round().toString() : '—',
          ),
        ],
      );

  Widget _stat(ThemeData theme, String label, String value) => Expanded(
        child: Column(
          children: <Widget>[
            Text(label, style: theme.textTheme.labelSmall),
            const SizedBox(height: 3),
            Text(value, style: theme.textTheme.titleMedium),
          ],
        ),
      );
}

class _TranscriptRow extends StatelessWidget {
  const _TranscriptRow({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isUser = message.isUser;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            isUser ? 'YOU' : 'K100',
            style: theme.textTheme.labelSmall?.copyWith(
              color: isUser ? AppColors.accent : AppColors.primary,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 4),
          Text(message.text, style: theme.textTheme.bodyLarge),
          if ((message.translation ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                message.translation!,
                style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textTertiary),
              ),
            ),
          if (isUser && message.hasCorrection)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  Flexible(
                    child: Text(
                      '✓ ${message.correction}',
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.secondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (isUser && message.hasExplanation)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                message.explanation!,
                textAlign: TextAlign.right,
                style: theme.textTheme.labelSmall?.copyWith(height: 1.4),
              ),
            ),
        ],
      ),
    );
  }
}
