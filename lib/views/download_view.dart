import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/download_task.dart';
import '../services/download_service.dart';
import '../services/download_storage.dart';
import '../tv_ui/tv_focus_widget.dart';
import '../tv_ui/tv_theme.dart';
import '../tv_ui/tv_toast.dart';
import '../tv_ui/ui_adaptive.dart';
import 'folder_picker_view.dart';

/// 下载管理页。
///
/// 显示所有缓存任务：进度、速度、状态、失败原因，并提供暂停 / 继续 / 重试 /
/// 删除。顶栏同时负责「下载目录」的设置 —— 默认是应用私有目录（零权限），
/// 用户可以换成任意自选目录（需要「所有文件访问权限」）。
class DownloadView extends StatefulWidget {
  const DownloadView({super.key});

  @override
  State<DownloadView> createState() => _DownloadViewState();
}

class _DownloadViewState extends State<DownloadView> {
  final DownloadStorage _storage = DownloadStorage.instance;

  String _dirPath = '';
  bool _dirIsCustom = false;
  int _freeBytes = -1;

  @override
  void initState() {
    super.initState();
    _loadDir();
  }

  Future<void> _loadDir() async {
    final dir = await _storage.resolve();
    final free = await _storage.freeSpaceBytes(dir.path);
    if (!mounted) return;
    setState(() {
      _dirPath = dir.path;
      _dirIsCustom = dir.isCustom;
      _freeBytes = free;
    });
  }

  Future<void> _changeFolder() async {
    final picked = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const FolderPickerView()),
    );
    if (picked == null || !mounted) return;
    await _storage.setCustomDirPath(picked);
    await _loadDir();
    if (!mounted) return;
    TvToast.show(context, '下载目录已改为：$picked', icon: Icons.check_circle_outline);
  }

  Future<void> _resetFolder() async {
    await _storage.setCustomDirPath(null);
    await _loadDir();
    if (!mounted) return;
    TvToast.show(context, '已恢复为应用私有目录');
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<DownloadService>();
    final tasks = service.tasks;

    return Scaffold(
      backgroundColor: TvTheme.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 36 * UiAdaptive.scale,
            vertical: 20 * UiAdaptive.scale,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(service),
              SizedBox(height: 12 * UiAdaptive.scale),
              _buildDirBar(),
              SizedBox(height: 12 * UiAdaptive.scale),
              _buildSummary(service),
              SizedBox(height: 12 * UiAdaptive.scale),
              Expanded(
                child: tasks.isEmpty
                    ? _buildEmpty()
                    : ListView.separated(
                        itemCount: tasks.length,
                        separatorBuilder: (_, _) =>
                            SizedBox(height: 10 * UiAdaptive.scale),
                        itemBuilder: (context, idx) =>
                            _buildTaskRow(service, tasks[idx]),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(DownloadService service) {
    final hasActive = service.hasActiveWork;
    return Row(
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
        SizedBox(width: 14 * UiAdaptive.scale),
        const Text(
          '我的下载',
          style: TextStyle(
            color: TvTheme.textPrimary,
            fontSize: 20 * TvTheme.fontScale,
            fontWeight: FontWeight.bold,
          ),
        ),
        const Spacer(),
        TvFocusWidget(
          borderRadius: 8,
          onTap: () {
            if (hasActive) {
              service.pauseAll();
              TvToast.show(context, '已暂停全部下载');
            } else {
              service.resumeAll();
              TvToast.show(context, '已继续全部下载');
            }
          },
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: 16 * UiAdaptive.scale,
              vertical: 10 * UiAdaptive.scale,
            ),
            color: TvTheme.surfaceLighter,
            child: Row(
              children: [
                Icon(
                  hasActive
                      ? Icons.pause_circle_outline
                      : Icons.play_circle_outline,
                  color: TvTheme.textPrimary,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Text(
                  hasActive ? '全部暂停' : '全部继续',
                  style: const TextStyle(
                    color: TvTheme.textPrimary,
                    fontSize: 14 * TvTheme.fontScale,
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(width: 10 * UiAdaptive.scale),
        TvFocusWidget(
          borderRadius: 8,
          onTap: () async {
            await service.clearFinished();
            if (!mounted) return;
            TvToast.show(context, '已清空完成记录（文件保留在下载目录）');
          },
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: 16 * UiAdaptive.scale,
              vertical: 10 * UiAdaptive.scale,
            ),
            color: TvTheme.surfaceLighter,
            child: const Text(
              '清空已完成',
              style: TextStyle(
                color: TvTheme.textPrimary,
                fontSize: 14 * TvTheme.fontScale,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDirBar() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: 16 * UiAdaptive.scale,
        vertical: 10 * UiAdaptive.scale,
      ),
      decoration: BoxDecoration(
        color: TvTheme.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined, color: TvTheme.primary, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _dirIsCustom ? '下载目录（自选）' : '下载目录（应用私有）',
                  style: const TextStyle(
                    color: TvTheme.textSecondary,
                    fontSize: 12 * TvTheme.fontScale,
                  ),
                ),
                Text(
                  _dirPath.isEmpty ? '解析中…' : _dirPath,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: TvTheme.textPrimary,
                    fontSize: 13 * TvTheme.fontScale,
                  ),
                ),
              ],
            ),
          ),
          if (_freeBytes > 0)
            Padding(
              padding: EdgeInsets.only(right: 14 * UiAdaptive.scale),
              child: Text(
                '剩余 ${DownloadStorage.formatBytes(_freeBytes)}',
                style: const TextStyle(
                  color: TvTheme.textSecondary,
                  fontSize: 12 * TvTheme.fontScale,
                ),
              ),
            ),
          TvFocusWidget(
            borderRadius: 8,
            onTap: _changeFolder,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: 14 * UiAdaptive.scale,
                vertical: 9 * UiAdaptive.scale,
              ),
              decoration: BoxDecoration(
                color: TvTheme.primary.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '更换目录',
                style: TextStyle(
                  color: TvTheme.primary,
                  fontSize: 13 * TvTheme.fontScale,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          if (_dirIsCustom) ...[
            SizedBox(width: 8 * UiAdaptive.scale),
            TvFocusWidget(
              borderRadius: 8,
              onTap: _resetFolder,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 14 * UiAdaptive.scale,
                  vertical: 9 * UiAdaptive.scale,
                ),
                color: TvTheme.surfaceLighter,
                child: const Text(
                  '恢复默认',
                  style: TextStyle(
                    color: TvTheme.textSecondary,
                    fontSize: 13 * TvTheme.fontScale,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSummary(DownloadService service) {
    final items = <({String label, int count, Color color})>[
      (
        label: '进行中',
        count: service.tasks
            .where(
              (t) =>
                  t.status == DownloadStatus.downloading ||
                  t.status == DownloadStatus.merging ||
                  t.status == DownloadStatus.queued,
            )
            .length,
        color: TvTheme.primary,
      ),
      (label: '已完成', count: service.completedCount, color: TvTheme.success),
      (label: '失败', count: service.failedCount, color: TvTheme.error),
    ];
    return Row(
      children: [
        for (final it in items)
          Padding(
            padding: EdgeInsets.only(right: 22 * UiAdaptive.scale),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: it.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  '${it.label} ${it.count}',
                  style: const TextStyle(
                    color: TvTheme.textSecondary,
                    fontSize: 13 * TvTheme.fontScale,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.download_outlined, color: Colors.white24, size: 56),
          SizedBox(height: 14),
          Text(
            '还没有下载任务',
            style: TextStyle(
              color: TvTheme.textSecondary,
              fontSize: 16 * TvTheme.fontScale,
            ),
          ),
          SizedBox(height: 8),
          Text(
            '在剧集详情页点某一集右边的「下载」按钮即可',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 13 * TvTheme.fontScale,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskRow(DownloadService service, DownloadTask task) {
    final isActiveTask = service.activeTask?.id == task.id;
    return Container(
      padding: EdgeInsets.all(12 * UiAdaptive.scale),
      decoration: BoxDecoration(
        color: TvTheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 54 * UiAdaptive.scale,
              height: 72 * UiAdaptive.scale,
              child: CachedNetworkImage(
                imageUrl: task.cover,
                fit: BoxFit.cover,
                placeholder: (c, u) => Container(color: TvTheme.surfaceLighter),
                errorWidget: (c, u, e) => Container(
                  color: TvTheme.surfaceLighter,
                  child: const Icon(
                    Icons.movie_outlined,
                    color: Colors.white24,
                    size: 24,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(width: 14 * UiAdaptive.scale),

          // 信息 + 进度
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        task.title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: TvTheme.textPrimary,
                          fontSize: 15 * TvTheme.fontScale,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Text(
                      _statusLabel(service, task),
                      style: TextStyle(
                        color: _statusColor(task),
                        fontSize: 12 * TvTheme.fontScale,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 4 * UiAdaptive.scale),
                Text(
                  '${task.episodeName} · ${task.sourceName}'
                  '${task.sizeLabel.isEmpty ? '' : ' · ${task.sizeLabel}'}'
                  '${isActiveTask && service.speedBps > 0 ? ' · ${DownloadStorage.formatBytes(service.speedBps.round())}/s' : ''}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: TvTheme.textSecondary,
                    fontSize: 12 * TvTheme.fontScale,
                  ),
                ),
                SizedBox(height: 8 * UiAdaptive.scale),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: task.progress,
                    minHeight: 7,
                    backgroundColor: Colors.white12,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      task.isDone ? TvTheme.success : TvTheme.primary,
                    ),
                  ),
                ),
                if (task.totalSegments > 0) ...[
                  SizedBox(height: 4 * UiAdaptive.scale),
                  Text(
                    '${task.doneSegments} / ${task.totalSegments} 片'
                    '${task.durationSeconds > 0 ? ' · 时长 ${_fmtDuration(task.durationSeconds)}' : ''}'
                    '${task.encrypted ? ' · 加密线路（保留分片目录）' : ''}',
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 11 * TvTheme.fontScale,
                    ),
                  ),
                ],
                if (task.errorMessage != null &&
                    task.errorMessage!.isNotEmpty) ...[
                  SizedBox(height: 6 * UiAdaptive.scale),
                  Text(
                    task.errorMessage!,
                    style: const TextStyle(
                      color: TvTheme.error,
                      fontSize: 12 * TvTheme.fontScale,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: 14 * UiAdaptive.scale),

          // 操作
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  if (task.canPause)
                    _actionBtn(
                      icon: Icons.pause_rounded,
                      label: '暂停',
                      onTap: () => service.pause(task.id),
                    ),
                  if (task.canResume)
                    _actionBtn(
                      icon: Icons.refresh_rounded,
                      label: '重试',
                      color: TvTheme.primary,
                      onTap: () => service.retry(task.id),
                    ),
                  if (task.isDone)
                    _actionBtn(
                      icon: Icons.check_circle_outline,
                      label: '已完成',
                      color: TvTheme.success,
                      onTap: () => TvToast.show(
                        context,
                        task.outputPath == null
                            ? '文件已保存在下载目录'
                            : '已保存到：${task.outputPath}',
                        duration: const Duration(seconds: 5),
                      ),
                    ),
                  SizedBox(width: 8 * UiAdaptive.scale),
                  _actionBtn(
                    icon: Icons.delete_outline_rounded,
                    label: '删除',
                    color: TvTheme.error,
                    onTap: () => _confirmDelete(service, task),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(
    DownloadService service,
    DownloadTask task,
  ) async {
    final deleteFiles = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          '删除下载',
          style: TextStyle(
            color: TvTheme.textPrimary,
            fontSize: 18 * TvTheme.fontScale,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          '「${task.title} ${task.episodeName}」\n'
          '选择「删除任务和文件」会一并删掉磁盘上的内容，不可恢复。',
          style: const TextStyle(
            color: TvTheme.textSecondary,
            fontSize: 14 * TvTheme.fontScale,
            height: 1.6,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text(
              '取消',
              style: TextStyle(color: TvTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              '只删任务',
              style: TextStyle(color: TvTheme.textPrimary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '删除任务和文件',
              style: TextStyle(color: TvTheme.error),
            ),
          ),
        ],
      ),
    );
    if (deleteFiles == null || !mounted) return;
    await service.remove(task.id, deleteFiles: deleteFiles);
    if (!mounted) return;
    TvToast.show(context, deleteFiles ? '已删除任务和文件' : '已删除任务记录');
  }

  Widget _actionBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color color = TvTheme.textPrimary,
  }) {
    return TvFocusWidget(
      borderRadius: 8,
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: 12 * UiAdaptive.scale,
          vertical: 9 * UiAdaptive.scale,
        ),
        color: TvTheme.surfaceLighter,
        child: Row(
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(color: color, fontSize: 12 * TvTheme.fontScale),
            ),
          ],
        ),
      ),
    );
  }

  String _statusLabel(DownloadService service, DownloadTask task) {
    switch (task.status) {
      case DownloadStatus.queued:
        return task.attempt > 0 ? '等待自动重试' : '排队中';
      case DownloadStatus.downloading:
        return '下载中 ${(task.progress * 100).toStringAsFixed(0)}%';
      case DownloadStatus.merging:
        return '合并中…';
      case DownloadStatus.paused:
        return '已暂停';
      case DownloadStatus.completed:
        return '已完成';
      case DownloadStatus.failed:
        return '失败';
    }
  }

  Color _statusColor(DownloadTask task) {
    switch (task.status) {
      case DownloadStatus.completed:
        return TvTheme.success;
      case DownloadStatus.failed:
        return TvTheme.error;
      case DownloadStatus.paused:
        return TvTheme.accent;
      case DownloadStatus.merging:
        return TvTheme.accent;
      default:
        return TvTheme.primary;
    }
  }

  String _fmtDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
