import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../models/webdav_config.dart';

/// 一次 GET 的结果。
class WebDavFile {
  final String body;

  /// 强 ETag；服务器没给、或者给的是弱校验器时为 null。
  final String? etag;

  const WebDavFile({required this.body, this.etag});
}

/// 一个远端文件的元信息。只描述「服务器告诉我什么」，不含内容。
class WebDavStat {
  /// 字节数；-1 表示服务器没给。
  final int sizeBytes;

  /// 强 ETag；服务器没给、或者给的是弱校验器时为 null。
  final String? etag;

  /// 最后修改时间（毫秒）；服务器没给、或者格式看不懂时为 null。
  final int? lastModifiedMs;

  const WebDavStat({this.sizeBytes = -1, this.etag, this.lastModifiedMs});

  bool get hasSize => sizeBytes >= 0;

  /// 「这份文件换过没有」的判据。
  ///
  /// 优先用强 ETag —— 它是内容变了才会变的东西。自建 WebDAV 很常见不给 ETag，
  /// 这时退化成「大小 + 最后修改时间」。两者都拿不到就返回 null，调用方必须
  /// 当成「判断不了」而不是「没变」：后者会让用户换了包却检测不到，
  /// 而那正好是这个功能最该避免的事。
  String? get fingerprint {
    final e = etag;
    if (e != null && e.isNotEmpty) return 'etag:$e';
    if (hasSize && lastModifiedMs != null) {
      return 'len:$sizeBytes:mtime:$lastModifiedMs';
    }
    if (hasSize) return 'len:$sizeBytes';
    return null;
  }
}

/// 传输层错误。[message] 是可以直接显示给用户的中文说明。
class WebDavException implements Exception {
  final String message;
  final int? statusCode;

  /// 412：`If-Match` / `If-None-Match` 没通过，说明云端在读取之后被别的
  /// 设备改过。调用方应该重新拉取、重新合并、再写一次。
  final bool isConflict;

  const WebDavException(
    this.message, {
    this.statusCode,
    this.isConflict = false,
  });

  @override
  String toString() => message;
}

/// 极简 WebDAV 客户端：只做同步需要的四件事（PROPFIND / MKCOL / GET / PUT）。
///
/// 不用 `webdav_client` 之类的现成包：一来要的接口就这几个，二来并发写入
/// 必须自己控制 `ETag` / `If-Match`，套一层反而更难看清状态码。
class WebDavClient {
  WebDavClient(this.config) {
    _dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 30),
        followRedirects: true,
        // 状态码一律自己判。WebDAV 用 207 / 404 / 409 / 412 / 423 表达语义，
        // 让 dio 直接抛异常反而更难分辨到底是哪一种。
        validateStatus: (_) => true,
      ),
    );

    if (config.allowBadCert) {
      final adapter = _dio.httpClientAdapter;
      if (adapter is IOHttpClientAdapter) {
        adapter.createHttpClient = () {
          final client = HttpClient()
            // 跟 dio 默认值保持一致，别因为换了工厂函数就把空闲连接策略丢了。
            ..idleTimeout = const Duration(seconds: 3)
            ..badCertificateCallback = (cert, host, port) => true;
          return client;
        };
      }
    }
  }

  final WebDavConfig config;
  late final Dio _dio;

  void close() => _dio.close(force: true);

  Map<String, String> get _authHeaders => {
    'Authorization':
        'Basic ${base64.encode(utf8.encode('${config.trimmedUser}:${config.trimmedPassword}'))}',
  };

  /// 测试连接：确保同步目录存在，然后确认它可读。
  ///
  /// 成功返回一句可以直接显示的话，失败抛 [WebDavException]。
  /// 先建目录再探测，测的才是「真正要用的那条路径」，而不是根目录。
  Future<String> probe() async {
    if (config.normalizedUrl.isEmpty) {
      throw const WebDavException('还没填 WebDAV 地址');
    }
    if (config.trimmedUser.isEmpty) {
      throw const WebDavException('还没填用户名');
    }

    await ensureCollection();

    final resp = await _send(
      () => _dio.request<String>(
        config.collectionUrl,
        options: Options(
          method: 'PROPFIND',
          headers: {..._authHeaders, 'Depth': '0'},
          responseType: ResponseType.plain,
        ),
      ),
    );
    final code = resp.statusCode ?? 0;
    if (code == 207 || code == 200) {
      return '连接正常，目录已就绪';
    }
    throw _statusError(code, '访问 ${config.collectionUrl}');
  }

  /// 确保同步目录存在。已存在时什么都不做。
  ///
  /// 只信 PROPFIND 的返回码会踩坑：自建 WebDAV 上「路径不存在」未必回 404，
  /// 有的服务端回 403。所以 403 不能直接当成「没权限」，还要拿 MKCOL 复核一次
  /// —— 详见方法内的注释。
  Future<void> ensureCollection() async {
    final dir = config.collectionUrl;
    if (dir.isEmpty) throw const WebDavException('还没填 WebDAV 地址');

    final probe = await _propfind(dir);
    final code = probe.statusCode ?? 0;
    if (code == 207 || code == 200) return;
    // 401 是认证失败，MKCOL 也一样过不去；5xx 是服务端自己的问题。这两种直接报，
    // 不去建目录。
    if (code == 401 || code >= 500) {
      throw _statusError(code, '访问 $dir');
    }

    // 剩下的（403 / 404 / 409…）都当成「目录还不存在，试着建一个」。
    //
    // **403 也要试**：自建 WebDAV 上 403 有两种完全不同的成因 —— 真的没权限，
    // 和「这个服务端对不存在的路径一律回 403」。只看 PROPFIND 分不出来，但
    // MKCOL 能分：建成功说明本来就没有，回 403/401 才是真没权限。先试再报，
    // 比一上来就甩一句「这个账号对目标目录没有权限」、把用户支去改密码强。
    final mk = await _send(
      () => _dio.request<String>(
        dir,
        options: Options(
          method: 'MKCOL',
          headers: _authHeaders,
          responseType: ResponseType.plain,
        ),
      ),
    );
    final mcode = mk.statusCode ?? 0;
    if (mcode == 200 || mcode == 201 || mcode == 204) return;
    // 405：目录已经存在。这是竞态——另一台设备在我们 PROPFIND 之后建好了。
    if (mcode == 405) return;
    // 建目录也被拒，那 403 就是真的没权限了，报 MKCOL 这个结论。
    if (mcode == 401 || mcode == 403) {
      throw _statusError(mcode, '访问 $dir');
    }
    throw _statusError(mcode, '创建目录 $dir');
  }

  /// 读取同步文件。返回 null 表示云端还没有这个文件（404）。
  Future<WebDavFile?> get(String fileName) async {
    final url = '${config.collectionUrl}/$fileName';
    final resp = await _send(
      () => _dio.get<String>(
        url,
        options: Options(
          headers: _authHeaders,
          responseType: ResponseType.plain,
        ),
      ),
    );
    final code = resp.statusCode ?? 0;
    if (code == 404) return null;
    if (code == 200 || code == 203 || code == 204) {
      return WebDavFile(body: resp.data ?? '', etag: _strongEtagOf(resp));
    }
    throw _statusError(code, '读取 $fileName');
  }

  /// 写入同步文件。
  ///
  /// [ifMatch] 是上一次 GET 拿到的强 ETag，用来做乐观并发控制：云端被别的
  /// 设备改过时会返回 412，而不是把对方的改动直接盖掉。
  /// [createOnly] 用于「云端还没有文件，我来创建」这一路，对应
  /// `If-None-Match: *`，同样能在竞态时拿到 412 而不是覆盖。
  ///
  /// 返回写入后的新 ETag（服务器给了强 ETag 才有）。
  Future<String?> put(
    String fileName,
    String body, {
    String? ifMatch,
    bool createOnly = false,
  }) async {
    final headers = <String, String>{
      ..._authHeaders,
      'Content-Type': 'application/json; charset=utf-8',
    };
    if (ifMatch != null) headers['If-Match'] = ifMatch;
    if (createOnly) headers['If-None-Match'] = '*';

    final url = '${config.collectionUrl}/$fileName';
    final resp = await _send(
      () => _dio.put<String>(
        url,
        // 显式给字节，不让 dio 按字符串去猜编码：同步文件里有中文标题。
        data: utf8.encode(body),
        options: Options(headers: headers, responseType: ResponseType.plain),
      ),
    );
    final code = resp.statusCode ?? 0;
    if (code == 200 || code == 201 || code == 204) {
      return _strongEtagOf(resp);
    }
    if (code == 412) {
      throw const WebDavException(
        '云端文件已被其他设备修改',
        statusCode: 412,
        isConflict: true,
      );
    }
    throw _statusError(code, '写入 $fileName');
  }

  /// 只问「有没有、多大、变没变」，**不下载内容**。
  ///
  /// 先发 HEAD 当快路径：大多数服务端（nginx / Apache / Nextcloud / 坚果云）都会
  /// 在响应头里直接给出 `Content-Length` / `ETag`，省掉一次 XML 解析。
  ///
  /// **但 HEAD 只当加速用，不当依据。** 自建 WebDAV 上 HEAD 的行为很不可靠，
  /// 实测遇到过三种：把 HEAD 当成未授权方法直接回 403；没实现 HEAD 回 405 / 501；
  /// 以及**对不存在的路径回 403 而不是 404**。前两种会让检查直接抛错、更新功能
  /// 整个不可用；第三种更隐蔽 —— 会把「云端没有包」误判成「没权限」。
  /// 所以除了「HEAD 给了现成可用的元数据」这一种情况，其余一律交给 PROPFIND 定论：
  /// 它是 WebDAV 的强制方法，认不认 HEAD 都必须实现它。
  ///
  /// 返回 null 表示云端没有这个文件。调用方按约定把它当成「不更新」。
  Future<WebDavStat?> stat(String fileName) async {
    final url = '${config.collectionUrl}/$fileName';
    final head = await _send(
      () => _dio.head<String>(
        url,
        options: Options(
          headers: _authHeaders,
          responseType: ResponseType.plain,
        ),
      ),
    );
    final code = head.statusCode ?? 0;
    if (code == 200 || code == 203 || code == 204) {
      final stat = WebDavStat(
        sizeBytes: _intOf(head.headers.value('content-length')),
        etag: _strongEtag(head.headers.value('etag')),
        lastModifiedMs: _httpDateMs(head.headers.value('last-modified')),
      );
      // HEAD 既没给大小也没给 ETag，判断不了「变没变」，还是得问 PROPFIND。
      if (stat.hasSize || stat.etag != null) return stat;
    }
    return _statByPropfind(url, fileName);
  }

  Future<WebDavStat?> _statByPropfind(String url, String fileName) async {
    final resp = await _send(
      () => _dio.request<String>(
        url,
        options: Options(
          method: 'PROPFIND',
          headers: {..._authHeaders, 'Depth': '0'},
          responseType: ResponseType.plain,
        ),
      ),
    );
    final code = resp.statusCode ?? 0;
    if (code == 404) return null;
    if (code != 207 && code != 200) throw _statusError(code, '查询 $fileName');

    final body = resp.data ?? '';
    final size = _intOf(_xmlText(body, 'getcontentlength'));
    final etag = _strongEtag(_xmlText(body, 'getetag'));
    final mtime = _httpDateMs(_xmlText(body, 'getlastmodified'));

    if (size < 0 && etag == null && mtime == null && !body.contains(fileName)) {
      // 有的服务端对**不存在的路径**回 207 + 空 multistatus，而不是 404。
      // 一条属性都抠不到、连文件名的影子都没有，就按「云端没有这个文件」处理。
      // 反过来（声称有包、点下去才发现 404）会让用户以为更新功能坏了，
      // 而且自动检查每次都会白下 20 MB。
      return null;
    }

    return WebDavStat(sizeBytes: size, etag: etag, lastModifiedMs: mtime);
  }

  /// 把远端文件下载到本机 [target]，边下边回报进度。
  ///
  /// 先写 `$target.part`、下完再改名。中途断网或者进程被杀掉时，磁盘上不会留下
  /// 一个「看着下完了、其实是半个包」的 APK —— 那种文件拿去安装只会报
  /// 「解析包时出现问题」，用户完全看不出是哪一步坏的。
  ///
  /// [expectedSize] 是 stat 拿到的字节数（未知传 -1）。下完对一次长度：
  /// 服务器说的和实际收到的对不上，说明中间被截断了，宁可报错重下。
  ///
  /// 返回实际写入的字节数。
  Future<int> downloadTo(
    String fileName,
    File target, {
    int expectedSize = -1,
    void Function(int received, int total)? onProgress,
  }) async {
    final tmp = File('${target.path}.part');
    if (await tmp.exists()) await tmp.delete();

    final url = '${config.collectionUrl}/$fileName';
    final Response<dynamic> resp;
    try {
      resp = await _send(
        () => _dio.download(
          url,
          tmp.path,
          options: Options(headers: _authHeaders),
          // 网络出错时让 dio 自己把半成品删掉，别留在磁盘上。
          deleteOnError: true,
          onReceiveProgress: onProgress,
        ),
      );
    } catch (e) {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }

    final code = resp.statusCode ?? 0;
    if (code == 404) {
      if (await tmp.exists()) await tmp.delete();
      throw WebDavException('云端已经没有 $fileName 了（404）', statusCode: 404);
    }
    if (code != 200 && code != 203) {
      if (await tmp.exists()) await tmp.delete();
      throw _statusError(code, '下载 $fileName');
    }

    final actual = await tmp.length();
    if (actual == 0) {
      await tmp.delete();
      throw const WebDavException('下载下来是空文件，服务器可能返回了错误内容');
    }
    if (expectedSize > 0 && actual != expectedSize) {
      await tmp.delete();
      throw WebDavException(
        '下载不完整：服务器说有 $expectedSize 字节，实际只收到 $actual 字节。请重试',
      );
    }

    if (await target.exists()) await target.delete();
    await tmp.rename(target.path);
    return actual;
  }

  Future<Response<String>> _propfind(String url) => _send(
    () => _dio.request<String>(
      url,
      options: Options(
        method: 'PROPFIND',
        headers: {..._authHeaders, 'Depth': '0'},
        responseType: ResponseType.plain,
      ),
    ),
  );

  /// 取强 ETag。
  ///
  /// 弱校验器（`W/"..."`）按 RFC 7232 §3.1 不能用在 `If-Match` 上；格式不
  /// 规整的（没带引号）也一律不认。这两种情况都返回 null，退化成无条件写入，
  /// 否则每写一次都被服务器判 412，同步会直接卡死在重试循环里。
  static String? _strongEtagOf(Response<dynamic> resp) =>
      _strongEtag(resp.headers.value('etag'));

  static String? _strongEtag(String? raw) {
    final s = raw?.trim();
    if (s == null || s.isEmpty) return null;
    if (s.startsWith('W/') || s.startsWith('w/')) return null;
    if (s.length < 3 || !s.startsWith('"') || !s.endsWith('"')) return null;
    return s;
  }

  static int _intOf(String? raw) {
    if (raw == null) return -1;
    return int.tryParse(raw.trim()) ?? -1;
  }

  /// 解析 HTTP 日期（`Mon, 28 Sep 2026 10:00:00 GMT` 这种）。看不懂就返回 null。
  static int? _httpDateMs(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return HttpDate.parse(raw.trim()).millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  /// 从 WebDAV 的 XML 里抠一个元素的值。
  ///
  /// 不引 XML 解析库：这里只要三个标量，而命名空间前缀（`D:` / `d:` / 无前缀）
  /// 各家服务端都不一样，按「本地名」匹配反而比按命名空间配更省事、也更不容易漏。
  static String? _xmlText(String xml, String localName) {
    final re = RegExp(
      '<(?:[A-Za-z0-9_.-]+:)?$localName\\b[^>]*>([\\s\\S]*?)</(?:[A-Za-z0-9_.-]+:)?$localName>',
      caseSensitive: false,
    );
    final m = re.firstMatch(xml);
    if (m == null) return null;
    return _unescapeXml(m.group(1)?.trim() ?? '');
  }

  /// 反转义顺序有讲究：`&amp;` 必须放最后，否则 `&amp;lt;` 会被解成 `<`。
  static String _unescapeXml(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  /// 把所有底层异常翻译成一句用户能看懂的话。
  Future<Response<T>> _send<T>(Future<Response<T>> Function() call) async {
    try {
      return await call();
    } on DioException catch (e) {
      throw _networkError(e);
    } on HandshakeException catch (e) {
      throw WebDavException('HTTPS 握手失败（${e.message}）：证书不受信任，或地址/端口写错');
    } on SocketException catch (e) {
      throw WebDavException(
        '连不上服务器（${e.osError?.message ?? e.message}）：检查地址、端口和网络',
      );
    }
  }

  WebDavException _networkError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return const WebDavException('连接超时：地址或端口不对，或者被防火墙挡住了');
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return const WebDavException('传输超时：服务器响应太慢，稍后再试');
      case DioExceptionType.badCertificate:
        return const WebDavException('HTTPS 证书校验失败。自建服务器可以在设置里打开「信任自签证书」');
      case DioExceptionType.connectionError:
        final err = e.error;
        if (err is HandshakeException) {
          return const WebDavException(
            'HTTPS 握手失败：证书不受信任，或地址/端口写错（自建服务器可打开「信任自签证书」）',
          );
        }
        if (err is SocketException) {
          return WebDavException(
            '连不上服务器（${err.osError?.message ?? err.message}）：检查地址、端口和网络',
          );
        }
        return const WebDavException('连不上服务器：检查地址和网络');
      case DioExceptionType.cancel:
        return const WebDavException('请求被取消');
      case DioExceptionType.badResponse:
        return _statusError(e.response?.statusCode ?? 0, '请求');
      case DioExceptionType.unknown:
        return WebDavException('请求失败：${e.message ?? e.error ?? '未知原因'}');
    }
  }

  WebDavException _statusError(int code, String action) {
    switch (code) {
      case 401:
        return WebDavException(
          '认证失败（401）：用户名或密码不对。坚果云这类服务要填「应用密码」，不是登录密码',
          statusCode: code,
        );
      case 403:
        return WebDavException('服务器拒绝访问（403）：这个账号对目标目录没有权限', statusCode: code);
      case 404:
        return WebDavException(
          '路径不存在（404）：$action 时找不到目标。'
          '地址填错、目录还没建、或者服务器把认证失败也回成 404（有些服务端会这样）'
          '都可能报这个，先确认地址和密码',
          statusCode: code,
        );
      case 409:
        return WebDavException('上级目录不存在（409）：地址里的某一段路径还没建出来', statusCode: code);
      case 423:
        return WebDavException('文件被锁定（423）：稍后再试', statusCode: code);
      case 507:
        return WebDavException('云端空间不足（507）', statusCode: code);
      default:
        if (code >= 500) {
          return WebDavException(
            '服务器错误（$code）：$action 失败，稍后重试',
            statusCode: code,
          );
        }
        return WebDavException('$action 失败（HTTP $code）', statusCode: code);
    }
  }
}
