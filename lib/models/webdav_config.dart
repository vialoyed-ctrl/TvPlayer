/// 同步目录名。放在用户 WebDAV 根目录下的一个子目录里，不跟别的东西混在一起。
const String kSyncDirName = 'tvplayer';

/// 同步文件名。
const String kSyncFileName = 'sync.json';

/// WebDAV 连接配置。
///
/// 用户名和密码**只保存在本机**，绝不写进同步文件——同步文件是放在用户
/// 自己的 WebDAV 上的，把凭据写进去等于把密码上传。
///
/// 注意：这份配置在 SharedPreferences 里是明文。要更安全就得引
/// `flutter_secure_storage`（Android Keystore），那会多一个原生依赖；
/// 当前的数据是「观看历史 + 收藏」，凭据又是用户自建服务的一份专用应用密码，
/// 权衡下来先用明文 + 「应用密码而不是登录密码」的提示。
class WebDavConfig {
  /// 用户填的 WebDAV 地址，可以带或不带结尾斜杠。
  final String url;
  final String username;
  final String password;

  /// 是否信任自签名证书。自建 NAS（群晖 / 威联通）常见，默认关闭。
  final bool allowBadCert;

  const WebDavConfig({
    this.url = '',
    this.username = '',
    this.password = '',
    this.allowBadCert = false,
  });

  static const WebDavConfig none = WebDavConfig();

  /// 用户名和密码的首尾空格一律去掉。
  ///
  /// 复制粘贴带上的换行/空格是这类配置里最高频的「莫名其妙认证失败」来源；
  /// 而 WebDAV 的应用密码首尾带有效空格基本不存在。设置页会写明这一点。
  String get trimmedUser => username.trim();

  String get trimmedPassword => password.trim();

  bool get isConfigured => url.trim().isNotEmpty && trimmedUser.isNotEmpty;

  /// 规范化后的地址：补协议头、去掉结尾斜杠。
  String get normalizedUrl {
    var u = url.trim();
    if (u.isEmpty) return '';
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  /// 同步文件所在目录的完整 URL。
  ///
  /// 用户可能填三种地址，都认：WebDAV 根（`.../dav/`）、我们自己的目录
  /// （`.../dav/tvplayer`）、或者干脆把同步文件的地址整个粘进来。
  /// 不识别的话会拼成 `.../tvplayer/tvplayer/sync.json` 这种不存在的路径。
  /// 设置页会把最终拼出来的地址显示出来，所以这里是可验证的，不是黑魔法。
  String get collectionUrl {
    var u = normalizedUrl;
    if (u.isEmpty) return '';
    if (u.endsWith('/$kSyncFileName')) {
      u = u.substring(0, u.length - kSyncFileName.length - 1);
    }
    if (u.endsWith('/$kSyncDirName')) return u;
    return '$u/$kSyncDirName';
  }

  /// 同步文件的完整 URL。
  String get fileUrl {
    final dir = collectionUrl;
    return dir.isEmpty ? '' : '$dir/$kSyncFileName';
  }

  WebDavConfig copyWith({
    String? url,
    String? username,
    String? password,
    bool? allowBadCert,
  }) => WebDavConfig(
    url: url ?? this.url,
    username: username ?? this.username,
    password: password ?? this.password,
    allowBadCert: allowBadCert ?? this.allowBadCert,
  );

  Map<String, dynamic> toJson() => {
    'url': url,
    'username': username,
    'password': password,
    'allowBadCert': allowBadCert,
  };

  static WebDavConfig fromJson(Object? json) {
    if (json is! Map) return none;
    String str(Object? v) => v is String ? v : '';
    return WebDavConfig(
      url: str(json['url']),
      username: str(json['username']),
      password: str(json['password']),
      allowBadCert: json['allowBadCert'] == true,
    );
  }
}
