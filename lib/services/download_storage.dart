import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 解析结果：实际要用哪个目录，以及它是不是用户自选的。
class DownloadDir {
  final String path;

  /// true = 用户自选目录（需要「所有文件访问权限」）；
  /// false = 应用私有目录（零权限）。
  final bool isCustom;

  const DownloadDir(this.path, {required this.isCustom});

  String get label => isCustom ? '自选目录' : '应用私有目录';
}

/// 下载目录的解析，以及「所有文件访问权限」的申请。
///
/// 两种模式：
///
/// 1. **默认** —— 应用自己的外部私有目录
///    （`Android/data/<包名>/files/tvplayer_download`）。零权限、一定能写；
///    代价是 Android 11+ 的文件管理器里看不到它。
/// 2. **自选** —— 用户授权「所有文件访问权限」（`MANAGE_EXTERNAL_STORAGE`）之后，
///    用 `dart:io` 直接读写任意目录（含 SD 卡、系统「下载」目录）。
///
/// 权限没拿到、或者用户选的目录后来变得不可写（SD 卡拔了、目录被删了），
/// 一律**静默退回模式 1** 并清掉自选路径 —— 绝不让「下载」因为目录问题
/// 整个不可用。
class DownloadStorage {
  DownloadStorage._();
  static final DownloadStorage instance = DownloadStorage._();

  static const MethodChannel _channel = MethodChannel('tvplayer/storage');
  static const String _keyCustomDir = 'tv_download_dir';
  static const String _defaultFolderName = 'tvplayer_download';
  static const String _probeFileName = '.tvplayer_write_test';

  SharedPreferences? _prefs;

  Future<void> _ensurePrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  // --- 权限 ---------------------------------------------------------------

  /// 是否已经拿到「所有文件访问权限」。
  Future<bool> hasAllFilesAccess() async {
    try {
      return await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
    } catch (e) {
      debugPrint('[DownloadStorage] hasAllFilesAccess failed: $e');
      return false;
    }
  }

  /// 跳到系统的「所有文件访问权限」设置页。
  ///
  /// 注意：这是个**开关页面**，用户自己拨开关，App 收不到「已授权」的回调。
  /// 所以调用方要在回到前台时重新查一次 [hasAllFilesAccess]。
  Future<void> requestAllFilesAccess() async {
    try {
      await _channel.invokeMethod<void>('requestAllFilesAccess');
    } catch (e) {
      debugPrint('[DownloadStorage] requestAllFilesAccess failed: $e');
    }
  }

  /// 可用的存储根（主存储 + SD 卡），给目录浏览器当起点。
  Future<List<String>> storageRoots() async {
    try {
      final roots = await _channel.invokeListMethod<String>('storageRoots');
      if (roots != null && roots.isNotEmpty) return roots;
    } catch (e) {
      debugPrint('[DownloadStorage] storageRoots failed: $e');
    }
    // 原生侧拿不到时的兜底：主存储的常规挂载点。
    return const ['/storage/emulated/0'];
  }

  /// 某个路径所在卷的剩余空间（字节）。拿不到时返回 -1。
  Future<int> freeSpaceBytes(String path) async {
    try {
      return await _channel.invokeMethod<int>('freeSpaceBytes', {
            'path': path,
          }) ??
          -1;
    } catch (e) {
      debugPrint('[DownloadStorage] freeSpaceBytes failed: $e');
      return -1;
    }
  }

  // --- 目录 ---------------------------------------------------------------

  /// 应用私有目录。不需要任何权限。
  Future<Directory> defaultDir() async {
    Directory? base;
    try {
      // getExternalStorageDirectory 在 Android 上是
      // /storage/emulated/0/Android/data/<包名>/files —— 外部存储里属于本应用
      // 的那一块，不需要权限。卸载 App 时会被系统一起清掉，这也符合预期。
      base = await getExternalStorageDirectory();
    } catch (e) {
      debugPrint('[DownloadStorage] getExternalStorageDirectory failed: $e');
    }
    base ??= await getApplicationSupportDirectory();
    return Directory('${base.path}/$_defaultFolderName');
  }

  Future<String?> customDirPath() async {
    await _ensurePrefs();
    final v = _prefs!.getString(_keyCustomDir);
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> setCustomDirPath(String? path) async {
    await _ensurePrefs();
    if (path == null || path.trim().isEmpty) {
      await _prefs!.remove(_keyCustomDir);
    } else {
      await _prefs!.setString(_keyCustomDir, path.trim());
    }
  }

  /// 解析实际要用的下载目录。**永远**返回一个可写的目录。
  Future<DownloadDir> resolve() async {
    final custom = await customDirPath();
    if (custom != null) {
      if (await canWrite(custom)) return DownloadDir(custom, isCustom: true);
      // 自选目录不能用了（权限被撤 / SD 卡拔了 / 目录被删了）：
      // 清掉它退回默认目录。这里不抛错 —— 能继续下载比提示重要。
      debugPrint(
        '[DownloadStorage] custom dir unusable, falling back: $custom',
      );
      await setCustomDirPath(null);
    }
    final d = await defaultDir();
    return DownloadDir(d.path, isCustom: false);
  }

  /// 目录是否存在、能不能真的写进去。
  ///
  /// 不能只判断 `existsSync()`：Android 11+ 上「路径存在但没权限」是常态，
  /// 只有真的写一个探针文件才知道行不行。
  Future<bool> canWrite(String path) async {
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final probe = File('$path/$_probeFileName');
      probe.writeAsStringSync('ok', flush: true);
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 列出 [path] 下的子目录（目录浏览器用）。
  Future<List<String>> listSubDirs(String path) async {
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) return const [];
      final out = <String>[];
      for (final e in dir.listSync(followLinks: false)) {
        if (e is! Directory) continue;
        final name = e.path.split('/').last;
        // 跳过隐藏目录：Android 的系统目录全是 `.` 开头，对用户没意义，
        // 还会把列表刷得很长、遥控器要按半天。
        if (name.startsWith('.')) continue;
        out.add(e.path);
      }
      out.sort();
      return out;
    } catch (e) {
      // 没权限的目录 listSync 会抛 —— 正常情况，返回空即可。
      debugPrint('[DownloadStorage] listSubDirs($path) failed: $e');
      return const [];
    }
  }

  /// 确保目录存在。
  Future<Directory> ensureDir(String path) async {
    final dir = Directory(path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  // --- 文件名 -------------------------------------------------------------

  /// 把剧名/集名里的非法字符换掉。
  ///
  /// `\ / : * ? " < > |` 在 FAT/exFAT 的 SD 卡上是非法字符，不换掉会在写文件时
  /// 抛异常；结尾的点和空格在 Windows 上会被静默吞掉，一并去掉。
  static String sanitizeFileName(String name) {
    var s = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s.replaceAll(RegExp(r'[. ]+$'), '');
    if (s.isEmpty) s = 'untitled';
    if (s.length > 80) s = s.substring(0, 80);
    return s;
  }

  /// 人类可读的字节数。
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
