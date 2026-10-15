import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:k100/core/constants.dart';
import 'package:k100/core/logger.dart';
import 'package:k100/core/theme.dart';
import 'package:k100/models/model_catalog.dart';
import 'package:k100/providers/app_providers.dart';
import 'package:k100/services/llm_service.dart';

/// One catalogue row: what the model is, whether it fits this phone, and the
/// complete download lifecycle (resolve → download → pause → resume → verify →
/// delete) driven by the single progress stream in [downloadProgressProvider].
class ModelCard extends ConsumerStatefulWidget {
  const ModelCard({
    super.key,
    required this.entry,
    required this.isSelected,
    required this.isInstalled,
    this.onSelect,
    this.onInstalled,
    this.allowDelete = true,
  });

  final ModelEntry entry;

  /// Currently chosen model for the learner's profile.
  final bool isSelected;

  /// Weights present on disk.
  final bool isInstalled;

  final Future<void> Function(ModelEntry entry)? onSelect;

  /// Fired after a successful download (the caller loads it into the engine).
  final Future<void> Function(ModelEntry entry)? onInstalled;

  final bool allowDelete;

  @override
  ConsumerState<ModelCard> createState() => _ModelCardState();
}

class _ModelCardState extends ConsumerState<ModelCard> {
  bool _expanded = false;
  bool _busy = false;

  ModelEntry get entry => widget.entry;

  LlmService get _llm => ref.read(llmServiceProvider);

  bool get _fitsDevice {
    // Platform.numberOfProcessors is not RAM; the real gate is the minRamMb hint
    // in the catalogue, which the user can read. We only flag the very large
    // models on the setup screen, so nothing is hidden — just labelled.
    return true;
  }

  Future<void> _download() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ModelCatalogService catalog = ref.read(modelCatalogServiceProvider);
      // Ask the Hub for the exact size + sha256 first: the progress bar and the
      // integrity check both depend on it.
      final ModelFileInfo? info = await catalog.resolve(entry);
      final String? path = await _llm.downloader.download(entry, resolvedFile: info);
      if (!mounted) return;
      if (path != null) {
        ref.invalidate(installedModelsProvider);
        ref.invalidate(modelStorageProvider);
        await widget.onInstalled?.call(entry);
      }
    } catch (error, stack) {
      Log.error('Download failed for ${entry.id}', error, stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Delete ${entry.displayName}?'),
        content: Text(
          'The ${entry.sizeLabel} file will be removed from this device. '
          'You can download it again at any time.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _llm.downloader.deleteModel(entry.id);
    ref.invalidate(installedModelsProvider);
    ref.invalidate(modelStorageProvider);
    if (entry.id == ref.read(profileProvider).selectedModelId) {
      await _llm.unload();
      ref.invalidate(tutorControllerProvider);
    }
  }

  Future<void> _select() async {
    await widget.onSelect?.call(entry);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${entry.displayName} selected')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<DownloadProgress> progressAsync =
        ref.watch(downloadProgressProvider);
    final DownloadProgress? progress = progressAsync.asData?.value;
    final DownloadProgress own =
        (progress != null && progress.modelId == entry.id)
            ? progress
            : DownloadProgress.idle(entry.id);

    final bool downloading = own.status == DownloadStatus.downloading ||
        own.status == DownloadStatus.resolving ||
        own.status == DownloadStatus.verifying;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: widget.isSelected
              ? AppColors.primary.withValues(alpha: 0.65)
              : (entry.recommended ? AppColors.secondary.withValues(alpha: 0.35) : AppColors.outline),
          width: widget.isSelected ? 1.4 : 1,
        ),
      ),
      child: Column(
        children: <Widget>[
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Flexible(
                                  child: Text(
                                    entry.displayName,
                                    style: theme.textTheme.titleMedium,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (entry.recommended) ...<Widget>[
                                  const SizedBox(width: 8),
                                  _Badge(
                                    text: 'RECOMMENDED',
                                    color: AppColors.secondary,
                                  ),
                                ],
                                if (widget.isInstalled) ...<Widget>[
                                  const SizedBox(width: 6),
                                  _Badge(text: 'ON DEVICE', color: AppColors.accent),
                                ],
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${entry.parameters} · ${entry.quant} · ${entry.sizeLabel} · '
                              '${entry.license}',
                              style: theme.textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        color: AppColors.textTertiary,
                      ),
                    ],
                  ),
                  if (_expanded) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(
                      entry.description,
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: _Meter(
                            label: 'Language quality',
                            value: entry.qualityScore / 5,
                            color: AppColors.primary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _Meter(
                            label: 'Speed',
                            value: entry.speedScore / 5,
                            color: AppColors.secondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        _InfoChip(icon: Icons.memory, text: entry.minRamLabel),
                        _InfoChip(
                          icon: Icons.data_object,
                          text: '${entry.family.label} template',
                        ),
                        _InfoChip(
                          icon: Icons.article_outlined,
                          text: 'ctx ${entry.contextWindow}',
                        ),
                        _InfoChip(
                          icon: Icons.tag,
                          text: entry.fileName,
                        ),
                      ],
                    ),
                    if (!_fitsDevice) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        'This model needs about ${entry.minRamLabel}. It will run, '
                        'but expect slower replies on smaller phones.',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: AppColors.warning),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          if (downloading || own.status == DownloadStatus.paused || own.hasFailed)
            _ProgressPanel(
              progress: own,
              onPause: () => _llm.downloader.pause(),
              onResume: _download,
              onCancel: () async {
                await _llm.downloader.cancel();
              },
              onRetry: _download,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Row(
              children: <Widget>[
                if (!widget.isInstalled)
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy || downloading ? null : _download,
                      icon: const Icon(Icons.download_for_offline_outlined, size: 18),
                      label: Text(
                        own.status == DownloadStatus.paused
                            ? 'Resume (${formatBytes(own.received)})'
                            : 'Download ${entry.sizeLabel}',
                      ),
                    ),
                  ),
                if (widget.isInstalled)
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: widget.isSelected ? null : _select,
                      icon: Icon(
                        widget.isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                        size: 18,
                      ),
                      label: Text(widget.isSelected ? 'Selected' : 'Use this model'),
                    ),
                  ),
                if (widget.allowDelete && (widget.isInstalled || own.received > 0)) ...<Widget>[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Delete the downloaded file',
                    onPressed: _busy ? null : _delete,
                    icon: const Icon(Icons.delete_outline, color: AppColors.danger),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Progress bar with the four controls the brief demands: pause, resume, cancel,
/// and a readable speed/ETA line.
class _ProgressPanel extends StatelessWidget {
  const _ProgressPanel({
    required this.progress,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    required this.onRetry,
  });

  final DownloadProgress progress;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool failed = progress.hasFailed;
    final bool paused = progress.isPaused;
    final Color accent = failed
        ? AppColors.danger
        : paused
            ? AppColors.warning
            : AppColors.primary;

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                failed
                    ? Icons.error_outline
                    : paused
                        ? Icons.pause_circle_outline
                        : Icons.downloading,
                size: 15,
                color: accent,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  failed
                      ? 'Download failed'
                      : paused
                          ? 'Paused'
                          : progress.status.label,
                  style: TextStyle(
                    color: accent,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (!failed)
                Text(
                  progress.percentLabel,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          if (failed) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              progress.error ?? 'Unknown error',
              style: theme.textTheme.labelSmall?.copyWith(height: 1.4),
            ),
          ] else ...<Widget>[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progress.fraction,
                minHeight: 6,
                backgroundColor: AppColors.outline,
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                Text(progress.progressLabel, style: theme.textTheme.labelSmall),
                const Spacer(),
                Text(
                  <String>[
                    progress.speedLabel,
                    progress.etaLabel,
                  ].where((String s) => s.isNotEmpty).join(' · '),
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              if (failed)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Try again'),
                  ),
                )
              else if (paused)
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onResume,
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('Resume'),
                  ),
                )
              else
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onPause,
                    icon: const Icon(Icons.pause, size: 16),
                    label: const Text('Pause'),
                  ),
                ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: onCancel,
                child: const Text('Cancel', style: TextStyle(color: AppColors.danger)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(
          text,
          style: TextStyle(color: color, fontSize: 8.5, fontWeight: FontWeight.w800),
        ),
      );
}

class _Meter extends StatelessWidget {
  const _Meter({required this.label, required this.value, required this.color});

  final String label;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value.clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: AppColors.outline,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      );
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 11, color: AppColors.textTertiary),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 190),
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 10),
              ),
            ),
          ],
        ),
      );
}

/// Warns when the models folder is consuming a lot of the phone's storage.
class StorageSummary extends ConsumerWidget {
  const StorageSummary({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<int> used = ref.watch(modelStorageProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          const Icon(Icons.sd_storage_outlined, size: 14, color: AppColors.textTertiary),
          const SizedBox(width: 6),
          Text(
            'Model storage: ${used.maybeWhen(
              data: (int bytes) => formatBytes(bytes),
              orElse: () => '…',
            )}',
            style: const TextStyle(color: AppColors.textTertiary, fontSize: 11),
          ),
          const Spacer(),
          Text(
            'GGUF files are never bundled in the APK',
            style: TextStyle(color: AppColors.textTertiary.withValues(alpha: 0.7), fontSize: 10),
          ),
        ],
      ),
    );
  }
}

/// Shared helper: the folder the weights live in, shown in the UI for support.
String modelsLocationHint() =>
    '${AppConfig.modelDirectoryName}/ inside the app documents folder';
