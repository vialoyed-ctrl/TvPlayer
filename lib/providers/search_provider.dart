import 'dart:async';

import 'package:flutter/material.dart';

import '../models/vod_item.dart';
import '../services/video_site_scraper.dart';
import '../services/storage_service.dart';
import '../services/pinyin_matcher.dart';

class SearchProvider extends ChangeNotifier {
  SearchProvider() {
    // 构造即去站点取热搜词。拿不到不影响任何功能 ——
    // popularKeywords 会退回本地列表，首屏不会空着。
    unawaited(loadHotWords());
  }

  final VideoSiteScraper _scraper = VideoSiteScraper();
  final StorageService _storage = StorageService.instance;

  bool _disposed = false;

  String _query = '';
  String get query => _query;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  List<VodItem> _results = [];
  List<VodItem> get results => _results;

  List<String> _suggestions = [];
  List<String> get suggestions => _suggestions;

  // --- 热搜词（站点实时） -------------------------------------------------

  List<String> _hotWords = const [];

  /// 热搜词。优先用站点实时列表（和站点搜索框下拉里那批完全一致），
  /// 取不到时退回本地列表，保证首屏永远有内容可点。
  List<String> get popularKeywords =>
      _hotWords.isNotEmpty ? _hotWords : PinyinMatcher.popularKeywords;

  /// 站点热搜词是否已经拿到（UI 想区分「实时」与「本地兜底」时用）。
  bool get hasLiveHotWords => _hotWords.isNotEmpty;

  /// 拉一次站点热搜词。失败静默 —— 有本地兜底，不该为此弹错。
  Future<void> loadHotWords() async {
    try {
      final words = await _scraper.getHotSearchWords();
      if (_disposed || words.isEmpty) return;
      _hotWords = words;
      notifyListeners();
    } catch (e) {
      debugPrint('[SearchProvider] loadHotWords failed: $e');
    }
  }

  // --- 翻页 ---------------------------------------------------------------

  bool _isLoadingMore = false;
  bool get isLoadingMore => _isLoadingMore;

  bool _hasMore = false;
  bool get hasMore => _hasMore;

  int _currentPage = 1;
  int get currentPage => _currentPage;

  /// 当前结果实际对应的关键词。
  ///
  /// 和 [query] 可能不同：拼音缩写直接搜不到时会自动改用中文建议词
  /// （见 [_triggerSearch] 里的兜底），翻页必须用那个**真的搜出结果**的词，
  /// 否则第二页会变成另一个词的结果。
  String _activeKeyword = '';

  /// 每次发起新搜索 +1。翻页结果回来时若已换词就直接丢弃，
  /// 免得把「上一个词的第二页」追加到「当前词」的结果后面。
  int _searchGeneration = 0;

  List<String> get searchHistory => _storage.getSearchHistory();

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String? _autoResolvedChinese;
  String? get autoResolvedChinese => _autoResolvedChinese;

  void appendChar(String char) {
    _query += char;
    _updateSuggestions();
    notifyListeners();
    _triggerSearch();
  }

  void backspace() {
    if (_query.isNotEmpty) {
      _query = _query.substring(0, _query.length - 1);
      _updateSuggestions();
      notifyListeners();
      if (_query.isNotEmpty) {
        _triggerSearch();
      } else {
        _clearResults();
        notifyListeners();
      }
    }
  }

  void clear() {
    _query = '';
    _suggestions = [];
    _clearResults();
    notifyListeners();
  }

  void setQuery(String text) {
    _query = text;
    _updateSuggestions();
    notifyListeners();
    _triggerSearch();
  }

  void searchKeyword(String keyword) {
    _query = keyword;
    _updateSuggestions();
    notifyListeners();
    _triggerSearch();
  }

  void clearHistory() {
    _storage.clearSearchHistory();
    notifyListeners();
  }

  void _updateSuggestions() {
    if (_query.trim().isEmpty) {
      _suggestions = [];
    } else {
      _suggestions = PinyinMatcher.matchSuggestions(_query.trim());
    }
  }

  /// 清空结果并复位翻页状态；顺手让在途请求作废。
  void _clearResults() {
    _results = [];
    _errorMessage = null;
    _autoResolvedChinese = null;
    _activeKeyword = '';
    _searchGeneration++;
    _resetPaging();
  }

  void _resetPaging() {
    _currentPage = 1;
    _hasMore = false;
    _isLoadingMore = false;
  }

  Future<void> _triggerSearch() async {
    final trimmed = _query.trim();
    final gen = ++_searchGeneration;
    _resetPaging();

    if (trimmed.isEmpty) {
      _results = [];
      _errorMessage = null;
      _autoResolvedChinese = null;
      _activeKeyword = '';
      _isLoading = false;
      notifyListeners();
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    _autoResolvedChinese = null;
    notifyListeners();

    try {
      // 1. 直接拿关键词去站点搜
      var items = await _scraper.search(trimmed);
      var usedKeyword = trimmed;

      // 2. 搜不到、而且输入像拼音缩写（A-Z）、又匹配到中文建议词时，
      //    自动改用建议词再搜一次（例如 KB -> 狂飙）。
      if (items.isEmpty && _suggestions.isNotEmpty) {
        final candidate = _suggestions.first;
        debugPrint(
          '[SearchProvider] Query "$trimmed" returned 0 items. '
          'Fallback searching suggestion: "$candidate"',
        );
        final fallbackItems = await _scraper.search(candidate);
        if (fallbackItems.isNotEmpty) {
          items = fallbackItems;
          usedKeyword = candidate;
          _autoResolvedChinese = candidate;
        }
      }

      // 期间用户又改了词 → 这批结果作废，别覆盖新的。
      if (gen != _searchGeneration) return;

      _results = items;
      _activeKeyword = usedKeyword;
      // 站点每页固定 listPageSize 条；拿满一页就认为「可能还有下一页」，
      // 到底了没有由 loadMore 拉到空页来确认。
      _hasMore = items.length >= VideoSiteScraper.listPageSize;

      if (items.isEmpty) {
        _errorMessage = '未找到与 "$trimmed" 相关的影视内容';
      } else {
        await _storage.addSearchHistory(usedKeyword);
      }
    } catch (e) {
      if (gen != _searchGeneration) return;
      _errorMessage = '搜索出错: $e';
    } finally {
      if (gen == _searchGeneration) {
        _isLoading = false;
        _notify();
      }
    }
  }

  /// 拉下一页搜索结果。
  ///
  /// 由结果网格滚到底部时调用（见 `search_view.dart` 的 `_onScroll`）。
  Future<void> loadMore() async {
    if (_isLoading || _isLoadingMore || !_hasMore) return;

    final keyword = _activeKeyword.isNotEmpty ? _activeKeyword : _query.trim();
    if (keyword.isEmpty) return;

    final gen = _searchGeneration;
    final nextPage = _currentPage + 1;
    _isLoadingMore = true;
    notifyListeners();

    try {
      final more = await _scraper.searchPage(keyword, page: nextPage);
      if (gen != _searchGeneration) return; // 词已经换了，这批作废

      if (more.isEmpty) {
        _hasMore = false;
      } else {
        // 跨页去重：站点列表页偶尔会把同一条塞进相邻两页。
        final existing = _results.map((e) => e.id).toSet();
        final fresh = more.where((e) => !existing.contains(e.id)).toList();
        if (fresh.isEmpty) {
          // 整页都是重复项，说明站点在重复喂同一批，别再无意义地翻下去。
          _hasMore = false;
        } else {
          _results = [..._results, ...fresh];
          _currentPage = nextPage;
          _hasMore = more.length >= VideoSiteScraper.listPageSize;
        }
      }
    } catch (e) {
      // 本页失败就保持页码不变，下次滚动还能重试。
      debugPrint('[SearchProvider] loadMore page $nextPage failed: $e');
    } finally {
      if (gen == _searchGeneration) {
        _isLoadingMore = false;
        _notify();
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
