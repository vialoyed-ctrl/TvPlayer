import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../providers/history_provider.dart';
import '../models/history_item.dart';
import '../tv_ui/tv_theme.dart';
import '../tv_ui/tv_focus_widget.dart';
import '../tv_ui/ui_adaptive.dart';
import 'detail_view.dart';

class HistoryView extends StatelessWidget {
  const HistoryView({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => HistoryProvider(),
      child: const _HistoryContent(),
    );
  }
}

class _HistoryContent extends StatelessWidget {
  const _HistoryContent();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<HistoryProvider>();

    return Scaffold(
      backgroundColor: TvTheme.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 36 * UiAdaptive.scale,
            vertical: 24 * UiAdaptive.scale,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top Bar
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
                          Icon(Icons.arrow_back, color: Colors.white, size: 18),
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
                  SizedBox(width: 24 * UiAdaptive.scale),

                  // Tabs: History vs Favorites
                  _buildTab(
                    context,
                    provider,
                    0,
                    '观看历史 (${provider.histories.length})',
                  ),
                  SizedBox(width: 12 * UiAdaptive.scale),
                  _buildTab(
                    context,
                    provider,
                    1,
                    '我的收藏 (${provider.favorites.length})',
                  ),

                  const Spacer(),

                  if (provider.selectedTab == 0 &&
                      provider.histories.isNotEmpty)
                    TvFocusWidget(
                      borderRadius: 8,
                      onTap: () => provider.clearHistory(),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 18 * UiAdaptive.scale,
                          vertical: 12 * UiAdaptive.scale,
                        ),
                        color: Colors.redAccent.withValues(alpha: 0.2),
                        child: const Row(
                          children: [
                            Icon(
                              Icons.delete_outline,
                              color: Colors.redAccent,
                              size: 18,
                            ),
                            SizedBox(width: 6),
                            Text(
                              '清空历史',
                              style: TextStyle(
                                color: Colors.redAccent,
                                fontSize: 13 * TvTheme.fontScale,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),

              SizedBox(height: 24 * UiAdaptive.scale),

              // Content List
              Expanded(
                child: provider.selectedTab == 0
                    ? _buildHistoryGrid(context, provider)
                    : _buildFavoritesGrid(context, provider),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTab(
    BuildContext context,
    HistoryProvider provider,
    int tabIdx,
    String title,
  ) {
    final isSelected = provider.selectedTab == tabIdx;
    return TvFocusWidget(
      borderRadius: 8,
      onTap: () => provider.switchTab(tabIdx),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: 24 * UiAdaptive.scale,
          vertical: 14 * UiAdaptive.scale,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? TvTheme.primary.withValues(alpha: 0.25)
              : TvTheme.surfaceLighter,
          border: isSelected
              ? Border.all(color: TvTheme.primary, width: 1.5)
              : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          title,
          style: TextStyle(
            color: isSelected ? TvTheme.primary : TvTheme.textSecondary,
            fontSize: 15 * TvTheme.fontScale,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryGrid(BuildContext context, HistoryProvider provider) {
    if (provider.histories.isEmpty) {
      return const Center(
        child: Text(
          '暂无观看历史记录',
          style: TextStyle(
            color: TvTheme.textSecondary,
            fontSize: 16 * TvTheme.fontScale,
          ),
        ),
      );
    }

    return GridView.builder(
      // 电视档 4 列，数字与改动前一致；手机档按最大单元宽度切列。
      gridDelegate: UiAdaptive.isPhone
          ? const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 130,
              mainAxisSpacing: 12,
              crossAxisSpacing: 10,
              childAspectRatio: 0.72,
            )
          : const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 20,
              crossAxisSpacing: 18,
              childAspectRatio: 0.72,
            ),
      itemCount: provider.histories.length,
      itemBuilder: (context, idx) {
        final item = provider.histories[idx];
        return _buildHistoryCard(context, item);
      },
    );
  }

  Widget _buildHistoryCard(BuildContext context, HistoryItem item) {
    final posSec = item.positionMs ~/ 1000;
    final durSec = item.durationMs ~/ 1000;
    final progressText = durSec > 0
        ? '${posSec ~/ 60}:${(posSec % 60).toString().padLeft(2, '0')} / ${durSec ~/ 60}:${(durSec % 60).toString().padLeft(2, '0')}'
        : '${posSec ~/ 60} 分钟';

    return TvFocusWidget(
      borderRadius: 10,
      scale: 1.08,
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DetailView(
              detailPath: '/detail/${item.vodId}.html',
              autoPlay: true,
            ),
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
            CachedNetworkImage(imageUrl: item.cover, fit: BoxFit.cover),
            // Episode & Progress Badge
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: EdgeInsets.all(8 * UiAdaptive.scale),
                color: Colors.black.withValues(alpha: 0.9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13 * TvTheme.fontScale,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${item.episodeName} · $progressText',
                      style: const TextStyle(
                        color: TvTheme.primary,
                        fontSize: 11 * TvTheme.fontScale,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFavoritesGrid(BuildContext context, HistoryProvider provider) {
    if (provider.favorites.isEmpty) {
      return const Center(
        child: Text(
          '暂无收藏影视',
          style: TextStyle(
            color: TvTheme.textSecondary,
            fontSize: 16 * TvTheme.fontScale,
          ),
        ),
      );
    }

    return GridView.builder(
      gridDelegate: UiAdaptive.isPhone
          ? const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 130,
              mainAxisSpacing: 12,
              crossAxisSpacing: 10,
              childAspectRatio: 0.72,
            )
          : const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 20,
              crossAxisSpacing: 18,
              childAspectRatio: 0.72,
            ),
      itemCount: provider.favorites.length,
      itemBuilder: (context, idx) {
        final item = provider.favorites[idx];
        return TvFocusWidget(
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
                CachedNetworkImage(imageUrl: item.cover, fit: BoxFit.cover),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: EdgeInsets.all(8 * UiAdaptive.scale),
                    color: Colors.black.withValues(alpha: 0.9),
                    child: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13 * TvTheme.fontScale,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
