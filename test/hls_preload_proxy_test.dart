import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvplayer/services/hls_preload_proxy.dart';
import 'package:dio/dio.dart';

void main() {
  test('HlsPreloadProxy starts, serves rewritten m3u8, and resets cache cleanly', () async {
    final proxy = HlsPreloadProxy.instance;
    await proxy.ensureStarted();
    expect(proxy.port, greaterThan(0));
    print('HlsPreloadProxy started on port: ${proxy.port}');

    // Mock upstream server serving an M3U8
    final mockUpstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    const mockM3u8 = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
segment0.ts
#EXTINF:10.0,
segment1.ts
#EXTINF:10.0,
segment2.ts
#EXT-X-ENDLIST''';

    mockUpstream.listen((req) {
      if (req.uri.path.endsWith('.m3u8')) {
        req.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        req.response.write(mockM3u8);
        req.response.close();
      } else if (req.uri.path.endsWith('.ts')) {
        req.response.headers.contentType = ContentType('video', 'mp2t');
        req.response.add(List.generate(1024, (i) => i % 256));
        req.response.close();
      }
    });

    final upstreamUrl = 'http://127.0.0.1:${mockUpstream.port}/index.m3u8';
    final proxiedUrl = proxy.getProxiedM3u8Url(
      upstreamUrl,
      videoId: 'test_vod_1',
      episodeName: 'ep1',
    );
    expect(proxiedUrl, contains('127.0.0.1:${proxy.port}/playlist.m3u8'));

    // Fetch the proxied M3U8
    final dio = Dio();
    final resp = await dio.get<String>(proxiedUrl);
    expect(resp.statusCode, 200);
    final rewritten = resp.data!;
    expect(rewritten, contains('/segment.ts?idx=0'));
    expect(rewritten, contains('/segment.ts?idx=1'));
    expect(rewritten, contains('/segment.ts?idx=2'));
    print('Rewritten M3U8 verified:\n$rewritten');

    // Wait a brief moment for preload workers
    await Future.delayed(const Duration(milliseconds: 300));

    // Request segment 0 from proxy
    final segResp = await dio.get<List<int>>(
      'http://127.0.0.1:${proxy.port}/segment.ts?idx=0',
      options: Options(responseType: ResponseType.bytes),
    );
    expect(segResp.statusCode, 200);
    expect(segResp.data!.length, 1024);
    print(
      'Proxied segment 0 downloaded successfully (${segResp.data!.length} bytes)',
    );

    // Test automatic cache reset when switching video
    proxy.resetForNewVideo('test_vod_2_ep1');
    expect(proxy.currentVideoKey, 'test_vod_2_ep1');

    await mockUpstream.close(force: true);
    await proxy.dispose();
  });
}
