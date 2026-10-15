import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fcllama/fllama.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:k100/core/constants.dart';
import 'package:k100/core/logger.dart';
import 'package:k100/models/model_catalog.dart';

// ══════════════════════════════════════════════════════════════════════════════
//  DOWNLOAD LAYER
// ══════════════════════════════════════════════════════════════════════════════

/// Lifecycle of a single model download.
enum DownloadStatus {
  idle('Not downloaded'),
  resolving('Checking the Hub…'),
  downloading('Downloading'),
  paused('Paused'),
  verifying('Verifying'),
  completed('Ready'),
  failed('Failed'),
  cancelled('Cancelled');

  const DownloadStatus(this.label);

  final String label;

  bool get isActive =>
      this == DownloadStatus.downloading ||
      this == DownloadStatus.resolving ||
      this == DownloadStatus.verifying;

  bool get isTerminal => this == DownloadStatus.completed || this == DownloadStatus.failed;
}

/// One progress tick. Immutable so the UI can diff cheaply.
@immutable
class DownloadProgress {
  const DownloadProgress({
    required this.modelId,
    required this.status,
    this.received = 0,
    this.total = 0,
    this.bytesPerSecond = 0,
    this.message = '',
    this.error,
    this.expectedSha256,
    this.verified = false,
  });

  final String modelId;
  final DownloadStatus status;

  /// Bytes on disk (including a resumed `.part` file).
  final int received;

  /// Total bytes, or 0 when unknown (a custom URL without Content-Length).
  final int total;

  final double bytesPerSecond;

  /// Human-readable stage description.
  final String message;

  final String? error;

  final String? expectedSha256;

  /// True once the sha256 in the Hub's LFS metadata matched.
  final bool verified;

  static DownloadProgress idle(String modelId) =>
      DownloadProgress(modelId: modelId, status: DownloadStatus.idle);

  /// 0..1, or null when the total size is not known yet.
  double? get fraction {
    if (total <= 0) return null;
    return (received / total).clamp(0.0, 1.0);
  }

  int get remaining => total > received ? total - received : 0;

  bool get isActive => status.isActive;

  bool get isPaused => status == DownloadStatus.paused;

  bool get hasFailed => status == DownloadStatus.failed;

  bool get isComplete => status == DownloadStatus.completed;

  /// "412 MB / 1.04 GB"
  String get progressLabel => '${formatBytes(received)} / '
      '${total > 0 ? formatBytes(total) : '?'}';

  /// Time left, or null when it cannot be estimated yet.
  Duration? get eta {
    if (bytesPerSecond <= 0 || remaining <= 0) return null;
    final double seconds = remaining / bytesPerSecond;
    if (seconds.isInfinite || seconds.isNaN || seconds > 60 * 60 * 6) return null;
    return Duration(seconds: seconds.round());
  }

  String get speedLabel => bytesPerSecond <= 0
      ? ''
      : '${formatBytes(bytesPerSecond.round())}/s';

  String get etaLabel {
    final Duration? value = eta;
    if (value == null) return '';
    if (value.inSeconds < 60) return '${value.inSeconds}s left';
    if (value.inMinutes < 60) return '${value.inMinutes}m left';
    final int hours = value.inHours;
    final int minutes = value.inMinutes % 60;
    return '${hours}h ${minutes}m left';
  }

  String get percentLabel {
    final double? value = fraction;
    if (value == null) return '';
    return '${(value * 100).toStringAsFixed(value > 0.995 ? 0 : 1)}%';
  }

  DownloadProgress copyWith({
    DownloadStatus? status,
    int? received,
    int? total,
    double? bytesPerSecond,
    String? message,
    String? error,
    bool clearError = false,
    String? expectedSha256,
    bool? verified,
  }) =>
      DownloadProgress(
        modelId: modelId,
        status: status ?? this.status,
        received: received ?? this.received,
        total: total ?? this.total,
        bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
        message: message ?? this.message,
        error: clearError ? null : (error ?? this.error),
        expectedSha256: expectedSha256 ?? this.expectedSha256,
        verified: verified ?? this.verified,
      );

  @override
  String toString() => 'DownloadProgress($modelId, ${status.name}, $percentLabel)';
}

/// Human-readable byte formatting used across the app.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  const int kb = 1024;
  const int mb = kb * 1024;
  const int gb = mb * 1024;
  if (bytes >= gb) {
    final double value = bytes / gb;
    return '${value.toStringAsFixed(value >= 10 ? 1 : 2)} GB';
  }
  if (bytes >= mb) return '${(bytes / mb).round()} MB';
  if (bytes >= kb) return '${(bytes / kb).round()} KB';
  return '$bytes B';
}

/// Downloads GGUF weights from a public URL into the app documents directory.
///
/// Guarantees:
///  * **Resumable.** Bytes are appended to `<file>.part`; a resume issues a
///    `Range: bytes=N-` request and *verifies* it got `206 Partial Content`
///    back. A `200` means the server ignored the range → the partial file is
///    discarded and the download restarts from zero (never corrupt).
///  * **Verified.** The GGUF magic is checked immediately, then the sha256 is
///    computed in a background isolate over the finished file and compared with
///    the Hub's LFS metadata.
///  * **Pausable.** [pause] finishes the current chunk, flushes to disk and
///    leaves the `.part` file in place — no byte is ever lost by pausing.
///  * **Never silent.** Every state change is broadcast on [progressStream].
class ModelDownloader {
  ModelDownloader({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: AppConfig.connectTimeout,
                receiveTimeout: AppConfig.receiveTimeout,
                followRedirects: true,
                validateStatus: (int? status) => status != null && status < 400,
              ),
            );

  final Dio _dio;

  final StreamController<DownloadProgress> _progress =
      StreamController<DownloadProgress>.broadcast();

  DownloadProgress _current = DownloadProgress.idle('');

  CancelToken? _cancelToken;
  bool _paused = false;
  bool _cancelled = false;

  /// The last emitted progress, for widgets that attach mid-download.
  DownloadProgress get current => _current;

  Stream<DownloadProgress> get progressStream => _progress.stream;

  /// True while bytes are being written for [modelId].
  bool isDownloading(String modelId) =>
      _current.modelId == modelId && _current.status.isActive;

  // ── Paths ─────────────────────────────────────────────────────────────────

  /// `<appDocuments>/models/` — created on demand.
  Future<Directory> modelsDirectory() async {
    final Directory documents = await getApplicationDocumentsDirectory();
    final Directory models = Directory('${documents.path}/${AppConfig.modelDirectoryName}');
    if (!await models.exists()) {
      await models.create(recursive: true);
    }
    return models;
  }

  /// Where the weights for [entry] live once the download completes.
  ///
  /// One file name per catalogue id keeps "which model is installed?" a pure
  /// filesystem question — no state to get out of sync.
  Future<String> targetPath(ModelEntry entry) async {
    final Directory models = await modelsDirectory();
    return '${models.path}/${_fileNameFor(entry)}';
  }

  String _fileNameFor(ModelEntry entry) {
    // Keep the real file name (with quant) so a user browsing
    // Android/data/.../files/models can tell what is there.
    final String safeId = entry.fileName.replaceAll(RegExp(r'[/\\]'), '_');
    return safeId.isNotEmpty ? safeId : '${entry.id}.gguf';
  }

  /// Non-async variant for hot paths that already have the directory cached.
  Future<String> partPath(ModelEntry entry) async => '${await targetPath(entry)}.part';

  /// Every model id currently on disk, complete files only.
  Future<Set<String>> installedModelIds() async {
    final Directory models = await modelsDirectory();
    final List<FileSystemEntity> files = await models.list().toList();
    final Set<String> installed = <String>{};
    for (final FileSystemEntity entity in files) {
      if (entity is! File) continue;
      final String name = entity.path.split('/').last;
      if (name.endsWith('.part')) continue;
      if (!name.toLowerCase().endsWith('.gguf')) continue;
      for (final ModelEntry entry in ModelCatalog.all) {
        if (entry.fileName == name) installed.add(entry.id);
      }
    }
    return installed;
  }

  Future<bool> isInstalled(ModelEntry entry) async =>
      File(await targetPath(entry)).exists();

  Future<int> downloadedBytes(ModelEntry entry) async {
    final File file = File(await targetPath(entry));
    if (await file.exists()) return file.length();
    final File part = File('${file.path}.part');
    if (await part.exists()) return part.length();
    return 0;
  }

  /// Total bytes sitting in the models folder (complete + partial).
  Future<int> storageUsed() async {
    final Directory models = await modelsDirectory();
    int total = 0;
    await for (final FileSystemEntity entity in models.list()) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  // ── Control ───────────────────────────────────────────────────────────────

  /// Ask the in-flight download to stop after the current chunk. The `.part`
  /// file stays on disk and is resumed by the next call to [download].
  void pause() {
    if (!_current.status.isActive) return;
    _paused = true;
    _emit(
      _current.copyWith(
        status: DownloadStatus.paused,
        bytesPerSecond: 0,
        message: 'Paused — ${formatBytes(_current.received)} kept on disk',
      ),
    );
    Log.info('Download paused at ${_current.received} bytes');
  }

  /// Abort and delete the partial file.
  Future<void> cancel() async {
    _cancelled = true;
    _cancelToken?.cancel('cancelled by user');
    _emit(
      _current.copyWith(
        status: DownloadStatus.cancelled,
        bytesPerSecond: 0,
        message: 'Cancelled',
      ),
    );
    Log.info('Download cancelled');
  }

  /// Deletes a downloaded model (and any partial file next to it).
  Future<void> deleteModel(String modelId) async {
    final ModelEntry? entry = ModelCatalog.byId(modelId);
    if (entry == null) return;
    final String path = await targetPath(entry);
    for (final String candidate in <String>[path, '$path.part']) {
      final File file = File(candidate);
      if (await file.exists()) {
        await file.delete();
        Log.info('Deleted ${candidate.split('/').last}');
      }
    }
  }

  /// Removes every `.part` file in the models directory.
  Future<void> clearPartialFiles() async {
    final Directory models = await modelsDirectory();
    await for (final FileSystemEntity entity in models.list()) {
      if (entity is File && entity.path.endsWith('.part')) {
        await entity.delete();
      }
    }
  }

  // ── The download itself ───────────────────────────────────────────────────

  /// Downloads [entry] and returns the final path, or null when the download was
  /// paused, cancelled or failed.
  ///
  /// [resolvedFile] carries the Hub's metadata (exact size + LFS sha256) when the
  /// caller already fetched it; otherwise it is looked up here.
  Future<String?> download(
    ModelEntry entry, {
    ModelFileInfo? resolvedFile,
    bool verifyIntegrity = true,
  }) async {
    _paused = false;
    _cancelled = false;

    final String target = await targetPath(entry);
    final File targetFile = File(target);
    final String partPath = '$target.part';
    final File partFile = File(partPath);

    // Already complete? Nothing to do.
    if (await targetFile.exists()) {
      final int length = await targetFile.length();
      if (length > 0) {
        _emit(
          DownloadProgress(
            modelId: entry.id,
            status: DownloadStatus.completed,
            received: length,
            total: length,
            message: 'Already on this device',
          ),
        );
        return target;
      }
      await targetFile.delete();
    }

    _emit(
      DownloadProgress(
        modelId: entry.id,
        status: DownloadStatus.resolving,
        message: 'Preparing download…',
      ),
    );

    // 1. Resolve the real URL, size and hash.
    final Uri uri = _resolveUri(entry);
    ModelFileInfo? info = resolvedFile;
    if (info == null || info.sizeBytes == 0) {
      info = await _resolveMetadata(entry, uri);
    }
    final int expectedTotal = info?.sizeBytes ?? entry.sizeBytes;
    final String? expectedSha = info?.sha256 ?? entry.sha256;

    _emit(
      DownloadProgress(
        modelId: entry.id,
        status: DownloadStatus.downloading,
        received: 0,
        total: expectedTotal,
        expectedSha256: expectedSha,
        message: 'Downloading ${entry.displayName} (${entry.quant})',
      ),
    );

    // 2. Download with resume, in chunks, with retries.
    int received = await partFile.exists() ? await partFile.length() : 0;

    for (int attempt = 1; attempt <= AppConfig.downloadMaxRetries; attempt++) {
      if (_cancelled) return _finishCancelled(partFile);
      if (_paused) return null;

      try {
        received = await _streamInto(
          uri: uri,
          file: partFile,
          startOffset: received,
          modelId: entry.id,
          expectedTotal: expectedTotal,
          attempt: attempt,
        );

        if (_cancelled) return _finishCancelled(partFile);
        if (_paused) return null;

        // A short file means the server closed early — try again with a range.
        if (expectedTotal > 0 && received < expectedTotal) {
          throw _IncompleteDownloadException(received, expectedTotal);
        }
        break;
      } on _IncompleteDownloadException catch (error) {
        Log.warn('Download attempt $attempt incomplete: ${error.received}/${error.expected}');
        if (attempt == AppConfig.downloadMaxRetries) {
          _emitFailed(entry.id, 'Connection kept dropping '
              '(${formatBytes(error.received)} of ${formatBytes(error.expected)} '
              'received). Pause and resume to continue from where it stopped.');
          return null;
        }
        received = await partFile.exists() ? await partFile.length() : 0;
        await Future<void>.delayed(
          AppConfig.downloadRetryBackoff * attempt,
        );
      } on DioException catch (error) {
        if (CancelToken.isCancel(error)) return _finishCancelled(partFile);
        Log.warn('Download attempt $attempt failed', error.message);
        if (attempt == AppConfig.downloadMaxRetries) {
          _emitFailed(entry.id, _friendlyDioMessage(error));
          return null;
        }
        received = await partFile.exists() ? await partFile.length() : 0;
        await Future<void>.delayed(AppConfig.downloadRetryBackoff * attempt);
      } catch (error, stack) {
        Log.error('Unexpected download failure', error, stack);
        _emitFailed(entry.id, 'Unexpected error: $error');
        return null;
      }
    }

    // 3. Move the finished file into place.
    if (!await partFile.exists()) {
      _emitFailed(entry.id, 'The downloaded file disappeared.');
      return null;
    }

    final int finalSize = await partFile.length();
    if (expectedTotal > 0 && finalSize < expectedTotal) {
      _emitFailed(
        entry.id,
        'File is short: ${formatBytes(finalSize)} of ${formatBytes(expectedTotal)}.',
      );
      return null;
    }

    try {
      if (await targetFile.exists()) await targetFile.delete();
      await partFile.rename(target);
    } on FileSystemException catch (error) {
      Log.error('Could not finalise the download', error);
      _emitFailed(
        entry.id,
        error.osError?.errorCode == 28
            ? 'Not enough free storage to finish the download.'
            : 'Could not save the file: ${error.message}',
      );
      return null;
    }

    // 4. Sanity + integrity.
    _emit(
      _currentOr(entry.id).copyWith(
        status: DownloadStatus.verifying,
        received: finalSize,
        total: expectedTotal > 0 ? expectedTotal : finalSize,
        message: 'Verifying the model file…',
      ),
    );

    if (verifyIntegrity) {
      final bool magicOk = await _hasGgufMagic(target);
      if (!magicOk) {
        await File(target).delete();
        _emitFailed(
          entry.id,
          'The downloaded file is not a GGUF model. The URL may have served an '
          'HTML error page — check the link and try again.',
        );
        return null;
      }

      if (expectedSha != null && expectedSha.isNotEmpty) {
        final String actual = await _sha256OfFile(target);
        if (actual != expectedSha) {
          await File(target).delete();
          _emitFailed(
            entry.id,
            'Checksum mismatch — the download was corrupted (or the file on the '
            'Hub changed). Tap download to fetch it again.',
          );
          return null;
        }
      }
    }

    _emit(
      DownloadProgress(
        modelId: entry.id,
        status: DownloadStatus.completed,
        received: finalSize,
        total: finalSize,
        expectedSha256: expectedSha,
        verified: expectedSha != null,
        message: 'Model ready · ${formatBytes(finalSize)}',
      ),
    );
    Log.info('Model ${entry.id} downloaded → $target (${formatBytes(finalSize)})');
    return target;
  }

  Uri _resolveUri(ModelEntry entry) {
    if (entry.isCustom && (entry.customUrl ?? '').isNotEmpty) {
      final Uri? uri = Uri.tryParse(entry.customUrl!);
      if (uri != null && uri.hasScheme) return uri;
    }
    return Uri.parse(AppConfig.resolveUrl(entry.repoId, entry.fileName));
  }

  Future<ModelFileInfo?> _resolveMetadata(ModelEntry entry, Uri uri) async {
    try {
      if (entry.repoId.isNotEmpty && !entry.isCustom) {
        final ModelCatalogService service = ModelCatalogService(dio: _dio);
        return await service.resolve(entry);
      }
      // Custom URL: take the size from a HEAD request when the server offers it.
      final Response<dynamic> head = await _dio.head<dynamic>(uri.toString());
      final Object? length = head.headers.value('content-length');
      final int size = int.tryParse('$length') ?? 0;
      return ModelFileInfo(fileName: entry.fileName, sizeBytes: size);
    } catch (error) {
      Log.warn('Could not resolve model metadata for ${entry.id}', error);
      return null;
    }
  }

  /// Streams the response body into [file], appending to whatever is there.
  /// Returns the total number of bytes now on disk.
  Future<int> _streamInto({
    required Uri uri,
    required File file,
    required int startOffset,
    required String modelId,
    required int expectedTotal,
    required int attempt,
  }) async {
    final CancelToken token = CancelToken();
    _cancelToken = token;

    final Response<ResponseBody> response = await _dio.get<ResponseBody>(
      uri.toString(),
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
        headers: <String, dynamic>{
          if (startOffset > 0) 'Range': 'bytes=$startOffset-',
        },
        receiveTimeout: AppConfig.receiveTimeout,
      ),
      cancelToken: token,
    );

    // A 200 to a ranged request means the server ignored the range: restart.
    int offset = startOffset;
    if (startOffset > 0 && response.statusCode == 200) {
      Log.warn('Server ignored the Range header — restarting the download');
      if (await file.exists()) await file.delete();
      offset = 0;
    }

    int total = expectedTotal;
    final String? contentRange = response.headers.value('content-range');
    if (contentRange != null) {
      final String? rangeTotal = contentRange.split('/').last.trim();
      final int? parsed = int.tryParse(rangeTotal);
      if (parsed != null && parsed > 0) total = parsed;
    } else {
      final String? contentLength = response.headers.value('content-length');
      final int? parsed = int.tryParse('$contentLength');
      if (parsed != null && parsed > 0 && offset == 0) total = parsed;
    }

    final ResponseBody body = response.data!;
    final IOSink sink = file.openWrite(mode: FileMode.append);
    int received = offset;
    final Stopwatch sinceEmit = Stopwatch()..start();
    int bytesSinceEmit = 0;
    final Stopwatch session = Stopwatch()..start();

    try {
      await for (final Uint8List chunk in body.stream) {
        if (_cancelled) {
          throw DioException(requestOptions: response.requestOptions, message: 'cancelled');
        }
        if (_paused) {
          // Flush what we have and leave the partial file for a resume.
          break;
        }
        sink.add(chunk);
        received += chunk.length;
        bytesSinceEmit += chunk.length;

        if (sinceEmit.elapsedMilliseconds >= AppConfig.progressEmitInterval.inMilliseconds) {
          final double elapsed = session.elapsedMilliseconds / 1000.0;
          final double speed = elapsed > 0 ? (received - offset) / elapsed : 0;
          _emit(
            _current.modelId == modelId
                ? _current.copyWith(
                    received: received,
                    total: total,
                    bytesPerSecond: speed,
                    status: DownloadStatus.downloading,
                    message: attempt > 1 ? 'Resuming download (attempt $attempt)' : '',
                  )
                : DownloadProgress(
                    modelId: modelId,
                    status: DownloadStatus.downloading,
                    received: received,
                    total: total,
                    bytesPerSecond: speed,
                  ),
          );
          sinceEmit.reset();
          bytesSinceEmit = 0;
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    if (_paused) {
      _emit(
        _current.copyWith(
          received: received,
          total: total,
          bytesPerSecond: 0,
          status: DownloadStatus.paused,
          message: 'Paused — ${formatBytes(received)} kept on disk',
        ),
      );
      return received;
    }

    // Neither a range nor a length: at least confirm the file grew.
    final int finalLength = await file.length();
    if (total > 0 && finalLength < total) {
      throw _IncompleteDownloadException(finalLength, total);
    }
    return finalLength;
  }

  String _finishCancelled(File partFile) {
    // Fire and forget: the caller has already been told the download is over.
    partFile.delete().ignore();
    return '';
  }

  DownloadProgress _currentOr(String modelId) =>
      _current.modelId == modelId ? _current : DownloadProgress.idle(modelId);

  /// Publishes a progress update: stores it as the current snapshot and pushes it
  /// to [progressStream] listeners.
  void _emit(DownloadProgress progress) {
    _current = progress;
    if (!_progress.isClosed) _progress.add(progress);
  }

  void _emitFailed(String modelId, String message) {
    _emit(
      _currentOr(modelId).copyWith(
        status: DownloadStatus.failed,
        bytesPerSecond: 0,
        error: message,
        message: message,
      ),
    );
    Log.error('Download failed for $modelId: $message');
  }

  String _friendlyDioMessage(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
        return 'The connection timed out. Check your network and tap resume.';
      case DioExceptionType.sendTimeout:
        return 'Upload timed out — unusual for a download. Try again.';
      case DioExceptionType.badResponse:
        final int? status = error.response?.statusCode;
        if (status == 404) {
          return 'File not found on the server (404). The model may have been '
              'renamed or removed from the Hub.';
        }
        if (status == 403) {
          return 'Access denied (403). Only public model repositories work '
              'without a token.';
        }
        if (status == 416) {
          return 'The partial file no longer matches the server copy. Delete it '
              'and download again.';
        }
        return 'The server answered with an error (HTTP $status).';
      case DioExceptionType.connectionError:
        return 'No internet connection. The download will resume when you are back.';
      case DioExceptionType.cancel:
        return 'Cancelled.';
      case DioExceptionType.badCertificate:
        return 'The server certificate could not be verified.';
      case DioExceptionType.unknown:
        return 'Network error: ${error.message ?? 'unknown'}';
      // dio adds members to this enum between minor releases (`transformTimeout`
      // arrived in 5.11). Exhaustiveness over a *package* enum is a compile
      // error waiting to happen, so this switch ends with a default — and it
      // must be the *last* case.
      default:
        return 'The download failed: ${error.message ?? error.type.name}';
    }
  }

  // ── Verification helpers ──────────────────────────────────────────────────

  /// First four bytes must be "GGUF". Cheap, catches HTML error pages and
  /// truncated files before the expensive hash pass.
  Future<bool> _hasGgufMagic(String path) async {
    final RandomAccessFile file = await File(path).open();
    try {
      final Uint8List header = await file.read(4);
      if (header.length < 4) return false;
      for (int i = 0; i < 4; i++) {
        if (header[i] != AppConfig.ggufMagic[i]) return false;
      }
      return true;
    } catch (error) {
      Log.warn('Could not read the GGUF header', error);
      return false;
    } finally {
      await file.close();
    }
  }

  /// Chunked sha256. A 1.5B Q4_K_M model is ~1.07 GB, so hashing runs in a
  /// background isolate with a 4 MB window — the UI thread never blocks and
  /// memory stays flat.
  Future<String> _sha256OfFile(String path) async {
    return compute<String, String>(_hashFile, path);
  }

  static String _hashFile(String path) {
    final RandomAccessFile file = File(path).openSync();
    try {
      final int length = file.lengthSync();
      const int window = 4 * 1024 * 1024;
      final _ChunkedHashSink sink = _ChunkedHashSink();
      final ByteConversionSink input = sha256.startChunkedConversion(sink);
      int offset = 0;
      while (offset < length) {
        final int size = math.min(window, length - offset);
        final Uint8List chunk = file.readSync(size);
        if (chunk.isEmpty) break;
        input.add(chunk);
        offset += chunk.length;
      }
      input.close();
      return sink.digest.toString();
    } finally {
      file.closeSync();
    }
  }

  Future<void> dispose() async {
    await _progress.close();
  }
}

/// Incremental digest collector for the chunked sha256 conversion.
class _ChunkedHashSink implements Sink<Digest> {
  Digest? _digest;

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}

  Digest get digest => _digest ?? sha256.convert(<int>[]);
}

class _IncompleteDownloadException implements Exception {
  _IncompleteDownloadException(this.received, this.expected);

  final int received;
  final int expected;

  @override
  String toString() => 'IncompleteDownload($received/$expected)';
}

// ══════════════════════════════════════════════════════════════════════════════
//  INFERENCE LAYER
// ══════════════════════════════════════════════════════════════════════════════

/// Anything that goes wrong inside llama.cpp, wrapped with a message that can be
/// shown to a learner.
class LlmException implements Exception {
  LlmException(this.message, {this.cause});

  final String message;
  final Object? cause;

  bool get isOutOfMemory => message.toLowerCase().contains('memory') ||
      message.toLowerCase().contains('alloc');

  bool get isContextBusy => message.toLowerCase().contains('context is busy');

  @override
  String toString() => 'LlmException: $message';
}

/// A finished generation.
@immutable
class LlmGenerationResult {
  const LlmGenerationResult({
    required this.text,
    required this.tokensPredicted,
    required this.tokensEvaluated,
    required this.duration,
    this.stoppedEos = false,
    this.truncated = false,
    this.stoppedWord = false,
    this.peakTokensPerSecond = 0,
  });

  final String text;
  final int tokensPredicted;
  final int tokensEvaluated;
  final Duration duration;
  final bool stoppedEos;
  final bool truncated;
  final bool stoppedWord;
  final double peakTokensPerSecond;

  bool get isEmpty => text.trim().isEmpty;

  /// Decode speed for the diagnostics panel.
  double get tokensPerSecond {
    final double seconds = duration.inMilliseconds / 1000.0;
    if (seconds <= 0) return 0;
    return tokensPredicted / seconds;
  }

  @override
  String toString() =>
      'LlmGenerationResult($tokensPredicted tokens, ${duration.inMilliseconds}ms, '
      '${tokensPerSecond.toStringAsFixed(1)} tok/s)';
}

/// Wraps the llama.cpp engine exposed by `fcllama`.
///
/// Responsibilities:
///  * one context at a time, guarded by [_busy] — llama.cpp is not reentrant and
///    a second `completion()` while one is running throws "Context is busy";
///  * streaming tokens out through [LlmTokenCallback];
///  * cooperative cancellation ([stopGeneration]) that the listen loop folds
///    into a *partial but parsed* result instead of an error;
///  * thread-count selection from the device's core count.
///
/// FFI note: `fcllama` reaches llama.cpp through a **platform channel** to a
/// bound Android `Service` (`ink.xcl.fllama.FllamaService`), not `dart:ffi`
/// directly. That is deliberate — llama.cpp runs on a background Android thread
/// with its own looper, and Kotlin owns the native handle (`long/llama_context*`).
/// The public Dart API is identical to an FFI binding
/// (`initContext` / `completion` / `stopCompletion`), which is why this class
/// reads like a classic FFI wrapper.
class LlmService {
  LlmService({ModelDownloader? downloader})
      : downloader = downloader ?? ModelDownloader();

  /// The model downloader lives here so a single provider owns every byte of
  /// model I/O.
  final ModelDownloader downloader;

  FCllama? _engine;
  double? _contextId;
  bool _loaded = false;
  bool _busy = false;
  bool _stopRequested = false;
  String _loadedPath = '';
  ModelFamily _family = ModelFamily.qwen2;
  int _contextSize = AppConfig.contextSize;
  int _threads = AppConfig.minThreads;
  String _modelDisplayName = '';

  StreamSubscription<dynamic>? _tokenSubscription;
  void Function(String delta)? _onToken;
  void Function(double progress)? _onLoadProgress;
  Completer<void>? _firstToken;

  // ── Accessors ─────────────────────────────────────────────────────────────

  bool get isLoaded => _loaded;

  bool get isBusy => _busy;

  int get threads => _threads;

  int get contextSize => _contextSize;

  ModelFamily get family => _family;

  String get loadedPath => _loadedPath;

  String get modelDisplayName => _modelDisplayName;

  double? get contextId => _contextId;

  // ── Loading ───────────────────────────────────────────────────────────────

  /// Loads GGUF weights into memory. Safe to call twice — the second call is a
  /// no-op when the same [path] is already loaded.
  ///
  /// [onProgress] receives 0..1 while llama.cpp reads the tensor data (the
  /// slowest part on a phone: 1+ GB from flash).
  Future<void> loadModel(
    String path, {
    ModelFamily family = ModelFamily.qwen2,
    String displayName = '',
    int? contextSize,
    int? threads,
    bool useMmap = true,
    bool useMlock = false,
    void Function(double progress)? onProgress,
  }) async {
    if (_loaded && _loadedPath == path) return;
    if (_busy) {
      throw LlmException('The engine is still generating. Stop it before '
          'loading a different model.');
    }
    await unload();

    final File file = File(path);
    if (!await file.exists()) {
      throw LlmException('Model file not found at $path');
    }
    final int sizeBytes = await file.length();
    if (sizeBytes < 4 * 1024 * 1024) {
      throw LlmException('The model file is only ${formatBytes(sizeBytes)} — '
          'that is not a GGUF model. Download it again.');
    }

    _family = family;
    _contextSize = contextSize ?? AppConfig.contextSize;
    _threads = threads ?? recommendedThreads();
    _modelDisplayName = displayName.isNotEmpty
        ? displayName
        : path.split('/').last.replaceAll('.gguf', '');

    onProgress?.call(0.02);
    Log.info('Loading model $_modelDisplayName '
        '(${formatBytes(sizeBytes)}) · threads=$_threads · ctx=$_contextSize');

    try {
      final FCllama? engine = FCllama.instance();
      if (engine == null) {
        throw LlmException(
          'The llama.cpp engine is not available on this device. It is built '
          'for arm64-v8a only — check that this is a 64-bit ARM phone.',
        );
      }
      _engine = engine;

      // `onTokenStream` is null until the native side has registered its
      // channel, so it is subscribed lazily and tolerant of a null.
      _engine!.onTokenStream?.listen(
        _handleEngineEvent,
        onError: (Object error) => Log.warn('Engine stream error', error),
      );

      // Load progress arrives as `loadProgress` events on the same stream.
      _onLoadProgress = onProgress;

      final Map<Object?, dynamic>? context = await _engine!.initContext(
        path,
        embedding: false,
        nCtx: _contextSize,
        nBatch: AppConfig.promptBatch,
        nThreads: _threads,
        nGpuLayers: 0, // no GPU backend on Android in this build
        useMlock: useMlock,
        useMmap: useMmap,
        emitLoadProgress: onProgress != null,
      );

      // The context id lives in the returned map (`{'contextId': …}`), not in
      // the return value itself.
      final double? id = _contextIdOf(context);
      if (id == null) {
        throw LlmException(
          'llama.cpp did not return a context id. The model file may be '
          'damaged or incompatible — delete it and download it again.',
        );
      }
      _contextId = id;
      _loaded = true;
      _loadedPath = path;
      onProgress?.call(1);
      Log.info('Model loaded (context $_contextId, ${_threads} threads)');
    } on LlmException {
      rethrow;
    } catch (error, stack) {
      _loaded = false;
      _contextId = null;
      Log.error('Model load failed', error, stack);
      final String message = '$error';
      if (message.toLowerCase().contains('memory')) {
        throw LlmException(
          'Not enough memory to load this model. Close other apps, or pick a '
          'smaller model (Qwen2.5 0.5B).',
          cause: error,
        );
      }
      if (message.toLowerCase().contains('file') ||
          message.toLowerCase().contains('open')) {
        throw LlmException(
          'llama.cpp could not open the model file. It may be corrupted — '
          'delete it and download again.',
          cause: error,
        );
      }
      throw LlmException('The model could not be loaded: $message', cause: error);
    }
  }

  /// Number of decode threads: cores − 2, clamped. Two cores are left for the
  /// audio pipeline and the UI thread; more than six stops helping on ARM big.LITTLE.
  int recommendedThreads() {
    final int cores = Platform.numberOfProcessors;
    final int value = cores - 2;
    if (value < AppConfig.minThreads) return AppConfig.minThreads;
    if (value > AppConfig.maxThreads) return AppConfig.maxThreads;
    return value;
  }

  /// Frees the context and the ~1 GB of mapped weights.
  Future<void> unload() async {
    _stopRequested = true;
    _onToken = null;
    _firstToken = null;
    final double? id = _contextId;
    _contextId = null;
    _loaded = false;
    _loadedPath = '';
    try {
      await _tokenSubscription?.cancel();
      _tokenSubscription = null;
      _onLoadProgress = null;
      if (id != null) {
        await _engine?.releaseContext(id);
      }
    } catch (error) {
      Log.warn('Engine release threw', error);
    }
    _family = ModelFamily.qwen2;
    Log.info('Engine unloaded');
  }

  // ── Generation ────────────────────────────────────────────────────────────

  /// Runs one completion. Throws [LlmException] when the engine is not ready or
  /// already busy — callers should treat "busy" as "drop this turn", never as a
  /// reason to queue a second inference.
  Future<LlmGenerationResult> generate({
    required String prompt,
    List<String> stop = const <String>[],
    int maxTokens = AppConfig.maxTokensPerTurn,
    double temperature = AppConfig.temperature,
    double topP = AppConfig.topP,
    int topK = AppConfig.topK,
    double minP = AppConfig.minP,
    double repeatPenalty = AppConfig.repeatPenalty,
    int seed = -1,
    void Function(String delta)? onToken,
  }) async {
    if (!_loaded || _contextId == null) {
      throw LlmException('No model is loaded.');
    }
    if (_busy) {
      throw LlmException('The engine is already generating a reply.',
          cause: 'Context is busy');
    }

    _busy = true;
    _stopRequested = false;
    _onToken = onToken;
    _firstToken = Completer<void>();
    final Stopwatch stopwatch = Stopwatch()..start();

    try {
      final double? id = _contextId;
      final Map<Object?, dynamic> result =
          await _engine!.completion(
        id!,
        prompt: prompt,
        stop: stop.isEmpty ? _family.stopSequences : stop,
        temperature: temperature,
        topK: topK,
        topP: topP,
        minP: minP,
        penaltyRepeat: repeatPenalty,
        penaltyLastN: AppConfig.repeatLastN,
        nThreads: _threads,
        nPredict: maxTokens,
        seed: seed,
        emitRealtimeCompletion: onToken != null,
      ) ??
              const <Object?, dynamic>{};
      stopwatch.stop();

      final String text = _finalText(result);
      final int predicted = _asInt(result['tokens_predicted']);
      final int evaluated = _asInt(result['tokens_evaluated']);
      final Duration duration = stopwatch.elapsed;

      final LlmGenerationResult generation = LlmGenerationResult(
        text: text,
        tokensPredicted: predicted,
        tokensEvaluated: evaluated,
        duration: duration,
        stoppedEos: _asBool(result['stopped_eos']),
        truncated: _asBool(result['truncated']),
        stoppedWord: _asBool(result['stopped_word']),
        peakTokensPerSecond: duration.inMilliseconds > 0
            ? predicted / (duration.inMilliseconds / 1000.0)
            : 0,
      );
      Log.info('Generated ${predicted} tokens in ${duration.inMilliseconds} ms '
          '(${generation.tokensPerSecond.toStringAsFixed(1)} tok/s)');
      return generation;
    } on LlmException {
      rethrow;
    } catch (error, stack) {
      final String message = '$error';
      if (message.toLowerCase().contains('busy')) {
        throw LlmException('The engine is already generating a reply.',
            cause: error);
      }
      Log.error('Generation failed', error, stack);
      throw LlmException('Generation failed: $message', cause: error);
    } finally {
      _busy = false;
      _onToken = null;
      _firstToken = null;
      _stopRequested = false;
    }
  }

  /// Cancels the in-flight completion. The engine returns the tokens it produced
  /// so far, which the caller can still try to parse — a half-finished sentence
  /// beats silence.
  Future<void> stopGeneration() async {
    if (!_busy || _contextId == null) return;
    _stopRequested = true;
    try {
      await _engine?.stopCompletion(contextId: _contextId!);
      Log.info('Generation stopped by request');
    } catch (error) {
      Log.warn('stopCompletion threw', error);
    }
  }

  /// Waits until the first token of the current generation arrives. Used by the
  /// controller to time the "thinking" indicator.
  Future<void> waitForFirstToken() => _firstToken?.future ?? Future<void>.value();

  // ── Engine event handling ─────────────────────────────────────────────────

  void _handleEngineEvent(dynamic event) {
    if (event is! Map) return;
    final Map<dynamic, dynamic> map = event;
    final String function = '${map['function'] ?? ''}';

    // fcllama sends the context id as an int-valued string sometimes and an int
    // other times — compare as int to avoid a silent no-op.
    final int? eventContext = _asIntOrNull(map['contextId']);
    if (eventContext != null &&
        _contextId != null &&
        eventContext != _contextId!.toInt()) {
      return;
    }

    final dynamic payload = map['result'];

    if (function == 'completion') {
      String? delta;
      if (payload is Map) {
        delta = (payload['token'] ?? payload['content'] ?? payload['text']) as String?;
        if (delta == null) {
          final dynamic completion = payload['completion'];
          if (completion is String) delta = completion;
        }
      } else if (payload is String) {
        delta = payload;
      }
      if (delta == null || delta.isEmpty) return;
      if (_firstToken != null && !_firstToken!.isCompleted) _firstToken!.complete();
      final void Function(String delta)? callback = _onToken;
      if (callback != null) {
        try {
          callback(delta);
        } catch (error) {
          Log.warn('Token callback threw', error);
        }
      }
      return;
    }

    if (function == 'loadProgress') {
      // llama.cpp reports this as a fraction (0..1) in this build; a percentage
      // is normalised just in case.
      double? fraction;
      if (payload is num) {
        fraction = payload.toDouble();
        if (fraction > 1) fraction = fraction / 100;
      } else if (payload is Map) {
        final Object? value = payload['progress'] ?? payload['value'];
        if (value is num) {
          fraction = value.toDouble();
          if (fraction > 1) fraction = fraction / 100;
        }
      }
      if (fraction != null) {
        final void Function(double)? callback = _onLoadProgress;
        if (callback != null) callback(fraction.clamp(0.0, 1.0));
      }
    }
  }

  /// The context id inside the map `initContext` returns. The value arrives as a
  /// `num` on Android and as a numeric string on some platforms, so both shapes
  /// are accepted.
  double? _contextIdOf(Map<Object?, dynamic>? context) {
    final Object? raw = context?['contextId'];
    if (raw == null) return null;
    if (raw is num) return raw.toDouble();
    return double.tryParse('$raw');
  }

  String _finalText(Map<Object?, dynamic> result) {
    final dynamic text = result['text'];
    if (text is String) return text;
    if (text is List) {
      return text.map((dynamic e) => '$e').join();
    }
    return '';
  }

  int _asInt(Object? value) => _asIntOrNull(value) ?? 0;

  int? _asIntOrNull(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value) ?? double.tryParse(value)?.toInt();
    return null;
  }

  bool _asBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value.toLowerCase() == 'true' || value == '1';
    return false;
  }

  // ── Diagnostics ───────────────────────────────────────────────────────────

  /// Everything the settings screen prints when a learner taps "check my engine".
  Future<Map<String, Object?>> deviceReport() async {
    final Map<String, Object?> report = <String, Object?>{
      'platform': Platform.operatingSystem,
      'cores': Platform.numberOfProcessors,
      'threads': _threads,
      'contextSize': _contextSize,
      'modelLoaded': _loaded,
      'modelPath': _loadedPath,
      'modelName': _modelDisplayName,
      'family': _family.name,
      'busy': _busy,
      'engine': 'fcllama 0.0.3 (llama.cpp, arm64-v8a)',
      'contextId': _contextId,
    };
    try {
      final Map<Object?, dynamic>? cpu = await _engine?.getCpuInfo();
      if (cpu != null) {
        for (final MapEntry<Object?, dynamic> entry in cpu.entries) {
          report['cpu.${entry.key}'] = entry.value;
        }
      }
    } catch (error) {
      report['cpuError'] = '$error';
    }
    return report;
  }

  /// A short decode benchmark, run on demand from Settings.
  ///
  /// Uses the engine's own llama.cpp `bench` when it succeeds (it reports prompt
  /// processing and text generation separately), and falls back to timing one
  /// real completion.
  Future<String> benchmark() async {
    if (!_loaded) throw LlmException('Load a model before benchmarking.');

    final double? id = _contextId;
    if (id != null) {
      try {
        final String? native = await _engine!.bench(id, pp: 8, tg: 4, pl: 2, nr: 1);
        if (native != null && native.trim().isNotEmpty) {
          return 'llama.cpp bench: ${native.trim()}';
        }
      } catch (error) {
        Log.warn('Engine bench unavailable, timing a completion instead', error);
      }
    }

    final Stopwatch stopwatch = Stopwatch()..start();
    final LlmGenerationResult result = await generate(
      prompt: 'Write a short sentence about the weather.\n',
      maxTokens: 32,
      temperature: 0.1,
      stop: <String>['\n\n'],
    );
    stopwatch.stop();
    final double speed = result.tokensPredicted / (stopwatch.elapsedMicroseconds / 1e6);
    return '${speed.toStringAsFixed(1)} tokens/s · '
        '${result.tokensPredicted} tokens in ${stopwatch.elapsedMilliseconds} ms';
  }

  Future<void> dispose() async {
    await unload();
    await downloader.dispose();
  }
}
