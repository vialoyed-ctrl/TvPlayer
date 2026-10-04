import 'dart:convert';

import 'history_item.dart';
import 'vod_item.dart';

/// 同步文档（云端 `sync.json`）的结构版本号。
///
/// 解码器对未知字段是宽容的，所以**新增可选字段不需要改版本号**；
/// 只有在已有字段的含义发生不兼容变化时才 +1。
const int kSyncSchema = 1;

/// 观看历史最多保留多少条。
///
/// 与 `StorageService.saveHistory` 共用同一个上限。两处必须一致：合并时按
/// 这个数裁掉、本地写入又按这个数裁掉，一旦两个数字不同，多出来的那部分
/// 就会每次同步都被反复丢弃又重建。
const int kMaxHistoryItems = 100;

/// 搜索历史最多保留多少个关键词，同上。
const int kMaxSearchItems = 20;

/// 「这东西在同步功能出现之前就已经存在」的哨兵时间戳。
///
/// 收藏功能早于同步功能，老数据没有 `addedAt`。如果当成 0，收藏的存活判定
/// `addedAt > removedAt` 会把用户原有的收藏全部判成「已删除」。用这个值兜住：
/// 它 > 0 所以保持存活，又远小于任何真实的 epoch 毫秒（真实值至少 1.7e12），
/// 所以「另一台设备把它删了」这个更晚的动作永远能赢。
const int kLegacyStamp = 1;

/// 宽容地把任意 JSON 值读成非负整数，读不出来就当 0。
int _asInt(Object? v) {
  if (v is int) return v < 0 ? 0 : v;
  if (v is num) {
    final i = v.toInt();
    return i < 0 ? 0 : i;
  }
  return 0;
}

/// 一个「带时间戳的值」。
///
/// 同步里所有的标量项（跳片头秒数、跳片尾秒数、自动换源开关、搜索关键词）
/// 都统一成这个形状，于是合并规则只剩下一条：**谁的时间戳更大谁赢**。
/// [at] 为 0 表示「从来没设置过」，这时无条件让位给对面。
class TimedValue {
  final Object? value;
  final int at;

  const TimedValue(this.value, this.at);

  /// 是否是一个「用户真的动过手」的值。
  bool get isSet => at > 0;

  int? get asInt => value is int ? value as int : null;

  bool? get asBool => value is bool ? value as bool : null;

  String? get asString => value is String ? value as String : null;

  Map<String, dynamic> toJson() => {'v': value, 't': at};

  /// 读不出来返回 null（而不是一个 at=0 的空壳），让合并逻辑能把
  /// 「字段缺失」和「字段存在但没设置过」区分开。
  static TimedValue? fromJson(Object? json) {
    if (json is! Map) return null;
    if (!json.containsKey('v')) return null;
    return TimedValue(json['v'], _asInt(json['t']));
  }

  @override
  String toString() => 'TimedValue($value @$at)';
}

/// 一条收藏记录（含墓碑）。
///
/// 存活判定只有一句：`addedAt > removedAt`。两端合并时这两个时间戳各取
/// max，于是「加」和「删」谁更晚、结果就是谁赢——不需要再额外定义优先级。
///
/// 墓碑（[item] 为 null 的记录）**不做回收**，永久保留。回收会让长期离线的
/// 设备把已删除的收藏「复活」：那台设备上 `removedAt` 随墓碑一起被丢掉之后，
/// 它本地的旧收藏就重新变成 `addedAt > 0 = removedAt`，一同步就回来了。
class FavoriteEntry {
  final String id;

  /// 最后一次执行「加入收藏」的时间。
  final int addedAt;

  /// 最后一次执行「取消收藏」的时间。
  final int removedAt;

  /// 收藏内容。墓碑不需要它，所以可以是 null。
  final VodItem? item;

  const FavoriteEntry({
    required this.id,
    required this.addedAt,
    required this.removedAt,
    this.item,
  });

  bool get isAlive => addedAt > removedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'addedAt': addedAt,
    'removedAt': removedAt,
    if (item != null) 'item': item!.toJson(),
  };

  static FavoriteEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;

    VodItem? item;
    final rawItem = json['item'];
    if (rawItem is Map) {
      try {
        item = VodItem.fromJson(Map<String, dynamic>.from(rawItem));
      } catch (_) {
        // 单条记录坏掉不该毁掉整份文档：没有 item 的活收藏会被本地忽略，
        // 但 addedAt 还在，下一次「加入收藏」就会把它补回来。
        item = null;
      }
    }

    return FavoriteEntry(
      id: id,
      addedAt: _asInt(json['addedAt']),
      removedAt: _asInt(json['removedAt']),
      item: item,
    );
  }
}

/// 需要同步的设置项。
///
/// 每一项都是 [TimedValue]，`null` 表示「本机从来没设置过」——注意这跟
/// 「设置成了默认值」是两回事：从没设置过就应该无条件接受对面传来的值，
/// 否则新装的设备永远同步不到老设备上改过的设置。
class SyncSettings {
  final TimedValue? skipIntroSeconds;
  final TimedValue? skipOutroSeconds;
  final TimedValue? autoSwitchSource;

  const SyncSettings({
    this.skipIntroSeconds,
    this.skipOutroSeconds,
    this.autoSwitchSource,
  });

  static const SyncSettings empty = SyncSettings();

  bool get isEmpty =>
      skipIntroSeconds == null &&
      skipOutroSeconds == null &&
      autoSwitchSource == null;

  Map<String, dynamic> toJson() => {
    if (skipIntroSeconds != null)
      'skipIntroSeconds': skipIntroSeconds!.toJson(),
    if (skipOutroSeconds != null)
      'skipOutroSeconds': skipOutroSeconds!.toJson(),
    if (autoSwitchSource != null)
      'autoSwitchSource': autoSwitchSource!.toJson(),
  };

  static SyncSettings fromJson(Object? json) {
    if (json is! Map) return empty;
    return SyncSettings(
      skipIntroSeconds: TimedValue.fromJson(json['skipIntroSeconds']),
      skipOutroSeconds: TimedValue.fromJson(json['skipOutroSeconds']),
      autoSwitchSource: TimedValue.fromJson(json['autoSwitchSource']),
    );
  }
}

/// 解码结果。
///
/// 必须把「云端还没有文件」和「云端有文件但读不懂」分开：前者可以放心把
/// 本机数据推上去，后者**必须中止同步**——拿本机数据覆盖一个读不懂的文件，
/// 等于把另一台设备的数据直接删掉。
class SyncDecodeResult {
  final SyncPayload? payload;

  /// 非空表示云端文件存在但无法解析，此时必须中止。
  final String? error;

  const SyncDecodeResult._(this.payload, this.error);

  /// 云端还没有同步文件（或文件是空的）。
  const SyncDecodeResult.fresh() : this._(null, null);

  const SyncDecodeResult.ok(SyncPayload payload) : this._(payload, null);

  const SyncDecodeResult.broken(String reason) : this._(null, reason);

  bool get isFresh => payload == null && error == null;

  bool get isOk => payload != null;
}

/// 一份完整的同步文档。
///
/// 这是**纯数据 + 纯函数**，不碰网络也不碰 SharedPreferences，所以合并算法
/// 可以单独验证（见 `sim_sync_merge.py`）。
class SyncPayload {
  final int schema;

  /// 写入云端的时间，只用于展示「云端数据时间」。
  final int savedAt;

  final List<HistoryItem> history;

  /// 最后一次「清空观看历史」的时间。合并时取两端的最大值，再把
  /// `updatedAt <= historyClearedAt` 的记录滤掉，这样「清空」这个动作也能同步。
  final int historyClearedAt;

  /// 收藏记录，**包含墓碑**。
  final List<FavoriteEntry> favorites;

  /// 搜索历史，`value` 是关键词。
  final List<TimedValue> searchHistory;

  /// 最后一次「清空搜索历史」的时间。
  final int searchClearedAt;

  final SyncSettings settings;

  const SyncPayload({
    this.schema = kSyncSchema,
    this.savedAt = 0,
    this.history = const [],
    this.historyClearedAt = 0,
    this.favorites = const [],
    this.searchHistory = const [],
    this.searchClearedAt = 0,
    this.settings = SyncSettings.empty,
  });

  static const SyncPayload empty = SyncPayload();

  /// 活着的收藏个数（墓碑不算）。
  int get aliveFavoriteCount => favorites.where((f) => f.isAlive).length;

  /// 给设置页用的一行摘要。
  String describe() =>
      '历史 ${history.length} 条 · 收藏 $aliveFavoriteCount 个 · 搜索 ${searchHistory.length} 个';

  Map<String, dynamic> toJson() => {
    'schema': schema,
    'savedAt': savedAt,
    'history': history.map((h) => h.toJson()).toList(),
    'historyClearedAt': historyClearedAt,
    'favorites': favorites.map((f) => f.toJson()).toList(),
    'searchHistory': searchHistory.map((t) => t.toJson()).toList(),
    'searchClearedAt': searchClearedAt,
    'settings': settings.toJson(),
  };

  /// 带缩进编码。文件只有几十 KB，换行缩进换来的是「用户能用 WebDAV
  /// 直接打开看一眼」，值。
  String encode() => JsonEncoder.withIndent('  ').convert(toJson());

  /// 宽容解码。见 [SyncDecodeResult] 对 fresh / broken 的区分。
  static SyncDecodeResult decode(String? body) {
    final text = body?.trim() ?? '';
    if (text.isEmpty) return const SyncDecodeResult.fresh();

    Object? raw;
    try {
      raw = jsonDecode(text);
    } catch (e) {
      return SyncDecodeResult.broken('云端文件不是合法 JSON（$e）');
    }
    if (raw is! Map) {
      return const SyncDecodeResult.broken('云端文件顶层不是 JSON 对象');
    }
    final map = Map<String, dynamic>.from(raw);

    // 认不出是我们自己的文档就别动它。最常见的触发场景：WebDAV 服务端
    // 把 404 或目录列表当成正文返回，此时若继续「以本机覆盖云端」，
    // 就会把真正的那份数据冲掉。
    if (map['schema'] is! int) {
      return const SyncDecodeResult.broken('云端文件里没有 schema 字段，不像是本应用的同步文件');
    }

    final history = <HistoryItem>[];
    final rawHistory = map['history'];
    if (rawHistory is List) {
      for (final e in rawHistory) {
        if (e is! Map) continue;
        try {
          history.add(HistoryItem.fromJson(Map<String, dynamic>.from(e)));
        } catch (_) {
          // 单条坏数据丢掉就行，不要让整份文档作废。
        }
      }
    }

    final favorites = <FavoriteEntry>[];
    final rawFavorites = map['favorites'];
    if (rawFavorites is List) {
      for (final e in rawFavorites) {
        final f = FavoriteEntry.fromJson(e);
        if (f != null) favorites.add(f);
      }
    }

    final searchHistory = <TimedValue>[];
    final rawSearch = map['searchHistory'];
    if (rawSearch is List) {
      for (final e in rawSearch) {
        final t = TimedValue.fromJson(e);
        if (t != null && (t.asString?.isNotEmpty ?? false)) {
          searchHistory.add(t);
        }
      }
    }

    return SyncDecodeResult.ok(
      SyncPayload(
        schema: map['schema'] as int,
        savedAt: _asInt(map['savedAt']),
        history: history,
        historyClearedAt: _asInt(map['historyClearedAt']),
        favorites: favorites,
        searchHistory: searchHistory,
        searchClearedAt: _asInt(map['searchClearedAt']),
        settings: SyncSettings.fromJson(map['settings']),
      ),
    );
  }

  /// 合并两端，规则统一为「谁的动作更晚谁赢」。
  ///
  /// [local] 在前、[remote] 在后，所以**时间戳完全相等时保留本地**——这是一个
  /// 刻意的选择：相等意味着分不出先后，这时改动本机状态更容易让用户困惑。
  ///
  /// 不处理跨设备时钟偏差：如果某台设备的系统时间明显不对，它的时间戳会
  /// 一直偏大、一直赢。这种情况用设置页的「以本机为准 / 以云端为准」兜底，
  /// 而不是在合并里猜一个时钟偏移量——猜错会把正常的那台设备判成落后。
  static SyncPayload merge({
    required SyncPayload local,
    required SyncPayload remote,
    required int now,
  }) {
    // ---------- 观看历史 ----------
    final historyClearedAt = local.historyClearedAt > remote.historyClearedAt
        ? local.historyClearedAt
        : remote.historyClearedAt;

    final byVod = <String, HistoryItem>{};
    for (final h in local.history) {
      byVod[h.vodId] = h;
    }
    for (final h in remote.history) {
      final cur = byVod[h.vodId];
      if (cur == null || _historyNewer(h, cur)) byVod[h.vodId] = h;
    }

    final history =
        byVod.values
            // historyClearedAt == 0 表示「从来没清空过」，此时不能用
            // `updatedAt > 0` 去筛：`updatedAt` 字段是后加的，老数据全是 0，
            // 那样会把用户原有的历史全部滤掉。
            .where(
              (h) => historyClearedAt == 0 || h.updatedAt > historyClearedAt,
            )
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (history.length > kMaxHistoryItems) {
      history.removeRange(kMaxHistoryItems, history.length);
    }

    // ---------- 收藏（含墓碑） ----------
    final byFavorite = <String, FavoriteEntry>{};
    for (final f in local.favorites) {
      byFavorite[f.id] = f;
    }
    for (final f in remote.favorites) {
      final cur = byFavorite[f.id];
      byFavorite[f.id] = cur == null ? f : _mergeFavorite(cur, f);
    }
    final favorites = byFavorite.values.toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));

    // ---------- 搜索历史 ----------
    final searchClearedAt = local.searchClearedAt > remote.searchClearedAt
        ? local.searchClearedAt
        : remote.searchClearedAt;

    final byKeyword = <String, int>{};
    for (final t in local.searchHistory) {
      final k = t.asString;
      if (k == null || k.isEmpty) continue;
      byKeyword[k] = t.at;
    }
    for (final t in remote.searchHistory) {
      final k = t.asString;
      if (k == null || k.isEmpty) continue;
      final cur = byKeyword[k];
      if (cur == null || t.at > cur) byKeyword[k] = t.at;
    }
    final keywordEntries =
        byKeyword.entries.where((e) => e.value > searchClearedAt).toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    if (keywordEntries.length > kMaxSearchItems) {
      keywordEntries.removeRange(kMaxSearchItems, keywordEntries.length);
    }
    final searchHistory = keywordEntries
        .map((e) => TimedValue(e.key, e.value))
        .toList();

    // ---------- 设置（逐项比时间戳） ----------
    final settings = SyncSettings(
      skipIntroSeconds: _pickNewer(
        local.settings.skipIntroSeconds,
        remote.settings.skipIntroSeconds,
      ),
      skipOutroSeconds: _pickNewer(
        local.settings.skipOutroSeconds,
        remote.settings.skipOutroSeconds,
      ),
      autoSwitchSource: _pickNewer(
        local.settings.autoSwitchSource,
        remote.settings.autoSwitchSource,
      ),
    );

    return SyncPayload(
      schema: kSyncSchema,
      savedAt: now,
      history: history,
      historyClearedAt: historyClearedAt,
      favorites: favorites,
      searchHistory: searchHistory,
      searchClearedAt: searchClearedAt,
      settings: settings,
    );
  }

  /// 同一个 `vodId` 的两条历史，哪条算「更晚的动作」。
  static bool _historyNewer(HistoryItem a, HistoryItem b) {
    if (a.updatedAt != b.updatedAt) return a.updatedAt > b.updatedAt;
    // 时间戳撞在一起（典型情况：两边都是 `updatedAt = 0` 的老数据）时，
    // 进度更靠前的算更晚。断点续播时多走一点总比退回去好。
    return a.positionMs > b.positionMs;
  }

  /// 同一条收藏的两侧记录合并：两个时间戳各取 max，谁的动作更晚谁赢。
  static FavoriteEntry _mergeFavorite(FavoriteEntry a, FavoriteEntry b) {
    final addedAt = a.addedAt > b.addedAt ? a.addedAt : b.addedAt;
    final removedAt = a.removedAt > b.removedAt ? a.removedAt : b.removedAt;

    // item 取「addedAt 更大」那一侧：那侧才是真正执行了「加入收藏」这个动作
    // 的设备，它手上的标题/封面更可能是新的（站点会改标题）。
    // addedAt 相等时保留本地的。
    final VodItem? item;
    if (b.addedAt > a.addedAt) {
      item = b.item ?? a.item;
    } else {
      item = a.item ?? b.item;
    }

    return FavoriteEntry(
      id: a.id,
      addedAt: addedAt,
      removedAt: removedAt,
      item: item,
    );
  }

  /// 两个带时间戳的值取更晚的那个；相等时保留本地。
  /// `null` 表示「从来没设置过」，所以对面只要有值就无条件接受。
  static TimedValue? _pickNewer(TimedValue? a, TimedValue? b) {
    if (a == null) return b;
    if (b == null) return a;
    return b.at > a.at ? b : a;
  }
}
