import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 下载任务的状态机。
///
///   queued ──► downloading ──► merging ──► completed
///      ▲            │
///      │            ├──► paused      （用户暂停 / 断网）
///      └────────────┴──► failed ──(30 秒后自动重排)──► queued
///
/// 进程被杀时停留在 downloading / merging 的任务，下次启动会被改回 queued
/// 重新排队 —— 分片文件还在磁盘上，续传会跳过已经下好的部分，代价很小。
enum DownloadStatus {
  /// 排队等待，或正在等待自动重试。
  queued,

  /// 正在下载分片。
  downloading,

  /// 用户手动暂停，或因为断网自动挂起。
  paused,

  /// 分片已下完，正在合并成单文件。
  merging,

  /// 已完成。
  completed,

  /// 失败。会自动重试；重试次数用尽后等用户手动重试。
  failed;

  static DownloadStatus parse(String? raw) {
    for (final v in DownloadStatus.values) {
      if (v.name == raw) return v;
    }
    // 认不出来的一律当「排队中」：宁可重下一次，也不要卡在一个不认识的状态上
    // （比如以后加了新状态又回滚了版本）。
    return DownloadStatus.queued;
  }

  /// 这个状态下任务还会继续占用下载队列。
  bool get isActive => this == queued || this == downloading || this == merging;
}

class DownloadTask {
  /// 任务 id，同时也是去重键：`<vodId>_<线路名>_<集号>`。
  ///
  /// 刻意**不含时间戳**之类会变的东西 —— 否则同一集会被反复入队、下出好几份。
  final String id;

  final String vodId;
  final String title;
  final String cover;

  /// 线路名（`PlaySource.name`，如「2K线路」「超清2」）。同一个剧不同线路是不同任务。
  final String sourceName;
  final String episodeName;
  final int episodeIndex;

  /// 详情页里的 `/play/...` 路径。m3u8 解析失败要重来时得靠它。
  final String playPath;

  /// 解析出来的 m3u8 地址。缓存下来，重试时不必再解析一次播放页。
  String? playlistUrl;

  DownloadStatus status;

  int totalSegments;
  int doneSegments;
  int totalBytes;

  /// 整任务已经自动重试过几轮（0 表示还没重试过）。
  int attempt;

  String? errorMessage;

  /// 播放列表 `#EXTINF` 的总和，用于显示「本集时长」。
  int durationSeconds;

  /// 播放列表带 `#EXT-X-KEY`：分片是加密的。
  ///
  /// 加密分片**无法合并**成单文件 —— HLS 默认用「媒体序号」当 AES 的 IV，
  /// 每片一个 IV，合并之后就再也解不开了。这种情况保留分片目录 + 本地播放列表
  /// （详见 `DownloadService` 里的说明）。
  bool encrypted;

  /// 成品路径：未加密时是合并出来的单文件，加密时是保留下来的目录。
  String? outputPath;

  final int createdAtMs;
  int updatedAtMs;

  DownloadTask({
    required this.id,
    required this.vodId,
    required this.title,
    required this.cover,
    required this.sourceName,
    required this.episodeName,
    required this.episodeIndex,
    required this.playPath,
    this.playlistUrl,
    this.status = DownloadStatus.queued,
    this.totalSegments = 0,
    this.doneSegments = 0,
    this.totalBytes = 0,
    this.attempt = 0,
    this.errorMessage,
    this.durationSeconds = 0,
    this.encrypted = false,
    this.outputPath,
    int? createdAtMs,
    int? updatedAtMs,
  }) : createdAtMs = createdAtMs ?? DateTime.now().millisecondsSinceEpoch,
       updatedAtMs = updatedAtMs ?? DateTime.now().millisecondsSinceEpoch;

  /// 稳定的任务 id。线路名和集号都在里面，所以「同一集换条线路再下」是两条任务。
  static String buildId({
    required String vodId,
    required String sourceName,
    required int episodeIndex,
  }) => '${vodId}_${sourceName}_$episodeIndex';

  /// 0.0 ~ 1.0。分片数还没拿到时返回 0。
  double get progress {
    if (totalSegments <= 0) return 0;
    return (doneSegments / totalSegments).clamp(0.0, 1.0);
  }

  bool get isDone => status == DownloadStatus.completed;
  bool get isFailed => status == DownloadStatus.failed;
  bool get isPaused => status == DownloadStatus.paused;

  /// 是否还能被「暂停」。
  bool get canPause =>
      status == DownloadStatus.queued || status == DownloadStatus.downloading;

  /// 是否还能被「继续 / 重试」。
  bool get canResume =>
      status == DownloadStatus.paused || status == DownloadStatus.failed;

  String get sizeLabel {
    if (totalBytes <= 0) return '';
    const mb = 1024 * 1024;
    if (totalBytes >= 1024 * mb) {
      return '${(totalBytes / (1024 * mb)).toStringAsFixed(2)} GB';
    }
    if (totalBytes >= mb) {
      return '${(totalBytes / mb).toStringAsFixed(1)} MB';
    }
    return '${(totalBytes / 1024).toStringAsFixed(0)} KB';
  }

  DownloadTask copyWith({
    String? playlistUrl,
    DownloadStatus? status,
    int? totalSegments,
    int? doneSegments,
    int? totalBytes,
    int? attempt,
    String? errorMessage,
    bool clearError = false,
    int? durationSeconds,
    bool? encrypted,
    String? outputPath,
    int? updatedAtMs,
  }) => DownloadTask(
    id: id,
    vodId: vodId,
    title: title,
    cover: cover,
    sourceName: sourceName,
    episodeName: episodeName,
    episodeIndex: episodeIndex,
    playPath: playPath,
    playlistUrl: playlistUrl ?? this.playlistUrl,
    status: status ?? this.status,
    totalSegments: totalSegments ?? this.totalSegments,
    doneSegments: doneSegments ?? this.doneSegments,
    totalBytes: totalBytes ?? this.totalBytes,
    attempt: attempt ?? this.attempt,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    durationSeconds: durationSeconds ?? this.durationSeconds,
    encrypted: encrypted ?? this.encrypted,
    outputPath: outputPath ?? this.outputPath,
    createdAtMs: createdAtMs,
    updatedAtMs: updatedAtMs ?? DateTime.now().millisecondsSinceEpoch,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'vodId': vodId,
    'title': title,
    'cover': cover,
    'sourceName': sourceName,
    'episodeName': episodeName,
    'episodeIndex': episodeIndex,
    'playPath': playPath,
    'playlistUrl': playlistUrl,
    'status': status.name,
    'totalSegments': totalSegments,
    'doneSegments': doneSegments,
    'totalBytes': totalBytes,
    'attempt': attempt,
    'errorMessage': errorMessage,
    'durationSeconds': durationSeconds,
    'encrypted': encrypted,
    'outputPath': outputPath,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) => DownloadTask(
    id: json['id'] as String,
    vodId: json['vodId'] as String? ?? '',
    title: json['title'] as String? ?? '',
    cover: json['cover'] as String? ?? '',
    sourceName: json['sourceName'] as String? ?? '',
    episodeName: json['episodeName'] as String? ?? '',
    episodeIndex: json['episodeIndex'] as int? ?? 0,
    playPath: json['playPath'] as String? ?? '',
    playlistUrl: json['playlistUrl'] as String?,
    status: DownloadStatus.parse(json['status'] as String?),
    totalSegments: json['totalSegments'] as int? ?? 0,
    doneSegments: json['doneSegments'] as int? ?? 0,
    totalBytes: json['totalBytes'] as int? ?? 0,
    attempt: json['attempt'] as int? ?? 0,
    errorMessage: json['errorMessage'] as String?,
    durationSeconds: json['durationSeconds'] as int? ?? 0,
    encrypted: json['encrypted'] as bool? ?? false,
    outputPath: json['outputPath'] as String?,
    createdAtMs: json['createdAtMs'] as int?,
    updatedAtMs: json['updatedAtMs'] as int?,
  );

  static String encodeList(List<DownloadTask> tasks) =>
      jsonEncode(tasks.map((t) => t.toJson()).toList());

  static List<DownloadTask> decodeList(String raw) {
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => DownloadTask.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      // 存档坏了就当没有任务，不要因为一条脏数据让整个下载页崩掉。
      // 但要留痕：返回空表之后下载页会显示「没有任务」，用户会以为下载记录
      // 被清空了；不看日志的话，原因（存档损坏）完全不可见。
      debugPrint('[DownloadTask] 下载任务存档解析失败，本次按空列表处理: $e');
      return [];
    }
  }
}
