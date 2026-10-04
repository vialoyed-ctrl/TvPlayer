import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/update_info.dart';
import '../models/webdav_config.dart';
import '../services/storage_service.dart';
import '../services/sync_service.dart';
import '../services/update_service.dart';
import '../services/webdav_client.dart';
import '../tv_ui/tv_focus_widget.dart';
import '../tv_ui/tv_theme.dart';
import '../tv_ui/tv_toast.dart';
import '../tv_ui/ui_adaptive.dart';

/// 设置页：WebDAV 跨设备同步 + 应用更新。
///
/// 输入框用系统键盘（和搜索页一样，电视上会弹出遥控器能操作的软键盘）。
/// 没有复用 `TvKeyboard`：那套键盘只有 A-Z 和 0-9，输不了 URL 里的
/// `:` `/` `.` 和邮箱里的 `@`。
class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

/// 「把焦点挪到相邻输入框」的意图。
///
/// 为什么非要自己拦方向键：Flutter 的 `DefaultTextEditingShortcuts` 把四个方向键都
/// 映射成了文本选择意图（上下 = `ExtendSelectionVerticallyToAdjacentLineIntent`，
/// 左右 = `ExtendSelectionByCharacterIntent`），命中后返回 `KeyEventResult.handled`，
/// 事件**不再向上冒泡**，外层那套焦点遍历永远收不到方向键。表现就是
/// 「地址填完了，遥控器按上下一动不动，焦点卡在框里出不去」。
///
/// 按键是从主焦点**向上冒泡**的，所以只要在 `TextField` 外面、比内置快捷键更靠近
/// 焦点的位置插一层 `Shortcuts`，就能抢先把它改写成「挪到下一个框」。
/// 搜索页用的是同一招（那边是「跳到搜索结果」）。
///
/// **只拦上下**：左右必须留给输入框自己移动光标。
class _MoveFieldIntent extends Intent {
  const _MoveFieldIntent({required this.forward});

  /// true = 往下（下一个框），false = 往上（上一个框）。
  final bool forward;
}

class _SettingsViewState extends State<SettingsView> {
  final StorageService _storage = StorageService.instance;
  final SyncService _sync = SyncService.instance;
  final UpdateService _update = UpdateService.instance;

  late final TextEditingController _urlCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _passCtrl;
  late final FocusNode _urlFocus;
  late final FocusNode _userFocus;
  late final FocusNode _passFocus;

  bool _allowBadCert = false;
  bool _autoSync = false;
  bool _obscure = true;
  bool _testing = false;
  String? _testMessage;
  bool _testOk = false;

  /// 有没有「安装未知应用」的权限。它是特殊权限，只能去系统设置页手动开，
  /// 所以这里只做显示和跳转。
  bool _canInstall = true;

  /// 「安装未知应用」在系统设置里，用户开完开关回到 App 时界面已经不知道了。
  /// 靠这个监听在回到前台的那一刻重新查一次。
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    final c = _storage.webDavConfig;
    _urlCtrl = TextEditingController(text: c.url);
    _userCtrl = TextEditingController(text: c.username);
    _passCtrl = TextEditingController(text: c.password);
    _allowBadCert = c.allowBadCert;
    _autoSync = _storage.syncEnabled;
    _urlFocus = FocusNode();
    _userFocus = FocusNode();
    _passFocus = FocusNode();
    unawaited(_refreshInstallPermission());
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_refreshInstallPermission()),
    );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _urlFocus.dispose();
    _userFocus.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  Future<void> _refreshInstallPermission() async {
    final ok = await _update.canInstallPackages();
    if (!mounted) return;
    if (ok != _canInstall) setState(() => _canInstall = ok);
  }

  /// 用当前输入框里的内容拼一份配置（还没保存的那份）。
  WebDavConfig get _draft => WebDavConfig(
    url: _urlCtrl.text,
    username: _userCtrl.text,
    password: _passCtrl.text,
    allowBadCert: _allowBadCert,
  );

  Future<void> _test() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    try {
      final msg = await _sync.testConnection(_draft);
      if (!mounted) return;
      setState(() {
        _testOk = true;
        _testMessage = msg;
      });
    } on WebDavException catch (e) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testMessage = '$e';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    await _storage.setWebDavConfig(_draft);
    await _storage.setSyncEnabled(_autoSync);
    if (!mounted) return;
    // 必须自己重建一次：同步按钮的可用状态是从**已保存**的配置算出来的，
    // 而自动同步关着时 onConfigChanged 不会发任何通知，界面就不会刷新。
    setState(() {});
    TvToast.show(context, '已保存', icon: Icons.check_circle_outline);
    // 自动同步开着的话，立刻拉一次，让用户马上看到效果。
    _sync.onConfigChanged();
    // 换了服务器，更新检查那边的旧结果（可能还是上一台服务器的）必须作废。
    _update.onConfigChanged();
  }

  Future<void> _toggleAutoSync(bool value) async {
    setState(() => _autoSync = value);
    await _storage.setSyncEnabled(value);
    if (!mounted) return;
    if (value) {
      _sync.onConfigChanged();
    }
  }

  Future<void> _confirmForce({
    required String title,
    required String body,
    required Future<void> Function() action,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          title,
          style: const TextStyle(
            color: TvTheme.textPrimary,
            fontSize: 18 * TvTheme.fontScale,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          body,
          style: const TextStyle(
            color: TvTheme.textSecondary,
            fontSize: 14 * TvTheme.fontScale,
            height: 1.6,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              '取消',
              style: TextStyle(color: TvTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定覆盖', style: TextStyle(color: TvTheme.error)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await action();
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final update = context.watch<UpdateService>();
    return Scaffold(
      backgroundColor: TvTheme.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: 36 * UiAdaptive.scale,
            vertical: 20 * UiAdaptive.scale,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              SizedBox(height: 16 * UiAdaptive.scale),
              _buildWebDavCard(),
              SizedBox(height: 16 * UiAdaptive.scale),
              _buildSyncCard(sync),
              SizedBox(height: 16 * UiAdaptive.scale),
              _buildUpdateCard(update),
              SizedBox(height: 28 * UiAdaptive.scale),
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
          '设置',
          style: TextStyle(
            color: TvTheme.textPrimary,
            fontSize: 20 * TvTheme.fontScale,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _card({
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(18 * UiAdaptive.scale),
      decoration: BoxDecoration(
        color: TvTheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: TvTheme.primary, size: 20),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  color: TvTheme.textPrimary,
                  fontSize: 16 * TvTheme.fontScale,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          SizedBox(height: 14 * UiAdaptive.scale),
          ...children,
        ],
      ),
    );
  }

  Widget _buildWebDavCard() {
    return _card(
      icon: Icons.cloud_outlined,
      title: 'WebDAV 同步',
      children: [
        const Text(
          '把观看历史（含播放进度）、收藏、搜索历史、跳片头/跳片尾秒数、'
          '自动换源开关同步到你自己的 WebDAV。\n'
          '下载任务和下载目录不会同步 —— 它们存的是本机路径，'
          '同步过去只会得到一堆指向不存在文件的记录。',
          style: TextStyle(
            color: TvTheme.textSecondary,
            fontSize: 12 * TvTheme.fontScale,
            height: 1.7,
          ),
        ),
        SizedBox(height: 14 * UiAdaptive.scale),
        _field(
          label: '服务器地址',
          controller: _urlCtrl,
          focusNode: _urlFocus,
          nextFocus: _userFocus,
          hint: 'https://dav.jianguoyun.com/dav/',
          keyboardType: TextInputType.url,
        ),
        SizedBox(height: 10 * UiAdaptive.scale),
        _field(
          label: '用户名',
          controller: _userCtrl,
          focusNode: _userFocus,
          prevFocus: _urlFocus,
          nextFocus: _passFocus,
          hint: '登录邮箱',
          keyboardType: TextInputType.emailAddress,
        ),
        SizedBox(height: 10 * UiAdaptive.scale),
        _field(
          label: '密码',
          controller: _passCtrl,
          focusNode: _passFocus,
          prevFocus: _userFocus,
          hint: '应用密码，不是登录密码',
          obscure: _obscure,
          trailing: IconButton(
            icon: Icon(
              _obscure ? Icons.visibility_off : Icons.visibility,
              color: TvTheme.textSecondary,
              size: 18,
            ),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
        SizedBox(height: 6 * UiAdaptive.scale),
        const Text(
          '用户名和密码首尾的空格会自动去掉；密码只存在本机，不会写进同步文件。',
          style: TextStyle(
            color: TvTheme.textSecondary,
            fontSize: 11 * TvTheme.fontScale,
            height: 1.6,
          ),
        ),
        SizedBox(height: 10 * UiAdaptive.scale),
        _boolRow(
          value: _allowBadCert,
          label: '信任自签证书',
          hint: '自建 NAS（群晖 / 威联通）用 HTTPS 才需要打开',
          onChanged: (v) => setState(() => _allowBadCert = v),
        ),
        SizedBox(height: 12 * UiAdaptive.scale),
        // 把最终会写入的地址显示出来：用户填的地址可能带不带我们这层目录，
        // 也可能直接把文件地址粘进来，这里让他一眼看到结果，不用猜。
        ListenableBuilder(
          listenable: _urlCtrl,
          builder: (_, _) => Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: 12 * UiAdaptive.scale,
              vertical: 10 * UiAdaptive.scale,
            ),
            decoration: BoxDecoration(
              color: TvTheme.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.insert_drive_file_outlined,
                  color: TvTheme.textSecondary,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _draft.fileUrl.isEmpty ? '（先填服务器地址）' : _draft.fileUrl,
                    style: const TextStyle(
                      color: TvTheme.textSecondary,
                      fontSize: 12 * TvTheme.fontScale,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_testMessage != null) ...[
          SizedBox(height: 12 * UiAdaptive.scale),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _testOk ? Icons.check_circle_outline : Icons.error_outline,
                color: _testOk ? TvTheme.success : TvTheme.error,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _testMessage!,
                  style: TextStyle(
                    color: _testOk ? TvTheme.success : TvTheme.error,
                    fontSize: 13 * TvTheme.fontScale,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ],
        SizedBox(height: 14 * UiAdaptive.scale),
        Row(
          children: [
            _button(
              label: _testing ? '测试中…' : '测试连接',
              icon: Icons.wifi_tethering,
              onTap: _testing ? null : _test,
            ),
            SizedBox(width: 10 * UiAdaptive.scale),
            _button(
              label: '保存',
              icon: Icons.save_outlined,
              highlight: true,
              onTap: _save,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSyncCard(SyncService sync) {
    final configured = _storage.webDavConfig.isConfigured;
    final busy = sync.isSyncing;
    final phaseColor = switch (sync.phase) {
      SyncPhase.ok => TvTheme.success,
      SyncPhase.failed => TvTheme.error,
      SyncPhase.syncing => TvTheme.primary,
      SyncPhase.idle => TvTheme.textSecondary,
    };

    return _card(
      icon: Icons.sync,
      title: '同步',
      children: [
        _boolRow(
          value: _autoSync,
          label: '自动同步',
          hint: '启动 App、退出播放器、退到后台时自动同步一次',
          onChanged: _toggleAutoSync,
        ),
        SizedBox(height: 10 * UiAdaptive.scale),
        _infoRow('上次同步', sync.lastSyncText),
        SizedBox(height: 6 * UiAdaptive.scale),
        _infoRow(
          '状态',
          sync.message.isEmpty ? '—' : sync.message,
          color: phaseColor,
        ),
        SizedBox(height: 14 * UiAdaptive.scale),
        Row(
          children: [
            _button(
              label: busy ? '同步中…' : '立即同步',
              icon: Icons.sync,
              highlight: true,
              onTap: busy || !configured ? null : () => _sync.syncNow(),
            ),
            SizedBox(width: 10 * UiAdaptive.scale),
            _button(
              label: '以本机为准覆盖云端',
              icon: Icons.cloud_upload_outlined,
              onTap: busy || !configured
                  ? null
                  : () => _confirmForce(
                      title: '以本机为准覆盖云端',
                      body:
                          '会用本机的观看历史、收藏、搜索历史覆盖云端那份，'
                          '另一台设备上多出来的内容会被丢掉。\n\n'
                          '适合「本机内容才是最新的、想把云端整份换成本机这份」时用。',
                      action: _sync.forcePushLocal,
                    ),
            ),
            SizedBox(width: 10 * UiAdaptive.scale),
            _button(
              label: '以云端为准覆盖本机',
              icon: Icons.cloud_download_outlined,
              onTap: busy || !configured
                  ? null
                  : () => _confirmForce(
                      title: '以云端为准覆盖本机',
                      body:
                          '会用云端那份覆盖本机的观看历史、收藏、搜索历史，'
                          '本机上多出来的内容会被丢掉。\n\n'
                          '如果两台设备同步结果明显不对（多半是某台设备的系统时间不准），'
                          '请到「时间不对的那台设备」上点这个按钮，把本机数据整份换成云端的。'
                          '这样能把本机存的错误时间戳一并清掉，之后就不会再被顶回去了。',
                      action: _sync.forcePullRemote,
                    ),
            ),
          ],
        ),
        if (!configured) ...[
          SizedBox(height: 10 * UiAdaptive.scale),
          const Text(
            '先填好上面的地址和用户名，点「保存」之后同步按钮才会生效。',
            style: TextStyle(
              color: TvTheme.accent,
              fontSize: 12 * TvTheme.fontScale,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildUpdateCard(UpdateService update) {
    final configured = _storage.webDavConfig.isConfigured;
    final busy = update.busy;
    final phaseColor = switch (update.phase) {
      UpdatePhase.ready => TvTheme.success,
      UpdatePhase.failed => TvTheme.error,
      UpdatePhase.checking ||
      UpdatePhase.downloading ||
      UpdatePhase.installing => TvTheme.primary,
      UpdatePhase.idle => TvTheme.textSecondary,
    };

    // 四种状态要分开，不能都显示成「云端没有」：
    //   configured == false  → 还没填地址，无从查起
    //   正在查               → 老实说在查，别把上一轮的结论挂在这儿
    //   remoteKnown == false → 查了但没问到（403 / 超时 / 网络不通）
    //   remote == null       → 问到了，云端确实没放这个包
    final remote = update.remote;
    final String remoteText;
    if (!configured) {
      remoteText = '—';
    } else if (update.phase == UpdatePhase.checking ||
        update.phase == UpdatePhase.downloading) {
      remoteText = '查询中…';
    } else if (!update.remoteKnown) {
      remoteText = '没问到（本次检查没有成功）';
    } else if (remote == null) {
      remoteText = '云端没有 ${UpdateService.kApkFileName}';
    } else {
      remoteText =
          '${UpdateService.kApkFileName}（${formatBytes(remote.sizeBytes)}）';
    }

    return _card(
      icon: Icons.system_update_alt,
      title: '应用更新',
      children: [
        Text(
          '把新版本的 ${UpdateService.kApkFileName} 放进同一个 WebDAV 目录'
          '（和 sync.json 放在一起），App 就会发现有更新并下载安装；'
          '没放这个文件就不更新。\n'
          '装之前会先核对包名和签名，对不上的一律拒绝安装。',
          style: const TextStyle(
            color: TvTheme.textSecondary,
            fontSize: 12 * TvTheme.fontScale,
            height: 1.7,
          ),
        ),
        SizedBox(height: 12 * UiAdaptive.scale),
        _boolRow(
          value: update.autoCheck,
          label: '自动检查',
          hint: '启动 App 时检查一次，最多 6 小时一次；检查只问「文件在不在」，不下载内容',
          onChanged: (v) => unawaited(update.setAutoCheck(v)),
        ),
        SizedBox(height: 10 * UiAdaptive.scale),
        _boolRow(
          value: update.autoInstall,
          label: '直接安装',
          hint: '打开后，下载完直接跳系统安装界面，不再询问',
          onChanged: (v) => unawaited(update.setAutoInstall(v)),
        ),
        SizedBox(height: 10 * UiAdaptive.scale),
        _infoRow('当前版本', update.current.display),
        SizedBox(height: 6 * UiAdaptive.scale),
        _infoRow('云端安装包', remoteText),
        SizedBox(height: 6 * UiAdaptive.scale),
        _infoRow('上次检查', update.lastCheckText),
        SizedBox(height: 6 * UiAdaptive.scale),
        _infoRow(
          '状态',
          update.message.isEmpty ? '—' : update.message,
          color: phaseColor,
        ),
        if (update.phase == UpdatePhase.downloading) ...[
          SizedBox(height: 10 * UiAdaptive.scale),
          _progressBar(update.progress),
          SizedBox(height: 6 * UiAdaptive.scale),
          Text(
            update.progressText,
            style: const TextStyle(
              color: TvTheme.textSecondary,
              fontSize: 12 * TvTheme.fontScale,
            ),
          ),
        ],
        if (!_canInstall) ...[
          SizedBox(height: 10 * UiAdaptive.scale),
          const Text(
            '系统还没允许本应用安装其他应用。点下面的「允许安装」打开开关，'
            '回到 App 后再点一次安装。',
            style: TextStyle(
              color: TvTheme.accent,
              fontSize: 12 * TvTheme.fontScale,
              height: 1.6,
            ),
          ),
        ],
        SizedBox(height: 14 * UiAdaptive.scale),
        Row(
          children: [
            _button(
              label: busy ? '处理中…' : '检查更新',
              icon: Icons.cloud_download_outlined,
              highlight: true,
              onTap: busy || !configured
                  ? null
                  : () => unawaited(update.checkManually()),
            ),
            SizedBox(width: 10 * UiAdaptive.scale),
            _button(
              label: '立即安装',
              icon: Icons.system_update_alt,
              onTap: busy || update.apk == null
                  ? null
                  : () => unawaited(update.install()),
            ),
            if (!_canInstall) ...[
              SizedBox(width: 10 * UiAdaptive.scale),
              _button(
                label: '允许安装',
                icon: Icons.settings_applications_outlined,
                onTap: () => unawaited(update.openInstallPermission()),
              ),
            ],
          ],
        ),
        if (!configured) ...[
          SizedBox(height: 10 * UiAdaptive.scale),
          const Text(
            '更新走的是上面那份 WebDAV 配置。先填好地址、点「保存」才能检查更新。',
            style: TextStyle(
              color: TvTheme.accent,
              fontSize: 12 * TvTheme.fontScale,
            ),
          ),
        ],
      ],
    );
  }

  /// 下载进度条。
  ///
  /// 没用 `LinearProgressIndicator`：它的 `valueColor` 在新版 Flutter 里已废弃、
  /// `color` / `backgroundColor` 各版本又不一致，直接拿 Container + Align 画
  /// 反而更稳，视觉上也和这一页的方角风格更一致。
  ///
  /// 填充条必须包在 `Align` 里：`Container` 设了 `width` 之后会把子节点强制
  /// 撑满，直接嵌一层 `FractionallySizedBox` 是拿不到按比例宽度的。
  Widget _progressBar(double? value) {
    final factor = (value ?? 0).clamp(0.0, 1.0);
    final radius = BorderRadius.circular(3);
    return Container(
      width: double.infinity,
      height: 6 * UiAdaptive.scale,
      decoration: BoxDecoration(
        color: TvTheme.surfaceLighter,
        borderRadius: radius,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: factor,
          heightFactor: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: TvTheme.primary,
              borderRadius: radius,
            ),
          ),
        ),
      ),
    );
  }

  // --- 小组件 ---

  /// 把焦点挪到相邻输入框。
  ///
  /// [next] / [prev] 为空表示这一组输入框已经到底/到顶，这时交给标准的焦点遍历，
  /// 让焦点能走到卡片里的开关和按钮上 —— 而不是卡在最后一个框里出不去。
  void _moveFieldFocus({
    required bool forward,
    FocusNode? next,
    FocusNode? prev,
  }) {
    final target = forward ? next : prev;
    if (target != null && target.canRequestFocus) {
      target.requestFocus();
      return;
    }
    // NextFocusIntent / PreviousFocusIntent 由 WidgetsApp 默认注册，行为等同于 Tab。
    Actions.maybeInvoke(
      context,
      forward ? const NextFocusIntent() : const PreviousFocusIntent(),
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    required FocusNode focusNode,
    FocusNode? nextFocus,
    FocusNode? prevFocus,
    String? hint,
    bool obscure = false,
    TextInputType? keyboardType,
    Widget? trailing,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 110 * UiAdaptive.scale,
          child: Text(
            label,
            style: const TextStyle(
              color: TvTheme.textSecondary,
              fontSize: 13 * TvTheme.fontScale,
            ),
          ),
        ),
        Expanded(
          // 焦点边框随焦点变化重画，但不用 setState —— 免得每敲一个字符
          // 都把整页重建一遍。
          child: ListenableBuilder(
            listenable: focusNode,
            builder: (_, _) => Container(
              padding: EdgeInsets.symmetric(
                horizontal: 12 * UiAdaptive.scale,
                vertical: 4 * UiAdaptive.scale,
              ),
              decoration: BoxDecoration(
                color: TvTheme.surfaceLighter,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: focusNode.hasFocus
                      ? TvTheme.primary
                      : Colors.white.withValues(alpha: 0.08),
                  width: focusNode.hasFocus ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    // 这一层 Shortcuts 必须比 Flutter 内置的
                    // DefaultTextEditingShortcuts 更靠近焦点，否则上下键会被内置的
                    // 文本选择快捷键吃掉，遥控器就走不出输入框（详见 _MoveFieldIntent）。
                    child: Shortcuts(
                      shortcuts: const <ShortcutActivator, Intent>{
                        SingleActivator(LogicalKeyboardKey.arrowDown):
                            _MoveFieldIntent(forward: true),
                        SingleActivator(LogicalKeyboardKey.arrowUp):
                            _MoveFieldIntent(forward: false),
                      },
                      child: Actions(
                        actions: <Type, Action<Intent>>{
                          _MoveFieldIntent: CallbackAction<_MoveFieldIntent>(
                            onInvoke: (intent) {
                              _moveFieldFocus(
                                forward: intent.forward,
                                next: nextFocus,
                                prev: prevFocus,
                              );
                              return null;
                            },
                          ),
                        },
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          obscureText: obscure,
                          keyboardType: keyboardType,
                          // 软键盘上的「下一项」也挪到下一个框；最后一个框是「完成」。
                          textInputAction: nextFocus == null
                              ? TextInputAction.done
                              : TextInputAction.next,
                          // 最后一个框不给 onSubmitted：done 会先 unfocus，
                          // 这时候再去走遍历，起点已经不确定了，不如就让键盘收起来。
                          onSubmitted: nextFocus == null
                              ? null
                              : (_) => _moveFieldFocus(
                                  forward: true,
                                  next: nextFocus,
                                  prev: prevFocus,
                                ),
                          style: const TextStyle(
                            color: TvTheme.textPrimary,
                            fontSize: 13 * TvTheme.fontScale,
                          ),
                          decoration: InputDecoration(
                            hintText: hint,
                            hintStyle: const TextStyle(
                              color: TvTheme.textSecondary,
                              fontSize: 12 * TvTheme.fontScale,
                            ),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                              vertical: 10 * UiAdaptive.scale,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _boolRow({
    required bool value,
    required String label,
    required String hint,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110 * UiAdaptive.scale,
          child: Text(
            label,
            style: const TextStyle(
              color: TvTheme.textSecondary,
              fontSize: 13 * TvTheme.fontScale,
            ),
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TvFocusWidget(
                borderRadius: 6,
                onTap: () => onChanged(!value),
                child: Container(
                  width: 30 * UiAdaptive.scale,
                  height: 30 * UiAdaptive.scale,
                  decoration: BoxDecoration(
                    color: value ? TvTheme.primary : TvTheme.surfaceLighter,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: value
                          ? TvTheme.primary
                          : Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                  child: value
                      ? const Icon(Icons.check, color: Colors.black, size: 18)
                      : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: 4 * UiAdaptive.scale),
                  child: Text(
                    hint,
                    style: const TextStyle(
                      color: TvTheme.textSecondary,
                      fontSize: 12 * TvTheme.fontScale,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _infoRow(String label, String value, {Color? color}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110 * UiAdaptive.scale,
          child: Text(
            label,
            style: const TextStyle(
              color: TvTheme.textSecondary,
              fontSize: 13 * TvTheme.fontScale,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: color ?? TvTheme.textPrimary,
              fontSize: 13 * TvTheme.fontScale,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }

  /// [onTap] 传 null 表示禁用（正在忙、或者还没配置好）。
  Widget _button({
    required String label,
    required IconData icon,
    VoidCallback? onTap,
    bool highlight = false,
  }) {
    final disabled = onTap == null;
    final bg = highlight ? TvTheme.primary : TvTheme.surfaceLighter;
    final fg = disabled
        ? TvTheme.textSecondary
        : (highlight ? Colors.black : TvTheme.textPrimary);

    final content = Container(
      padding: EdgeInsets.symmetric(
        horizontal: 16 * UiAdaptive.scale,
        vertical: 11 * UiAdaptive.scale,
      ),
      color: disabled ? TvTheme.surface : bg,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: fg, size: 17),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 13 * TvTheme.fontScale,
              fontWeight: highlight && !disabled ? FontWeight.bold : null,
            ),
          ),
        ],
      ),
    );

    if (disabled) return content;
    return TvFocusWidget(borderRadius: 8, onTap: onTap, child: content);
  }
}
