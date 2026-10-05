import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvplayer/services/github_update_client.dart';

class ReleaseAdapter implements HttpClientAdapter {
  ReleaseAdapter(
    this.metadata,
    this.payload, {
    this.status = 200,
    this.manifestStatus = 404,
  });
  final int manifestStatus;
  final List<String> requests = [];
  final Map<String, dynamic> metadata;
  final List<int> payload;
  final int status;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri.toString());
    if (options.uri.path.endsWith('/update.json')) {
      return ResponseBody.fromString(
        jsonEncode(metadata),
        manifestStatus,
        headers: {
          Headers.contentTypeHeader: ['application/octet-stream'],
        },
      );
    }
    if (options.uri.path.endsWith('/latest')) {
      return ResponseBody.fromString(
        jsonEncode(metadata),
        status,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromBytes(
      payload,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/octet-stream'],
        Headers.contentLengthHeader: ['${payload.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final payload = utf8.encode('verified apk fixture');
  Map<String, dynamic> release({bool prerelease = false, String? digest}) => {
    'tag_name': 'v1.0.1',
    'draft': false,
    'prerelease': prerelease,
    'assets': ['tvplayer_32bit.apk', 'tvplayer_64bit.apk']
        .map(
          (name) => {
            'name': name,
            'state': 'uploaded',
            'size': payload.length,
            'digest': digest ?? 'sha256:${sha256.convert(payload)}',
            'browser_download_url':
                '${GitHubUpdateClient.downloadPrefix}v1.0.1/$name',
          },
        )
        .toList(),
  };
  GitHubUpdateClient client(
    Map<String, dynamic> data, {
    List<int>? bytes,
    int status = 200,
  }) {
    final dio = Dio()
      ..httpClientAdapter = ReleaseAdapter(
        data,
        bytes ?? payload,
        status: status,
      );
    return GitHubUpdateClient(dio: dio);
  }

  test(
    'selects the matching architecture and compares versions numerically',
    () async {
      final apk = (await client(release()).latest('tvplayer_64bit.apk'))!;
      expect(apk.name, 'tvplayer_64bit.apk');
      expect(apk.isNewerThan('1.0.0'), true);
      expect(apk.isNewerThan('1.0.1'), false);
      expect(apk.isNewerThan('1.0.2'), false);
      expect(GitHubReleaseApk.versionParts('v1.10.0'), [1, 10, 0]);
      expect(GitHubReleaseApk.versionParts('v1.0.2-beta'), null);
    },
  );
  test('does not accept prereleases or unverifiable assets', () async {
    await expectLater(
      client(release(prerelease: true)).latest('tvplayer_32bit.apk'),
      throwsA(isA<GitHubUpdateException>()),
    );
    await expectLater(
      client(release(digest: '')).latest('tvplayer_32bit.apk'),
      throwsA(isA<GitHubUpdateException>()),
    );
  });
  test('handles no release and API throttling', () async {
    expect(await client({}, status: 404).latest('tvplayer_32bit.apk'), null);
    await expectLater(
      client({}, status: 403).latest('tvplayer_32bit.apk'),
      throwsA(isA<GitHubUpdateException>()),
    );
  });
  test('public manifest avoids API throttling', () async {
    final adapter = ReleaseAdapter(
      release(),
      payload,
      status: 403,
      manifestStatus: 200,
    );
    final service = GitHubUpdateClient(dio: Dio()..httpClientAdapter = adapter);
    expect((await service.latest('tvplayer_64bit.apk'))!.tag, 'v1.0.1');
    expect(adapter.requests, [GitHubUpdateClient.manifestUrl]);
  });
  test('rejects an APK download from another repository', () async {
    final data = release();
    (data['assets'] as List).first['browser_download_url'] =
        'https://github.com/other/app/releases/download/v1.0.1/test.apk';
    await expectLater(
      client(data).latest('tvplayer_32bit.apk'),
      throwsA(isA<GitHubUpdateException>()),
    );
  });
  test(
    'downloads and verifies the actual bytes before committing the file',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'tvplayer-update-test-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final service = client(release());
      final apk = (await service.latest('tvplayer_32bit.apk'))!;
      final file = File('${temp.path}/update.apk');
      await service.download(apk, file, onProgress: (_, _) {});
      expect(await service.matches(file, apk), true);
      expect(await File('${file.path}.part').exists(), false);
    },
  );
  test('a corrupt download cannot replace an existing APK', () async {
    final temp = await Directory.systemTemp.createTemp('tvplayer-update-test-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/update.apk');
    await file.writeAsString('previous valid APK');
    final service = client(release(), bytes: utf8.encode('corrupt download'));
    final apk = (await service.latest('tvplayer_32bit.apk'))!;
    await expectLater(
      service.download(apk, file, onProgress: (_, _) {}),
      throwsA(isA<GitHubUpdateException>()),
    );
    expect(await file.readAsString(), 'previous valid APK');
    expect(await File('${file.path}.part').exists(), false);
  });
}
