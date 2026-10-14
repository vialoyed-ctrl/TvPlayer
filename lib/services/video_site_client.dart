import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'cdndefend_solver.dart';

class VideoSiteUnavailableException implements Exception {
  const VideoSiteUnavailableException();
  @override
  String toString() => '视频站点暂时都无法访问，请检查网络后重试';
}

class VideoSiteClient {
  static final VideoSiteClient instance = VideoSiteClient();
  static const String _siteTemplate = String.fromEnvironment(
    'TVPLAYER_SITE_TEMPLATE',
  );
  static final List<String> siteUrls = _siteTemplate.isEmpty
      ? const []
      : List.unmodifiable(
          List.generate(
            10,
            (index) => _siteTemplate.replaceAll('{index}', '$index'),
          ),
        );
  static String get baseUrl => siteUrls.isEmpty ? '' : siteUrls.first;
  static const List<String> _fallbackImageMirrors = [
    'https://vres.wkcyvs.cn',
    'https://vres.esadj.com',
    'https://vres.cyscyy.com',
  ];
  static List<String> _discoveredImageMirrors = const [];
  static List<String> get imageCdnMirrors =>
      {..._discoveredImageMirrors, ..._fallbackImageMirrors}.toList();

  final Dio _dio;
  final Map<String, String> _cookies = {};
  final List<String> _sites;
  late String _activeBaseUrl;
  String get activeBaseUrl => _activeBaseUrl;
  DateTime? _lastImageConfigCheck;

  VideoSiteClient({Dio? dio, List<String>? sites})
    : _dio = dio ?? Dio(),
      _sites = List.unmodifiable(sites ?? siteUrls) {
    _activeBaseUrl = _sites.isEmpty ? '' : _sites.first;
    _dio.options = BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 10),
      responseType: ResponseType.plain,
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      },
      validateStatus: (_) => true,
    );
  }

  /// Fix image URL: maps relative /vod1/ paths to fast CDN mirror
  static String fixImageUrl(String? rawUrl) {
    final value = rawUrl?.trim() ?? '';
    if (value.isEmpty) {
      return '';
    }
    final uri = Uri.tryParse(value);
    if (uri == null) return '';
    if (value.startsWith('//')) return 'https:$value';
    if (uri.hasScheme) {
      return uri.scheme == 'http' || uri.scheme == 'https'
          ? uri.toString()
          : '';
    }
    final base = value.startsWith('/vod1/') || value.startsWith('vod1/')
        ? imageCdnMirrors.first
        : instance.activeBaseUrl;
    if (base.isEmpty) return '';
    return Uri.parse('$base/').resolve(value).toString();
  }

  static List<String> imageCandidates(String rawUrl) {
    final normalized = fixImageUrl(rawUrl);
    if (normalized.isEmpty) return const [];
    final uri = Uri.parse(normalized);
    final known = imageCdnMirrors.any(
      (base) => Uri.parse(base).host == uri.host,
    );
    return {
      normalized,
      if (known)
        ...imageCdnMirrors.map(
          (base) => Uri.parse(base)
              .resolveUri(
                Uri(path: uri.path, query: uri.hasQuery ? uri.query : null),
              )
              .toString(),
        ),
    }.toList();
  }

  bool _isChallenge(Response<String> response) {
    final body = response.data ?? '';
    return response.statusCode == 850 ||
        body.contains('Protected by cdndefend') ||
        body.contains('cdndefend_js_cookie=');
  }

  Future<void> _refreshImageConfig(String body, String site) async {
    final last = _lastImageConfigCheck;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 5)) {
      return;
    }
    final match = RegExp(
      r'''<script\b[^>]*\bsrc\s*=\s*["']([^"']*/rdul\.js(?:\?[^"']*)?)["']''',
      caseSensitive: false,
    ).firstMatch(body);
    if (match == null) return;
    final script = Uri.parse('$site/').resolve(match.group(1)!);
    if (script.scheme != 'https' || script.host.isEmpty) return;
    _lastImageConfigCheck = DateTime.now();
    try {
      final response = await _dio.get<String>(
        script.toString(),
        options: Options(
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 3),
        ),
      );
      if (response.statusCode != 200) return;
      final array = RegExp(r'\bRDUL\s*=\s*\[([^\]]*)\]')
          .firstMatch(response.data ?? '');
      if (array == null) return;
      final domains = <String>[];
      for (final value in RegExp(
        r'''["'](https://[^"']+)["']''',
      ).allMatches(array.group(1)!)) {
        final uri = Uri.tryParse(value.group(1)!);
        if (uri == null ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            !uri.host.contains('.') ||
            RegExp(r'^[0-9.]+$').hasMatch(uri.host) ||
            uri.hasQuery ||
            uri.hasFragment ||
            (uri.path.isNotEmpty && uri.path != '/')) {
          continue;
        }
        domains.add(uri.origin);
      }
      if (domains.isNotEmpty) {
        _discoveredImageMirrors = domains.toSet().toList();
      }
    } on DioException {
      // 配置暂时获取失败时，仍使用上次的有效配置和备用镜像。
    }
  }

  Future<Response<String>> _request(
    String site,
    Uri path,
    Map<String, dynamic>? queryParameters,
  ) => _dio.get<String>(
    Uri.parse(site).resolveUri(path).toString(),
    queryParameters: queryParameters,
    options: Options(
      headers: {
        'Origin': site,
        'Referer': '$site/',
        if (_cookies[site] != null) 'Cookie': _cookies[site],
      },
    ),
  );

  Future<String> getHtml(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    if (_sites.isEmpty) {
      throw StateError('尚未配置视频站点');
    }
    // Detail/play links may contain an old absolute site address.
    final uri = Uri.parse(path);
    if (uri.hasAuthority &&
        !_sites.any((site) => Uri.parse(site).host == uri.host)) {
      throw ArgumentError.value(path, 'path', '仅支持已配置的视频站点地址');
    }
    final relative = Uri(
      path: uri.path.isEmpty ? '/' : uri.path,
      query: uri.hasQuery ? uri.query : null,
    );
    // Snapshot order so concurrent requests cannot change this iteration.
    final candidates = [
      _activeBaseUrl,
      ..._sites.where((site) => site != _activeBaseUrl),
    ];
    for (final site in candidates) {
      try {
        var response = await _request(site, relative, queryParameters);
        if (_isChallenge(response)) {
          final cookie = await compute(
            CdndefendSolver.solve,
            response.data ?? '',
          );
          if (cookie == null) continue;
          _cookies[site] = cookie;
          response = await _request(site, relative, queryParameters);
        }
        final status = response.statusCode ?? 0;
        final body = response.data ?? '';
        if (status < 200 ||
            status >= 300 ||
            _isChallenge(response) ||
            !RegExp(r'<(?:html|body)\b', caseSensitive: false).hasMatch(body)) {
          continue;
        }
        _activeBaseUrl = site;
        await _refreshImageConfig(body, site);
        return body;
      } on DioException catch (error) {
        if (error.type == DioExceptionType.cancel) rethrow;
        debugPrint('[VideoSiteClient] $site 请求失败，尝试下一站点 (${error.type.name})');
      }
    }
    throw const VideoSiteUnavailableException();
  }
}
