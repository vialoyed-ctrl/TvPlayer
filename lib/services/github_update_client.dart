import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

class GitHubUpdateException implements Exception {
  const GitHubUpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

class GitHubReleaseApk {
  const GitHubReleaseApk({
    required this.tag,
    required this.name,
    required this.url,
    required this.sizeBytes,
    required this.sha256Digest,
  });
  final String tag;
  final String name;
  final String url;
  final int sizeBytes;
  final String sha256Digest;
  String get fingerprint => '$tag:$name:$sha256Digest';

  static List<int>? versionParts(String version) {
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$')
        .firstMatch(version.trim());
    if (match == null) return null;
    return List.generate(3, (i) => int.parse(match.group(i + 1)!));
  }

  bool isNewerThan(String? current) {
    final latest = versionParts(tag);
    final installed = versionParts(current ?? '');
    if (latest == null || installed == null) {
      throw const GitHubUpdateException('无法识别版本号，暂不自动安装');
    }
    for (var i = 0; i < 3; i++) {
      if (latest[i] != installed[i]) return latest[i] > installed[i];
    }
    return false;
  }
}

class GitHubUpdateClient {
  GitHubUpdateClient({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options = BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'User-Agent': 'TvPlayer',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2026-03-10',
      },
    );
  }
  static const repository = 'vialoyed-ctrl/TvPlayer';
  static const latestUrl =
      'https://api.github.com/repos/$repository/releases/latest';
  static const manifestUrl =
      'https://github.com/$repository/releases/latest/download/update.json';
  static const downloadPrefix =
      'https://github.com/$repository/releases/download/';
  final Dio _dio;

  Future<GitHubReleaseApk?> latest(String apkName) async {
    dynamic data;
    try {
      final manifest = await _dio.get<String>(
        manifestUrl,
        options: Options(
          responseType: ResponseType.plain,
          headers: {'Accept': 'application/octet-stream'},
        ),
      );
      try {
        data = jsonDecode(manifest.data ?? '');
      } on FormatException {
        throw const GitHubUpdateException('GitHub 更新清单格式不正确');
      }
    } on DioException {
      data = await _latestApi();
    }
    if (data == null) return null;
    return _parse(data, apkName);
  }

  Future<dynamic> _latestApi() async {
    Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(latestUrl);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      if (e.response?.statusCode == 403 || e.response?.statusCode == 429) {
        throw const GitHubUpdateException('GitHub 请求受到限制，请稍后重试');
      }
      throw const GitHubUpdateException('无法连接 GitHub，请检查网络后重试');
    }
    return response.data;
  }

  GitHubReleaseApk _parse(dynamic data, String apkName) {
    if (data is! Map || data['draft'] != false || data['prerelease'] != false) {
      throw const GitHubUpdateException('GitHub 尚无可用的正式版本');
    }
    final tag = data['tag_name'] as String? ?? '';
    if (GitHubReleaseApk.versionParts(tag) == null) {
      throw const GitHubUpdateException('GitHub 版本号格式不正确');
    }
    final assets = data['assets'];
    if (assets is List) {
      for (final asset in assets) {
        if (asset is! Map ||
            asset['name'] != apkName ||
            asset['state'] != 'uploaded') {
          continue;
        }
        final url = asset['browser_download_url'] as String? ?? '';
        final size = (asset['size'] as num?)?.toInt() ?? 0;
        final digest = asset['digest'] as String? ?? '';
        if (!url.startsWith('$downloadPrefix$tag/') ||
            Uri.tryParse(url)?.scheme != 'https' ||
            size <= 0 ||
            !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest)) {
          throw const GitHubUpdateException('发布的安装包信息不完整，暂不安装');
        }
        return GitHubReleaseApk(
          tag: tag,
          name: apkName,
          url: url,
          sizeBytes: size,
          sha256Digest: digest.substring(7).toLowerCase(),
        );
      }
    }
    throw GitHubUpdateException('GitHub 新版尚未提供 $apkName，请稍后重试');
  }

  Future<bool> matches(File file, GitHubReleaseApk apk) async {
    if (!await file.exists() || await file.length() != apk.sizeBytes) {
      return false;
    }
    return (await sha256.bind(file.openRead()).first).toString() ==
        apk.sha256Digest;
  }

  Future<void> download(
    GitHubReleaseApk apk,
    File file, {
    required void Function(int, int) onProgress,
  }) async {
    final partial = File('${file.path}.part');
    try {
      await _dio.download(
        apk.url,
        partial.path,
        options: Options(headers: {'Accept': 'application/octet-stream'}),
        onReceiveProgress: onProgress,
      );
      if (!await matches(partial, apk)) {
        throw const GitHubUpdateException('安装包大小或 SHA-256 校验失败，请重新下载');
      }
      if (await file.exists()) await file.delete();
      await partial.rename(file.path);
    } on DioException {
      throw const GitHubUpdateException('从 GitHub 下载安装包失败，请检查网络后重试');
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }
}
