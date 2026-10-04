/// 自动更新相关的纯数据模型。
///
/// 这里不碰网络、不碰原生通道：`UpdateService` 负责编排、界面负责显示，
/// 这些类型只负责把信息装起来，顺便把几个容易搞错的判断收敛成 getter。
library;

/// 云端固定的安装包文件名。
///
/// 约定：**这个文件在同步目录里就更新，不在就不更新。** 于是「发新版」这件事
/// 退化成「把新包拖进网盘目录」，不需要再维护一份版本清单。
///
/// 放在这个纯 Dart 文件里（而不是 `UpdateService` 里），是为了让传输层的
/// 测试脚本也能引用同一个来源 —— 常量两处各写一份，迟早会漂移。
const String kUpdateApkFileName = 'tvplayer_32bit.apk';

/// 把一个字节数说成人话。负数（服务器没给）统一说「未知」。
String formatBytes(int bytes) {
  if (bytes < 0) return '大小未知';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

/// 本机当前装着的版本。
class InstalledAppInfo {
  final int versionCode;
  final String? versionName;

  const InstalledAppInfo({this.versionCode = 0, this.versionName});

  bool get known => versionCode > 0;

  String get display {
    final name = versionName;
    if (name == null || name.isEmpty) {
      return versionCode > 0 ? '$versionCode' : '未知';
    }
    return '$name（$versionCode）';
  }
}

/// 从下载好的 APK 文件里读出来的信息（原生 `getPackageArchiveInfo`）。
///
/// 这几个字段的作用是「装之前先验包」。包名不是自己、签名和已装的不一样，
/// 都要在下载完就拦下来 —— 丢给系统安装器只会得到一个
/// `INSTALL_FAILED_UPDATE_INCOMPATIBLE`，用户完全看不出是哪里不对。
class ApkInfo {
  final String? packageName;
  final String? versionName;
  final String? appLabel;
  final int versionCode;

  /// 包名是不是本应用。
  final bool isSamePackage;

  /// 签名和已安装的那份是不是同一个。
  final bool sameSigner;

  /// 签名有没有读出来。读不出来时 [sameSigner] 也是 false，但原因不一样
  /// （一个是「确认不是同一个签名」，一个是「压根没读到」），报错话术也不同，
  /// 所以单独留一个标志。
  final bool signerUnknown;

  final int sizeBytes;

  const ApkInfo({
    this.packageName,
    this.versionName,
    this.appLabel,
    this.versionCode = 0,
    this.isSamePackage = false,
    this.sameSigner = false,
    this.signerUnknown = true,
    this.sizeBytes = -1,
  });

  static ApkInfo? fromMap(Map<dynamic, dynamic>? m) {
    if (m == null) return null;
    return ApkInfo(
      packageName: m['packageName'] as String?,
      versionName: m['versionName'] as String?,
      appLabel: m['appLabel'] as String?,
      versionCode: (m['versionCode'] as num?)?.toInt() ?? 0,
      isSamePackage: m['isSamePackage'] == true,
      sameSigner: m['sameSigner'] == true,
      signerUnknown: m['signerUnknown'] == true,
      sizeBytes: (m['sizeBytes'] as num?)?.toInt() ?? -1,
    );
  }

  String get versionDisplay {
    final name = versionName;
    if (name == null || name.isEmpty) return '$versionCode';
    return '$name（$versionCode）';
  }
}
