import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:tvplayer/services/video_site_client.dart';
import 'package:tvplayer/services/video_site_scraper.dart';

void main() {
  test(
    'image domains follow the page configuration without executing its script',
    () async {
      final requests = <String>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              requests.add(request.uri.path);
              handler.resolve(
                Response<String>(
                  requestOptions: request,
                  statusCode: 200,
                  data: request.uri.path == '/assets/rdul.js'
                      ? 'window.RDUL = ["https://current.images.example.test", "https://127.0.0.1:443", "http://invalid.example.test"];'
                      : '<html><head><script src="https://static.example.test/assets/rdul.js?v=2"></script></head><body>page</body></html>',
                ),
              );
            },
          ),
        );
      final client = VideoSiteClient(
        dio: dio,
        sites: ['https://video.example.test'],
      );
      await client.getHtml('/');
      expect(requests, ['/', '/assets/rdul.js']);
      expect(
        VideoSiteClient.fixImageUrl('/vod1/a.webp'),
        'https://current.images.example.test/vod1/a.webp',
      );
      expect(
        VideoSiteClient.imageCdnMirrors,
        isNot(contains('https://127.0.0.1:443')),
      );
      requests.clear();
      await client.getHtml('/detail/123.html');
      expect(requests, ['/detail/123.html']);
    },
  );
  test('protocol-relative and whitespace image links are valid HTTPS URLs', () {
    expect(
      VideoSiteClient.fixImageUrl(' //images.example.test/a.webp '),
      'https://images.example.test/a.webp',
    );
  });
  test(
    'cover mirrors preserve path and query and never rewrite unrelated CDNs',
    () {
      final urls = VideoSiteClient.imageCandidates(
        '${VideoSiteClient.imageCdnMirrors.first}/vod1/a.webp?token=one',
      );
      expect(urls.length, 4);
      expect(
        urls[1],
        '${VideoSiteClient.imageCdnMirrors[1]}/vod1/a.webp?token=one',
      );
      expect(
        VideoSiteClient.imageCandidates('https://images.example.test/a.webp'),
        ['https://images.example.test/a.webp'],
      );
      expect(
        VideoSiteClient.imageCandidates('data:image/png;base64,abc'),
        isEmpty,
      );
    },
  );
  test(
    'detail titles follow stylesheet visibility instead of hidden decoys',
    () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              handler.resolve(
                Response<String>(
                  requestOptions: request,
                  statusCode: 200,
                  data: '''
        <html><head><style>.detail-title strong:nth-child(odd) { display: none; }</style></head><body>
        <div class="detail-title"><strong>错误片名</strong><strong>正确片名</strong><strong>干扰片名</strong></div>
        <div class="detail-pic"><img data-original="/placeholder.png" data-src="//images.example.test/real.webp"></div>
        <div class="detail-desc"><p>真实剧情简介</p></div>
        </body></html>''',
                ),
              );
            },
          ),
        );
      final detail = (await VideoSiteScraper(
        client: VideoSiteClient(
          dio: dio,
          sites: ['https://video.example.test'],
        ),
      ).getVodDetail('/detail/123.html'))!;
      expect(detail.title, '正确片名');
      expect(detail.cover, 'https://images.example.test/real.webp');
      expect(detail.desc, '真实剧情简介');
    },
  );
  test('CSS-hidden decoy titles and lazy placeholders do not replace real metadata', () async {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            handler.resolve(
              Response<String>(
                requestOptions: request,
                statusCode: 200,
                data: '''
        <html><head><style>.decoy { display:none !important; }</style></head><body>
        <a href="/detail/123.html"><h3 class="decoy">错误标题</h3>
        <h3>全家福</h3><img data-original="" data-src="/vod1/real.webp" src="/placeholder.png">
        <span class="v-item-bottom">更新至20集</span></a>
        </body></html>''',
              ),
            );
          },
        ),
      );
    final client = VideoSiteClient(
      dio: dio,
      sites: ['https://video.example.test'],
    );
    final items = await VideoSiteScraper(client: client).getHomeFeatured();
    expect(items.single.title, '全家福');
    expect(
      items.single.cover,
      '${VideoSiteClient.imageCdnMirrors.first}/vod1/real.webp',
    );
    expect(items.single.remark, '更新至20集');
  });
}
