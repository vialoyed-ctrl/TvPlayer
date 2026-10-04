import 'dart:io';

import 'package:flutter/material.dart';

import '../services/download_storage.dart';
import '../tv_ui/tv_focus_widget.dart';
import '../tv_ui/tv_theme.dart';
import '../tv_ui/tv_toast.dart';
import '../tv_ui/ui_adaptive.dart';

/// 遥控器友好的目录浏览器。
///
/// **为什么不用系统自带的 SAF 选择器**：电视上那个界面要靠遥控器在一个多级
/// 列表里点来点去，既没有焦点高亮、也不好返回；这里自己画一个，方向键移动、
/// OK 进入、左上角返回上一级，与 App 其余部分的操作手感一致。
///
/// 需要「所有文件访问权限」才能列出目录内容。没授权时只显示提示与授权按钮；
/// 用户去系统设置拨完开关回来后，靠 [WidgetsBindingObserver] 重新检查。
///
/// 返回值为选中的绝对路径（`Navigator.pop(context, path)`），用户放弃则返回 null。
class FolderPickerView extends StatefulWidget {
  const FolderPickerView({super.key});

  @override
  State<FolderPickerView> createState() => _FolderPickerViewState();
}

class _FolderPickerViewState extends State<FolderPickerView>
    with WidgetsBindingObserver {
  final DownloadStorage _storage = DownloadStorage.instance;

  List<String> _roots = const [];
  String _current = '';
  List<String> _subDirs = const [];

  bool _loading = true;
  bool _hasAccess = false;
  int _freeBytes = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 用户去系统设置里拨「所有文件访问权限」的开关，App 收不到任何回调，
    // 只能在回到前台时自己重新查一次。
    if (state == AppLifecycleState.resumed) {
      _boot();
    }
  }

  Future<void> _boot() async {
    setState(() => _loading = true);
    final access = await _storage.hasAllFilesAccess();
    final roots = await _storage.storageRoots();
    if (!mounted) return;

    var current = _current;
    if (current.isEmpty) {
      // 默认从「上一次选过的目录」开始，没有就落到第一个存储根。
      final saved = await _storage.customDirPath();
      if (saved != null && Directory(saved).existsSync()) {
        current = saved;
      } else {
        current = roots.isNotEmpty ? roots.first : '';
      }
    }

    setState(() {
      _hasAccess = access;
      _roots = roots;
      _current = current;
      _loading = false;
    });
    await _refreshListing();
  }

  Future<void> _refreshListing() async {
    if (_current.isEmpty) return;
    final dirs = await _storage.listSubDirs(_current);
    final free = await _storage.freeSpaceBytes(_current);
    if (!mounted) return;
    setState(() {
      _subDirs = dirs;
      _freeBytes = free;
    });
  }

  Future<void> _enter(String path) async {
    setState(() {
      _current = path;
      _subDirs = const [];
    });
    await _refreshListing();
  }

  Future<void> _goUp() async {
    if (_current.isEmpty) return;
    // 已经到存储根了就不再往上 —— 再往上就是 `/`，里面全是系统目录。
    final isRoot = _roots.contains(_current);
    if (isRoot) {
      TvToast.show(context, '已经是存储根目录了');
      return;
    }
    final parent = Directory(_current).parent.path;
    await _enter(parent);
  }

  Future<void> _pickCurrent() async {
    if (_current.isEmpty) return;
    final ok = await _storage.canWrite(_current);
    if (!mounted) return;
    if (!ok) {
      TvToast.show(context, '这个目录不可写，换一个试试', icon: Icons.error_outline);
      return;
    }
    Navigator.pop(context, _current);
  }

  @override
  Widget build(BuildContext context) {
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
              _buildHeader(),
              SizedBox(height: 14 * UiAdaptive.scale),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: TvTheme.primary,
                        ),
                      )
                    : (_hasAccess ? _buildBrowser() : _buildPermissionPrompt()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
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
          '选择下载目录',
          style: TextStyle(
            color: TvTheme.textPrimary,
            fontSize: 20 * TvTheme.fontScale,
            fontWeight: FontWeight.bold,
          ),
        ),
        const Spacer(),
        if (_freeBytes > 0)
          Text(
            '剩余 ${DownloadStorage.formatBytes(_freeBytes)}',
            style: const TextStyle(
              color: TvTheme.textSecondary,
              fontSize: 13 * TvTheme.fontScale,
            ),
          ),
      ],
    );
  }

  /// 没有「所有文件访问权限」时的引导页。
  Widget _buildPermissionPrompt() {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 760),
        padding: EdgeInsets.all(28 * UiAdaptive.scale),
        decoration: BoxDecoration(
          color: TvTheme.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.folder_off_outlined,
              color: TvTheme.accent,
              size: 48,
            ),
            SizedBox(height: 16 * UiAdaptive.scale),
            const Text(
              '需要「所有文件访问权限」',
              style: TextStyle(
                color: TvTheme.textPrimary,
                fontSize: 18 * TvTheme.fontScale,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 10 * UiAdaptive.scale),
            const Text(
              '自选下载目录需要这个权限才能读写 SD 卡和系统「下载」目录。\n'
              '不授权也能下载 —— 文件会存到应用自己的目录里，\n'
              '只是文件管理器里看不到。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: TvTheme.textSecondary,
                fontSize: 14 * TvTheme.fontScale,
                height: 1.6,
              ),
            ),
            SizedBox(height: 22 * UiAdaptive.scale),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TvFocusWidget(
                  borderRadius: 10,
                  autofocus: true,
                  onTap: () async {
                    await _storage.requestAllFilesAccess();
                    if (!mounted) return;
                    TvToast.show(context, '请在系统设置里打开开关，然后返回本页');
                  },
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 24 * UiAdaptive.scale,
                      vertical: 14 * UiAdaptive.scale,
                    ),
                    decoration: BoxDecoration(
                      color: TvTheme.primary.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      '去授权',
                      style: TextStyle(
                        color: TvTheme.primary,
                        fontSize: 15 * TvTheme.fontScale,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 16 * UiAdaptive.scale),
                TvFocusWidget(
                  borderRadius: 10,
                  onTap: _boot,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 24 * UiAdaptive.scale,
                      vertical: 14 * UiAdaptive.scale,
                    ),
                    color: TvTheme.surfaceLighter,
                    child: const Text(
                      '我已授权，重新检查',
                      style: TextStyle(
                        color: TvTheme.textPrimary,
                        fontSize: 15 * TvTheme.fontScale,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrowser() {
    // 条目 = 「上一级」+ 子目录。做成一条扁平的列表，遥控器上下走最顺手。
    final entries = <_Entry>[
      if (!_roots.contains(_current))
        _Entry(
          path: Directory(_current).parent.path,
          label: '.. 上一级',
          isUp: true,
        ),
      ..._subDirs.map((p) => _Entry(path: p, label: p.split('/').last)),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 当前路径
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: 16 * UiAdaptive.scale,
            vertical: 12 * UiAdaptive.scale,
          ),
          decoration: BoxDecoration(
            color: TvTheme.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: TvTheme.primary.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              const Icon(Icons.folder_open, color: TvTheme.primary, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _current,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: TvTheme.textPrimary,
                    fontSize: 14 * TvTheme.fontScale,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 12 * UiAdaptive.scale),

        // 存储根快捷切换（主存储 / SD 卡）
        if (_roots.length > 1) ...[
          Row(
            children: [
              for (final r in _roots)
                Padding(
                  padding: EdgeInsets.only(right: 10 * UiAdaptive.scale),
                  child: TvFocusWidget(
                    borderRadius: 8,
                    onTap: () => _enter(r),
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 14 * UiAdaptive.scale,
                        vertical: 10 * UiAdaptive.scale,
                      ),
                      decoration: BoxDecoration(
                        color: r == _current
                            ? TvTheme.primary.withValues(alpha: 0.25)
                            : TvTheme.surfaceLighter,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        r,
                        style: TextStyle(
                          color: r == _current
                              ? TvTheme.primary
                              : TvTheme.textPrimary,
                          fontSize: 13 * TvTheme.fontScale,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(height: 12 * UiAdaptive.scale),
        ],

        Expanded(
          child: entries.isEmpty
              ? const Center(
                  child: Text(
                    '这个目录下没有子文件夹\n可以直接选择它作为下载目录',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: TvTheme.textSecondary,
                      fontSize: 15 * TvTheme.fontScale,
                      height: 1.7,
                    ),
                  ),
                )
              : GridView.builder(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 340 * UiAdaptive.scale,
                    mainAxisSpacing: 10 * UiAdaptive.scale,
                    crossAxisSpacing: 10 * UiAdaptive.scale,
                    childAspectRatio: 3.4,
                  ),
                  itemCount: entries.length,
                  itemBuilder: (context, idx) {
                    final e = entries[idx];
                    return TvFocusWidget(
                      borderRadius: 10,
                      autofocus: idx == 0,
                      onTap: () => e.isUp ? _goUp() : _enter(e.path),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 14 * UiAdaptive.scale,
                        ),
                        decoration: BoxDecoration(
                          color: TvTheme.surface,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              e.isUp
                                  ? Icons.arrow_upward_rounded
                                  : Icons.folder_rounded,
                              color: e.isUp ? TvTheme.accent : TvTheme.primary,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                e.label,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: TvTheme.textPrimary,
                                  fontSize: 14 * TvTheme.fontScale,
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

        SizedBox(height: 14 * UiAdaptive.scale),
        Row(
          children: [
            TvFocusWidget(
              borderRadius: 10,
              scale: 1.05,
              onTap: _pickCurrent,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 26 * UiAdaptive.scale,
                  vertical: 14 * UiAdaptive.scale,
                ),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [TvTheme.primaryDark, TvTheme.primary],
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.check_rounded, color: Colors.black, size: 20),
                    SizedBox(width: 8),
                    Text(
                      '选择这个文件夹',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 15 * TvTheme.fontScale,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(width: 14 * UiAdaptive.scale),
            TvFocusWidget(
              borderRadius: 10,
              onTap: _goUp,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 20 * UiAdaptive.scale,
                  vertical: 14 * UiAdaptive.scale,
                ),
                color: TvTheme.surfaceLighter,
                child: const Text(
                  '上一级',
                  style: TextStyle(
                    color: TvTheme.textPrimary,
                    fontSize: 15 * TvTheme.fontScale,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Entry {
  final String path;
  final String label;
  final bool isUp;
  const _Entry({required this.path, required this.label, this.isUp = false});
}
