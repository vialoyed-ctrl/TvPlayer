import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../providers/search_provider.dart';
import '../models/vod_item.dart';
import '../tv_ui/tv_theme.dart';
import '../tv_ui/tv_focus_widget.dart';
import '../tv_ui/tv_keyboard.dart';
import '../tv_ui/ui_adaptive.dart';
import 'detail_view.dart';

/// 把焦点从输入框移到搜索结果网格。
///
/// 为什么需要它：单行 TextField 一旦获得焦点，Flutter 内置的
/// `DefaultTextEditingShortcuts` 会把方向键映射成「文本选择」意图并
/// **停止事件继续冒泡**（见 default_text_editing_shortcuts.dart 中
/// arrowUp/arrowDown -> ExtendSelectionVerticallyToAdjacentLineIntent）。
/// 结果就是遥控器的方向键在输入框里只能移动光标，永远走不出去，
/// 搜出来的结果一张都选不到。
///
/// 解决办法是在 TextField 外面、比内置快捷键**更靠近焦点**的位置插一层
/// Shortcuts：按键事件从主焦点向上冒泡，先命中我们这层，于是方向键被
/// 改写成「跳到结果」。
class _FocusResultsIntent extends Intent {
  const _FocusResultsIntent();
}

class SearchView extends StatelessWidget {
  const SearchView({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => SearchProvider(),
      child: const _SearchContent(),
    );
  }
}

class _SearchContent extends StatefulWidget {
  const _SearchContent();

  @override
  State<_SearchContent> createState() => _SearchContentState();
}

class _SearchContentState extends State<_SearchContent> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();

  /// 搜索结果网格首项的焦点节点。用于把焦点从输入框「送出去」。
  final FocusNode _firstResultFocusNode = FocusNode();

  /// 结果网格的滚动控制器：滚到底部时自动拉下一页。
  final ScrollController _scrollController = ScrollController();

  /// 搜索是异步的：按下方向键/搜索键时结果可能还没回来，
  /// 这里记一笔，等结果到达后再把焦点交过去。
  bool _pendingJumpToResults = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _textController.dispose();
    _inputFocusNode.dispose();
    _firstResultFocusNode.dispose();
    super.dispose();
  }

  /// 滚到离底部 400 像素以内就预取下一页（与首页列表同一套写法）。
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 400) {
      context.read<SearchProvider>().loadMore();
    }
  }

  /// 换关键词时回到顶部，否则新一批结果会停在上一批的滚动位置上。
  void _resetScroll() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  /// 结果变化后检查一次：如果网格还没填满一屏（内容不够高、根本滚不动），
  /// 就直接把下一页拉进来 —— 否则 [ScrollController] 永远收不到滚动事件，
  /// 用户会以为「只有这一页」。
  ///
  /// 不会死循环：每拉一页要么内容变高（可滚动了，maxScrollExtent > 0 就停），
  /// 要么 [SearchProvider.hasMore] 变成 false（到底了）。
  void _autoFillViewport(SearchProvider provider) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (_scrollController.position.maxScrollExtent <= 0 &&
          provider.hasMore &&
          !provider.isLoadingMore &&
          !provider.isLoading) {
        provider.loadMore();
      }
    });
  }

  void _onKeywordSelected(SearchProvider provider, String kw) {
    _textController.text = kw;
    provider.searchKeyword(kw);
    _pendingJumpToResults = true;
    _resetScroll();
  }

  /// 把焦点交给搜索结果首项。结果还没回来就先挂起。
  void _jumpToResults(SearchProvider provider) {
    if (provider.results.isEmpty) {
      _pendingJumpToResults = true;
      return;
    }
    _pendingJumpToResults = false;
    if (_firstResultFocusNode.canRequestFocus) {
      _firstResultFocusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SearchProvider>();

    // Synchronize query if set from on-screen keyboard
    if (provider.query != _textController.text && !_inputFocusNode.hasFocus) {
      _textController.value = TextEditingValue(
        text: provider.query,
        selection: TextSelection.collapsed(offset: provider.query.length),
      );
    }

    // 结果到达后，兑现之前挂起的「跳到结果」请求
    if (_pendingJumpToResults &&
        !provider.isLoading &&
        provider.results.isNotEmpty) {
      _pendingJumpToResults = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _firstResultFocusNode.canRequestFocus) {
          _firstResultFocusNode.requestFocus();
        }
      });
    }

    // 结果不足一屏时自动补下一页（见 _autoFillViewport）
    if (provider.results.isNotEmpty &&
        provider.hasMore &&
        !provider.isLoadingMore) {
      _autoFillViewport(provider);
    }

    return Scaffold(
      backgroundColor: TvTheme.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 36 * UiAdaptive.scale,
            vertical: 20 * UiAdaptive.scale,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left: Back button & On-screen TV Keyboard
              //
              // 手机档不显示电视软键盘（手机有自己的系统输入法，再叠一层电视键盘
              // 会把结果区挤到只剩几十像素宽）。左栏因此收成「返回 + 标题」的
              // 内容宽度，不再固定 660。电视档一切照旧。
              SizedBox(
                width: UiAdaptive.hideTvKeyboard ? null : 660,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          TvFocusWidget(
                            borderRadius: 8,
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 18 * UiAdaptive.scale,
                                vertical: 12 * UiAdaptive.scale,
                              ),
                              color: TvTheme.surfaceLighter,
                              child: const Row(
                                children: [
                                  Icon(
                                    Icons.arrow_back,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                                  SizedBox(width: 6),
                                  Text(
                                    '返回',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 14 * TvTheme.fontScale,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          SizedBox(width: 14 * UiAdaptive.scale),
                          const Text(
                            '影视搜索',
                            style: TextStyle(
                              color: TvTheme.textPrimary,
                              fontSize: 20 * TvTheme.fontScale,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      // 手机档整块不显示；电视档结构与数值完全不变。
                      if (!UiAdaptive.hideTvKeyboard) ...[
                        SizedBox(height: 14 * UiAdaptive.scale),

                        // TV Keyboard
                        TvKeyboard(
                          onKeyPressed: (char) {
                            provider.appendChar(char);
                            _textController.text = provider.query;
                          },
                          onBackspace: () {
                            provider.backspace();
                            _textController.text = provider.query;
                          },
                          onClear: () {
                            provider.clear();
                            _textController.clear();
                          },
                          onSearch: () {
                            if (provider.query.isNotEmpty) {
                              provider.searchKeyword(provider.query);
                              // 搜完直接把焦点交给结果，用户接着按方向键就能选片
                              _pendingJumpToResults = true;
                              _resetScroll();
                            }
                          },
                          onOpenSystemKeyboard: () {
                            _inputFocusNode.requestFocus();
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              SizedBox(width: 32 * UiAdaptive.scale),

              // Right: Input Box + Smart Suggestions + Hot/History or Results
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Input Box with system TextField
                    Container(
                      width: double.infinity,
                      padding: EdgeInsets.symmetric(
                        horizontal: 20 * UiAdaptive.scale,
                        vertical: 10 * UiAdaptive.scale,
                      ),
                      decoration: BoxDecoration(
                        color: TvTheme.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: TvTheme.primary.withValues(alpha: 0.5),
                          width: 1.5,
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.search,
                            color: TvTheme.primary,
                            size: 22,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            // 这一层 Shortcuts 必须比 Flutter 内置的
                            // DefaultTextEditingShortcuts 更靠近焦点，否则方向键
                            // 会被内置的文本选择快捷键吃掉，焦点走不出输入框。
                            child: Shortcuts(
                              shortcuts: const <ShortcutActivator, Intent>{
                                SingleActivator(LogicalKeyboardKey.arrowDown):
                                    _FocusResultsIntent(),
                                SingleActivator(LogicalKeyboardKey.arrowUp):
                                    _FocusResultsIntent(),
                                SingleActivator(LogicalKeyboardKey.select):
                                    _FocusResultsIntent(),
                                SingleActivator(LogicalKeyboardKey.gameButtonA):
                                    _FocusResultsIntent(),
                              },
                              child: Actions(
                                actions: <Type, Action<Intent>>{
                                  _FocusResultsIntent:
                                      CallbackAction<_FocusResultsIntent>(
                                        onInvoke: (_) {
                                          _jumpToResults(provider);
                                          return null;
                                        },
                                      ),
                                },
                                child: TextField(
                                  controller: _textController,
                                  focusNode: _inputFocusNode,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16 * TvTheme.fontScale,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  decoration: const InputDecoration(
                                    hintText: '输入中文片名、拼音缩写 (如: 狂飙 / KB / FH)',
                                    hintStyle: TextStyle(
                                      color: TvTheme.textSecondary,
                                      fontSize: 15 * TvTheme.fontScale,
                                    ),
                                    border: InputBorder.none,
                                  ),
                                  onSubmitted: (val) {
                                    if (val.trim().isNotEmpty) {
                                      provider.searchKeyword(val.trim());
                                      _pendingJumpToResults = true;
                                      _resetScroll();
                                    }
                                  },
                                  onChanged: (val) {
                                    provider.setQuery(val);
                                    _resetScroll();
                                  },
                                ),
                              ),
                            ),
                          ),
                          if (provider.query.isNotEmpty)
                            IconButton(
                              icon: const Icon(
                                Icons.close_rounded,
                                color: TvTheme.textSecondary,
                                size: 20,
                              ),
                              onPressed: () {
                                provider.clear();
                                _textController.clear();
                              },
                            ),
                          TvFocusWidget(
                            borderRadius: 8,
                            onTap: () {
                              if (provider.query.trim().isNotEmpty) {
                                provider.searchKeyword(provider.query.trim());
                                _pendingJumpToResults = true;
                                _resetScroll();
                              }
                            },
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 20 * UiAdaptive.scale,
                                vertical: 12 * UiAdaptive.scale,
                              ),
                              decoration: BoxDecoration(
                                color: TvTheme.primary.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                '搜索',
                                style: TextStyle(
                                  color: TvTheme.primary,
                                  fontSize: 14 * TvTheme.fontScale,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Smart Pinyin / Hot Suggestions bar
                    if (provider.suggestions.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: TvTheme.surface.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.auto_awesome,
                              color: TvTheme.accent,
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              '猜你想搜:',
                              style: TextStyle(
                                color: TvTheme.accent,
                                fontSize: 13 * TvTheme.fontScale,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: provider.suggestions.map((sug) {
                                    return Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: TvFocusWidget(
                                        borderRadius: 6,
                                        onTap: () =>
                                            _onKeywordSelected(provider, sug),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color: TvTheme.surfaceLighter,
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                            border: Border.all(
                                              color: TvTheme.accent.withValues(
                                                alpha: 0.4,
                                              ),
                                            ),
                                          ),
                                          child: Text(
                                            sug,
                                            style: const TextStyle(
                                              color: TvTheme.textPrimary,
                                              fontSize: 13 * TvTheme.fontScale,
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Auto-resolved banner notice
                    if (provider.autoResolvedChinese != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        '💡 已根据首字母自动为您匹配展示 "${provider.autoResolvedChinese}" 的搜索结果',
                        style: const TextStyle(
                          color: TvTheme.accent,
                          fontSize: 13 * TvTheme.fontScale,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],

                    SizedBox(height: 16 * UiAdaptive.scale),

                    // Main display area: Loading, Results, or Search History & Hot Keywords
                    Expanded(
                      child: provider.isLoading
                          ? const Center(
                              child: CircularProgressIndicator(
                                color: TvTheme.primary,
                              ),
                            )
                          : provider.query.isNotEmpty
                          ? (provider.results.isEmpty
                                ? Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.search_off_rounded,
                                          color: Colors.white24,
                                          size: 56,
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          provider.errorMessage ??
                                              '未找到与 "${provider.query}" 相关的影视内容',
                                          style: const TextStyle(
                                            color: TvTheme.textSecondary,
                                            fontSize: 15 * TvTheme.fontScale,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        const Text(
                                          '建议：可尝试输入中文片名或点击下方热门推荐',
                                          style: TextStyle(
                                            color: Colors.white38,
                                            fontSize: 13 * TvTheme.fontScale,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : _buildResultsGrid(context, provider))
                          : _buildHotAndHistory(context, provider),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 搜索结果网格 + 翻页尾巴。
  ///
  /// 为什么用 CustomScrollView 而不是 GridView：翻页状态要挂在网格**后面**，
  /// 而 GridView 只能塞单元格，尾巴会被排进网格里、白占一个卡片位。
  /// 网格参数与改动前逐字一致（电视档 3 列，手机档按最大单元宽度切列）。
  Widget _buildResultsGrid(BuildContext context, SearchProvider provider) {
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverGrid(
          gridDelegate: UiAdaptive.isPhone
              ? const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 130,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.68,
                )
              : const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 18,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.68,
                ),
          delegate: SliverChildBuilderDelegate(
            (context, idx) => _buildResultCard(
              context,
              provider.results[idx],
              // 首项挂上焦点节点，供输入框「跳到结果」用
              focusNode: idx == 0 ? _firstResultFocusNode : null,
            ),
            childCount: provider.results.length,
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 18 * UiAdaptive.scale, bottom: 8),
            child: provider.isLoadingMore
                ? const Center(
                    child: SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        color: TvTheme.primary,
                        strokeWidth: 2.5,
                      ),
                    ),
                  )
                : (provider.hasMore
                      ? const SizedBox.shrink()
                      : Center(
                          child: Text(
                            '已经到底啦',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 12 * TvTheme.fontScale,
                            ),
                          ),
                        )),
          ),
        ),
      ],
    );
  }

  Widget _buildHotAndHistory(BuildContext context, SearchProvider provider) {
    final history = provider.searchHistory;
    final hotWords = provider.popularKeywords;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Search History
          if (history.isNotEmpty) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.history_rounded,
                      color: TvTheme.textSecondary,
                      size: 18,
                    ),
                    SizedBox(width: 6),
                    Text(
                      '搜索历史',
                      style: TextStyle(
                        color: TvTheme.textPrimary,
                        fontSize: 16 * TvTheme.fontScale,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                TvFocusWidget(
                  borderRadius: 6,
                  onTap: provider.clearHistory,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: const Text(
                      '清空历史',
                      style: TextStyle(
                        color: TvTheme.textSecondary,
                        fontSize: 12 * TvTheme.fontScale,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: history.map((item) {
                return TvFocusWidget(
                  borderRadius: 8,
                  onTap: () => _onKeywordSelected(provider, item),
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 18 * UiAdaptive.scale,
                      vertical: 12 * UiAdaptive.scale,
                    ),
                    decoration: BoxDecoration(
                      color: TvTheme.surfaceLighter,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      item,
                      style: const TextStyle(
                        color: TvTheme.textPrimary,
                        fontSize: 13 * TvTheme.fontScale,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),
          ],

          // Hot / Trending Keywords
          const Row(
            children: [
              Icon(
                Icons.local_fire_department_rounded,
                color: Colors.orangeAccent,
                size: 20,
              ),
              SizedBox(width: 6),
              Text(
                '热门推荐影视 (一键搜索)',
                style: TextStyle(
                  color: TvTheme.textPrimary,
                  fontSize: 16 * TvTheme.fontScale,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: hotWords.map((kw) {
              return TvFocusWidget(
                borderRadius: 8,
                scale: 1.08,
                onTap: () => _onKeywordSelected(provider, kw),
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 18 * UiAdaptive.scale,
                    vertical: 12 * UiAdaptive.scale,
                  ),
                  decoration: BoxDecoration(
                    color: TvTheme.surfaceLighter,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Text(
                    kw,
                    style: const TextStyle(
                      color: TvTheme.textPrimary,
                      fontSize: 13 * TvTheme.fontScale,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildResultCard(
    BuildContext context,
    VodItem item, {
    FocusNode? focusNode,
  }) {
    return TvFocusWidget(
      focusNode: focusNode,
      borderRadius: 10,
      scale: 1.08,
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DetailView(detailPath: item.detailPath),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: TvTheme.surface,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: CachedNetworkImage(
                imageUrl: item.cover,
                fit: BoxFit.cover,
                placeholder: (c, u) => Container(color: TvTheme.surfaceLighter),
                errorWidget: (c, u, e) => Container(
                  color: TvTheme.surfaceLighter,
                  child: const Center(
                    child: Icon(
                      Icons.movie_outlined,
                      color: Colors.white24,
                      size: 36,
                    ),
                  ),
                ),
              ),
            ),
            if (item.remark.isNotEmpty)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    item.remark,
                    style: const TextStyle(
                      color: TvTheme.primary,
                      fontSize: 11 * TvTheme.fontScale,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.85),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(10),
                    bottomRight: Radius.circular(10),
                  ),
                ),
                child: Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13 * TvTheme.fontScale,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
