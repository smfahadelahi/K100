import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:k100/core/constants.dart';
import 'package:k100/core/logger.dart';

/// Prompt-template family. The **only** thing the engine needs to know about a
/// model besides the weights: how to wrap system/user/assistant turns.
///
/// Getting this wrong is the classic 2024-era failure mode — a Gemma model fed
/// ChatML tokens produces fluent nonsense.
enum ModelFamily {
  /// Qwen2 / Qwen2.5. ChatML, has a real system role.
  qwen2('Qwen 2.5', '<|im_start|>', '<|im_end|>', true),

  /// Gemma 2. `<start_of_turn>` blocks, **no system role** — the system prompt is
  /// folded into the first user turn.
  gemma2('Gemma 2', '<start_of_turn>', '<end_of_turn>', false),

  /// Llama 3.2. Header-based template, has a real system role.
  llama3('Llama 3.2', '<|start_header_id|>', '<|eot_id|>', true);

  const ModelFamily(
    this.label,
    this.startToken,
    this.endToken,
    this.hasSystemRole,
  );

  final String label;
  final String startToken;
  final String endToken;

  /// Whether the template can carry a system prompt *separately*. When false the
  /// prompt builder folds the instructions into the first user message.
  final bool hasSystemRole;

  /// Sequences that must stop generation. The model's own end token is handled
  /// by llama.cpp; these prevent runaway text after a turn closes.
  List<String> get stopSequences => <String>[
        endToken,
        '<|im_start|>',
        '<|endoftext|>',
        '<start_of_turn>',
        '<|eot_id|>',
        '<|start_header_id|>',
      ];

  /// Close-out token for the assistant turn being generated.
  String get assistantCloseToken => this == ModelFamily.gemma2 ? '<end_of_turn>' : endToken;
}

/// A downloadable model. Values (sizes, licences, parameter counts) are the real
/// numbers published on the Hugging Face Hub — see the README for the table.
@immutable
class ModelEntry {
  const ModelEntry({
    required this.id,
    required this.displayName,
    required this.repoId,
    required this.fileName,
    required this.sizeBytes,
    required this.family,
    required this.parameters,
    required this.quant,
    required this.contextWindow,
    required this.minRamMb,
    required this.license,
    required this.description,
    this.sha256,
    this.recommended = false,
    this.qualityScore = 0,
    this.speedScore = 0,
    this.customUrl,
  });

  /// Stable slug used in preferences and the SQLite rows.
  final String id;
  final String displayName;

  /// `Qwen/Qwen2.5-1.5B-Instruct-GGUF`
  final String repoId;

  /// Exact file name inside that repo.
  final String fileName;

  /// Byte size, published by the Hub. Used for the progress bar before the
  /// download starts and for the free-space check.
  final int sizeBytes;

  /// LFS sha256 when known. Verified after download when present.
  final String? sha256;

  final ModelFamily family;

  /// "1.5B"
  final String parameters;

  /// "Q4_K_M"
  final String quant;

  /// Training context length in tokens.
  final int contextWindow;

  /// Roughly the minimum device RAM this model runs comfortably in.
  final int minRamMb;

  final String license;
  final String description;

  /// The default pick shown with a "Recommended" badge.
  final bool recommended;

  /// 1–5, subjective: language quality on real conversation prompts.
  final int qualityScore;

  /// 1–5, subjective: tokens/second on a Snapdragon 7-series phone.
  final int speedScore;

  /// Set only for the "custom GGUF URL" pseudo-entry.
  final String? customUrl;

  bool get isCustom => id == 'custom' && customUrl != null;

  String get sizeLabel {
    final double gb = sizeBytes / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(2)} GB';
    return '${(sizeBytes / (1024 * 1024)).round()} MB';
  }

  double get sizeGb => sizeBytes / (1024 * 1024 * 1024);

  String get minRamLabel => '${(minRamMb / 1024).toStringAsFixed(1)} GB RAM';

  String get fileExtension => fileName.toLowerCase().split('.').last;

  ModelEntry copyWith({
    String? id,
    String? displayName,
    String? repoId,
    String? fileName,
    int? sizeBytes,
    String? sha256,
    ModelFamily? family,
    String? customUrl,
  }) =>
      ModelEntry(
        id: id ?? this.id,
        displayName: displayName ?? this.displayName,
        repoId: repoId ?? this.repoId,
        fileName: fileName ?? this.fileName,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        sha256: sha256 ?? this.sha256,
        family: family ?? this.family,
        parameters: parameters,
        quant: quant,
        contextWindow: contextWindow,
        minRamMb: minRamMb,
        license: license,
        description: description,
        recommended: recommended,
        qualityScore: qualityScore,
        speedScore: speedScore,
        customUrl: customUrl ?? this.customUrl,
      );

  @override
  String toString() => 'ModelEntry($id, $sizeLabel)';
}

/// What the downloader needs to know about a concrete file, once the Hub has
/// been asked for metadata.
@immutable
class ModelFileInfo {
  const ModelFileInfo({
    required this.fileName,
    required this.sizeBytes,
    this.sha256,
    this.quant,
  });

  final String fileName;
  final int sizeBytes;
  final String? sha256;
  final String? quant;

  String get sizeLabel {
    final double gb = sizeBytes / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(2)} GB';
    return '${(sizeBytes / (1024 * 1024)).round()} MB';
  }

  @override
  String toString() => 'ModelFileInfo($fileName, $sizeLabel)';
}

/// The catalogue. Five curated models, ordered from "runs on anything" to
/// "needs a flagship phone".
class ModelCatalog {
  ModelCatalog._();

  // ── Entries ───────────────────────────────────────────────────────────────

  /// 0.5B — a phone with 3 GB of RAM can still talk. Noticeably dumber, but it
  /// fits, and it is the right default for very old devices.
  static const ModelEntry qwen05b = ModelEntry(
    id: 'qwen2.5-0.5b-instruct-q4_k_m',
    displayName: 'Qwen2.5 0.5B Instruct',
    repoId: 'Qwen/Qwen2.5-0.5B-Instruct-GGUF',
    fileName: 'qwen2.5-0.5b-instruct-q4_k_m.gguf',
    sizeBytes: 491400032,
    family: ModelFamily.qwen2,
    parameters: '0.5B',
    quant: 'Q4_K_M',
    contextWindow: 32768,
    minRamMb: 2048,
    license: 'Apache-2.0',
    description: 'Tiny and fast. Good for absolute beginners who mainly need '
        'short replies and pronunciation practice. Grammar explanations are '
        'shallow.',
    qualityScore: 2,
    speedScore: 5,
  );

  /// 1.5B — the default. Best quality-per-byte that still streams at a
  /// conversational pace on a mid-range phone.
  static const ModelEntry qwen15b = ModelEntry(
    id: 'qwen2.5-1.5b-instruct-q4_k_m',
    displayName: 'Qwen2.5 1.5B Instruct',
    repoId: 'Qwen/Qwen2.5-1.5B-Instruct-GGUF',
    fileName: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
    sizeBytes: 1117320736,
    sha256: '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e',
    family: ModelFamily.qwen2,
    parameters: '1.5B',
    quant: 'Q4_K_M',
    contextWindow: 32768,
    minRamMb: 4096,
    license: 'Apache-2.0',
    description: 'The default. Strong instruction following and the most '
        'reliable JSON output of the small models, which is exactly what this '
        'app needs for grammar feedback. ~5-12 tokens/s on a Snapdragon 7-series.',
    recommended: true,
    qualityScore: 4,
    speedScore: 4,
  );

  /// Gemma-2 2B — the best *language* quality in this size class and the
  /// alternate recommendation in the project brief.
  static const ModelEntry gemma2b = ModelEntry(
    id: 'gemma-2-2b-it-q4_k_m',
    displayName: 'Gemma 2 2B Instruct',
    repoId: 'bartowski/gemma-2-2b-it-GGUF',
    fileName: 'gemma-2-2b-it-Q4_K_M.gguf',
    sizeBytes: 1708582752,
    sha256: 'e0aee85060f168f0f2d8473d7ea41ce2f3230c1bc1374847505ea599288a7787',
    family: ModelFamily.gemma2,
    parameters: '2B',
    quant: 'Q4_K_M',
    contextWindow: 8192,
    minRamMb: 5120,
    license: 'Gemma Terms of Use',
    description: 'Google’s 2B model. Warm, natural, idiomatic replies and the '
        'best explanations of the bunch — but it has no system role, so the '
        'prompt is folded into the first turn, and JSON discipline is slightly '
        'weaker than Qwen.',
    qualityScore: 5,
    speedScore: 3,
  );

  /// Qwen2.5 3B — noticeably better grammar analysis if the phone can take it.
  static const ModelEntry qwen3b = ModelEntry(
    id: 'qwen2.5-3b-instruct-q4_k_m',
    displayName: 'Qwen2.5 3B Instruct',
    repoId: 'Qwen/Qwen2.5-3B-Instruct-GGUF',
    fileName: 'qwen2.5-3b-instruct-q4_k_m.gguf',
    sizeBytes: 1926463456,
    family: ModelFamily.qwen2,
    parameters: '3B',
    quant: 'Q4_K_M',
    contextWindow: 32768,
    minRamMb: 6144,
    license: 'Qwen Research License',
    description: 'For 8 GB+ devices. The most accurate corrections and the '
        'most patient explanations, at roughly half the speed of the 1.5B.',
    qualityScore: 5,
    speedScore: 2,
  );

  /// Llama 3.2 3B Instruct — third family, included so the app is not hostage to
  /// one vendor's tokenizer.
  static const ModelEntry llama32_3b = ModelEntry(
    id: 'llama-3.2-3b-instruct-q4_k_m',
    displayName: 'Llama 3.2 3B Instruct',
    repoId: 'bartowski/Llama-3.2-3B-Instruct-GGUF',
    fileName: 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
    sizeBytes: 2019377696,
    family: ModelFamily.llama3,
    parameters: '3B',
    quant: 'Q4_K_M',
    contextWindow: 131072,
    minRamMb: 6144,
    license: 'Llama 3.2 Community License',
    description: 'Meta’s 3B. Excellent English and Spanish, decent JSON '
        'discipline, and a huge context window if you want longer conversations.',
    qualityScore: 4,
    speedScore: 2,
  );

  /// All catalogue entries in display order.
  static const List<ModelEntry> all = <ModelEntry>[
    qwen15b,
    gemma2b,
    qwen05b,
    qwen3b,
    llama32_3b,
  ];

  /// The entry the app ships as its default.
  static ModelEntry get recommended =>
      all.firstWhere((ModelEntry e) => e.recommended, orElse: () => qwen15b);

  static ModelEntry? byId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final ModelEntry entry in all) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// Entries that fit in [availableRamMb] (with a 512 MB OS headroom reserve).
  static List<ModelEntry> fittingIn(int availableRamMb) => all
      .where((ModelEntry e) => e.minRamMb <= availableRamMb - 512)
      .toList();

  /// Builds a pseudo-entry for a user-supplied direct GGUF URL.
  ///
  /// The name/size are inferred from the URL when possible; the real size and
  /// sha256 are resolved from the Hub at download time when the URL points at
  /// Hugging Face.
  static ModelEntry custom({
    required String url,
    String? name,
    int sizeBytes = 0,
  }) {
    final String fileName = url.split('?').first.split('/').last;
    final String repoId = _repoIdFromUrl(url) ?? '';
    final ModelFamily family = detectFamilyFromName(name ?? fileName);
    return ModelEntry(
      id: 'custom',
      displayName: name ?? _prettify(fileName),
      repoId: repoId,
      fileName: fileName,
      sizeBytes: sizeBytes,
      family: family,
      parameters: _parameterHint(fileName),
      quant: _quantHint(fileName),
      contextWindow: 8192,
      minRamMb: 4096,
      license: 'Check the model card',
      description: 'A model you supplied yourself. Anything llama.cpp can load '
          'will work; quality, licence and language coverage are on you.',
      customUrl: url,
    );
  }

  /// Guess the prompt template from a model name. Falls back to Qwen2 ChatML,
  /// which is the most forgiving of the three when a model is mislabelled.
  static ModelFamily detectFamilyFromName(String name) {
    final String lowered = name.toLowerCase();
    if (lowered.contains('gemma')) return ModelFamily.gemma2;
    if (lowered.contains('llama-3') ||
        lowered.contains('llama3') ||
        lowered.contains('llama_3') ||
        lowered.contains('llama-4') ||
        lowered.contains('llama4')) {
      return ModelFamily.llama3;
    }
    if (lowered.contains('qwen')) return ModelFamily.qwen2;
    if (lowered.contains('phi') || lowered.contains('mistral') || lowered.contains('smollm')) {
      // These use ChatML-ish templates most of the time.
      return ModelFamily.qwen2;
    }
    return ModelFamily.qwen2;
  }

  /// `https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/x.gguf`
  /// → `Qwen/Qwen2.5-1.5B-Instruct-GGUF`
  static String? _repoIdFromUrl(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || !uri.host.contains('huggingface.co')) return null;
    final List<String> segments =
        uri.pathSegments.where((String s) => s.isNotEmpty).toList();
    if (segments.length < 2) return null;
    return '${segments[0]}/${segments[1]}';
  }

  static String _prettify(String fileName) {
    String name = fileName.replaceAll(RegExp(r'\.gguf$', caseSensitive: false), '');
    name = name.replaceAll(RegExp(r'[-_]'), ' ');
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (name.isEmpty) return 'Custom model';
    return name[0].toUpperCase() + name.substring(1);
  }

  static String _quantHint(String fileName) {
    final RegExpMatch? match = RegExp(
      r'(iq\d(?:_[a-z0-9]+)*|q\d(?:_[a-z0-9]+)*|f16|fp16|bf16|f32)',
      caseSensitive: false,
    ).firstMatch(fileName);
    return match?.group(0)?.toUpperCase() ?? 'unknown';
  }

  static String _parameterHint(String fileName) {
    final RegExpMatch? match =
        RegExp(r'(\d+(?:\.\d+)?)\s*[bB](?![a-zA-Z])').firstMatch(fileName);
    if (match != null) return '${match.group(1)}B';
    return 'unknown size';
  }
}

/// Talks to the Hugging Face Hub for the *metadata* of a model: the real file
/// size and the LFS sha256, both of which are needed for an honest progress bar
/// and a verified download.
///
/// This is the only network code outside the downloader itself, and it is
/// optional: when it fails (offline, rate limit, private repo) the app falls back
/// to the catalogue's published size and skips the sha256 check.
class ModelCatalogService {
  ModelCatalogService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: AppConfig.connectTimeout,
                receiveTimeout: const Duration(seconds: 20),
                headers: const <String, String>{'Accept': 'application/json'},
              ),
            );

  final Dio _dio;
  final Map<String, ModelFileInfo> _cache = <String, ModelFileInfo>{};

  /// Resolves the file inside [entry]'s repo. Returns null when the Hub cannot be
  /// reached or the file is not listed.
  Future<ModelFileInfo?> resolve( ModelEntry entry) async {
    if (entry.isCustom) {
      final ModelFileInfo? fromRepo = await resolveCustom(entry);
      return fromRepo;
    }
    final ModelFileInfo? info = await _resolveFile(entry.repoId, entry.fileName);
    if (info != null) return info;
    // Offline / blocked: the catalogue values are still good enough to download.
    return ModelFileInfo(
      fileName: entry.fileName,
      sizeBytes: entry.sizeBytes,
      sha256: entry.sha256,
      quant: entry.quant,
    );
  }

  /// Resolves the size/sha of a user-supplied URL by asking the Hub for the file
  /// list of the repo it points at.
  Future<ModelFileInfo?> resolveCustom(ModelEntry entry) async {
    final String url = entry.customUrl ?? '';
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return null;
    final List<String> segments =
        uri.pathSegments.where((String s) => s.isNotEmpty).toList();
    if (!uri.host.contains('huggingface.co') || segments.length < 2) {
      // A plain HTTPS URL: we cannot know the size ahead of time. The downloader
      // reads Content-Length instead.
      return ModelFileInfo(fileName: entry.fileName, sizeBytes: 0);
    }
    final String repoId = '${segments[0]}/${segments[1]}';
    return _resolveFile(repoId, entry.fileName);
  }

  /// Every `.gguf` file in a repo, best-quant-first. Used by the advanced
  /// "paste a repo id" flow.
  Future<List<ModelFileInfo>> ggufFiles(String repoId) async {
    final Map<String, dynamic>? json = await _fetchRepo(repoId);
    if (json == null) return <ModelFileInfo>[];
    return _parseSiblings(json)
        .where((Map<String, dynamic> s) =>
            '${s['rfilename']}'.toLowerCase().endsWith('.gguf'))
        .map(_toFileInfo)
        .toList()
      ..sort((ModelFileInfo a, ModelFileInfo b) => a.sizeBytes.compareTo(b.sizeBytes));
  }

  Future<ModelFileInfo?> _resolveFile(String repoId, String fileName) async {
    if (repoId.isEmpty) return null;
    final String key = '$repoId/$fileName';
    final ModelFileInfo? cached = _cache[key];
    if (cached != null) return cached;

    final Map<String, dynamic>? json = await _fetchRepo(repoId);
    if (json == null) return null;

    for (final Map<String, dynamic> sibling in _parseSiblings(json)) {
      final String name = '${sibling['rfilename']}';
      if (name.toLowerCase() == fileName.toLowerCase()) {
        final ModelFileInfo info = _toFileInfo(sibling);
        _cache[key] = info;
        return info;
      }
    }

    // Case-insensitive / suffix match: repos occasionally rename a quant.
    for (final Map<String, dynamic> sibling in _parseSiblings(json)) {
      final String name = '${sibling['rfilename']}'.toLowerCase();
      if (name.endsWith(fileName.toLowerCase())) {
        final ModelFileInfo info = _toFileInfo(sibling);
        _cache[key] = info;
        return info;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> _fetchRepo(String repoId) async {
    try {
      final Response<dynamic> response = await _dio.get<dynamic>(
        AppConfig.repoApiUrl(repoId),
      );
      final Object? data = response.data;
      if (data is Map<String, dynamic>) return data;
      if (data is String && data.isNotEmpty) {
        final Object? decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
      }
      return null;
    } on DioException catch (error) {
      Log.warn('Model metadata lookup failed for $repoId', error.message);
      return null;
    } catch (error, stack) {
      Log.warn('Model metadata lookup crashed for $repoId', error, stack);
      return null;
    }
  }

  List<Map<String, dynamic>> _parseSiblings(Map<String, dynamic> json) {
    final Object? siblings = json['siblings'];
    if (siblings is! List) return <Map<String, dynamic>>[];
    return siblings.whereType<Map<String, dynamic>>().toList();
  }

  ModelFileInfo _toFileInfo(Map<String, dynamic> sibling) {
    final String name = '${sibling['rfilename']}';
    final Object? lfs = sibling['lfs'];
    String? sha;
    int size = 0;
    if (lfs is Map) {
      sha = lfs['sha256'] as String?;
      size = (lfs['size'] as num?)?.toInt() ?? 0;
    }
    if (size == 0) {
      size = (sibling['size'] as num?)?.toInt() ?? 0;
    }
    return ModelFileInfo(
      fileName: name,
      sizeBytes: size,
      sha256: sha,
      quant: ModelCatalog._quantHint(name),
    );
  }
}
