import 'package:flutter/material.dart';

import '../models/history_item.dart';
import '../models/vod_item.dart';
import '../services/storage_service.dart';

class HistoryProvider extends ChangeNotifier {
  final StorageService _storage = StorageService.instance;

  List<HistoryItem> _histories = [];
  List<HistoryItem> get histories => _histories;

  List<VodItem> _favorites = [];
  List<VodItem> get favorites => _favorites;

  int _selectedTab = 0; // 0: History, 1: Favorites
  int get selectedTab => _selectedTab;

  HistoryProvider() {
    loadData();
    // 后台同步会把存储里的历史/收藏整批换掉，而这里是内存副本。
    // 不听这一声，同步完成后这个页面显示的还是合并前的旧数据。
    _storage.addListener(_onStorageChanged);
  }

  void _onStorageChanged() {
    loadData();
  }

  @override
  void dispose() {
    _storage.removeListener(_onStorageChanged);
    super.dispose();
  }

  Future<void> loadData() async {
    _histories = _storage.getHistory();
    _favorites = _storage.getFavorites();
    notifyListeners();
  }

  void switchTab(int index) {
    _selectedTab = index;
    notifyListeners();
  }

  Future<void> clearHistory() async {
    await _storage.clearHistory();
    _histories = [];
    notifyListeners();
  }

  Future<void> removeFavorite(String vodId) async {
    final item = _favorites.firstWhere((f) => f.id == vodId);
    await _storage.toggleFavorite(item);
    _favorites = _storage.getFavorites();
    notifyListeners();
  }
}
