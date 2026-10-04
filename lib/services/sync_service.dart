import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/sync_payload.dart';
import '../models/webdav_config.dart';
import 'storage_service.dart';
import 'webdav_client.dart';

/// 同步当前处在哪一步，给设置页画状态用。
enum SyncPhase { idle, syncing, ok, failed }

/// 跨设备同步的编排层。
///
/// 只做一件事：把本机状态和云端那份 JSON 合到一起。合并规则统一是
/// 「谁的动作更晚谁赢」，两端各自记录自己的时间戳，所以没有「哪台是主设备」
/// 的问题，服务端也不需要任何特殊支持——一个 JSON 文件就够。
///
/// 为什么不用现成的同步方案：数据量只有几十 KB，而免费 WebDAV（坚果云）
/// 限流大约 30 分钟 600 次请求。**上传必须是独立防抖的**，绝不能挂在本地写入
/// 上：播放器每 10 秒存一次进度，一集 40 分钟就是 240 次写入，跟着传会立刻
/// 把配额吃光。所以这里只有 [markDirty] 一个入口，由它统一防抖。
class SyncService extends ChangeNotifier {
  static final SyncService instance = SyncService._internal();
  SyncService._internal();

  final StorageService _storage = StorageService.instance;

  /// 本地改动之后等多久再上传。
  ///
  /// 25 秒是权衡出来的：一轮播放中途停下来超过这个时间才会上传一次，
  /// 而连续搜索、连续收藏这类操作会被合并成一次。
  static const Duration uploadDebounce = Duration(seconds: 25);

  /// 一次同步最多重试几次（每次都重新拉取 + 重新合并）。
  static const int maxAttempts = 3;

  /// 「App 退到后台就顺手同步一次」的最小间隔，防止反复切前后台刷请求。
  static const Duration minSyncInterval = Duration(seconds: 60);

  SyncPhase _phase = SyncPhase.idle;
  SyncPhase get phase => _phase;

  String _message = '';
  String get message => _message;

  bool get isSyncing => _phase == SyncPhase.syncing;

  int get lastSyncAt => _storage.lastSyncAt;

  /// 上次同步时间，给设置页显示。
  String get lastSyncText {
    final ms = lastSyncAt;
    if (ms <= 0) return '从未同步';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  Timer? _uploadTimer;
  Timer? _startupTimer;
  bool _running = false;

  /// 一轮正在跑的时候又来了新改动：跑完立刻再跑一轮，别把这次改动丢掉。
  bool _runAgain = false;

  Future<void> init() async {
    await _storage.init();
    // 低频、用户主动的写操作会触发这里（收藏、清空、改设置……）。
    // 播放进度那种每 10 秒一次的写入**刻意不触发**，见类注释。
    _storage.addDirtyListener(markDirty);

    if (_storage.syncEnabled && _storage.webDavConfig.isConfigured) {
      // 启动后隔几秒再同步：别跟首屏那批接口请求抢带宽。
      _startupTimer = Timer(const Duration(seconds: 5), () {
        unawaited(syncNow());
      });
    }
  }

  /// 本机数据有改动，安排一次上传。
  ///
  /// 注意是**防抖**不是立即上传：每次调用都会把计时器往后推，所以一轮连续
  /// 操作（连着搜 5 次、连着收藏 3 个）只会产生一次上传。
  void markDirty() {
    if (!_storage.syncEnabled) return;
    if (!_storage.webDavConfig.isConfigured) return;
    _uploadTimer?.cancel();
    _uploadTimer = Timer(uploadDebounce, () {
      _uploadTimer = null;
      unawaited(syncNow());
    });
  }

  /// App 退到后台时调用：把待上传的改动立刻推出去，别等那 25 秒防抖。
  ///
  /// 没有待上传改动时也同步一次（带限流）。这不是多余的：播放进度是在播放
  /// 过程中每 10 秒写进本机的，光靠播放器 `dispose` 那一下保不住它——用户
  /// 直接从播放器切走时 `dispose` 根本不会触发，而进程随时可能被系统杀掉。
  ///
  /// 一次同步是 2 个请求（GET + PUT）。坚果云免费版约 30 分钟 600 次，
  /// 配合 [minSyncInterval] 正常使用远远够用。
  Future<void> onAppBackgrounded() async {
    if (!_storage.syncEnabled) return;
    if (!_storage.webDavConfig.isConfigured) return;

    final pending = _uploadTimer != null;
    _uploadTimer?.cancel();
    _uploadTimer = null;

    if (!pending) {
      final since = DateTime.now().millisecondsSinceEpoch - _storage.lastSyncAt;
      if (_storage.lastSyncAt > 0 && since < minSyncInterval.inMilliseconds) {
        return;
      }
    }
    await syncNow();
  }

  /// 配置保存后调用。自动同步开着的话立刻拉一次，让用户马上看到效果。
  void onConfigChanged() {
    _startupTimer?.cancel();
    _startupTimer = null;
    if (_storage.syncEnabled && _storage.webDavConfig.isConfigured) {
      unawaited(syncNow());
    }
  }

  /// 用一份**还没保存**的配置测试连接（设置页的「测试连接」按钮）。
  ///
  /// 失败时抛 [WebDavException]，`message` 可以直接显示给用户。
  Future<String> testConnection(WebDavConfig config) async {
    final client = WebDavClient(config);
    try {
      return await client.probe();
    } finally {
      client.close();
    }
  }

  /// 完整跑一轮：拉取 → 合并 → 推送 → 落盘。
  Future<void> syncNow() => _runExclusive('正在同步…', _syncOnce);

  /// 以本机为准覆盖云端。
  ///
  /// 给「两端时间戳分不出先后」准备的兜底手段——比如某台设备系统时间明显
  /// 不对，它的时间戳会一直偏大、一直赢。这种情况没法靠合并算法猜出来，
  /// 只能让用户明确选一边。
  Future<void> forcePushLocal() => _runExclusive('正在以本机为准覆盖云端…', _forcePush);

  /// 以云端为准覆盖本机。
  Future<void> forcePullRemote() => _runExclusive('正在以云端为准覆盖本机…', _forcePull);

  /// 同一时刻只允许一轮在跑，避免两个并发同步互相把对方的 ETag 撞掉。
  Future<void> _runExclusive(
    String busyLabel,
    Future<String> Function(WebDavClient client) body,
  ) async {
    if (_running) {
      _runAgain = true;
      return;
    }
    final config = _storage.webDavConfig;
    if (!config.isConfigured) {
      _setPhase(SyncPhase.failed, '还没配置 WebDAV 地址和用户名');
      return;
    }

    _running = true;
    _setPhase(SyncPhase.syncing, busyLabel);
    WebDavClient? client;
    try {
      client = WebDavClient(config);
      await client.ensureCollection();
      final summary = await body(client);
      await _storage.setLastSyncAt(DateTime.now().millisecondsSinceEpoch);
      _setPhase(SyncPhase.ok, summary);
    } on WebDavException catch (e) {
      _setPhase(SyncPhase.failed, e.message);
    } catch (e) {
      _setPhase(SyncPhase.failed, '同步失败：$e');
    } finally {
      client?.close();
      _running = false;
      if (_runAgain) {
        _runAgain = false;
        unawaited(syncNow());
      }
    }
  }

  Future<String> _syncOnce(WebDavClient client) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final remote = await client.get(kSyncFileName);
      final now = DateTime.now().millisecondsSinceEpoch;

      if (remote == null) {
        // 云端还没有这个文件：直接把本机数据推上去。
        // 用 `If-None-Match: *` 而不是无条件写：万一另一台设备就在这几毫秒里
        // 建好了文件，我们会拿到 412 去重新合并，而不是把对方整个盖掉。
        final local = _storage.exportSyncPayload(now: now);
        try {
          await client.put(kSyncFileName, local.encode(), createOnly: true);
        } on WebDavException catch (e) {
          if (e.isConflict && attempt < maxAttempts) continue;
          rethrow;
        }
        await _storage.applySyncPayload(local);
        return '已把本机数据上传到云端（${local.describe()}）';
      }

      final decoded = SyncPayload.decode(remote.body);
      if (decoded.error != null) {
        // 读不懂就停下。绝不能拿本机数据把它盖掉——那等于把另一台设备的
        // 数据直接删了。只有用户手动点「以本机为准覆盖云端」才会覆盖。
        throw WebDavException('${decoded.error}。已中止同步，云端文件没有被改动');
      }

      final localPayload = _storage.exportSyncPayload(now: now);
      final merged = SyncPayload.merge(
        local: localPayload,
        remote: decoded.payload ?? SyncPayload.empty,
        now: now,
      );

      try {
        await client.put(kSyncFileName, merged.encode(), ifMatch: remote.etag);
      } on WebDavException catch (e) {
        if (e.isConflict && attempt < maxAttempts) {
          debugPrint('[SyncService] 第 $attempt 次遇到云端冲突，重新拉取后重试');
          continue;
        }
        rethrow;
      }

      // 推送成功之后才落盘：推送失败时本机保持原样，下次同步重新合并一遍
      // （合并是幂等的），不会出现「本地已经是合并结果、云端却没写进去」
      // 这种两边不一致的中间态。
      await _storage.applySyncPayload(merged);
      return '已同步（${merged.describe()}）';
    }
    throw const WebDavException('云端文件一直被其他设备改动，请稍后再试');
  }

  Future<String> _forcePush(WebDavClient client) async {
    final local = _storage.exportSyncPayload(
      now: DateTime.now().millisecondsSinceEpoch,
    );
    // 不带 If-Match：用户点的就是「覆盖」，这里就是要盖掉云端。
    await client.put(kSyncFileName, local.encode());
    await _storage.applySyncPayload(local);
    return '已用本机数据覆盖云端（${local.describe()}）';
  }

  Future<String> _forcePull(WebDavClient client) async {
    final remote = await client.get(kSyncFileName);
    if (remote == null) throw const WebDavException('云端还没有同步文件');
    final decoded = SyncPayload.decode(remote.body);
    if (decoded.error != null) throw WebDavException(decoded.error!);
    final payload = decoded.payload;
    if (payload == null) throw const WebDavException('云端同步文件是空的');
    await _storage.applySyncPayload(payload);
    return '已用云端数据覆盖本机（${payload.describe()}）';
  }

  void _setPhase(SyncPhase phase, String message) {
    _phase = phase;
    _message = message;
    debugPrint('[SyncService] $phase: $message');
    notifyListeners();
  }
}
