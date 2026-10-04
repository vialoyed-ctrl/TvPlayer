import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/update_info.dart';
import '../tv_ui/app_navigator.dart';
import '../views/update_dialog.dart';
import 'storage_service.dart';
import 'webdav_client.dart';

/// 更新流程当前走到哪一步，给设置页画状态用。
enum UpdatePhase { idle, checking, downloading, ready, installing, failed }

/// 安装包相关的问题。[message] 可以直接显示给用户。
class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);
  @override
  String toString() => message;
}

/// 自动更新的编排层。
///
/// 约定很简单：**云端同步目录里放了 `tvplayer_32bit.apk` 就更新，没放就不更新。**
/// 于是「发新版」这个动作退化成「把新包拖进网盘目录」，不需要再维护一份版本
/// 清单文件，也不需要服务端做任何配合。
///
/// 四个刻意的设计：
///
/// 1. **先只问、不下载**。检查走 HEAD / PROPFIND 拿 `Content-Length` + `ETag`，
///    20 MB 的包不可能每次启动都拉一遍。
/// 2. **用指纹去重**。把「已经验过、交给系统安装过」的那份包的指纹记下来，
///    指纹没变就不再提示 —— 否则只要那个文件还躺在网盘里，每次启动都会弹框。
/// 3. **装之前先验包**。包名不是自己、签名和已装的不一样，都要在下载完之后
///    就拦下来并说清楚原因，而不是丢给系统安装器报一个 `INSTALL_FAILED_...`。
/// 4. **不自动跳安装界面**（除非用户明确打开「发现后直接安装」）。装下去不可逆，
///    而且过程中 App 会退出，让用户点一次更稳妥。
class UpdateService extends ChangeNotifier {
  static final UpdateService instance = UpdateService._internal();
  UpdateService._internal();

  static const MethodChannel _channel = MethodChannel('tvplayer/update');

  /// 云端固定的包名。只认这一个文件。
  ///
  /// 真身在 `models/update_info.dart`，这里只是给界面用的短别名。
  static const String kApkFileName = kUpdateApkFileName;

  /// 自动检查的最小间隔。后台静默跑的检查不该比这更频繁。
  static const Duration autoCheckInterval = Duration(hours: 6);

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

  WebDavStat? _remote;
  WebDavStat? get remote => _remote;

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
  bool get busy => _busy;

  Timer? _startupTimer;

  bool get configured => _storage.webDavConfig.isConfigured;
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
    if (_storage.updateAutoCheck && configured) {
      _startupTimer = Timer(firstCheckDelay, () => unawaited(runAutoCheck()));
    }
  }

  /// 启动时的自动检查：带节流，而且只处理「还没处理过」的那份包。
  Future<void> runAutoCheck() async {
    if (!_storage.updateAutoCheck) return;
    if (!configured) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _storage.updateLastCheckAt;
    if (last > 0 && now - last < autoCheckInterval.inMilliseconds) return;
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

  /// WebDAV 配置被改过（换了地址 / 账号）。
  ///
  /// 上一台服务器问到的结果对新地址没有任何意义：留着会让设置页显示一个
  /// 已经不属于当前配置的「云端安装包」状态。清空重来。
  void onConfigChanged() {
    _remote = null;
    _apk = null;
    _remoteKnown = false;
    _set(UpdatePhase.idle, '');
  }

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
    if (_nativeUnavailable) {
      _set(UpdatePhase.failed, '原生模块不可用，请重新构建 App 后再试');
      return;
    }
    final file = await _localApkFile();
    if (!await file.exists()) {
      _set(UpdatePhase.failed, '本机还没有下载好的安装包，先点「检查更新」');
      return;
    }

    if (!await canInstallPackages()) {
      _set(UpdatePhase.failed, '还没允许本应用安装其他应用，正在跳到系统设置…');
      await openInstallPermission();
      return;
    }

    _set(UpdatePhase.installing, '正在打开系统安装界面…');
    try {
      final m = await _invokeMap('installApk', {'path': file.path});
      if (m?['ok'] != true) {
        throw UpdateException(m?['message'] as String? ?? '打开安装界面失败');
      }
      _set(UpdatePhase.ready, m?['message'] as String? ?? '已打开系统安装界面');
    } on UpdateException catch (e) {
      _set(UpdatePhase.failed, e.message);
    }
  }

  // --- 主流程 -------------------------------------------------------------

  Future<void> _run({required bool silent}) async {
    if (_busy) return;
    if (_nativeUnavailable) {
      _set(UpdatePhase.failed, '原生模块不可用，请重新构建 App 后再试');
      return;
    }
    if (!configured) {
      _set(UpdatePhase.failed, '先在上面填好 WebDAV 地址并保存');
      return;
    }

    _busy = true;
    WebDavClient? client;
    try {
      // 先清状态位再改文案：否则这一瞬间界面会拿着上一轮的 remoteKnown
      // 配上「正在检查」的新消息，显示成一个已经过时的结论。
      _remoteKnown = false;
      _set(UpdatePhase.checking, '正在检查云端有没有 $kApkFileName…');
      client = WebDavClient(_storage.webDavConfig);

      // 和同步走同一条路径：先确认目录在，再去问里面的文件。
      //
      // 不确认的话，文件名会被拼到一个可能还不存在的目录上；而自建 WebDAV 对
      // 「路径不存在」回的未必是 404 —— 有的回 403。那样「目录还没建出来」就会
      // 被报成「这个账号没权限」，把人往查密码的方向带，白折腾半天。
      await client.ensureCollection();

      final stat = await client.stat(kApkFileName);
      // 走到这里说明云端给了明确答复：要么有包（stat 非空），要么确实没有（null）。
      _remoteKnown = true;
      await _storage.setUpdateLastCheckAt(
        DateTime.now().millisecondsSinceEpoch,
      );

      if (stat == null) {
        // 约定：没放就不更新。这不是错误，状态回到 idle。
        _remote = null;
        _apk = null;
        _set(UpdatePhase.idle, '云端没有 $kApkFileName，当前已是最新');
        return;
      }
      _remote = stat;

      final fp = stat.fingerprint;
      if (fp == null && silent) {
        // 判断不了「变没变」。自动流程不能因为判断不了就每次启动都下载
        // 20 MB 再弹一遍框，所以这里只提示、不动手；用户想装就自己点。
        _set(UpdatePhase.idle, '云端有安装包，但服务器没给大小和修改时间，无法判断是否为新包');
        return;
      }

      final handled = _storage.updateHandledFingerprint;
      if (silent && fp != null && fp == handled) {
        // 还是上次那个包，已经交给系统安装过了。别再弹一遍。
        _set(
          UpdatePhase.idle,
          '云端还是上次那个安装包（${formatBytes(stat.sizeBytes)}），已跳过',
        );
        return;
      }

      final file = await _localApkFile();
      final hasLocal = await file.exists();
      // 本机已经有同一份包就别再下一遍 20 MB。
      final needDownload = !(hasLocal && fp != null && fp == handled);

      if (needDownload) {
        await _download(client, stat, file);
      }

      _set(UpdatePhase.checking, '正在校验安装包…');
      final info = await _readApkInfo(file.path);
      _apk = info;
      if (info == null) {
        throw const UpdateException('读不出安装包的包信息，文件可能不完整，请重试');
      }
      _verify(info);

      // 验过包、确实能用，才记指纹。下载完就记的话，一个坏包会被永远跳过，
      // 用户连报错都看不到。
      if (fp != null) await _storage.setUpdateHandledFingerprint(fp);

      final newer = info.versionCode > _current.versionCode;
      _set(
        UpdatePhase.ready,
        newer
            ? '发现新版本 ${info.versionDisplay}（当前 ${_current.display}）'
            : '安装包已就绪：${info.versionDisplay}（版本号没有变化）',
      );

      if (_storage.updateAutoInstall) {
        await install();
      } else {
        await _promptInstall();
      }
    } on WebDavException catch (e) {
      _set(UpdatePhase.failed, e.message);
    } on UpdateException catch (e) {
      _set(UpdatePhase.failed, e.message);
    } catch (e) {
      _set(UpdatePhase.failed, '检查更新失败：$e');
    } finally {
      client?.close();
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _download(
    WebDavClient client,
    WebDavStat stat,
    File file,
  ) async {
    _received = 0;
    _total = stat.hasSize ? stat.sizeBytes : 0;
    _set(UpdatePhase.downloading, '正在下载安装包（${formatBytes(stat.sizeBytes)}）…');

    var lastPercent = -1;
    await client.downloadTo(
      kApkFileName,
      file,
      expectedSize: stat.sizeBytes,
      onProgress: (received, total) {
        final t = total > 0 ? total : stat.sizeBytes;
        _received = received;
        _total = t > 0 ? t : 0;
        if (_total > 0) {
          // 别为每几 KB 都重建一次界面：百分比没变就不通知。
          final percent = (received * 100 / _total).floor();
          if (percent == lastPercent) return;
          lastPercent = percent;
        }
        notifyListeners();
      },
    );
    _received = _total > 0 ? _total : _received;
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
    return File('${dir.path}/$kApkFileName');
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
    super.dispose();
  }
}
