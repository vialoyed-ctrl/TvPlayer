import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvplayer/services/github_update_client.dart';
import 'package:tvplayer/services/update_service.dart';

class FakeReleaseClient extends GitHubUpdateClient {
  int checks = 0;
  int downloads = 0;
  String? selectedName;
  @override
  Future<GitHubReleaseApk?> latest(String apkName) async {
    checks++;
    selectedName = apkName;
    return GitHubReleaseApk(
      tag: 'v1.0.1',
      name: apkName,
      url: 'fixture',
      sizeBytes: 3,
      sha256Digest: 'fixture',
    );
  }

  @override
  Future<bool> matches(File file, GitHubReleaseApk apk) => file.exists();
  @override
  Future<void> download(
    GitHubReleaseApk apk,
    File file, {
    required void Function(int, int) onProgress,
  }) async {
    downloads++;
    await file.writeAsString('apk');
    onProgress(3, 3);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  const channel = MethodChannel('tvplayer/update');
  late Directory temp;
  var currentVersion = '1.0.0';
  var currentCode = 1001;
  var archiveCode = 1002;
  var signer = true;
  var permission = true;
  var installs = 0;
  var permissionRequests = 0;
  var filename = 'tvplayer_32bit.apk';
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tvplayer-flow-test-');
    currentVersion = '1.0.0';
    currentCode = 1001;
    archiveCode = 1002;
    signer = true;
    permission = true;
    installs = 0;
    permissionRequests = 0;
    filename = 'tvplayer_32bit.apk';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'currentVersion':
              return {
                'versionName': currentVersion,
                'versionCode': currentCode,
                'apkFileName': filename,
              };
            case 'appFilesDir':
              return temp.path;
            case 'canInstallPackages':
              return permission;
            case 'requestInstallPermission':
              permissionRequests++;
              return null;
            case 'apkInfo':
              return {
                'packageName': 'com.tvplayer.app',
                'versionName': '1.0.1',
                'versionCode': archiveCode,
                'sameSigner': signer,
                'isSamePackage': true,
                'signerUnknown': false,
              };
            case 'installApk':
              installs++;
              return {'ok': true};
          }
          return null;
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await temp.delete(recursive: true);
  });
  Future<UpdateService> create(FakeReleaseClient client) async {
    final service = UpdateService.forTesting(client);
    await service.init();
    addTearDown(service.dispose);
    return service;
  }

  test(
    'every opening checks GitHub even when the last check was recent',
    () async {
      currentVersion = '1.0.1';
      currentCode = 1002;
      final client = FakeReleaseClient();
      final service = await create(client);
      await service.runAutoCheck();
      await service.runAutoCheck();
      expect(client.checks, 2);
      expect(client.downloads, 0);
      expect(installs, 0);
    },
  );
  test(
    'automatically downloads the 64-bit update and launches installation',
    () async {
      filename = 'tvplayer_64bit.apk';
      currentCode = 2001;
      archiveCode = 2002;
      final client = FakeReleaseClient();
      final service = await create(client);
      await service.runAutoCheck();
      expect(client.selectedName, 'tvplayer_64bit.apk');
      expect(client.downloads, 1);
      expect(installs, 1);
      await service.runAutoCheck();
      expect(installs, 1, reason: 'Do not reopen the installer in a loop');
    },
  );
  test('refuses an APK signed by someone else', () async {
    signer = false;
    final service = await create(FakeReleaseClient());
    await service.runAutoCheck();
    expect(installs, 0);
    expect(service.phase, UpdatePhase.failed);
  });
  test('refuses a non-incremented Android version code', () async {
    archiveCode = currentCode;
    final service = await create(FakeReleaseClient());
    await service.runAutoCheck();
    expect(installs, 0);
    expect(service.phase, UpdatePhase.failed);
  });
  test('permission denial does not repeatedly reopen settings', () async {
    permission = false;
    final service = await create(FakeReleaseClient());
    await service.runAutoCheck();
    expect(permissionRequests, 1);
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(permissionRequests, 1);
    expect(installs, 0);
    permission = true;
    await service.install();
    expect(installs, 1);
  });
}
