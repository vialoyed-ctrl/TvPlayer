import 'package:flutter_test/flutter_test.dart';
import 'package:tvplayer/services/cdndefend_solver.dart';
import 'package:tvplayer/services/video_site_client.dart';
import 'package:tvplayer/services/video_site_scraper.dart';
import 'package:tvplayer/services/source_speed_tester.dart';

void main() {
  test('CdndefendSolver solves known challenge', () {
    const mockHtml = '''
    const a0_0x2a54=['4C18DF7937F5E1730979546B9A5F0C845A2D6373','cdndefend_js_cookie=','array'];
    ''';
    final result = CdndefendSolver.solve(mockHtml);
    expect(result, isNotNull);
    expect(
      result,
      contains('cdndefend_js_cookie=4C18DF7937F5E1730979546B9A5F0C845A2D6373'),
    );
  });

  test(
    'VideoSiteScraper fetches home items',
    () async {
      final scraper = VideoSiteScraper();
      final items = await scraper.getHomeFeatured();
      expect(items, isNotEmpty);
      print(
        'Fetched ${items.length} featured items. First: ${items.first.title}',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
    skip: VideoSiteClient.siteUrls.isEmpty,
  );

  test(
    'VideoSiteScraper fetches channel 1 movies and details',
    () async {
      final scraper = VideoSiteScraper();
      final items = await scraper.getChannelItems(1);
      expect(items, isNotEmpty);
      print(
        'Channel 1: ${items.length} items. Testing detail for ${items.first.title}',
      );

      final detail = await scraper.getVodDetail(items.first.detailPath);
      expect(detail, isNotNull);
      expect(detail!.title, isNotEmpty);
      expect(detail.sources, isNotEmpty);
      print(
        'Movie: ${detail.title}, sources: ${detail.sources.length}, episodes: ${detail.sources.first.episodes.length}',
      );

      // Test speed ranking
      final ranked = await SourceSpeedTester.probeAndRankSources(
        sources: detail.sources,
        episodeIndex: 0,
        scraper: scraper,
      );
      for (final s in ranked) {
        print(
          'Source: ${s.source.name} => Speed: ${s.speedLabel}, Latency: ${s.latencyMs}ms, Available: ${s.isAvailable}',
        );
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
    skip: VideoSiteClient.siteUrls.isEmpty,
  );
}
