import 'video_site_client.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import '../models/play_source.dart';
import 'video_site_scraper.dart';

class TestedPlaySource {
  final PlaySource source;
  final String playUrl;
  final double speedKBps; // Real download speed in KB/s
  final int latencyMs;
  final bool isAvailable;

  const TestedPlaySource({
    required this.source,
    required this.playUrl,
    required this.speedKBps,
    required this.latencyMs,
    required this.isAvailable,
  });

  String get speedLabel {
    if (!isAvailable || speedKBps <= 0) return '不可用';
    if (speedKBps >= 1024) {
      return '${(speedKBps / 1024).toStringAsFixed(1)} MB/s';
    }
    return '${speedKBps.toInt()} KB/s';
  }
}

class SourceSpeedTester {
  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(milliseconds: 4000),
      receiveTimeout: const Duration(milliseconds: 5000),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        if (VideoSiteClient.instance.activeBaseUrl.isNotEmpty)
          'Origin': VideoSiteClient.instance.activeBaseUrl,
        if (VideoSiteClient.instance.activeBaseUrl.isNotEmpty)
          'Referer': '${VideoSiteClient.instance.activeBaseUrl}/',
      },
      validateStatus: (status) =>
          status != null && status >= 200 && status < 300,
    ),
  );

  static bool isHeavySource(PlaySource source) {
    final combined = '${source.name} ${source.sourceId}'.toLowerCase();
    return combined.contains('4k') || combined.contains('2k');
  }

  /// 并发探测各线路的第 [episodeIndex] 集，返回**确认有源**的线路子集。
  ///
  /// 用途：把站点上没配源的线路（实测「4K」线路在全站都是 `src: ""`）
  /// 从详情页的线路列表里摘掉，而不是让用户点进去才发现放不了。
  ///
  /// 三条安全边界：
  /// 1. 线路数 ≤ 1 时原样返回 —— 没有可摘的东西，不必付网络代价。
  /// 2. 分批并发（每批 [concurrency] 条），避免在电视盒子上一次开一堆连接。
  /// 3. 只有 [PlayProbe.emptySource] 才摘；`unknown`（超时/断网/结构变化）保留。
  ///    并且若过滤后一条不剩，**原样返回** —— 宁可留一条坏线路，
  ///    也不能因为站点改版或断网让详情页变成「没有任何线路」。
  static Future<List<PlaySource>> filterPlayableSources({
    required List<PlaySource> sources,
    required VideoSiteScraper scraper,
    int episodeIndex = 0,
    int concurrency = 4,
  }) async {
    if (sources.length <= 1) return sources;

    final keep = List<bool>.filled(sources.length, true);
    final batchSize = concurrency < 1 ? 1 : concurrency;

    for (int start = 0; start < sources.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, sources.length);
      final batch = <Future<void>>[];
      for (int i = start; i < end; i++) {
        final idx = i;
        final src = sources[idx];
        if (src.episodes.isEmpty) {
          keep[idx] = false;
          continue;
        }
        final epIdx = (episodeIndex >= 0 && episodeIndex < src.episodes.length)
            ? episodeIndex
            : 0;
        batch.add(() async {
          final probe = await scraper.probePlayPath(
            src.episodes[epIdx].playPath,
          );
          keep[idx] = probe != PlayProbe.emptySource;
        }());
      }
      await Future.wait(batch);
    }

    final filtered = <PlaySource>[];
    for (int i = 0; i < sources.length; i++) {
      if (keep[i]) filtered.add(sources[i]);
    }

    if (filtered.isEmpty || filtered.length == sources.length) return sources;
    return filtered;
  }

  /// Tests sources sequentially (without concurrency) measuring REAL video chunk download speed.
  /// Avoids bandwidth contention and accurately measures each line's raw baseline.
  static Future<List<TestedPlaySource>> probeAndRankSources({
    required List<PlaySource> sources,
    required int episodeIndex,
    required VideoSiteScraper scraper,
    void Function(TestedPlaySource fastestWorking)? onFirstWorkingSource,
  }) async {
    final results = <TestedPlaySource>[];
    bool notifiedFirst = false;

    // Test sequentially without concurrency to prevent bandwidth contention
    for (final src in sources) {
      if (episodeIndex >= src.episodes.length) continue;
      final ep = src.episodes[episodeIndex];

      try {
        // Step 1: Resolve M3U8 URL from play page HTML
        final m3u8Url = await scraper.resolvePlayM3u8(ep.playPath);
        if (m3u8Url == null || !m3u8Url.startsWith('http')) {
          results.add(
            TestedPlaySource(
              source: src,
              playUrl: '',
              speedKBps: 0,
              latencyMs: 9999,
              isAvailable: false,
            ),
          );
          continue;
        }

        // Step 2: Fetch M3U8 manifest
        final m3u8Resp = await _dio.get<String>(
          m3u8Url,
          options: Options(responseType: ResponseType.plain),
        );
        final m3u8Text = m3u8Resp.data ?? '';
        final isHls =
            m3u8Text.contains('#EXTM3U') || m3u8Text.contains('#EXT-X-');
        if (!isHls) {
          results.add(
            TestedPlaySource(
              source: src,
              playUrl: m3u8Url,
              speedKBps: 0,
              latencyMs: 9999,
              isAvailable: false,
            ),
          );
          continue;
        }

        // Step 3: Find first video segment (TS/M4S) to measure real video download throughput
        String segmentUrl = '';
        final lines = m3u8Text.split('\n');
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
          if (trimmed.endsWith('.m3u8') || trimmed.contains('.m3u8')) {
            // Nested playlist: resolve and fetch inner playlist
            final subM3u8 = trimmed.startsWith('http')
                ? trimmed
                : Uri.parse(m3u8Url).resolve(trimmed).toString();
            try {
              final subResp = await _dio.get<String>(
                subM3u8,
                options: Options(responseType: ResponseType.plain),
              );
              final subLines = (subResp.data ?? '').split('\n');
              for (final subL in subLines) {
                final sTrim = subL.trim();
                if (sTrim.isEmpty || sTrim.startsWith('#')) continue;
                segmentUrl = sTrim.startsWith('http')
                    ? sTrim
                    : Uri.parse(subM3u8).resolve(sTrim).toString();
                break;
              }
            } catch (e) {
              // 嵌套播放列表拉不到就退回外层地址测速 —— 兜底是对的，但测出来的
              // 是外层而不是真正要播的那个分片，速度会因此偏低。不记的话，
              // 「这条线路测出来很慢」永远看不出其实是取子列表失败了。
              debugPrint(
                '[SourceSpeedTester] nested playlist fetch failed, falling back to outer url ($subM3u8): $e',
              );
            }
            if (segmentUrl.isNotEmpty) break;
          } else {
            segmentUrl = trimmed.startsWith('http')
                ? trimmed
                : Uri.parse(m3u8Url).resolve(trimmed).toString();
            break;
          }
        }

        final testTarget = segmentUrl.isNotEmpty ? segmentUrl : m3u8Url;

        // Step 4: Measure REAL download throughput by streaming a 384KB video chunk (single connection)
        final speedStopwatch = Stopwatch()..start();
        final segResp = await _dio.get<List<int>>(
          testTarget,
          options: Options(
            responseType: ResponseType.bytes,
            headers: {
              'Range': 'bytes=0-393215', // 384 KB video chunk test
            },
          ),
        );
        speedStopwatch.stop();

        final downloadedBytes = segResp.data?.length ?? 0;
        final elapsedSec = speedStopwatch.elapsedMilliseconds / 1000.0;
        final speedKBps =
            (downloadedBytes / 1024.0) /
            (elapsedSec > 0.05 ? elapsedSec : 0.05);

        final testedSource = TestedPlaySource(
          source: src,
          playUrl: m3u8Url,
          speedKBps: speedKBps,
          latencyMs: speedStopwatch.elapsedMilliseconds,
          isAvailable: downloadedBytes > 500,
        );
        results.add(testedSource);

        // Prefer notifying first non-2K/4K working source for fast, smooth TV playback
        if (!notifiedFirst &&
            testedSource.isAvailable &&
            !isHeavySource(testedSource.source)) {
          notifiedFirst = true;
          onFirstWorkingSource?.call(testedSource);
        }
      } catch (e) {
        results.add(
          TestedPlaySource(
            source: src,
            playUrl: '',
            speedKBps: 0,
            latencyMs: 9999,
            isAvailable: false,
          ),
        );
      }
    }

    // Sort:
    // 1. Available first
    // 2. Non-heavy sources (non 2K/4K) prioritized over 2K/4K
    // 3. Highest speed (speedKBps descending)
    // 4. Latency ascending
    results.sort((a, b) {
      if (a.isAvailable && !b.isAvailable) return -1;
      if (!a.isAvailable && b.isAvailable) return 1;

      final aHeavy = isHeavySource(a.source);
      final bHeavy = isHeavySource(b.source);
      if (!aHeavy && bHeavy) return -1;
      if (aHeavy && !bHeavy) return 1;

      final speedCmp = b.speedKBps.compareTo(a.speedKBps);
      if (speedCmp != 0) return speedCmp;
      return a.latencyMs.compareTo(b.latencyMs);
    });

    return results;
  }
}
