import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/download_task.dart';
import 'download_storage.dart';
import 'video_site_scraper.dart';

/// 播放列表里的一个分片。
class _Seg {
  final String url;
  final double durationSec;
  const _Seg(this.url, this.durationSec);
}

/// 解析好的媒体播放列表。
class _Playlist {
  final List<_Seg> segments;

  /// AES-128 的密钥地址（已绝对化）。非加密列表为 null。
  final String? keyUri;

  /// `#EXT-X-MAP` 的初始化分片（fMP4 才有）。
  final String? initUri;

  final int durationSeconds;

  /// 这是 master playlist 时，第一个变体的地址（需要再去取一次）。
  final String? variantUri;

  /// `#EXT-X-MEDIA-SEQUENCE`。AES-128 的 IV **默认就是「媒体序号」**，
  /// 即 `mediaSequence + 分片下标`（16 字节大端）。这个值解析错的话
  /// 解出来的字节就是垃圾 —— 而 VOD 通常写 0，容易被忽略。
  final int mediaSequence;

  /// `#EXT-X-KEY` 里显式写的 `IV=0x...`。写了就用它，没写才退回媒体序号。
  final String? explicitIv;

  const _Playlist({
    required this.segments,
    required this.durationSeconds,
    this.keyUri,
    this.initUri,
    this.variantUri,
    this.mediaSequence = 0,
    this.explicitIv,
  });

  bool get encrypted => keyUri != null;

  /// 分片是 fMP4 还是 TS —— 决定分片扩展名用 `.m4s` 还是 `.ts`。
  bool get isFmp4 =>
      initUri != null ||
      (segments.isNotEmpty && segments.first.url.contains('.m4s'));

  /// 第 [index] 个分片解密时该用的 IV（16 字节）。
  ///
  /// 优先级：显式 `IV=0x...` > 媒体序号 + 下标（HLS 规范的默认行为）。
  List<int> ivFor(int index) {
    final explicit = explicitIv;
    if (explicit != null) {
      final hex = explicit.startsWith('0x') ? explicit.substring(2) : explicit;
      final out = <int>[];
      for (var i = 0; i + 1 < hex.length; i += 2) {
        out.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
      if (out.length == 16) return out;
      // 长度不对就当没写，别拿一个半截 IV 去解密。
    }
    final seq = mediaSequence + index;
    return List<int>.generate(16, (i) => (seq >> (8 * (15 - i))) & 0xff);
  }
}

/// 缓存下载引擎。
///
/// ## 队列模型
///
/// **任务串行、任务内 6 并发分片。** 不并行跑多个任务，是因为这台设备到 CDN 的
/// 总带宽实测只有 ~1.1 MB/s（6 路并发聚合），两个任务一起跑只会互相抢带宽、
/// 双双变慢，还让「剩余时间」变得没法估。
///
/// ## 失败自动重下（三层）
///
/// 1. **分片级** —— 单个分片最多试 [maxSegmentAttempts] 次，退避 0.5s → 1s →
///    2s → 4s → 8s。只有「网络异常 / 超时 / 非 2xx / 响应体明显不是视频」才重试。
/// 2. **任务级** —— 分片级用尽后整个任务标记失败，[taskRetryDelay] 之后
///    **自动重排**，最多 [maxTaskAttempts] 轮。因为已经下好的分片会被跳过，
///    整任务重试的代价很小。
/// 3. **启动时** —— [init] 会把上次没下完的任务重新排队（进程被杀也能续上）。
///
/// ## 断点续传
///
/// 分片落盘为 `parts/00001.ts`，**已存在且大于 [minValidSegmentBytes] 就跳过**。
/// 所以「暂停 / 杀进程 / 重试」都不需要额外记录进度 —— 文件本身就是进度。
class DownloadService extends ChangeNotifier {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  static const MethodChannel _fgChannel = MethodChannel('tvplayer/download');

  /// 加密分片的 AES-128-CBC 解密走原生（Dart 侧没有可用的 AES 实现）。
  static const MethodChannel _cryptoChannel = MethodChannel('tvplayer/crypto');

  /// 任务内并发分片数。与 `HlsPreloadProxy` 一致（实测该并发下聚合 ~1.1 MB/s）。
  static const int segmentWorkers = 6;

  static const int maxSegmentAttempts = 5;
  static const int maxTaskAttempts = 3;
  static const Duration taskRetryDelay = Duration(seconds: 30);

  /// 小于这个字节数的响应一律当成**坏分片**。
  ///
  /// 实测该站点的 CDN 在「302 跳转前的那个节点」上会对分片请求回一个
  /// **3 字节的 `OK\n`**（`4f 4b 0a`，`Content-Type: video/mp2t`）。
  /// 只判 HTTP 200 的话会把它当成功写进文件，成品就是一坨坏数据。
  static const int minValidSegmentBytes = 1000;

  static const String _keyTasks = 'tv_download_tasks';
  static const String _workRootName = '.tvplayer_tmp';

  final VideoSiteScraper _scraper = VideoSiteScraper();
  final DownloadStorage _storage = DownloadStorage.instance;

  late final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 20),
      // 自己处理状态码：4xx/5xx 交给重试逻辑，而不是让 dio 直接抛。
      validateStatus: (code) => code != null && code >= 200 && code < 400,
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      },
    ),
  );

  SharedPreferences? _prefs;

  final List<DownloadTask> _tasks = [];

  /// 正在跑的任务 id。同一时刻最多一个。
  String? _activeTaskId;

  /// 被要求「停下来」的任务 id。分片 worker 每次循环都查一下它。
  final Set<String> _stopRequested = <String>{};

  Timer? _retryTimer;
  bool _disposed = false;

  /// 任务级重试的「解禁时刻」：taskId → 到什么时候才允许再跑。
  ///
  /// 这个闸门是必须的。失败后 `_handleTaskFailure` 会把状态改回 `queued` 好让它重新
  /// 排队，可它返回之后 `_runTask` 的 `finally` 马上就会 `_pump()` —— 如果不在
  /// `_pump` 里拦一下，任务会被**立刻**重新捡起来，30 秒退避完全失效，三次任务级
  /// 重试会在几秒内烧完（实测间隔只有分片退避那 7.5 秒，任务退避贡献 0 秒）。
  final Map<String, DateTime> _retryAfter = <String, DateTime>{};

  /// 当前任务的下行速度（字节/秒），用于 UI 展示。
  double _speedBps = 0;
  double get speedBps => _speedBps;

  int _lastSpeedBytes = 0;
  DateTime _lastSpeedAt = DateTime.now();

  /// 通知刷新的节流时间戳。分片下得快时每秒能完成好几个，不节流会一直打扰系统。
  DateTime _lastNotifyAt = DateTime.fromMillisecondsSinceEpoch(0);

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  /// 正在下载的那条任务（没有就返回 null）。
  DownloadTask? get activeTask {
    final id = _activeTaskId;
    if (id == null) return null;
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  bool get hasActiveWork => _tasks.any(
    (t) =>
        t.status == DownloadStatus.downloading ||
        t.status == DownloadStatus.merging,
  );

  int get pendingCount => _tasks.where((t) => t.status.isActive).length;
  int get completedCount => _tasks.where((t) => t.isDone).length;
  int get failedCount => _tasks.where((t) => t.isFailed).length;

  /// 某个「剧 + 线路 + 集」是否已经下过 / 正在下。
  DownloadTask? findByEpisode({
    required String vodId,
    required String sourceName,
    required int episodeIndex,
  }) {
    final id = DownloadTask.buildId(
      vodId: vodId,
      sourceName: sourceName,
      episodeIndex: episodeIndex,
    );
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  // =========================================================================
  // 生命周期
  // =========================================================================

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    _tasks.clear();
    _tasks.addAll(DownloadTask.decodeList(_prefs!.getString(_keyTasks) ?? ''));

    // 进程上次被杀时停留在「下载中 / 合并中」的任务，状态已经没有意义了，
    // 改回「排队中」重新排队。分片文件还在，续传会跳过已下好的部分。
    var dirty = false;
    for (var i = 0; i < _tasks.length; i++) {
      final t = _tasks[i];
      if (t.status == DownloadStatus.downloading ||
          t.status == DownloadStatus.merging) {
        _tasks[i] = t.copyWith(status: DownloadStatus.queued, clearError: true);
        dirty = true;
      }
    }
    if (dirty) await _persist();
    _safeNotify();
    _pump();
  }

  /// 继续所有下载：把暂停中的改回排队，然后把队列跑起来。
  ///
  /// 必须同时处理「排队中」和「已暂停」两种状态 —— 只叫醒排队中的话，
  /// 用户点过「全部暂停」之后就再也恢复不了了（暂停的任务会永远停在 paused）。
  void resumeAll() {
    var dirty = false;
    // 用户明确要求继续，退避闸门一律清掉，不用再等。
    _retryAfter.clear();
    for (var i = 0; i < _tasks.length; i++) {
      final t = _tasks[i];
      if (t.status == DownloadStatus.paused) {
        _stopRequested.remove(t.id);
        _tasks[i] = t.copyWith(status: DownloadStatus.queued);
        dirty = true;
      }
    }
    if (dirty) {
      _persist();
      _safeNotify();
    }
    _pump();
  }

  /// 全局暂停：停掉当前任务，并把所有排队中的也挂起。
  void pauseAll() {
    _retryAfter.clear();
    for (var i = 0; i < _tasks.length; i++) {
      final t = _tasks[i];
      if (t.status == DownloadStatus.queued ||
          t.status == DownloadStatus.downloading) {
        _stopRequested.add(t.id);
        _tasks[i] = t.copyWith(status: DownloadStatus.paused);
      }
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    _persist();
    _safeNotify();
    _stopForeground();
  }

  // =========================================================================
  // 入队 / 控制
  // =========================================================================

  /// 入队一集。已经存在（无论什么状态）就不重复入队。
  Future<DownloadTask> enqueue({
    required String vodId,
    required String title,
    required String cover,
    required String sourceName,
    required String episodeName,
    required int episodeIndex,
    required String playPath,
  }) async {
    final id = DownloadTask.buildId(
      vodId: vodId,
      sourceName: sourceName,
      episodeIndex: episodeIndex,
    );
    final existing = findByEpisode(
      vodId: vodId,
      sourceName: sourceName,
      episodeIndex: episodeIndex,
    );
    if (existing != null) {
      // 已完成的再点一次不重下；失败/暂停的则当成「重试」。
      if (existing.canResume) await retry(id);
      return existing;
    }

    final task = DownloadTask(
      id: id,
      vodId: vodId,
      title: title,
      cover: cover,
      sourceName: sourceName,
      episodeName: episodeName,
      episodeIndex: episodeIndex,
      playPath: playPath,
    );
    _tasks.add(task);
    await _persist();
    _safeNotify();
    _pump();
    return task;
  }

  /// 批量入队（「下载本线路全部集数」）。
  Future<int> enqueueMany(
    Iterable<({String episodeName, int episodeIndex, String playPath})>
    episodes, {
    required String vodId,
    required String title,
    required String cover,
    required String sourceName,
  }) async {
    var added = 0;
    for (final ep in episodes) {
      final exists = findByEpisode(
        vodId: vodId,
        sourceName: sourceName,
        episodeIndex: ep.episodeIndex,
      );
      if (exists != null) continue;
      _tasks.add(
        DownloadTask(
          id: DownloadTask.buildId(
            vodId: vodId,
            sourceName: sourceName,
            episodeIndex: ep.episodeIndex,
          ),
          vodId: vodId,
          title: title,
          cover: cover,
          sourceName: sourceName,
          episodeName: ep.episodeName,
          episodeIndex: ep.episodeIndex,
          playPath: ep.playPath,
        ),
      );
      added++;
    }
    if (added > 0) {
      await _persist();
      _safeNotify();
      _pump();
    }
    return added;
  }

  void pause(String id) {
    final i = _indexOf(id);
    if (i < 0) return;
    final t = _tasks[i];
    if (!t.canPause) return;
    _stopRequested.add(id);
    _retryAfter.remove(id);
    _tasks[i] = t.copyWith(status: DownloadStatus.paused);
    _persist();
    _safeNotify();
  }

  Future<void> retry(String id) async {
    final i = _indexOf(id);
    if (i < 0) return;
    final t = _tasks[i];
    if (t.isDone) return;
    _stopRequested.remove(id);
    // 手动重试要把自动重试的计数清掉，否则用户点两次就「次数用尽」了。
    // 退避闸门同理要清 —— 用户已经主动要求重试，没理由再让他等 30 秒。
    _retryAfter.remove(id);
    _tasks[i] = t.copyWith(
      status: DownloadStatus.queued,
      attempt: 0,
      clearError: true,
    );
    await _persist();
    _safeNotify();
    _pump();
  }

  /// 删除任务。[deleteFiles] 为 true 时连磁盘上的成品和分片一起删。
  Future<void> remove(String id, {bool deleteFiles = true}) async {
    final i = _indexOf(id);
    if (i < 0) return;
    final t = _tasks[i];
    _stopRequested.add(id);
    _retryAfter.remove(id);
    _tasks.removeAt(i);
    if (_activeTaskId == id) _activeTaskId = null;
    await _persist();
    _safeNotify();

    if (deleteFiles) {
      await _deleteTaskFiles(t);
    }
    _pump();
  }

  /// 清掉所有已完成任务的记录（磁盘文件保留）。
  Future<void> clearFinished() async {
    _tasks.removeWhere((t) => t.isDone);
    await _persist();
    _safeNotify();
  }

  // =========================================================================
  // 队列调度
  // =========================================================================

  void _pump() {
    if (_disposed) return;
    if (_activeTaskId != null) return; // 已有任务在跑

    final now = DateTime.now();
    DownloadTask? next;
    for (final t in _tasks) {
      if (t.status != DownloadStatus.queued) continue;
      // 退避窗口内不碰它 —— 见 _retryAfter 的注释。
      final until = _retryAfter[t.id];
      if (until != null && now.isBefore(until)) continue;
      next = t;
      break;
    }
    if (next == null) {
      // 只有队列真的空了才撤前台服务。
      //
      // 注意「没有可跑的任务」≠「队列空了」：任务正处在 30 秒退避窗口里时这里也
      // 找不到 next。如果那时就撤服务，30 秒后重试时 App 多半已在后台，而
      // Android 12+ 禁止后台调用 startForegroundService —— 那一次重试就彻底失去
      // 保活保护，进程被系统回收的话这一集就白排了。所以退避期间让服务继续活着。
      final stillPending = _tasks.any((t) => t.status.isActive);
      if (!stillPending) _stopForeground();
      return;
    }
    _activeTaskId = next.id;
    unawaited(_runTask(next.id));
  }

  Future<void> _runTask(String taskId) async {
    final i = _indexOf(taskId);
    if (i < 0) {
      _activeTaskId = null;
      _pump();
      return;
    }

    var task = _tasks[i];

    // 排队之后、真正开跑之前，用户可能已经把它暂停了（或者删了）。
    // 这里不再检查一次的话会把暂停「顶掉」，用户点了暂停却还在下。
    if (task.status == DownloadStatus.paused) {
      _activeTaskId = null;
      _pump();
      return;
    }

    _stopRequested.remove(taskId);
    _setTask(
      i,
      task.copyWith(status: DownloadStatus.downloading, clearError: true),
    );
    _speedBps = 0;
    _lastSpeedBytes = 0;
    _lastSpeedAt = DateTime.now();
    // 立刻起前台服务：不能等到第一个分片下完才起。用户完全可能一点下载就切走，
    // 那几秒里没有前台服务保护，进程被系统回收的话这一集就白排了。
    _postForeground();

    try {
      // --- 1. 拿 m3u8 地址（没缓存过就先解析播放页） ---------------------
      var playlistUrl = task.playlistUrl;
      if (playlistUrl == null || playlistUrl.isEmpty) {
        playlistUrl = await _scraper.resolvePlayM3u8(task.playPath);
        if (playlistUrl == null || playlistUrl.isEmpty) {
          throw const _DownloadError('解析播放地址失败（站点没给这一集配源）');
        }
        task = task.copyWith(playlistUrl: playlistUrl);
        _setTask(i, task);
      }

      // --- 2. 取播放列表 --------------------------------------------------
      var playlist = await _fetchPlaylist(playlistUrl);

      // master playlist：挑第一个变体再取一次。
      if (playlist.variantUri != null) {
        playlistUrl = playlist.variantUri!;
        task = task.copyWith(playlistUrl: playlistUrl);
        _setTask(i, task);
        playlist = await _fetchPlaylist(playlistUrl);
      }

      if (playlist.segments.isEmpty) {
        throw const _DownloadError('播放列表里没有分片');
      }

      task = task.copyWith(
        totalSegments: playlist.segments.length,
        durationSeconds: playlist.durationSeconds,
        encrypted: playlist.encrypted,
      );
      _setTask(i, task);

      // 这条日志是「这一集到底会下成什么样」的唯一答案来源：
      // 加密与否决定能不能合并成单文件，而**在 PC 侧无法预先判定** ——
      // 站点 CDN 会对非 App 来源的 IP 直接关连接（连 TLS 握手都拒），
      // 所以只能让 App 自己在下第一集时把结论打出来。
      debugPrint(
        '[DownloadService] 播放列表已解析：'
        '${playlist.segments.length} 片 / ${playlist.durationSeconds}s / '
        '加密=${playlist.encrypted} / fMP4=${playlist.isFmp4} / '
        'keyUri=${playlist.keyUri ?? "-"} / initUri=${playlist.initUri ?? "-"}',
      );
      debugPrint(
        '[DownloadService] ⇒ 落盘方式：'
        '${playlist.encrypted ? "逐片 AES 解密后合并成单个 .mp4（媒体序号 ${playlist.mediaSequence} 起）" : "直接合并成单个 .mp4"}',
      );
      debugPrint(
        '[DownloadService] ⇒ 成品路径：'
        '${DownloadStorage.sanitizeFileName(task.title)}/'
        '${DownloadStorage.sanitizeFileName(task.title)}'
        '_${_episodeNumber(task)}.mp4',
      );
      debugPrint('[DownloadService] playlistUrl = $playlistUrl');

      // --- 3. 准备目录 ----------------------------------------------------
      final dir = await _storage.resolve();
      final workDir = Directory(
        '${dir.path}/$_workRootName/${_safeId(task.id)}',
      );
      final partsDir = Directory('${workDir.path}/parts');
      if (!partsDir.existsSync()) partsDir.createSync(recursive: true);

      final base = playlistUrl;
      final ext = playlist.isFmp4 ? 'm4s' : 'ts';

      // --- 4. 加密线路：把密钥也抓下来（合并时逐片解密要用） --------------
      String? keyFileName;
      List<int>? aesKey;
      if (playlist.encrypted) {
        keyFileName = 'key.bin';
        // AES-128 的密钥就是 16 字节，不能套用分片那套 1KB 门槛。
        final keyBytes = await _fetchBytes(
          playlist.keyUri!,
          retries: maxSegmentAttempts,
          minBytes: 16,
        );
        if (keyBytes == null) {
          throw const _DownloadError('加密线路的密钥下载失败');
        }
        aesKey = keyBytes;
        File('${workDir.path}/$keyFileName').writeAsBytesSync(keyBytes);
      }

      // --- 5. fMP4 的初始化分片 ------------------------------------------
      if (playlist.initUri != null) {
        // 初始化分片通常只有几百字节，同样不能套 1KB 门槛。
        final initBytes = await _fetchBytes(
          playlist.initUri!,
          retries: maxSegmentAttempts,
          minBytes: 32,
        );
        if (initBytes == null) throw const _DownloadError('初始化分片下载失败');
        File('${partsDir.path}/init.$ext').writeAsBytesSync(initBytes);
      }

      // --- 6. 并发下分片 --------------------------------------------------
      final done = await _downloadSegments(
        taskId: task.id,
        taskIndex: i,
        segments: playlist.segments,
        partsDir: partsDir,
        ext: ext,
        base: base,
      );

      // 被暂停 / 被删除 / 被要求停下：安静退出，不标失败。
      if (!done) {
        _activeTaskId = null;
        _pump();
        return;
      }

      // --- 7. 收尾 --------------------------------------------------------
      final fresh = _indexOf(taskId);
      if (fresh < 0) {
        _activeTaskId = null;
        _pump();
        return;
      }
      task = _tasks[fresh];

      // 成品一律是 `<剧名>/<剧名>_<集号>.mp4`。
      //
      // 注意：TS 分片拼出来的容器其实是 MPEG-TS，不是 MP4。后缀按用户要求统一
      // 写成 .mp4 —— 安卓侧的播放器（MX Player / VLC / ExoPlayer）都按**内容**
      // 嗅探，照播不误；但如果把文件拷到电脑上，Windows 自带播放器可能不认，
      // 用 VLC 打开即可。
      const outExt = 'mp4';

      if (playlist.encrypted) {
        // 加密线路：逐片解密后合并。之前「加密不能合并」的说法只在
        // 「不解密直接拼」的前提下成立 —— 每片用各自的 IV 解一次再追加就没问题。
        _setTask(fresh, task.copyWith(status: DownloadStatus.merging));
        await _persist();
        _safeNotify();

        String? singlePath;
        Object? mergeError;
        try {
          singlePath = await _mergeEncryptedToSingleFile(
            task: task,
            partsDir: partsDir,
            playlist: playlist,
            ext: ext,
            outExt: outExt,
            downloadRoot: dir.path,
            key: aesKey ?? const <int>[],
          );
        } catch (e) {
          mergeError = e;
        }

        // 被暂停 / 被删除：安静退出（不是失败，也别写 local.m3u8）。
        if (singlePath == null && mergeError == null) {
          _activeTaskId = null;
          _pump();
          return;
        }

        if (singlePath == null) {
          // 解密失败（例如原生通道不可用）→ 退回「保留分片 + local.m3u8」，
          // 总比把已经下好的整集丢掉强。这时**不能**删中间文件，
          // 否则那个 local.m3u8 指向的分片就没了。
          debugPrint('[DownloadService] 解密合并失败，退回保留分片：$mergeError');
          final localPlaylist = _buildLocalPlaylist(
            playlist: playlist,
            ext: ext,
            keyFileName: keyFileName,
          );
          File('${workDir.path}/local.m3u8').writeAsStringSync(localPlaylist);
          final idx = _indexOf(taskId);
          if (idx >= 0) {
            _setTask(
              idx,
              _tasks[idx].copyWith(
                status: DownloadStatus.completed,
                doneSegments: playlist.segments.length,
                outputPath: workDir.path,
                errorMessage: '解密失败，已保留分片与 local.m3u8',
              ),
            );
          }
          await _persist();
          _safeNotify();
          return;
        }

        final idx = _indexOf(taskId);
        if (idx >= 0) {
          _setTask(
            idx,
            _tasks[idx].copyWith(
              status: DownloadStatus.completed,
              doneSegments: playlist.segments.length,
              outputPath: singlePath,
              clearError: true,
            ),
          );
        }
        await _persist();
        _safeNotify();
        _deleteWorkDir(workDir);
      } else {
        _setTask(fresh, task.copyWith(status: DownloadStatus.merging));
        await _persist();
        _safeNotify();

        final outPath = await _mergeToSingleFile(
          task: task,
          partsDir: partsDir,
          ext: ext,
          outExt: outExt,
          downloadRoot: dir.path,
        );

        final after = _indexOf(taskId);
        if (after >= 0) {
          _setTask(
            after,
            _tasks[after].copyWith(
              status: DownloadStatus.completed,
              outputPath: outPath,
              clearError: true,
            ),
          );
        }
        await _persist();
        _safeNotify();

        // 合并成功才清工作目录。失败时留着，重试能直接续传。
        _deleteWorkDir(workDir);
      }
    } catch (e) {
      await _handleTaskFailure(taskId, e);
    } finally {
      _activeTaskId = null;
      _speedBps = 0;
      _safeNotify();
      _pump();
    }
  }

  /// 并发下所有分片。返回 false 表示「被主动停下」（暂停/删除），不是失败。
  Future<bool> _downloadSegments({
    required String taskId,
    required int taskIndex,
    required List<_Seg> segments,
    required Directory partsDir,
    required String ext,
    required String base,
  }) async {
    final total = segments.length;
    var nextIndex = 0;
    var doneCount = 0;
    var bytes = 0;
    Object? firstError;

    // 先扫一遍磁盘：已经下好的分片直接算数，这就是「断点续传」。
    final missing = <int>[];
    for (var idx = 0; idx < total; idx++) {
      final f = File('${partsDir.path}/${_partName(idx, ext)}');
      if (f.existsSync() && f.lengthSync() >= minValidSegmentBytes) {
        doneCount++;
        bytes += f.lengthSync();
      } else {
        missing.add(idx);
      }
    }
    if (doneCount > 0) {
      final i = _indexOf(taskId);
      if (i >= 0) {
        _setTask(
          i,
          _tasks[i].copyWith(doneSegments: doneCount, totalBytes: bytes),
        );
      }
      debugPrint('[DownloadService] resume: $doneCount/$total 片已在磁盘上，跳过');
    }

    Future<void> worker() async {
      while (true) {
        if (_stopRequested.contains(taskId)) return;
        final slot = nextIndex;
        if (slot >= missing.length) return;
        nextIndex++;

        final idx = missing[slot];
        final seg = segments[idx];
        final file = File('${partsDir.path}/${_partName(idx, ext)}');

        final data = await _fetchBytes(
          seg.url,
          retries: maxSegmentAttempts,
          cancelKey: taskId,
        );

        if (_stopRequested.contains(taskId)) return;

        if (data == null) {
          firstError ??= const _DownloadError('有分片多次重试仍下载失败');
          return;
        }
        try {
          // 用异步写入，别用 writeAsBytesSync：这里是**每个分片**都走的循环，
          // 而同步写 + flush 会在主 isolate 上真的阻塞（落盘 + fsync）。
          // 下载页正在滚动 / 显示进度时，每个分片卡一下就是掉帧。
          // flush: true 保持不变 —— 下面 788 行注释说了「每片都落盘，进程被杀
          // 之后进度不会丢」，落盘语义不能动，只把阻塞挪出主 isolate。
          await file.writeAsBytes(data, flush: true);
        } catch (e) {
          firstError ??= e;
          return;
        }

        doneCount++;
        bytes += data.length;
        _updateSpeed(bytes);

        final i = _indexOf(taskId);
        if (i >= 0) {
          // 每片都落盘：进程被杀之后进度不会丢，因为文件本身就是进度；
          // 这里写的是「给 UI 看的计数」。
          _setTask(
            i,
            _tasks[i].copyWith(doneSegments: doneCount, totalBytes: bytes),
          );
        }
        _throttledNotify();
      }
    }

    await Future.wait(List.generate(segmentWorkers, (_) => worker()));

    if (_stopRequested.contains(taskId)) return false;

    final i = _indexOf(taskId);
    if (i >= 0) {
      _setTask(
        i,
        _tasks[i].copyWith(doneSegments: doneCount, totalBytes: bytes),
      );
    }

    // 任何一片最终没下来 → 整个任务算失败，交给任务级重试。
    if (doneCount < total) {
      throw firstError ?? _DownloadError('还有 ${total - doneCount} 个分片没下完');
    }
    return true;
  }

  String _partName(int index, String ext) =>
      '${index.toString().padLeft(5, '0')}.$ext';

  /// 删掉中间文件（分片目录 + 密钥 + init）。合并成功后才调用。
  ///
  /// 失败时**不能**删 —— 那些分片就是断点续传的依据，留着重试才能只补缺片。
  void _deleteWorkDir(Directory workDir) {
    try {
      if (workDir.existsSync()) workDir.deleteSync(recursive: true);
      debugPrint('[DownloadService] 已清理中间文件 ${workDir.path}');
    } catch (e) {
      debugPrint('[DownloadService] cleanup workDir failed: $e');
    }
  }

  void _updateSpeed(int totalBytes) {
    final now = DateTime.now();
    final ms = now.difference(_lastSpeedAt).inMilliseconds;
    if (ms < 500) return;
    final delta = totalBytes - _lastSpeedBytes;
    if (delta > 0) {
      _speedBps = delta * 1000 / ms;
    }
    _lastSpeedBytes = totalBytes;
    _lastSpeedAt = now;
  }

  /// 成品路径：`<下载根>/<剧名>/<剧名>_<集号>.<outExt>`。
  ///
  /// 目录按**剧名**分（同一部剧的各集自然聚在一起，文件夹我们自己建），
  /// 文件名就是「剧名_集号」—— 这是各类媒体库和电视自带播放器最容易识别的形态。
  String _outputPathFor(DownloadTask task, String downloadRoot, String outExt) {
    final title = DownloadStorage.sanitizeFileName(task.title);
    final showDir = Directory('$downloadRoot/$title');
    if (!showDir.existsSync()) showDir.createSync(recursive: true);
    return '${showDir.path}/${title}_${_episodeNumber(task)}.$outExt';
  }

  /// 集号：优先取站点集名里的数字（`第01集` / `第1集` / `01` 都能取到），
  /// 取不到才退回「列表下标 + 1」。
  ///
  /// 注意 `DownloadTask.episodeIndex` 是**0 基**的（它是 `source.episodes` 的下标），
  /// 所以退回时要 +1，否则第一集会变成 `00`。统一补零到两位，
  /// 这样文件名的字典序和实际集序一致。
  static String _episodeNumber(DownloadTask task) {
    final m = RegExp(r'\d+').firstMatch(task.episodeName);
    final parsed = m == null ? null : int.tryParse(m.group(0)!);
    final value = parsed ?? (task.episodeIndex + 1);
    return value.toString().padLeft(2, '0');
  }

  /// 把分片拼成一个文件（未加密线路）。
  ///
  /// TS 的分片本身就是可拼接的流；fMP4 则是「init 分片 + 若干 moof/mdat 分片」，
  /// 顺序拼起来同样是一个合法的 fMP4 文件。两种情况都直接用字节流追加。
  ///
  /// [ext] 是**分片文件**的扩展名（决定去磁盘上找哪些文件），
  /// [outExt] 是**成品**的扩展名。两者刻意分开：fMP4 的分片习惯叫 `.m4s`，
  /// 但 init + 全部 moof/mdat 拼完之后就是一个标准 MP4。
  Future<String> _mergeToSingleFile({
    required DownloadTask task,
    required Directory partsDir,
    required String ext,
    required String outExt,
    required String downloadRoot,
  }) async {
    final outPath = _outputPathFor(task, downloadRoot, outExt);
    final outFile = File(outPath);

    final total = task.totalSegments;
    final sink = outFile.openWrite();
    try {
      final initFile = File('${partsDir.path}/init.$ext');
      if (initFile.existsSync()) {
        await sink.addStream(initFile.openRead());
      }
      for (var idx = 0; idx < total; idx++) {
        final f = File('${partsDir.path}/${_partName(idx, ext)}');
        if (!f.existsSync()) continue;
        await sink.addStream(f.openRead());
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    debugPrint('[DownloadService] merged -> $outPath');
    return outPath;
  }

  /// 加密线路：**边解密边拼**成一个单文件。
  ///
  /// 之前说「加密线路不能合并」，只在「不解密直接拼」的前提下成立 ——
  /// HLS 的 AES-128 是**逐分片独立加密**的（IV 默认就是媒体序号），
  /// 所以只要对每一片用对应的 IV 解一次、再顺序追加，拼出来就是一个正常的单文件，
  /// 用户要的「一个 .mp4」在加密线路上同样能拿到。
  ///
  /// 返回 null 表示**被暂停/删除**（不是失败）；真正的失败会抛异常，
  /// 由调用方决定退回「保留分片 + local.m3u8」。
  Future<String?> _mergeEncryptedToSingleFile({
    required DownloadTask task,
    required Directory partsDir,
    required _Playlist playlist,
    required String ext,
    required String outExt,
    required String downloadRoot,
    required List<int> key,
  }) async {
    final total = task.totalSegments;
    final outPath = _outputPathFor(task, downloadRoot, outExt);
    final outFile = File(outPath);

    final sink = outFile.openWrite();
    try {
      // init 分片（fMP4 才有）按惯例是不加密的，原样放在最前面。
      final initFile = File('${partsDir.path}/init.$ext');
      if (initFile.existsSync()) {
        await sink.addStream(initFile.openRead());
      }

      for (var idx = 0; idx < total; idx++) {
        if (_stopRequested.contains(task.id)) return null;

        final f = File('${partsDir.path}/${_partName(idx, ext)}');
        if (!f.existsSync()) {
          throw _DownloadError('第 ${idx + 1} 个分片不在磁盘上，无法合并');
        }
        final raw = await f.readAsBytes();
        final plain = await _aesDecrypt(key, playlist.ivFor(idx), raw);
        if (plain == null) {
          throw _DownloadError('第 ${idx + 1} 个分片解密失败');
        }
        sink.add(plain);

        // 合并阶段也回报进度，否则这一集看着像卡住了。
        final i = _indexOf(task.id);
        if (i >= 0) {
          _setTask(i, _tasks[i].copyWith(doneSegments: idx + 1));
        }
        _throttledNotify();
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    debugPrint('[DownloadService] merged (decrypted) -> $outPath');
    return outPath;
  }

  /// 调原生解一个分片。返回 null 表示失败。
  ///
  /// 走 `javax.crypto`（Android 自带、有硬件加速），不引纯 Dart 密码库 ——
  /// `package:crypto` 只有哈希和 HMAC，没有分组密码。
  Future<Uint8List?> _aesDecrypt(
    List<int> key,
    List<int> iv,
    List<int> data,
  ) async {
    try {
      return await _cryptoChannel.invokeMethod<Uint8List>('aesCbcDecrypt', {
        'key': Uint8List.fromList(key),
        'iv': Uint8List.fromList(iv),
        'data': Uint8List.fromList(data),
      });
    } catch (e) {
      debugPrint('[DownloadService] AES 解密失败: $e');
      return null;
    }
  }

  /// 给加密线路写一个指向本地分片的播放列表。
  String _buildLocalPlaylist({
    required _Playlist playlist,
    required String ext,
    String? keyFileName,
  }) {
    final buf = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:3')
      ..writeln('#EXT-X-PLAYLIST-TYPE:VOD');

    final maxDur = playlist.segments.isEmpty
        ? 10
        : playlist.segments
              .map((s) => s.durationSec.ceil())
              .reduce((a, b) => a > b ? a : b);
    buf.writeln('#EXT-X-TARGETDURATION:$maxDur');
    // 必须沿用原始媒体序号：播放器是按「媒体序号」推 AES 的 IV 的，
    // 这里写死 0 的话，只要原列表的序号不是从 0 开始，解密就会整片错位。
    buf.writeln('#EXT-X-MEDIA-SEQUENCE:${playlist.mediaSequence}');
    if (keyFileName != null) {
      // 密钥已经落到本地，播放器不用再联网。
      buf.writeln('#EXT-X-KEY:METHOD=AES-128,URI="$keyFileName"');
    }
    if (playlist.initUri != null) {
      buf.writeln('#EXT-X-MAP:URI="parts/init.$ext"');
    }
    for (var i = 0; i < playlist.segments.length; i++) {
      buf.writeln(
        '#EXTINF:${playlist.segments[i].durationSec.toStringAsFixed(3)},',
      );
      buf.writeln('parts/${_partName(i, ext)}');
    }
    buf.writeln('#EXT-X-ENDLIST');
    return buf.toString();
  }

  // =========================================================================
  // 网络
  // =========================================================================

  /// 取播放列表。返回的地址都是**绝对地址**。
  ///
  /// 注意基准：必须用**跟随 302 之后的最终地址**去解析相对路径。
  /// 实测这条 2K 线路的播放列表会 302 跳到同集群的另一个节点，用原始地址当基准
  /// 解析出来的分片地址会落到「跳转前」那个节点上 —— 它对分片请求只回一个
  /// 3 字节的 `OK\n`，画面直接黑屏。
  Future<_Playlist> _fetchPlaylist(String url) async {
    final resp = await _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final body = resp.data;
    if (body == null || body.isEmpty) {
      throw const _DownloadError('播放列表为空');
    }
    final text = String.fromCharCodes(body);
    final base = resp.realUri.toString();

    if (!text.contains('#EXTM3U')) {
      throw const _DownloadError('拿到的不是播放列表（可能被 CDN 拦了）');
    }

    // master playlist：挑第一个变体，让调用方再去取一次。
    if (text.contains('#EXT-X-STREAM-INF')) {
      for (final line in text.split('\n')) {
        final t = line.trim();
        if (t.isEmpty || t.startsWith('#')) continue;
        return _Playlist(
          segments: const [],
          durationSeconds: 0,
          variantUri: Uri.parse(base).resolve(t).toString(),
        );
      }
      throw const _DownloadError('master 播放列表里没有变体');
    }

    final segments = <_Seg>[];
    String? keyUri;
    String? initUri;
    String? explicitIv;
    var mediaSequence = 0;
    var durationMicros = 0;
    var pendingDur = 0.0;

    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('#')) {
        if (t.startsWith('#EXTINF:')) {
          final raw = t.substring(8).split(',').first.trim();
          pendingDur = double.tryParse(raw) ?? 0;
          durationMicros += (pendingDur * 1000000).round();
        } else if (t.startsWith('#EXT-X-KEY:')) {
          // METHOD=NONE 表示这一段没加密。
          if (!t.contains('METHOD=NONE')) {
            final m = RegExp(r'URI="([^"]+)"').firstMatch(t);
            if (m != null) {
              keyUri = Uri.parse(base).resolve(m.group(1)!).toString();
            }
            // 有的打包器会显式写 IV，那就以它为准（见 _Playlist.ivFor）。
            final iv = RegExp(r'IV=(0[xX][0-9A-Fa-f]+)').firstMatch(t);
            if (iv != null) explicitIv = iv.group(1);
          }
        } else if (t.startsWith('#EXT-X-MAP:')) {
          final m = RegExp(r'URI="([^"]+)"').firstMatch(t);
          if (m != null) {
            initUri = Uri.parse(base).resolve(m.group(1)!).toString();
          }
        } else if (t.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
          mediaSequence = int.tryParse(t.substring(22).trim()) ?? 0;
        }
        continue;
      }
      segments.add(_Seg(Uri.parse(base).resolve(t).toString(), pendingDur));
      pendingDur = 0;
    }

    return _Playlist(
      segments: segments,
      durationSeconds: durationMicros ~/ 1000000,
      keyUri: keyUri,
      initUri: initUri,
      mediaSequence: mediaSequence,
      explicitIv: explicitIv,
    );
  }

  /// 下载一段字节，带退避重试。返回 null 表示最终失败。
  ///
  /// [minBytes] 是「多大的响应才算拿到了真东西」。默认按分片算 ——
  /// 该站点的 CDN 会用 **HTTP 200 + 3 字节 `OK\n`** 表示「这个节点没有这个分片」，
  /// 只判状态码会把这种垃圾当成功写进文件。但密钥文件本身就只有 16 字节、
  /// fMP4 的初始化分片也可能不到 1KB，所以这两种情况必须把门槛放低，
  /// 否则会把正常文件当成坏分片、反复重试到失败。
  Future<List<int>?> _fetchBytes(
    String url, {
    int retries = 1,
    String? cancelKey,
    int minBytes = minValidSegmentBytes,
  }) async {
    var delay = const Duration(milliseconds: 500);
    for (var attempt = 1; attempt <= retries; attempt++) {
      if (cancelKey != null && _stopRequested.contains(cancelKey)) return null;
      try {
        final resp = await _dio.get<List<int>>(
          url,
          options: Options(responseType: ResponseType.bytes),
        );
        final data = resp.data;
        if (data != null && data.length >= minBytes) {
          return data;
        }
        debugPrint(
          '[DownloadService] bad response (${data?.length ?? 0} bytes, '
          'need >= $minBytes) from $url — attempt $attempt/$retries',
        );
      } catch (e) {
        debugPrint(
          '[DownloadService] segment attempt $attempt/$retries '
          'failed: $e',
        );
      }

      if (attempt < retries) {
        // 0.5 → 1 → 2 → 4 → 8 秒，上限 8 秒。
        await Future.delayed(delay);
        delay *= 2;
        if (delay > const Duration(seconds: 8)) {
          delay = const Duration(seconds: 8);
        }
      }
    }
    return null;
  }

  // =========================================================================
  // 失败处理
  // =========================================================================

  Future<void> _handleTaskFailure(String taskId, Object error) async {
    final i = _indexOf(taskId);
    if (i < 0) return;

    // 被主动停下（暂停 / 删除）不算失败。
    if (_stopRequested.contains(taskId)) {
      debugPrint('[DownloadService] task $taskId stopped by request');
      return;
    }

    final task = _tasks[i];
    final attempt = task.attempt + 1;
    final message = error is _DownloadError ? error.message : '$error';
    debugPrint(
      '[DownloadService] task $taskId failed '
      '(attempt $attempt/$maxTaskAttempts): $message',
    );

    if (attempt < maxTaskAttempts) {
      // 任务级自动重试：先排队等一会儿，再整个重来。
      // 已经下好的分片会被跳过，所以重试的代价只是「还没下的那些」。
      //
      // 必须同时把 _retryAfter 写进去：否则 _runTask 的 finally 里那次 _pump()
      // 会立刻把这条 queued 的任务重新捡起来，退避等于没有。
      _retryAfter[taskId] = DateTime.now().add(taskRetryDelay);
      _setTask(
        i,
        task.copyWith(
          status: DownloadStatus.queued,
          attempt: attempt,
          errorMessage:
              '$message（第 $attempt 次失败，'
              '${taskRetryDelay.inSeconds} 秒后自动重试）',
        ),
      );
      await _persist();
      _safeNotify();
      _scheduleRetry();
      // 刷新一下通知，让「等待重试」这件事在通知栏可见（此时服务仍在跑）。
      _postForeground();
    } else {
      _setTask(
        i,
        task.copyWith(
          status: DownloadStatus.failed,
          attempt: attempt,
          errorMessage:
              '$message（已自动重试 $maxTaskAttempts 次，'
              '可点「重试」再试）',
        ),
      );
      await _persist();
      _safeNotify();
    }
  }

  /// 起一个定时器，到「最早那个解禁时刻」放行。
  ///
  /// 不用「每个任务一个 Timer」是因为那样要维护一堆句柄；也不用「固定 30 秒」，
  /// 因为多个任务先后失败时后面的会被前面的定时器顺手取消掉。这里每次都瞄准当前
  /// 最早的 deadline，回调里清掉已到点的闸门、再续下一个，不会漏也不会提前。
  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_retryAfter.isEmpty) return;

    final earliest = _retryAfter.values.reduce((a, b) => a.isBefore(b) ? a : b);
    var delay = earliest.difference(DateTime.now());
    if (delay < Duration.zero) delay = Duration.zero;

    _retryTimer = Timer(delay, () {
      if (_disposed) return;
      final now = DateTime.now();
      _retryAfter.removeWhere((_, until) => !now.isBefore(until));
      _safeNotify();
      _pump();
      _scheduleRetry(); // 还有别的任务在等，把下一个定时器续上
    });
  }

  // =========================================================================
  // 持久化 / 通知 / 工具
  // =========================================================================

  int _indexOf(String id) {
    for (var i = 0; i < _tasks.length; i++) {
      if (_tasks[i].id == id) return i;
    }
    return -1;
  }

  void _setTask(int index, DownloadTask task) {
    if (index < 0 || index >= _tasks.length) return;
    _tasks[index] = task;
  }

  Future<void> _persist() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_keyTasks, DownloadTask.encodeList(_tasks));
  }

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// 分片级的高频通知节流：最快 400ms 一次。
  void _throttledNotify() {
    final now = DateTime.now();
    if (now.difference(_lastNotifyAt).inMilliseconds < 400) return;
    _lastNotifyAt = now;
    _safeNotify();
    _postForeground();
  }

  /// 更新前台服务通知。
  ///
  /// 这个服务只负责「保活 + 显示进度」；真正的下载在 Dart 侧。
  /// 没有它的话，App 一退到后台，系统随时可能把进程杀掉、下载就断了。
  void _postForeground() {
    final t = activeTask;
    if (t == null) {
      _stopForeground();
      return;
    }
    final speed = _speedBps > 0
        ? ' · ${DownloadStorage.formatBytes(_speedBps.round())}/s'
        : '';
    final text =
        '${t.episodeName} · ${t.doneSegments}/${t.totalSegments} 片$speed';
    _fgChannel
        .invokeMethod<void>('post', {
          'title': '正在下载 ${t.title}',
          'text': text,
          'progress': t.doneSegments,
          'max': t.totalSegments,
        })
        .catchError((Object e) {
          // 后台启动被系统拒绝是预期内的：通知停在上一帧，下载照跑。
          debugPrint('[DownloadService] foreground post failed: $e');
        });
  }

  void _stopForeground() {
    _fgChannel.invokeMethod<void>('stop').catchError((Object e) {
      debugPrint('[DownloadService] foreground stop failed: $e');
    });
  }

  String _safeId(String raw) => raw.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');

  Future<void> _deleteTaskFiles(DownloadTask task) async {
    try {
      final out = task.outputPath;
      if (out != null && out.isNotEmpty) {
        final f = File(out);
        if (f.existsSync()) {
          f.deleteSync();
        } else {
          final d = Directory(out);
          if (d.existsSync()) d.deleteSync(recursive: true);
        }
      }
      final dir = await _storage.resolve();
      final workDir = Directory(
        '${dir.path}/$_workRootName/${_safeId(task.id)}',
      );
      if (workDir.existsSync()) workDir.deleteSync(recursive: true);
    } catch (e) {
      debugPrint('[DownloadService] deleteTaskFiles failed: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    super.dispose();
  }
}

/// 下载过程中的可预期错误（拿来当给用户看的文案）。
class _DownloadError implements Exception {
  final String message;
  const _DownloadError(this.message);
  @override
  String toString() => message;
}
