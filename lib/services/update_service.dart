import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../models/update_info.dart';
import '../tv_ui/app_navigator.dart';
import '../views/update_dialog.dart';
import 'storage_service.dart';
import 'github_update_client.dart';

/// 更新流程当前走到哪一步，给设置页画状态用。
enum UpdatePhase { idle, checking, downloading, ready, installing, failed }

/// 安装包相关的问题。[message] 可以直接显示给用户。
class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);
  @override
  String toString() => message;
}

/// GitHub Releases 自动检查、下载、验证和系统安装流程。
class UpdateService extends ChangeNotifier with WidgetsBindingObserver {
  static final UpdateService instance = UpdateService._internal();
  UpdateService._internal() : _client = GitHubUpdateClient();
  @visibleForTesting
  UpdateService.forTesting(this._client);
  final GitHubUpdateClient _client;
  bool _foreground = true;
  bool _pendingInstall = false;
  String? _launchedFingerprint;

  static const MethodChannel _channel = MethodChannel('tvplayer/update');

  /// 云端固定的包名。只认这一个文件。
  ///
  /// 真身在 `models/update_info.dart`，这里只是给界面用的短别名。
  static const String kApkFileName = kUpdateApkFileName;

  /// 启动后隔多久做第一次自动检查。避开首屏那批接口请求抢带宽。
  static const Duration firstCheckDelay = Duration(seconds: 8);

  final StorageService _storage = StorageService.instance;

  UpdatePhase _phase = UpdatePhase.idle;
  UpdatePhase get phase => _phase;

  String _message = '';
  String get message => _message;

  int _received = 0;
  int _total = 0;

  /// 下载进度 0..1；总长度未知时为 null。
  double? get progress =>
      _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;

  /// 下载进度的人话版本。
  String get progressText {
    if (_total > 0) return '${formatBytes(_received)} / ${formatBytes(_total)}';
    if (_received > 0) return '已下载 ${formatBytes(_received)}';
    return '正在下载…';
  }

  GitHubReleaseApk? _remote;
  GitHubReleaseApk? get remote => _remote;

  /// 上一次检查有没有**真的问到**云端。
  ///
  /// `remote == null` 有两种完全不同的含义：「云端确实没有这个包」（问到了，
  /// 答案是 404），和「没问到」（403 / 超时 / 网络不通）。设置页必须把这两者
  /// 分开显示 —— 否则会出现「状态：服务器拒绝访问（403）」和「云端安装包：
  /// 云端没有 tvplayer_32bit.apk」同时挂在屏幕上的自相矛盾画面：既然请求被
  /// 拒了，凭什么断定文件不在。
  bool _remoteKnown = false;
  bool get remoteKnown => _remoteKnown;

  ApkInfo? _apk;
  ApkInfo? get apk => _apk;

  InstalledAppInfo _current = const InstalledAppInfo();
  InstalledAppInfo get current => _current;

  /// 原生通道用不了（比如只热重载、没重新构建 APK）。这时整个更新功能都要
  /// 优雅退化，而不是抛 `MissingPluginException` 把启动流程打断。
  bool _nativeUnavailable = false;
  bool get nativeUnavailable => _nativeUnavailable;

  bool _busy = false;
  bool _installing = false;
  bool get busy => _busy || _installing;

  Timer? _startupTimer;

  bool get configured => true;
  String get apkFileName => _current.apkFileName;
  bool get autoCheck => _storage.updateAutoCheck;
  bool get autoInstall => _storage.updateAutoInstall;

  /// 上次检查时间，给设置页显示。
  String get lastCheckText {
    final ms = _storage.updateLastCheckAt;
    if (ms <= 0) return '从未检查';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  Future<void> init() async {
    await _storage.init();
    _current = await _loadCurrentVersion();
    WidgetsBinding.instance.addObserver(this);
    _scheduleAutoCheck();
  }

  void _scheduleAutoCheck() {
    _startupTimer?.cancel();
    if (!autoCheck) return;
    _startupTimer = Timer(firstCheckDelay, () => unawaited(runAutoCheck()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _startupTimer?.cancel();
      return;
    }
    if (_pendingInstall && autoInstall) {
      unawaited(_resumePendingInstallation());
    } else {
      _scheduleAutoCheck();
    }
  }

  Future<void> _resumePendingInstallation() async {
    _pendingInstall = false;
    if (await canInstallPackages()) {
      await install();
    } else {
      _set(UpdatePhase.ready, '安装包已下载，请允许安装后点“立即安装”');
    }
  }

  /// 每次启动或返回前台都检查；已安装版本不会再次下载。
  Future<void> runAutoCheck() async {
    if (!autoCheck || !_foreground) return;
    await _run(silent: true);
  }

  /// 用户点「检查更新」。走同一条路，只是不节流、也不按「已处理过」过滤。
  Future<void> checkManually() => _run(silent: false);

  Future<void> setAutoCheck(bool value) async {
    await _storage.setUpdateAutoCheck(value);
    if (!value) {
      // 关掉就把还没到点的那次启动检查取消掉，别让它在几秒后突然跑起来。
      _startupTimer?.cancel();
      _startupTimer = null;
    }
    notifyListeners();
    if (value) unawaited(runAutoCheck());
  }

  Future<void> setAutoInstall(bool value) async {
    await _storage.setUpdateAutoInstall(value);
    notifyListeners();
  }

  /// WebDAV 同步配置不影响 GitHub 更新。
  void onConfigChanged() {}

  /// 有没有「安装未知应用」的权限。设置页要显示它，所以做成公开的。
  Future<bool> canInstallPackages() async {
    if (_nativeUnavailable) return false;
    try {
      return await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
    } on MissingPluginException {
      _nativeUnavailable = true;
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 跳到系统的「安装未知应用」设置页。
  ///
  /// 这是特殊权限，App 不能自己弹框申请，只能把用户送过去手动拨开关。
  Future<void> openInstallPermission() async {
    try {
      await _channel.invokeMethod<void>('requestInstallPermission');
    } on MissingPluginException {
      _nativeUnavailable = true;
    } on PlatformException catch (e) {
      debugPrint('[UpdateService] 打开安装权限设置页失败：${e.message}');
    }
  }

  /// 把已经下好、验过的包交给系统安装界面。
  ///
  /// 真正「装」的动作是系统做的，这里只负责递过去；没有安装权限时把用户
  /// 送到设置页，而不是丢一句「失败了」让他自己猜。
  Future<void> install() async {
    if (_installing) return;
    _installing = true;
    try {
      await _install();
    } finally {
      _installing = false;
      notifyListeners();
    }
  }

  Future<void> _install() async {
    if (_nativeUnavailable) {
      _set(UpdatePhase.failed, '原生模块不可用，请重新构建 App 后再试');
      return;
    }
    final file = await _localApkFile();
    if (!await file.exists()) {
      _set(UpdatePhase.failed, '本机还没有下载好的安装包，先点「检查更新」');
      return;
    }

    if (_remote == null || _apk == null) {
      _set(UpdatePhase.failed, '请先检查并下载新版本');
      return;
    }
    try {
      if (!await _client.matches(file, _remote!)) {
        throw const UpdateException('安装包校验失败，请重新检查更新');
      }
      final info = await _readApkInfo(file.path);
      if (info == null) throw const UpdateException('无法读取安装包');
      _current = await _loadCurrentVersion();
      if (!_current.known) throw const UpdateException('无法读取当前版本');
      _verify(info);
      if (info.versionCode <= _current.versionCode) {
        _pendingInstall = false;
        _set(UpdatePhase.idle, '当前已是最新版本');
        return;
      }
    } catch (e) {
      _pendingInstall = false;
      _set(UpdatePhase.failed, '$e');
      return;
    }
    if (!await canInstallPackages()) {
      _pendingInstall = true;
      _set(UpdatePhase.failed, '还没允许本应用安装其他应用，正在跳到系统设置…');
      await openInstallPermission();
      return;
    }

    _pendingInstall = false;
    _set(UpdatePhase.installing, '正在打开系统安装界面…');
    try {
      final m = await _invokeMap('installApk', {'path': file.path});
      if (m?['ok'] != true) {
        throw UpdateException(m?['message'] as String? ?? '打开安装界面失败');
      }
      _launchedFingerprint = _remote?.fingerprint;
      _set(UpdatePhase.ready, m?['message'] as String? ?? '已打开系统安装界面');
    } on UpdateException catch (e) {
      _set(UpdatePhase.failed, e.message);
    }
  }

  // --- 主流程 -------------------------------------------------------------

  Future<void> _run({required bool silent}) async {
    if (busy) return;
    if (_nativeUnavailable) {
      _set(UpdatePhase.failed, '原生模块不可用，请安装完整版本后再试');
      return;
    }
    _busy = true;
    try {
      _remoteKnown = false;
      _set(UpdatePhase.checking, '正在检查 GitHub 最新正式版本…');
      _current = await _loadCurrentVersion();
      if (!_current.known) throw const UpdateException('无法读取当前版本');
      final release = await _client.latest(apkFileName);
      _remote = release;
      _remoteKnown = true;
      await _storage.setUpdateLastCheckAt(
        DateTime.now().millisecondsSinceEpoch,
      );
      if (release == null) {
        _apk = null;
        _set(UpdatePhase.idle, 'GitHub 暂无正式发布版本');
        return;
      }
      if (!release.isNewerThan(_current.versionName)) {
        _apk = null;
        _set(UpdatePhase.idle, '当前已是最新版本 ${_current.display}');
        return;
      }
      // 用户从安装界面返回时，不在同一进程反复打开同一个安装包。
      if (silent && _launchedFingerprint == release.fingerprint) {
        _set(UpdatePhase.ready, '新版本已就绪，可在设置中再次安装');
        return;
      }
      final file = await _localApkFile();
      if (!await _client.matches(file, release)) {
        _received = 0;
        _total = release.sizeBytes;
        _set(UpdatePhase.downloading, '发现 ${release.tag}，正在下载安装包…');
        var lastPercent = -1;
        await _client.download(
          release,
          file,
          onProgress: (received, total) {
            _received = received;
            _total = total > 0 ? total : release.sizeBytes;
            final percent = (received * 100 / _total).floor();
            if (percent == lastPercent) return;
            lastPercent = percent;
            notifyListeners();
          },
        );
      }
      _set(UpdatePhase.checking, '正在核对安装包和签名…');
      final info = await _readApkInfo(file.path);
      if (info == null) throw const UpdateException('安装包无法读取，请重新下载');
      _verify(info);
      if (!listEquals(
        GitHubReleaseApk.versionParts(info.versionName ?? ''),
        GitHubReleaseApk.versionParts(release.tag),
      )) {
        throw const UpdateException('发布版本与 APK 版本不一致，已停止安装');
      }
      if (info.versionCode <= _current.versionCode) {
        throw const UpdateException('发布的 APK 版本号没有递增，已停止安装');
      }
      _apk = info;
      _set(UpdatePhase.ready, '新版本 ${info.versionDisplay} 已下载');
      if (autoInstall) {
        if (_foreground) {
          await install();
        } else {
          _pendingInstall = true;
        }
      } else if (_foreground) {
        await _promptInstall();
      }
    } catch (e) {
      _apk = null;
      _set(UpdatePhase.failed, '更新失败：$e');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 装之前的四道检查。任何一道不过都抛 [UpdateException]。
  void _verify(ApkInfo info) {
    if (!info.isSamePackage) {
      throw UpdateException('这个包的包名是 ${info.packageName ?? '未知'}，不是本应用，已拒绝安装');
    }
    if (info.signerUnknown) {
      throw const UpdateException('读不出签名信息，无法确认这个包是本应用签的，已拒绝安装');
    }
    if (!info.sameSigner) {
      throw const UpdateException(
        '这个包的签名和已安装的版本不一样，系统会拒绝覆盖安装。'
        '请用同一套签名密钥重新打包',
      );
    }
  }

  Future<void> _promptInstall() async {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) {
      // 界面还没起来（比如启动时的自动检查跑在了首帧之前）。状态已经写好了，
      // 用户进设置页就能看到并自己点安装。
      return;
    }
    final go = await showUpdateDialog(
      ctx,
      apk: _apk,
      remote: _remote,
      current: _current,
    );
    if (go == true) await install();
  }

  // --- 本机文件与原生通道 --------------------------------------------------

  /// 安装包在本机的落地位置。
  ///
  /// 目录由原生侧给（`context.filesDir`），**不猜也不引额外依赖**：
  /// FileProvider 的 `file_paths.xml` 里声明的 `<files-path>` 对应的就是它，
  /// 换成别的目录，很可能要到「点安装」那一步才发现这个 URI 授权不出去。
  ///
  /// 放在应用私有目录还有一个好处：不需要任何存储权限。放外部存储反而要处理
  /// 「所有文件访问权限」，为了一个安装包不值得。
  Future<File> _localApkFile() async {
    final base = await _appFilesDir();
    final dir = Directory('$base/update');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/$apkFileName');
  }

  Future<String> _appFilesDir() async {
    try {
      final path = await _channel.invokeMethod<String>('appFilesDir');
      if (path == null || path.isEmpty) {
        throw const UpdateException('拿不到应用私有目录，没法保存安装包');
      }
      return path;
    } on MissingPluginException {
      _nativeUnavailable = true;
      throw const UpdateException('原生模块不可用（需要重新构建 App 才能使用自动更新）');
    } on PlatformException catch (e) {
      throw UpdateException(e.message ?? '拿不到应用私有目录：${e.code}');
    }
  }

  Future<InstalledAppInfo> _loadCurrentVersion() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'currentVersion',
      );
      if (m == null) return const InstalledAppInfo();
      return InstalledAppInfo(
        versionCode: (m['versionCode'] as num?)?.toInt() ?? 0,
        versionName: m['versionName'] as String?,
        apkFileName: m['apkFileName'] as String? ?? kUpdateApkFileName,
      );
    } on MissingPluginException {
      // 只热重载、没重新构建 APK 时会走到这里。不能让它把启动流程打断。
      _nativeUnavailable = true;
      debugPrint('[UpdateService] 原生通道不可用，更新功能已停用');
      return const InstalledAppInfo();
    } on PlatformException catch (e) {
      debugPrint('[UpdateService] 读本机版本失败：${e.message}');
      return const InstalledAppInfo();
    }
  }

  Future<ApkInfo?> _readApkInfo(String path) async {
    final m = await _invokeMap('apkInfo', {'path': path});
    return ApkInfo.fromMap(m);
  }

  Future<Map<String, dynamic>?> _invokeMap(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    try {
      return await _channel.invokeMapMethod<String, dynamic>(method, args);
    } on MissingPluginException {
      _nativeUnavailable = true;
      throw const UpdateException('原生模块不可用（需要重新构建 App 才能使用自动更新）');
    } on PlatformException catch (e) {
      throw UpdateException(e.message ?? '原生调用失败：${e.code}');
    }
  }

  void _set(UpdatePhase phase, String message) {
    _phase = phase;
    _message = message;
    debugPrint('[UpdateService] $phase: $message');
    notifyListeners();
  }

  @override
  void dispose() {
    _startupTimer?.cancel();
    _startupTimer = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
