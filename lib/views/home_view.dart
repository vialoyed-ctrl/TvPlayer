import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../providers/home_provider.dart';
import '../models/vod_item.dart';
import '../services/download_service.dart';
import '../tv_ui/tv_theme.dart';
import '../tv_ui/tv_focus_widget.dart';
import '../tv_ui/ui_adaptive.dart';
import 'detail_view.dart';
import 'download_view.dart';
import 'search_view.dart';
import 'history_view.dart';
import 'settings_view.dart';

class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      context.read<HomeProvider>().loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<HomeProvider>();

    return Scaffold(
      backgroundColor: TvTheme.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Navigation Bar
            _buildTopBar(context, provider),

            // Main Content Area
            Expanded(
              child: provider.isLoading && provider.items.isEmpty
                  ? const Center(
                      child: CircularProgressIndicator(color: TvTheme.primary),
                    )
                  : provider.errorMessage != null && provider.items.isEmpty
                  ? _buildErrorView(provider)
                  : _buildPosterGrid(provider),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, HomeProvider provider) {
    return Container(
      // 手机档整体减半，电视档 scale == 1.0 时数值与原值完全相同。
      padding: EdgeInsets.symmetric(
        horizontal: 32 * UiAdaptive.scale,
        vertical: 12 * UiAdaptive.scale,
      ),
      decoration: BoxDecoration(
        color: TvTheme.surface.withValues(alpha: 0.8),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Row(
        children: [
          // App Logo
          Row(
            children: [
              Image.asset(
                'assets/app_icon.png',
                width: 34 * UiAdaptive.scale,
                height: 34 * UiAdaptive.scale,
              ),
              SizedBox(width: 8 * UiAdaptive.scale),
              const Text(
                'TvPlayer',
                style: TextStyle(
                  color: TvTheme.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 18 * TvTheme.fontScale,
                ),
              ),
            ],
          ),
          SizedBox(width: 32 * UiAdaptive.scale),

          // Channel Tabs
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: List.generate(provider.channels.length, (index) {
                  final ch = provider.channels[index];
                  final isSelected = provider.selectedChannelIndex == index;
                  return Padding(
                    padding: EdgeInsets.only(right: 12 * UiAdaptive.scale),
                    child: TvFocusWidget(
                      borderRadius: 8,
                      scale: 1.08,
                      onTap: () => provider.selectChannel(index),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 18 * UiAdaptive.scale,
                          vertical: 8 * UiAdaptive.scale,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? TvTheme.primary.withValues(alpha: 0.2)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: isSelected
                              ? Border.all(
                                  color: TvTheme.primary.withValues(alpha: 0.8),
                                  width: 1.5,
                                )
                              : null,
                        ),
                        child: Text(
                          ch.name,
                          style: TextStyle(
                            color: isSelected
                                ? TvTheme.primary
                                : TvTheme.textSecondary,
                            fontSize: 16 * TvTheme.fontScale,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),

          // Search & History Action Buttons
          TvFocusWidget(
            borderRadius: 8,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SearchView()),
              );
            },
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: 14 * UiAdaptive.scale,
                vertical: 8 * UiAdaptive.scale,
              ),
              color: TvTheme.surfaceLighter,
              child: const Row(
                children: [
                  Icon(Icons.search, color: TvTheme.textPrimary, size: 18),
                  SizedBox(width: 6),
                  Text(
                    '搜索',
                    style: TextStyle(
                      color: TvTheme.textPrimary,
                      fontSize: 14 * TvTheme.fontScale,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          TvFocusWidget(
            borderRadius: 8,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HistoryView()),
              );
            },
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: 14 * UiAdaptive.scale,
                vertical: 8 * UiAdaptive.scale,
              ),
              color: TvTheme.surfaceLighter,
              child: const Row(
                children: [
                  Icon(Icons.history, color: TvTheme.textPrimary, size: 18),
                  SizedBox(width: 6),
                  Text(
                    '历史',
                    style: TextStyle(
                      color: TvTheme.textPrimary,
                      fontSize: 14 * TvTheme.fontScale,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 下载：有任务在跑时角标显示数量，一眼能看出后台还在下东西。
          TvFocusWidget(
            borderRadius: 8,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DownloadView()),
              );
            },
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: 14 * UiAdaptive.scale,
                vertical: 8 * UiAdaptive.scale,
              ),
              color: TvTheme.surfaceLighter,
              child: Row(
                children: [
                  const Icon(
                    Icons.download_rounded,
                    color: TvTheme.textPrimary,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    '下载',
                    style: TextStyle(
                      color: TvTheme.textPrimary,
                      fontSize: 14 * TvTheme.fontScale,
                    ),
                  ),
                  if (context.watch<DownloadService>().pendingCount > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: TvTheme.primary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${context.watch<DownloadService>().pendingCount}',
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 11 * TvTheme.fontScale,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 设置：目前只有 WebDAV 跨设备同步。
          TvFocusWidget(
            borderRadius: 8,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsView()),
              );
            },
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: 14 * UiAdaptive.scale,
                vertical: 8 * UiAdaptive.scale,
              ),
              color: TvTheme.surfaceLighter,
              child: const Row(
                children: [
                  Icon(
                    Icons.settings_outlined,
                    color: TvTheme.textPrimary,
                    size: 18,
                  ),
                  SizedBox(width: 6),
                  Text(
                    '设置',
                    style: TextStyle(
                      color: TvTheme.textPrimary,
                      fontSize: 14 * TvTheme.fontScale,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPosterGrid(HomeProvider provider) {
    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 32 * UiAdaptive.scale,
            vertical: 16 * UiAdaptive.scale,
          ),
          child: GridView.builder(
            controller: _scrollController,
            // 电视档：固定 5 列，数字与改动前完全一致。
            // 手机档：换成「按最大单元宽度切列」，横屏手机上大约 6~7 列。
            // 用 maxCrossAxisExtent 而不是写死列数，是为了不必猜每台手机的逻辑
            // 分辨率 —— 屏宽一点就自动多一列，窄一点自动少一列。
            gridDelegate: UiAdaptive.isPhone
                ? const SliverGridDelegateWithMaxCrossAxisExtent(
                    // 横屏手机约 780~800 逻辑宽，减掉两侧留白后约 7 列。
                    // 与减半后的字号相比，这个密度下海报和标题的比例是协调的。
                    maxCrossAxisExtent: 110,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.65, // Standard movie poster ratio
                  )
                : const SliverGridDelegateWithFixedCrossAxisCount(
                    // 字号放大 3 倍后，6 列会让标题挤成一两个字，改为 5 列。
                    crossAxisCount: 5,
                    mainAxisSpacing: 24,
                    crossAxisSpacing: 20,
                    childAspectRatio: 0.65, // Standard movie poster ratio
                  ),
            itemCount: provider.items.length,
            itemBuilder: (context, index) {
              final item = provider.items[index];
              return _buildPosterCard(context, item);
            },
          ),
        ),

        // 往下滚到底部时自动加载下一页，这里给一个轻量提示
        if (provider.isLoadingMore ||
            (!provider.hasMore && provider.items.isNotEmpty))
          Positioned(
            left: 0,
            right: 0,
            bottom: 12,
            child: Center(
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 20 * UiAdaptive.scale,
                  vertical: 10 * UiAdaptive.scale,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: TvTheme.primary.withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  provider.isLoadingMore ? '正在加载下一页 ...' : '已经到底啦',
                  style: const TextStyle(
                    color: TvTheme.primary,
                    fontSize: 13 * TvTheme.fontScale,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPosterCard(BuildContext context, VodItem item) {
    return TvFocusWidget(
      borderRadius: 12,
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
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Poster Image
            CachedNetworkImage(
              imageUrl: item.cover,
              fit: BoxFit.cover,
              placeholder: (context, url) => Container(
                color: TvTheme.surfaceLighter,
                child: const Center(
                  child: Icon(
                    Icons.movie_outlined,
                    color: Colors.white24,
                    size: 36,
                  ),
                ),
              ),
              errorWidget: (context, url, error) => Container(
                color: TvTheme.surfaceLighter,
                child: const Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white24,
                    size: 36,
                  ),
                ),
              ),
            ),

            // Top-right Remark Badge
            if (item.remark.isNotEmpty)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 10 * UiAdaptive.scale,
                    vertical: 4 * UiAdaptive.scale,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: TvTheme.primary.withValues(alpha: 0.4),
                      width: 1.2,
                    ),
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

            // Bottom Gradient & Title
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: EdgeInsets.all(10 * UiAdaptive.scale),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.95),
                      Colors.black.withValues(alpha: 0.6),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: TvTheme.textPrimary,
                    fontSize: 14 * TvTheme.fontScale,
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

  Widget _buildErrorView(HomeProvider provider) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, color: Colors.white38, size: 54),
          const SizedBox(height: 16),
          Text(
            provider.errorMessage ?? '加载失败',
            style: const TextStyle(
              color: TvTheme.textSecondary,
              fontSize: 16 * TvTheme.fontScale,
            ),
          ),
          const SizedBox(height: 20),
          TvFocusWidget(
            borderRadius: 8,
            onTap: () => provider.loadChannel(provider.selectedChannelIndex),
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: 32 * UiAdaptive.scale,
                vertical: 16 * UiAdaptive.scale,
              ),
              color: TvTheme.primary,
              child: const Text(
                '点击重试',
                style: TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
