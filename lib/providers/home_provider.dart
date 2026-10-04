import 'package:flutter/material.dart';

import '../models/channel.dart';
import '../models/vod_item.dart';
import '../services/video_site_scraper.dart';

class HomeProvider extends ChangeNotifier {
  final VideoSiteScraper _scraper = VideoSiteScraper();

  final List<Channel> channels = Channel.defaultChannels;
  int _selectedChannelIndex = 0;
  int get selectedChannelIndex => _selectedChannelIndex;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  List<VodItem> _items = [];
  List<VodItem> get items => _items;

  int _currentPage = 1;
  bool _hasMore = true;
  bool get hasMore => _hasMore;

  /// 正在加载下一页（和首屏加载分开，避免翻页时整页转圈）
  bool _isLoadingMore = false;
  bool get isLoadingMore => _isLoadingMore;

  HomeProvider() {
    loadChannel(0);
  }

  Future<void> selectChannel(int index) async {
    if (_selectedChannelIndex == index && _items.isNotEmpty) return;
    _selectedChannelIndex = index;
    await loadChannel(index);
  }

  Future<void> loadChannel(int index) async {
    _isLoading = true;
    _isLoadingMore = false;
    _errorMessage = null;
    _currentPage = 1;
    _hasMore = true;
    _items = [];
    notifyListeners();

    try {
      final channel = channels[index];
      List<VodItem> result;
      if (channel.id == 0) {
        // 首页现在也是可翻页的列表页（电视剧 / 中国大陆 / 最热）
        result = await _scraper.getHomeList(page: 1);
        if (result.isEmpty) {
          // 列表页拿不到内容时退回原来的首页精选，至少不至于空白
          result = await _scraper.getHomeFeatured();
          _hasMore = false;
        }
      } else {
        result = await _scraper.getChannelItems(channel.id, page: 1);
      }
      _items = result;
    } catch (e) {
      _errorMessage = '加载失败: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    if (_isLoading || _isLoadingMore || !_hasMore) return;

    _isLoadingMore = true;
    final nextPage = _currentPage + 1;
    try {
      final channel = channels[_selectedChannelIndex];
      final more = channel.id == 0
          ? await _scraper.getHomeList(page: nextPage)
          : await _scraper.getChannelItems(channel.id, page: nextPage);

      // 跨页去重：站点列表页偶尔会把同一条塞进相邻两页
      final existing = _items.map((e) => e.id).toSet();
      final fresh = more.where((e) => !existing.contains(e.id)).toList();

      if (more.isEmpty || fresh.isEmpty) {
        _hasMore = false;
      } else {
        _items = [..._items, ...fresh];
        _currentPage = nextPage;
      }
    } catch (e) {
      // 本页失败就保持页码不变，下次滚动还能重试
    } finally {
      _isLoadingMore = false;
      notifyListeners();
    }
  }
}
