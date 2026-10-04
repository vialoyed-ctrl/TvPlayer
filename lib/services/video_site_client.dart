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
  static const List<String> imageCdnMirrors = [
    'https://vres.esadj.com',
    'https://vres.cyscyy.com',
    'https://vres.enbymae.com',
  ];

  final Dio _dio;
  final Map<String, String> _cookies = {};
  final List<String> _sites;
  late String _activeBaseUrl;
  String get activeBaseUrl => _activeBaseUrl;

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
    if (rawUrl == null || rawUrl.isEmpty) {
      return '';
    }
    if (rawUrl.startsWith('http')) return rawUrl;
    if (rawUrl.startsWith('/')) return '${imageCdnMirrors.first}$rawUrl';
    return '${imageCdnMirrors.first}/$rawUrl';
  }

  bool _isChallenge(Response<String> response) {
    final body = response.data ?? '';
    return response.statusCode == 850 ||
        body.contains('Protected by cdndefend') ||
        body.contains('cdndefend_js_cookie=');
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
        return body;
      } on DioException catch (error) {
        if (error.type == DioExceptionType.cancel) rethrow;
        debugPrint('[VideoSiteClient] $site 请求失败，尝试下一站点 (${error.type.name})');
      }
    }
    throw const VideoSiteUnavailableException();
  }
}
