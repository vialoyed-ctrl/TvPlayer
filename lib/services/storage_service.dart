import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/history_item.dart';
import '../models/sync_payload.dart';
import '../models/vod_item.dart';
import '../models/webdav_config.dart';

/// 本机所有持久化状态的唯一入口。
///
/// 同步功能给这里加了 6 个**旁路 key**（`_keyFavoritesAdded` 等），全部是新增，
/// 不改变任何已有 key 的格式，所以老版本的数据不用做任何迁移。
///
/// 设计上刻意不让这个类认识 WebDAV：它只负责「导出可同步子集」和「把合并
/// 结果写回本机」两件事，网络和合并都在 `SyncService` 里。这样合并算法可以
/// 脱离网络单独验证。
class StorageService extends ChangeNotifier {
  static final StorageService instance = StorageService._internal();
  StorageService._internal();

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  static const String _keyHistory = 'tv_watch_history';
  static const String _keyFavorites = 'tv_favorites';
  static const String _keyAutoSwitch = 'tv_auto_switch_source';

  // --- 同步用的旁路 key（全是新增，不影响老数据）---

  /// 最后一次「清空观看历史」的时间。
  static const String _keyHistoryClearedAt = 'tv_history_cleared_at';

  /// 收藏的「加入时间」表：`{vodId: 毫秒时间戳}`，JSON。
  static const String _keyFavoritesAdded = 'tv_favorites_added';

  /// 收藏的「取消时间」表（墓碑）：`{vodId: 毫秒时间戳}`，JSON。
  static const String _keyFavoritesRemoved = 'tv_favorites_removed';

  /// 搜索词的「使用时间」表：`{关键词: 毫秒时间戳}`，JSON。
  static const String _keySearchHistoryAt = 'tv_search_history_at';

  /// 最后一次「清空搜索历史」的时间。
  static const String _keySearchClearedAt = 'tv_search_history_cleared_at';

  /// 设置项的「修改时间」表：`{字段名: 毫秒时间戳}`，JSON。
  ///
  /// 三个设置项共用一个 key，省下两个 key，也省得三份几乎一样的读写代码。
  static const String _keySettingsUpdatedAt = 'tv_settings_updated_at';

  static const String _fieldSkipIntro = 'skipIntro';
  static const String _fieldSkipOutro = 'skipOutro';
  static const String _fieldAutoSwitch = 'autoSwitch';

  // --- WebDAV 同步配置（**不参与同步**，凭据绝不上传）---

  static const String _keyWebDav = 'tv_webdav_config';
  static const String _keySyncEnabled = 'tv_sync_enabled';
  static const String _keyLastSyncAt = 'tv_last_sync_at';

  // --- 「本机数据变了，值得安排一次同步上传」的通知 ---
  //
  // 刻意跟 [notifyListeners] 分开，也刻意**不**在 `saveHistory` 里发：
  // 播放器每 10 秒存一次进度，如果那次也发通知，历史页会在整个播放期间不停
  // 重建，同步也会被反复触发。这个回调只在低频、用户主动的写操作里发
  // （收藏、清空、改设置……），再由 `SyncService` 做防抖。
  final List<VoidCallback> _dirtyListeners = [];

  void addDirtyListener(VoidCallback callback) {
    if (!_dirtyListeners.contains(callback)) _dirtyListeners.add(callback);
  }

  void removeDirtyListener(VoidCallback callback) {
    _dirtyListeners.remove(callback);
  }

  void _notifyDirty() {
    // 复制一份再遍历：回调里可能会增删监听者。
    for (final cb in List<VoidCallback>.of(_dirtyListeners)) {
      cb();
    }
  }

  // --- History ---
  Future<void> saveHistory(HistoryItem item) async {
    await init();
    final list = getHistory();
    // remove existing item for same vodId
    list.removeWhere((h) => h.vodId == item.vodId);
    list.insert(0, item);
    // keep max history items
    if (list.length > kMaxHistoryItems) {
      list.removeRange(kMaxHistoryItems, list.length);
    }
    final jsonList = list.map((h) => jsonEncode(h.toJson())).toList();
    await _prefs!.setStringList(_keyHistory, jsonList);
  }

  List<HistoryItem> getHistory() {
    if (_prefs == null) return [];
    final jsonList = _prefs!.getStringList(_keyHistory) ?? [];
    return jsonList
        .map((s) => HistoryItem.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  HistoryItem? getHistoryForVod(String vodId) {
    final list = getHistory();
    for (final h in list) {
      if (h.vodId == vodId) return h;
    }
    return null;
  }

  Future<void> clearHistory() async {
    await init();
    await _prefs!.remove(_keyHistory);
    // 记下时间，否则「清空历史」这个动作同步不到另一台设备，
    // 下次一拉取，刚清掉的历史又全回来了。
    await _prefs!.setInt(
      _keyHistoryClearedAt,
      DateTime.now().millisecondsSinceEpoch,
    );
    _notifyDirty();
  }

  // --- Favorites ---
  Future<void> toggleFavorite(VodItem item) async {
    await init();
    final list = getFavorites();
    final exists = list.any((f) => f.id == item.id);
    final now = DateTime.now().millisecondsSinceEpoch;
    final added = _getStampMap(_keyFavoritesAdded);
    final removed = _getStampMap(_keyFavoritesRemoved);

    if (exists) {
      list.removeWhere((f) => f.id == item.id);
      // 墓碑：记下「什么时候删的」。没有它，另一台设备上还留着的这条收藏
      // 一合并就会把删除动作顶掉。
      removed[item.id] = now;
    } else {
      list.insert(0, item);
      added[item.id] = now;
    }

    final jsonList = list.map((f) => jsonEncode(f.toJson())).toList();
    await _prefs!.setStringList(_keyFavorites, jsonList);
    await _setStampMap(_keyFavoritesAdded, added);
    await _setStampMap(_keyFavoritesRemoved, removed);
    _notifyDirty();
  }

  bool isFavorite(String vodId) {
    final list = getFavorites();
    return list.any((f) => f.id == vodId);
  }

  List<VodItem> getFavorites() {
    if (_prefs == null) return [];
    final jsonList = _prefs!.getStringList(_keyFavorites) ?? [];
    return jsonList
        .map((s) => VodItem.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  // --- Auto Switch Source setting ---
  bool get autoSwitchSource => _prefs?.getBool(_keyAutoSwitch) ?? true;

  Future<void> setAutoSwitchSource(bool value) async {
    await init();
    await _prefs!.setBool(_keyAutoSwitch, value);
    await _stampSetting(_fieldAutoSwitch);
    _notifyDirty();
  }

  // --- Search History ---
  static const String _keySearchHistory = 'tv_search_history';

  List<String> getSearchHistory() {
    if (_prefs == null) return [];
    return _prefs!.getStringList(_keySearchHistory) ?? [];
  }

  Future<void> addSearchHistory(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    await init();
    final list = getSearchHistory().toList();
    list.remove(kw);
    list.insert(0, kw);
    if (list.length > kMaxSearchItems) {
      list.removeRange(kMaxSearchItems, list.length);
    }
    await _prefs!.setStringList(_keySearchHistory, list);

    // 搜索历史是一个只有顺序、没有时间的列表，没法直接做「谁更晚谁赢」。
    // 记下每个词的使用时间，合并时才能按词取新、而不是整张列表二选一
    // （后者会让另一台设备的搜索记录整批消失）。
    final at = _getStampMap(_keySearchHistoryAt);
    at[kw] = DateTime.now().millisecondsSinceEpoch;
    await _setStampMap(_keySearchHistoryAt, at);
    _notifyDirty();
  }

  Future<void> clearSearchHistory() async {
    await init();
    await _prefs!.remove(_keySearchHistory);
    await _prefs!.setInt(
      _keySearchClearedAt,
      DateTime.now().millisecondsSinceEpoch,
    );
    _notifyDirty();
  }

  // --- Skip Intro & Outro Settings ---
  static const String _keySkipIntro = 'tv_skip_intro_seconds';
  static const String _keySkipOutro = 'tv_skip_outro_seconds';

  int getSkipIntroSeconds() {
    return _prefs?.getInt(_keySkipIntro) ?? 90; // Default 90 seconds
  }

  Future<void> setSkipIntroSeconds(int seconds) async {
    await init();
    await _prefs!.setInt(_keySkipIntro, seconds);
    await _stampSetting(_fieldSkipIntro);
    _notifyDirty();
  }

  int getSkipOutroSeconds() {
    return _prefs?.getInt(_keySkipOutro) ?? 90; // Default 90 seconds
  }

  Future<void> setSkipOutroSeconds(int seconds) async {
    await init();
    await _prefs!.setInt(_keySkipOutro, seconds);
    await _stampSetting(_fieldSkipOutro);
    _notifyDirty();
  }

  // --- 播放倍速 ---
  static const String _keyPlaybackSpeed = 'tv_playback_speed';

  /// 播放倍速的合法区间。UI 上的按钮也只给这个范围。
  static const double minPlaybackSpeed = 0.5;
  static const double maxPlaybackSpeed = 3.0;

  /// 默认播放倍速，1.0 表示原速。
  ///
  /// 读的时候也夹一次区间：老版本写进去的值、或者被人手改过
  /// SharedPreferences 的值，都不能原样丢给播放器
  /// （`setPlaybackSpeed` 对 0 和负数会直接抛 ArgumentError）。
  double getPlaybackSpeed() {
    final v = _prefs?.getDouble(_keyPlaybackSpeed) ?? 1.0;
    if (v < minPlaybackSpeed) return minPlaybackSpeed;
    if (v > maxPlaybackSpeed) return maxPlaybackSpeed;
    return v;
  }

  Future<void> setPlaybackSpeed(double speed) async {
    await init();
    await _prefs!.setDouble(
      _keyPlaybackSpeed,
      speed.clamp(minPlaybackSpeed, maxPlaybackSpeed),
    );
  }

  // --- WebDAV 同步配置 ---

  WebDavConfig get webDavConfig {
    final raw = _prefs?.getString(_keyWebDav);
    if (raw == null || raw.isEmpty) return WebDavConfig.none;
    try {
      return WebDavConfig.fromJson(jsonDecode(raw));
    } catch (e) {
      // 配置坏了就退回「未配置」—— 这是对的（总比拿半截配置去发请求强）。
      // 但必须留痕：退回 none 之后，设置页会显示成「没填过地址」、同步开关也是
      // 关的，用户会以为自己从来没配过，而真正的成因（存档损坏）从此不可见。
      debugPrint(
        '[StorageService] WebDAV 配置解析失败，本次按「未配置」处理（原值仍留在 prefs 里，未被覆盖）: $e',
      );
      return WebDavConfig.none;
    }
  }

  Future<void> setWebDavConfig(WebDavConfig config) async {
    await init();
    await _prefs!.setString(_keyWebDav, jsonEncode(config.toJson()));
  }

  /// 自动同步开关。默认关闭——没配置好之前不该偷偷发网络请求。
  bool get syncEnabled => _prefs?.getBool(_keySyncEnabled) ?? false;

  Future<void> setSyncEnabled(bool value) async {
    await init();
    await _prefs!.setBool(_keySyncEnabled, value);
  }

  int get lastSyncAt => _prefs?.getInt(_keyLastSyncAt) ?? 0;

  Future<void> setLastSyncAt(int ms) async {
    await init();
    await _prefs!.setInt(_keyLastSyncAt, ms);
  }

  // --- 自动更新（**不参与同步**：这是本机的行为偏好，跟另一台设备无关）---

  static const String _keyUpdateAutoCheck = 'tv_update_auto_check';
  static const String _keyUpdateAutoInstall = 'tv_update_auto_install';
  static const String _keyUpdateHandledFingerprint =
      'tv_update_handled_fingerprint';
  static const String _keyUpdateLastCheckAt = 'tv_update_last_check_at';

  /// 自动检查更新。默认开 —— 没放包的时候检查只是一次 HEAD，很便宜。
  bool get updateAutoCheck => _prefs?.getBool(_keyUpdateAutoCheck) ?? true;

  Future<void> setUpdateAutoCheck(bool value) async {
    await init();
    await _prefs!.setBool(_keyUpdateAutoCheck, value);
  }

  /// 默认自动下载新版本，并调用 Android 系统安装界面。
  bool get updateAutoInstall => _prefs?.getBool(_keyUpdateAutoInstall) ?? true;

  Future<void> setUpdateAutoInstall(bool value) async {
    await init();
    await _prefs!.setBool(_keyUpdateAutoInstall, value);
  }

  /// 已经「验过包、交给系统安装过」的那份安装包的指纹。
  ///
  /// 没有它的话，只要云端那个文件还在，每次启动都会重新下载 20 MB 再弹一遍框。
  String? get updateHandledFingerprint {
    final v = _prefs?.getString(_keyUpdateHandledFingerprint);
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> setUpdateHandledFingerprint(String value) async {
    await init();
    await _prefs!.setString(_keyUpdateHandledFingerprint, value);
  }

  int get updateLastCheckAt => _prefs?.getInt(_keyUpdateLastCheckAt) ?? 0;

  Future<void> setUpdateLastCheckAt(int ms) async {
    await init();
    await _prefs!.setInt(_keyUpdateLastCheckAt, ms);
  }

  // --- 同步：导出本机可同步子集 ---

  /// 把本机状态打包成一份同步文档。
  ///
  /// 注意这里**不包含** `tv_download_tasks` / `tv_download_dir`：它们存的是
  /// `/storage/emulated/0/...` 这种本机绝对路径，同步过去只会得到一堆指向
  /// 不存在文件的记录。下载的文件本身也不在同步范围内——想在另一台设备上
  /// 看下载好的片子，正确做法是把 WebDAV 目录当成播放源（另一个功能）。
  SyncPayload exportSyncPayload({required int now}) {
    // 收藏：把「活着的」和「墓碑」拼成同一张记录表。
    final addedMap = _getStampMap(_keyFavoritesAdded);
    final removedMap = _getStampMap(_keyFavoritesRemoved);
    final favById = <String, FavoriteEntry>{};
    for (final item in getFavorites()) {
      favById[item.id] = FavoriteEntry(
        id: item.id,
        // 没有记录 = 这条收藏比同步功能还早。用哨兵值兜住，别让它被
        // 「addedAt > removedAt」判成已删除。
        addedAt: addedMap[item.id] ?? kLegacyStamp,
        removedAt: removedMap[item.id] ?? 0,
        item: item,
      );
    }
    for (final e in removedMap.entries) {
      if (favById.containsKey(e.key)) continue; // 已重新加回，按活着的算
      favById[e.key] = FavoriteEntry(
        id: e.key,
        addedAt: addedMap[e.key] ?? 0,
        removedAt: e.value,
      );
    }

    final searchAt = _getStampMap(_keySearchHistoryAt);
    final settingsAt = _getStampMap(_keySettingsUpdatedAt);

    /// 只有用户真的改过（有记录）才导出。`null` 表示「本机从没设置过」，
    /// 合并时会让位给对面——这正是新装设备能拿到老设备设置的原因。
    TimedValue? setting(Object? value, String field) {
      final at = settingsAt[field] ?? 0;
      if (at <= 0) return null;
      return TimedValue(value, at);
    }

    return SyncPayload(
      schema: kSyncSchema,
      savedAt: now,
      history: getHistory(),
      historyClearedAt: _prefs?.getInt(_keyHistoryClearedAt) ?? 0,
      favorites: favById.values.toList(),
      searchHistory: [
        for (final kw in getSearchHistory())
          TimedValue(kw, searchAt[kw] ?? kLegacyStamp),
      ],
      searchClearedAt: _prefs?.getInt(_keySearchClearedAt) ?? 0,
      settings: SyncSettings(
        skipIntroSeconds: setting(getSkipIntroSeconds(), _fieldSkipIntro),
        skipOutroSeconds: setting(getSkipOutroSeconds(), _fieldSkipOutro),
        autoSwitchSource: setting(autoSwitchSource, _fieldAutoSwitch),
      ),
    );
  }

  // --- 同步：把合并结果写回本机 ---

  /// 落盘一份合并结果，并通知界面刷新。
  ///
  /// 通知只在这条路径上发：`saveHistory` 在播放时每 10 秒被调一次，在那里
  /// 通知会让历史页在播放期间无意义地反复重建。
  Future<void> applySyncPayload(SyncPayload merged) async {
    await init();

    // 观看历史：合并结果已经按 updatedAt 倒序排好、也裁过条数了，直接落盘。
    await _prefs!.setStringList(
      _keyHistory,
      merged.history.map((h) => jsonEncode(h.toJson())).toList(),
    );

    // 收藏：活着的写回原来那个列表（格式不变），时间戳写进旁路 key。
    final alive = merged.favorites
        .where((f) => f.isAlive && f.item != null)
        .toList();
    await _prefs!.setStringList(
      _keyFavorites,
      alive.map((f) => jsonEncode(f.item!.toJson())).toList(),
    );
    await _setStampMap(_keyFavoritesAdded, {
      for (final f in merged.favorites)
        if (f.addedAt > 0) f.id: f.addedAt,
    });
    await _setStampMap(_keyFavoritesRemoved, {
      for (final f in merged.favorites)
        if (f.removedAt > 0) f.id: f.removedAt,
    });

    // 搜索历史
    await _prefs!.setStringList(
      _keySearchHistory,
      merged.searchHistory.map((t) => t.asString).whereType<String>().toList(),
    );
    await _setStampMap(_keySearchHistoryAt, {
      for (final t in merged.searchHistory)
        if (t.asString != null) t.asString!: t.at,
    });

    await _writeStamp(_keyHistoryClearedAt, merged.historyClearedAt);
    await _writeStamp(_keySearchClearedAt, merged.searchClearedAt);

    // 设置：合并结果里就是最终值，逐项写回并记下时间戳。
    final settingsAt = <String, int>{};
    final s = merged.settings;
    final intro = s.skipIntroSeconds;
    if (intro != null) {
      final v = intro.asInt;
      if (v != null) await _prefs!.setInt(_keySkipIntro, v);
      if (intro.isSet) settingsAt[_fieldSkipIntro] = intro.at;
    }
    final outro = s.skipOutroSeconds;
    if (outro != null) {
      final v = outro.asInt;
      if (v != null) await _prefs!.setInt(_keySkipOutro, v);
      if (outro.isSet) settingsAt[_fieldSkipOutro] = outro.at;
    }
    final auto = s.autoSwitchSource;
    if (auto != null) {
      final v = auto.asBool;
      if (v != null) await _prefs!.setBool(_keyAutoSwitch, v);
      if (auto.isSet) settingsAt[_fieldAutoSwitch] = auto.at;
    }
    await _setStampMap(_keySettingsUpdatedAt, settingsAt);

    notifyListeners();
  }

  // --- 内部工具 ---

  /// 读一张「字符串 → 毫秒时间戳」的表。读不出来就当空的：旁路 key 丢了只
  /// 会让同步少一点信息（退化成「没记录过」），不该让整个功能报错。
  Map<String, int> _getStampMap(String key) {
    final raw = _prefs?.getString(key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, int>{};
      decoded.forEach((k, v) {
        if (k is String && v is int && v > 0) out[k] = v;
      });
      return out;
    } catch (e) {
      // 退回空表是安全方向（当成「没记录过」），但会**静默改变同步语义**：
      // 收藏的墓碑表读不出来 → 另一端会把已删除的收藏又同步回来。
      // 所以要记，并写清退化成了什么。
      debugPrint('[StorageService] $key 解析失败，本次按空表处理（墓碑/时间戳会退化成「没记录过」）: $e');
      return {};
    }
  }

  Future<void> _setStampMap(String key, Map<String, int> map) async {
    await init();
    if (map.isEmpty) {
      await _prefs!.remove(key);
      return;
    }
    await _prefs!.setString(key, jsonEncode(map));
  }

  Future<void> _writeStamp(String key, int ms) async {
    await init();
    if (ms <= 0) {
      await _prefs!.remove(key);
      return;
    }
    await _prefs!.setInt(key, ms);
  }

  Future<void> _stampSetting(String field) async {
    final map = _getStampMap(_keySettingsUpdatedAt);
    map[field] = DateTime.now().millisecondsSinceEpoch;
    await _setStampMap(_keySettingsUpdatedAt, map);
  }
}
