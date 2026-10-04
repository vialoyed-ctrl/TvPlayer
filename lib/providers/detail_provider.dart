import 'dart:async';

import 'package:flutter/material.dart';

import '../models/vod_detail.dart';
import '../models/vod_item.dart';
import '../models/play_source.dart';
import '../models/history_item.dart';
import '../services/video_site_scraper.dart';
import '../services/storage_service.dart';
import '../services/source_speed_tester.dart';

class DetailProvider extends ChangeNotifier {
  final VideoSiteScraper _scraper = VideoSiteScraper();
  final StorageService _storage = StorageService.instance;

  DetailProvider() {
    // 同步可能改动本片的收藏状态或观看进度，见 _onStorageChanged。
    _storage.addListener(_onStorageChanged);
  }

  bool _isLoading = true;
  bool get isLoading => _isLoading;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  VodDetail? _detail;
  VodDetail? get detail => _detail;

  int _selectedSourceIndex = 0;
  int get selectedSourceIndex => _selectedSourceIndex;

  int _selectedEpisodeIndex = 0;
  int get selectedEpisodeIndex => _selectedEpisodeIndex;

  HistoryItem? _history;
  HistoryItem? get history => _history;

  bool _isFavorite = false;
  bool get isFavorite => _isFavorite;

  PlaySource? get currentSource {
    if (_detail == null || _detail!.sources.isEmpty) return null;
    if (_selectedSourceIndex >= _detail!.sources.length) {
      return _detail!.sources.first;
    }
    return _detail!.sources[_selectedSourceIndex];
  }

  Episode? get currentEpisode {
    final src = currentSource;
    if (src == null || src.episodes.isEmpty) return null;
    if (_selectedEpisodeIndex >= src.episodes.length) return src.episodes.first;
    return src.episodes[_selectedEpisodeIndex];
  }

  Future<void> loadDetail(String detailPath) async {
    _isLoading = true;
    _errorMessage = null;
    _detail = null;
    notifyListeners();

    try {
      final res = await _scraper.getVodDetail(detailPath);
      _detail = res;

      if (res != null) {
        _history = _storage.getHistoryForVod(res.id);
        _isFavorite = _storage.isFavorite(res.id);

        // If history exists, strictly select the last played source & episode
        if (_history != null && res.sources.isNotEmpty) {
          // 1. Match the exact last-played source name
          int matchedSourceIndex = res.sources.indexWhere(
            (s) => s.name == _history!.sourceName,
          );
          if (matchedSourceIndex == -1) {
            matchedSourceIndex = res.sources.indexWhere(
              (s) =>
                  s.name.contains(_history!.sourceName) ||
                  _history!.sourceName.contains(s.name),
            );
          }
          if (matchedSourceIndex == -1) {
            matchedSourceIndex = 0;
          }
          _selectedSourceIndex = matchedSourceIndex;

          // 2. Match the exact episode in that source
          final src = res.sources[_selectedSourceIndex];
          int matchedEpIndex = src.episodes.indexWhere(
            (e) =>
                e.name == _history!.episodeName ||
                e.playPath == _history!.playPath,
          );
          if (matchedEpIndex == -1) {
            final histNum = RegExp(r'\d+')
                .firstMatch(_history!.episodeName)
                ?.group(0);
            if (histNum != null) {
              matchedEpIndex = src.episodes.indexWhere(
                (e) => RegExp(r'\d+').firstMatch(e.name)?.group(0) == histNum,
              );
            }
          }
          if (matchedEpIndex != -1) {
            _selectedEpisodeIndex = matchedEpIndex;
          }
        } else if (res.sources.isNotEmpty) {
          // Default to the first fast, smooth non-2K/4K source (e.g. 1080P/蓝光/高清)
          int defaultSourceIdx = res.sources.indexWhere(
            (s) => !SourceSpeedTester.isHeavySource(s),
          );
          if (defaultSourceIdx == -1) defaultSourceIdx = 0;
          _selectedSourceIndex = defaultSourceIdx;
          _selectedEpisodeIndex = 0;
        }

        // 后台摘掉「站点确实没配源」的线路。
        // 实测「4K」线路在全站都是 `src: ""`（点进去放不了），而详情页的线路
        // 标签里没有任何不可用标记，只能靠一趟播放页请求判定。18 条线路串行
        // 探测要 6.3s，所以绝不能同步做 —— 放后台，探测完再更新列表。
        _pruneDeadSourcesInBackground(res);
      }
    } catch (e) {
      _errorMessage = '获取详情失败: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void selectSource(int index) {
    if (_selectedSourceIndex == index) return;
    _selectedSourceIndex = index;
    // ensure episode index is in range
    final src = currentSource;
    if (src != null && _selectedEpisodeIndex >= src.episodes.length) {
      _selectedEpisodeIndex = 0;
    }
    notifyListeners();
  }

  bool _isDisposed = false;
  bool _isPruning = false;

  /// 后台探测并摘掉「站点确实没配源」的线路。
  ///
  /// 延迟 1.2s 再开始，避开详情页首帧与封面图加载，免得抢带宽。
  /// 摘线路会让下标整体前移，所以必须按**线路名**重映射当前选中项，
  /// 否则用户会莫名其妙跳到另一条线路上 —— 这是本方法最容易出错的地方。
  Future<void> _pruneDeadSourcesInBackground(VodDetail loaded) async {
    if (_isPruning || loaded.sources.length <= 1) return;
    _isPruning = true;
    try {
      await Future.delayed(const Duration(milliseconds: 1200));
      if (_isDisposed) return;

      final playable = await SourceSpeedTester.filterPlayableSources(
        sources: loaded.sources,
        scraper: _scraper,
      );
      if (_isDisposed) return;
      // 详情页可能已经被重新加载成另一部片子了，别把旧结果写回去。
      if (_detail?.id != loaded.id) return;
      // 没有死线路：什么都不动（保持引用不变，避免无谓重建）。
      if (playable.length == loaded.sources.length) return;

      final selectedName =
          (_selectedSourceIndex >= 0 &&
              _selectedSourceIndex < loaded.sources.length)
          ? loaded.sources[_selectedSourceIndex].name
          : null;
      final newIndex = selectedName == null
          ? -1
          : playable.indexWhere((s) => s.name == selectedName);

      _detail = loaded.copyWith(sources: playable);
      // 选中的线路被摘掉了（例如历史记录停在已失效的「4K」上）→ 落到第一条可用线路。
      _selectedSourceIndex = newIndex >= 0 ? newIndex : 0;

      // 各线路集数可以不同，换线路后原集数下标可能越界。
      final src = currentSource;
      if (src != null && _selectedEpisodeIndex >= src.episodes.length) {
        _selectedEpisodeIndex = 0;
      }

      debugPrint(
        '[DetailProvider] Pruned ${loaded.sources.length - playable.length} '
        'source(s) with no stream; kept ${playable.length}: '
        '${playable.map((s) => s.name).join("/")}',
      );
      notifyListeners();
    } catch (e) {
      debugPrint('[DetailProvider] Source pruning error: $e');
    } finally {
      _isPruning = false;
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _storage.removeListener(_onStorageChanged);
    super.dispose();
  }

  /// 后台同步改动了存储时，只刷新跟本页有关的两个字段。
  ///
  /// 不能整个 `loadDetail` 重来：那会把用户已经选好的线路和集数重置掉。
  void _onStorageChanged() {
    final id = _detail?.id;
    if (id == null) return;
    _history = _storage.getHistoryForVod(id);
    _isFavorite = _storage.isFavorite(id);
    notifyListeners();
  }

  void selectEpisode(int index) {
    if (_selectedEpisodeIndex == index) return;
    _selectedEpisodeIndex = index;
    notifyListeners();
  }

  Future<void> toggleFavorite() async {
    if (_detail == null) return;
    final item = VodItem(
      id: _detail!.id,
      title: _detail!.title,
      cover: _detail!.cover,
      remark: _detail!.remark,
      detailPath: '/detail/${_detail!.id}.html',
    );
    await _storage.toggleFavorite(item);
    _isFavorite = _storage.isFavorite(_detail!.id);
    notifyListeners();
  }
}
