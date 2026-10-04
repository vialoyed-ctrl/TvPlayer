import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../models/play_source.dart';
import '../models/vod_detail.dart';
import '../providers/detail_provider.dart';
import '../services/download_service.dart';
import '../tv_ui/tv_theme.dart';
import '../tv_ui/tv_focus_widget.dart';
import '../tv_ui/tv_toast.dart';
import '../tv_ui/ui_adaptive.dart';
import 'player_view.dart';

class DetailView extends StatelessWidget {
  final String detailPath;
  final bool autoPlay;

  const DetailView({
    super.key,
    required this.detailPath,
    this.autoPlay = false,
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => DetailProvider()..loadDetail(detailPath),
      child: _DetailContent(autoPlay: autoPlay),
    );
  }
}

class _DetailContent extends StatefulWidget {
  final bool autoPlay;
  const _DetailContent({this.autoPlay = false});

  @override
  State<_DetailContent> createState() => _DetailContentState();
}

class _DetailContentState extends State<_DetailContent> {
  int _rangeIndex = 0;
  static const int _groupSize = 30;
  bool _hasAutoPlayed = false;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DetailProvider>();

    if (widget.autoPlay &&
        !_hasAutoPlayed &&
        !provider.isLoading &&
        provider.detail != null) {
      _hasAutoPlayed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _startPlayback(context, provider);
        }
      });
    }

    return Scaffold(
      backgroundColor: TvTheme.background,
      body: SafeArea(
        child: provider.isLoading
            ? const Center(
                child: CircularProgressIndicator(color: TvTheme.primary),
              )
            : provider.errorMessage != null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      provider.errorMessage!,
                      style: const TextStyle(color: TvTheme.textSecondary),
                    ),
                    const SizedBox(height: 16),
                    TvFocusWidget(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 20 * UiAdaptive.scale,
                          vertical: 10 * UiAdaptive.scale,
                        ),
                        color: TvTheme.surfaceLighter,
                        child: const Text(
                          '返回',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            : _buildBody(context, provider),
      ),
    );
  }

  Widget _buildBody(BuildContext context, DetailProvider provider) {
    final detail = provider.detail!;

    return Stack(
      children: [
        // Background blur hero poster
        Positioned.fill(
          child: Opacity(
            opacity: 0.15,
            child: CachedNetworkImage(
              imageUrl: detail.cover,
              fit: BoxFit.cover,
            ),
          ),
        ),

        // Foreground content
        Padding(
          padding: EdgeInsets.all(36 * UiAdaptive.scale),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left: Poster and Action buttons
              SizedBox(
                width: 420 * UiAdaptive.scale,
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          height: 300 * UiAdaptive.scale,
                          width: double.infinity,
                          color: TvTheme.surfaceLighter,
                          child: CachedNetworkImage(
                            imageUrl: detail.cover,
                            fit: BoxFit.cover,
                            errorWidget: (c, u, e) => const Center(
                              child: Icon(
                                Icons.movie_outlined,
                                color: Colors.white24,
                                size: 48,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      // Play / Resume Button
                      TvFocusWidget(
                        autofocus: true,
                        borderRadius: 10,
                        onTap: () => _startPlayback(context, provider),
                        focusBorderColor: TvTheme.accent,
                        child: Container(
                          width: double.infinity,
                          padding: EdgeInsets.symmetric(
                            vertical: 18 * UiAdaptive.scale,
                          ),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFFFFB300), Color(0xFFFF8F00)],
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.black,
                                size: 22,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                provider.history != null
                                    ? '继续: ${provider.history!.episodeName}'
                                    : '立即播放',
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15 * TvTheme.fontScale,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Favorite Toggle Button
                      TvFocusWidget(
                        borderRadius: 10,
                        onTap: () {
                          provider.toggleFavorite();
                          TvToast.show(
                            context,
                            provider.isFavorite ? '已加入收藏' : '已取消收藏',
                            icon: provider.isFavorite
                                ? Icons.favorite
                                : Icons.favorite_border,
                          );
                        },
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          color: TvTheme.surfaceLighter,
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                provider.isFavorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                color: provider.isFavorite
                                    ? Colors.redAccent
                                    : TvTheme.textSecondary,
                                size: 18,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                provider.isFavorite ? '已收藏' : '加入收藏',
                                style: const TextStyle(
                                  color: TvTheme.textPrimary,
                                  fontSize: 13 * TvTheme.fontScale,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              SizedBox(width: 40 * UiAdaptive.scale),

              // Right: Metadata & Episodes
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title
                      Text(
                        detail.title,
                        style: const TextStyle(
                          color: TvTheme.textPrimary,
                          fontSize: 28 * TvTheme.fontScale,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Tags Row
                      Row(
                        children: [
                          if (detail.year.isNotEmpty) _buildBadge(detail.year),
                          if (detail.area.isNotEmpty) _buildBadge(detail.area),
                          if (detail.type.isNotEmpty) _buildBadge(detail.type),
                          if (detail.remark.isNotEmpty)
                            _buildBadge(detail.remark, color: TvTheme.accent),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // Director & Actor
                      if (detail.director.isNotEmpty)
                        Text(
                          '导演: ${detail.director}',
                          style: const TextStyle(
                            color: TvTheme.textSecondary,
                            fontSize: 14 * TvTheme.fontScale,
                          ),
                        ),
                      if (detail.actor.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          '主演: ${detail.actor}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: TvTheme.textSecondary,
                            fontSize: 14 * TvTheme.fontScale,
                          ),
                        ),
                      ],

                      // Description
                      if (detail.desc.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          detail.desc,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 13 * TvTheme.fontScale,
                            height: 1.4,
                          ),
                        ),
                      ],

                      const SizedBox(height: 24),

                      // Play Source Tabs
                      if (detail.sources.isNotEmpty) ...[
                        const Text(
                          '播放线路 (支持自动测速优选):',
                          style: TextStyle(
                            color: TvTheme.textPrimary,
                            fontSize: 16 * TvTheme.fontScale,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (detail.sources.length > 1)
                          _buildSourceTabs(context, provider, detail.sources)
                        else
                          _buildSingleSourceChip(detail.sources.first.name),
                        const SizedBox(height: 20),
                      ],

                      // Episodes Section
                      if (provider.currentSource != null) ...[
                        Row(
                          children: [
                            const Text(
                              '选集列表',
                              style: TextStyle(
                                color: TvTheme.textPrimary,
                                fontSize: 16 * TvTheme.fontScale,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              '共 ${provider.currentSource!.episodes.length} 集',
                              style: const TextStyle(
                                color: TvTheme.textSecondary,
                                fontSize: 13 * TvTheme.fontScale,
                              ),
                            ),
                            const Spacer(),
                            // 缓存下载入口。做成「弹窗里勾选集数」而不是给每个格子塞一个
                            // 下载图标：电视上格子只有 110 宽，再塞图标会挤，而且每个格子
                            // 多一个焦点停靠点，遥控器走一遍很累。
                            TvFocusWidget(
                              borderRadius: 8,
                              scale: 1.06,
                              onTap: () =>
                                  _showDownloadDialog(context, provider),
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 16 * UiAdaptive.scale,
                                  vertical: 9 * UiAdaptive.scale,
                                ),
                                decoration: BoxDecoration(
                                  color: TvTheme.accent.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: TvTheme.accent.withValues(
                                      alpha: 0.5,
                                    ),
                                  ),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(
                                      Icons.download_rounded,
                                      color: TvTheme.accent,
                                      size: 16,
                                    ),
                                    SizedBox(width: 6),
                                    Text(
                                      '下载',
                                      style: TextStyle(
                                        color: TvTheme.accent,
                                        fontSize: 13 * TvTheme.fontScale,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),

                        // Range group tabs if episodes > 25
                        if (provider.currentSource!.episodes.length > 25) ...[
                          _buildRangeTabs(
                            provider.currentSource!.episodes.length,
                          ),
                          const SizedBox(height: 12),
                        ],

                        _buildCompactEpisodeGrid(context, provider),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 可切换的线路 pill 行（多于一条线路时）。
  Widget _buildSourceTabs(
    BuildContext context,
    DetailProvider provider,
    List<PlaySource> sources,
  ) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(sources.length, (sIndex) {
          final src = sources[sIndex];
          final isSelected = provider.selectedSourceIndex == sIndex;
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TvFocusWidget(
              borderRadius: 8,
              onTap: () {
                provider.selectSource(sIndex);
                _startPlayback(context, provider);
              },
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 20 * UiAdaptive.scale,
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
                  src.name,
                  style: TextStyle(
                    color: isSelected ? TvTheme.primary : TvTheme.textSecondary,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                    fontSize: 13 * TvTheme.fontScale,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  /// 只剩一条可用线路时的静态标签。
  ///
  /// 站点上没配源的线路（实测「4K」全站都是 `src: ""`）会被后台摘掉，
  /// 摘完常常只剩一条。这时**不能**沿用「线路数 ≤ 1 就整块隐藏」的老写法 ——
  /// 否则用户完全看不到当前用的是哪条源。
  ///
  /// 刻意**不**用 [TvFocusWidget]：它不可聚焦，遥控器的上下左右导航路径
  /// 与改动前逐点一致，不会多出一个要按过去的焦点。
  Widget _buildSingleSourceChip(String name) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 20 * UiAdaptive.scale,
        vertical: 14 * UiAdaptive.scale,
      ),
      decoration: BoxDecoration(
        color: TvTheme.primary.withValues(alpha: 0.25),
        border: Border.all(color: TvTheme.primary, width: 1.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        name,
        style: TextStyle(
          color: TvTheme.primary,
          fontWeight: FontWeight.bold,
          fontSize: 13 * TvTheme.fontScale,
        ),
      ),
    );
  }

  Widget _buildRangeTabs(int totalCount) {
    final groupCount = (totalCount / _groupSize).ceil();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(groupCount, (idx) {
          final start = idx * _groupSize + 1;
          final end = ((idx + 1) * _groupSize).clamp(1, totalCount);
          final isSelected = _rangeIndex == idx;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TvFocusWidget(
              borderRadius: 6,
              onTap: () {
                setState(() {
                  _rangeIndex = idx;
                });
              },
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 18 * UiAdaptive.scale,
                  vertical: 12 * UiAdaptive.scale,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? TvTheme.accent.withValues(alpha: 0.25)
                      : TvTheme.surfaceLighter,
                  border: isSelected
                      ? Border.all(color: TvTheme.accent, width: 1.5)
                      : null,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '$start-$end',
                  style: TextStyle(
                    color: isSelected ? TvTheme.accent : TvTheme.textSecondary,
                    fontSize: 13 * TvTheme.fontScale,
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
    );
  }

  Widget _buildCompactEpisodeGrid(
    BuildContext context,
    DetailProvider provider,
  ) {
    final episodes = provider.currentSource!.episodes;
    final startIndex = episodes.length > 25
        ? (_rangeIndex * _groupSize).clamp(0, episodes.length - 1)
        : 0;
    final endIndex = episodes.length > 25
        ? ((_rangeIndex + 1) * _groupSize).clamp(0, episodes.length)
        : episodes.length;
    final displayEpisodes = episodes.sublist(startIndex, endIndex);

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(displayEpisodes.length, (i) {
        final realIndex = startIndex + i;
        final ep = displayEpisodes[i];
        final isPlaying = provider.selectedEpisodeIndex == realIndex;

        final cleanEpName = _formatEpisodeLabel(ep.name, realIndex);
        final isShort = cleanEpName.length <= 4;

        return TvFocusWidget(
          borderRadius: 6,
          scale: 1.08,
          onTap: () {
            provider.selectEpisode(realIndex);
            _startPlayback(context, provider);
          },
          child: Container(
            width: (isShort ? 110 : 200) * UiAdaptive.scale,
            height: 72 * UiAdaptive.scale,
            decoration: BoxDecoration(
              color: isPlaying
                  ? TvTheme.primary.withValues(alpha: 0.25)
                  : TvTheme.surfaceLighter,
              border: isPlaying
                  ? Border.all(color: TvTheme.primary, width: 1.5)
                  : null,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              cleanEpName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isPlaying ? TvTheme.primary : TvTheme.textPrimary,
                fontWeight: isPlaying ? FontWeight.bold : FontWeight.w500,
                fontSize: 13 * TvTheme.fontScale,
              ),
            ),
          ),
        );
      }),
    );
  }

  String _formatEpisodeLabel(String name, int index) {
    final numMatch = RegExp(r'第?0*(\d+)集?').firstMatch(name);
    if (numMatch != null && name.length <= 6) {
      return numMatch.group(1)!;
    }
    return name;
  }

  Widget _buildBadge(String text, {Color color = TvTheme.primary}) {
    return Container(
      margin: EdgeInsets.only(right: 10 * UiAdaptive.scale),
      padding: EdgeInsets.symmetric(
        horizontal: 14 * UiAdaptive.scale,
        vertical: 8 * UiAdaptive.scale,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 1.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 12 * TvTheme.fontScale,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  /// 缓存下载的选集弹窗。
  ///
  /// 默认勾选当前正在看的那一集，所以「只下这一集」是两次确认的距离；
  /// 「整条线路全下」是「全选 → 开始下载」。
  ///
  /// 注意这里直接拿 `DownloadService.instance` 而不是 `context.watch`：
  /// `showDialog` 的 builder context 挂在根 Navigator 上，不在 Provider 作用域内。
  /// 需要实时刷新时用 [ListenableBuilder] 监听那个单例。
  void _showDownloadDialog(BuildContext context, DetailProvider provider) {
    final detail = provider.detail;
    final source = provider.currentSource;
    if (detail == null || source == null || source.episodes.isEmpty) return;

    final service = DownloadService.instance;
    final selected = <int>{provider.selectedEpisodeIndex};

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: TvTheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              const Icon(Icons.download_rounded, color: TvTheme.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '缓存下载 · ${detail.title}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: TvTheme.textPrimary,
                    fontSize: 18 * TvTheme.fontScale,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 1000 * UiAdaptive.scale,
            height: 430 * UiAdaptive.scale,
            child: ListenableBuilder(
              listenable: service,
              builder: (ctx2, _) {
                final episodes = source.episodes;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '线路「${source.name}」 · 共 ${episodes.length} 集 · 已选 ${selected.length} 集',
                      style: const TextStyle(
                        color: TvTheme.textSecondary,
                        fontSize: 13 * TvTheme.fontScale,
                      ),
                    ),
                    SizedBox(height: 12 * UiAdaptive.scale),
                    // 用 GridView 而不是 Wrap：一百多集的剧用 Wrap 会一次性
                    // 建出所有格子，弹窗打开要卡一下。
                    Expanded(
                      child: GridView.builder(
                        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 150 * UiAdaptive.scale,
                          mainAxisSpacing: 8 * UiAdaptive.scale,
                          crossAxisSpacing: 8 * UiAdaptive.scale,
                          childAspectRatio: 2.3,
                        ),
                        itemCount: episodes.length,
                        itemBuilder: (c, i) {
                          final ep = episodes[i];
                          final isSelected = selected.contains(i);
                          final existing = service.findByEpisode(
                            vodId: detail.id,
                            sourceName: source.name,
                            episodeIndex: i,
                          );
                          final done = existing?.isDone ?? false;
                          final running = existing != null && !existing.isDone;

                          final Color border;
                          if (done) {
                            border = TvTheme.success;
                          } else if (running) {
                            border = TvTheme.primary;
                          } else if (isSelected) {
                            border = TvTheme.accent;
                          } else {
                            border = Colors.transparent;
                          }

                          return TvFocusWidget(
                            borderRadius: 8,
                            scale: 1.06,
                            onTap: () {
                              setDialogState(() {
                                if (isSelected) {
                                  selected.remove(i);
                                } else {
                                  selected.add(i);
                                }
                              });
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? TvTheme.accent.withValues(alpha: 0.22)
                                    : TvTheme.surfaceLighter,
                                border: Border.all(color: border, width: 1.6),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (done || running) ...[
                                    Icon(
                                      done
                                          ? Icons.check_circle_rounded
                                          : Icons.downloading_rounded,
                                      size: 13,
                                      color: done
                                          ? TvTheme.success
                                          : TvTheme.primary,
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Flexible(
                                    child: Text(
                                      _formatEpisodeLabel(ep.name, i),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: isSelected
                                            ? TvTheme.accent
                                            : TvTheme.textPrimary,
                                        fontSize: 13 * TvTheme.fontScale,
                                        fontWeight: isSelected
                                            ? FontWeight.bold
                                            : FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => setDialogState(() {
                selected
                  ..clear()
                  ..addAll(List.generate(source.episodes.length, (i) => i));
              }),
              child: const Text(
                '全选',
                style: TextStyle(color: TvTheme.textPrimary),
              ),
            ),
            TextButton(
              onPressed: () => setDialogState(selected.clear),
              child: const Text(
                '清空',
                style: TextStyle(color: TvTheme.textSecondary),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text(
                '取消',
                style: TextStyle(color: TvTheme.textSecondary),
              ),
            ),
            TextButton(
              onPressed: selected.isEmpty
                  ? null
                  : () async {
                      final count = await _enqueueDownloads(
                        service,
                        detail,
                        source,
                        selected,
                      );
                      if (!dialogCtx.mounted) return;
                      Navigator.pop(dialogCtx);
                      if (!context.mounted) return;
                      TvToast.show(
                        context,
                        count > 0
                            ? '已加入下载队列 $count 集，可在首页「下载」里查看进度'
                            : '这些集都已经在下载队列里了',
                        icon: Icons.download_done_rounded,
                        duration: const Duration(seconds: 4),
                      );
                    },
              child: Text(
                '开始下载 (${selected.length})',
                style: TextStyle(
                  color: selected.isEmpty
                      ? TvTheme.textSecondary
                      : TvTheme.accent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 把勾选的集数入队。返回真正新增的任务数（已存在的会被跳过）。
  Future<int> _enqueueDownloads(
    DownloadService service,
    VodDetail detail,
    PlaySource source,
    Set<int> indexes,
  ) {
    final sorted = indexes.toList()..sort();
    return service.enqueueMany(
      sorted.map(
        (i) => (
          episodeName: source.episodes[i].name,
          episodeIndex: i,
          playPath: source.episodes[i].playPath,
        ),
      ),
      vodId: detail.id,
      title: detail.title,
      cover: detail.cover,
      sourceName: source.name,
    );
  }

  void _startPlayback(BuildContext context, DetailProvider provider) {
    final detail = provider.detail;
    if (detail == null || detail.sources.isEmpty) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerView(
          detail: detail,
          allSources: detail.sources,
          initialSourceIndex: provider.selectedSourceIndex,
          initialEpisodeIndex: provider.selectedEpisodeIndex,
        ),
      ),
    );
  }
}
