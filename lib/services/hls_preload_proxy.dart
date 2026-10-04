import 'video_site_client.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

/// Localhost HLS Concurrent Preload Proxy Server.
///
/// Features:
/// 1. Runs a lightweight local HTTP proxy (127.0.0.1:port).
/// 2. Rewrites M3U8 playlists so the video player fetches TS slices via localhost.
/// 3. Maintains a worker pool that pre-fetches upcoming TS slices in parallel,
///    overcoming single-connection CDN throttling, and streams any slice that
///    is not buffered yet straight through to the player.
/// 4. Automatically clears previous video's cache when switching to a new video or episode.
class HlsPreloadProxy {
  static final HlsPreloadProxy instance = HlsPreloadProxy._internal();

  HlsPreloadProxy._internal();

  HttpServer? _server;
  int get port => _server?.port ?? 0;

  // Concurrent download workers.
  // NOTE: this proxy shares the Flutter UI isolate. 10 parallel sockets plus the
  // per-slice byte copies saturated the CPU on low-end TV boxes and starved the
  // video decoder. 4 workers is enough to parallelise segment fetching while
  // leaving headroom for rendering + hardware decoding.
  static const int maxConcurrentWorkers = 4;
  // Preload window: keep up to 10 segments ahead in buffer (~60s of video)
  static const int preloadAheadCount = 10;
  // Max segments kept in memory to prevent TV box OOM (around 15MB)
  static const int maxMemorySegments = 10;
  // Stop preloading once this many slices are safely buffered ahead
  static const int preloadPauseAhead = 8;
  // Cap for the next-episode disk preload. Previously the WHOLE episode was
  // written to disk during playback (hundreds of MB of flash I/O on the UI
  // isolate). 60 slices already give a multi-minute head start.
  static const int maxNextEpisodePreloadSegments = 60;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 15),
      responseType: ResponseType.bytes,
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

  String? _currentVideoKey;
  String? get currentVideoKey => _currentVideoKey;

  // Parsed segments for the current active media playlist
  final List<String> _orderedSegments = [];

  // 当前播放列表的总时长（所有 #EXTINF 之和）与它是否带 #EXT-X-ENDLIST。
  //
  // 为什么要暴露给播放器层：ExoPlayer 上报的 duration 并不可靠。点播列表还好，
  // 但滚动窗口型的列表（没有 ENDLIST，窗口只有 1~2 分钟且不断滚动）会让它上报
  // 0 或不断变化的值。一旦 duration 为 0，PlayerProvider 里所有
  // 「position 已经到底 = 这一集播完了」的判断全部失效，表现就是
  // 「一集放完了不会自动下一集」，而且时好时坏（取决于当次拿到的是哪种列表）。
  //
  // 代理本来就要逐行重写播放列表，顺手把 EXTINF 累加起来即可，零额外网络开销。
  Duration _playlistDuration = Duration.zero;
  Duration get playlistDuration => _playlistDuration;

  bool _playlistHasEndList = false;
  bool get playlistHasEndList => _playlistHasEndList;

  // In-memory cache for TS slices: segment index -> bytes
  final Map<int, Uint8List> _segmentCache = {};

  // Active in-flight downloads: segment index -> Completer / CancelToken
  final Map<int, Completer<Uint8List?>> _pendingDownloads = {};
  final Map<int, CancelToken> _cancelTokens = {};

  int _lastRequestedIndex = 0;

  /// Starts the local HTTP server if not already running.
  Future<void> ensureStarted() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      debugPrint(
        '[HlsPreloadProxy] Local proxy server started on 127.0.0.1:$port',
      );
      _server!.listen(
        _handleRequest,
        onError: (e) {
          debugPrint('[HlsPreloadProxy] Server error: $e');
        },
      );
    } catch (e) {
      debugPrint('[HlsPreloadProxy] Failed to start local proxy: $e');
    }
  }

  String get _cacheRootDir =>
      '${Directory.systemTemp.path}/tvplayer_video_cache';

  void _deleteVideoDiskCache(String videoKey) {
    try {
      final dir = Directory('$_cacheRootDir/$videoKey');
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
        debugPrint(
          '[HlsPreloadProxy] Cleaned previous video disk cache: $videoKey',
        );
      }
    } catch (e) {
      debugPrint(
        '[HlsPreloadProxy] Error deleting disk cache for $videoKey: $e',
      );
    }
  }

  // Next episode pre-caching
  String? _nextVideoKey;
  final List<String> _nextOrderedSegments = [];
  final Map<int, Uint8List> _nextSegmentCache = {};
  final Map<int, CancelToken> _nextCancelTokens = {};
  bool _isPreloadingNext = false;
  int _downloadedNextCount = 0;
  int get downloadedNextCount => _downloadedNextCount;
  int get totalNextCount => _nextOrderedSegments.length;

  /// 下一集预加载的失败只记一次。
  ///
  /// 这是**每个分片**都走一遍的循环，逐次记录几秒内就能把日志刷爆，反而看不出
  /// 真正的原因（哪一段、什么错）。而失败原因本身是需要的 —— 下面的
  /// 「Next episode preload finished (x / total)」会照常打印，不看错误日志的话
  /// 会以为预加载成功了，只是段数偏少。
  bool _nextPreloadErrorLogged = false;

  /// 当前集预加载 worker 的失败只记一次，理由同上（每个分片一次）。
  bool _segmentDownloadErrorLogged = false;

  /// Automatically clears previous video's cache and cancels any in-flight downloads.
  void resetForNewVideo([String? newKey]) {
    debugPrint(
      '[HlsPreloadProxy] Resetting cache for new video (previous: $_currentVideoKey, new: $newKey)',
    );

    // Automatically delete previous video's cache on disk
    final oldKey = _currentVideoKey;
    if (oldKey != null && oldKey != newKey) {
      _deleteVideoDiskCache(oldKey);
    }

    // 1. Cancel all active download tokens
    for (final token in _cancelTokens.values) {
      token.cancel('Video switched, cancelling preload');
    }
    _cancelTokens.clear();

    // 2. Complete any pending download futures with null
    for (final completer in _pendingDownloads.values) {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    }
    _pendingDownloads.clear();

    // 3. Clear segment cache and ordered segments
    _segmentCache.clear();
    _orderedSegments.clear();
    _lastRequestedIndex = 0;
    _currentVideoKey = newKey;
    // 上一集的时长不能留到下一集：否则新播放列表还没取回来时，
    // PlayerProvider 会拿旧时长去判断「这一集播完了」。
    _playlistDuration = Duration.zero;
    _playlistHasEndList = false;

    // 4. Cancel next episode preloader if switching away from this series.
    //    (The previous expression could never be true, so a stale next-episode
    //    preload kept downloading in the background after switching series.)
    final newVideoId = newKey?.split('_').first;
    final nextVideoId = _nextVideoKey?.split('_').first;
    if (newKey == null || (nextVideoId != null && nextVideoId != newVideoId)) {
      _cancelNextPreload();
      if (_nextVideoKey != null) {
        _deleteVideoDiskCache(_nextVideoKey!);
      }
    }
  }

  void _cancelNextPreload() {
    for (final token in _nextCancelTokens.values) {
      token.cancel('Series switched');
    }
    _nextCancelTokens.clear();
    _nextOrderedSegments.clear();
    _nextSegmentCache.clear();
    _nextVideoKey = null;
    _isPreloadingNext = false;
    _downloadedNextCount = 0;
    // 换了视频就重新给一次记录机会：上一集的失败不该把这一集的日志闸门焊死。
    _nextPreloadErrorLogged = false;
    _segmentDownloadErrorLogged = false;
  }

  /// Builds a proxied M3U8 URL for the video player.
  /// If the requested episode matches the preloaded next episode, promotes it seamlessly!
  String getProxiedM3u8Url(
    String originalM3u8Url, {
    required String videoId,
    required String episodeName,
  }) {
    final newKey = '${videoId}_$episodeName';
    if (_currentVideoKey != newKey) {
      final diskDir = Directory('$_cacheRootDir/$newKey');
      final hasDiskCache =
          diskDir.existsSync() && diskDir.listSync().isNotEmpty;
      if (_nextVideoKey == newKey || hasDiskCache) {
        _promoteNextEpisodeToCurrent(newKey);
      } else {
        resetForNewVideo(newKey);
      }
    }
    final encodedUrl = Uri.encodeComponent(originalM3u8Url);
    final encodedKey = Uri.encodeComponent(newKey);
    return 'http://127.0.0.1:$port/playlist.m3u8?url=$encodedUrl&key=$encodedKey';
  }

  /// Promotes the preloaded next episode into active playback with 0ms buffering!
  void _promoteNextEpisodeToCurrent(String newKey) {
    debugPrint(
      '[HlsPreloadProxy] Promoting preloaded next episode to active: $newKey (with full preloaded disk cache)',
    );

    // REQUIREMENT 4: Automatically delete previous video cache from disk!
    final oldKey = _currentVideoKey;
    if (oldKey != null && oldKey != newKey) {
      _deleteVideoDiskCache(oldKey);
    }

    // 1. Clear previous video workers
    for (final token in _cancelTokens.values) {
      token.cancel('Promoted to next episode');
    }
    _cancelTokens.clear();
    for (final completer in _pendingDownloads.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    _pendingDownloads.clear();
    _segmentCache.clear();
    _orderedSegments.clear();

    // 2. Transfer next episode segments & cache
    _currentVideoKey = newKey;
    _orderedSegments.addAll(_nextOrderedSegments);
    _segmentCache.addAll(_nextSegmentCache);

    // 3. Clear next episode slots
    _nextVideoKey = null;
    _nextOrderedSegments.clear();
    _nextSegmentCache.clear();
    _nextCancelTokens.clear();
    _downloadedNextCount = 0;
    // 这一集已经顶上来了，它自己的预加载失败要重新有机会被记录。
    _nextPreloadErrorLogged = false;

    _lastRequestedIndex = 0;

    // 4. Continue preloading remaining segments of current episode if any
    _schedulePreload(fromIndex: 0);
  }

  /// Automatically preloads the next episode in the background
  Future<void> preloadNextEpisode({
    required String nextM3u8Url,
    required String videoId,
    required String nextEpisodeName,
  }) async {
    final nextKey = '${videoId}_$nextEpisodeName';
    if (_nextVideoKey == nextKey ||
        _currentVideoKey == nextKey ||
        _isPreloadingNext) {
      return;
    }

    _isPreloadingNext = true;
    _nextVideoKey = nextKey;
    _nextOrderedSegments.clear();
    _nextSegmentCache.clear();

    try {
      debugPrint(
        '[HlsPreloadProxy] Background preloading next episode: $nextEpisodeName',
      );
      final resp = await _dio.get<String>(
        nextM3u8Url,
        options: Options(responseType: ResponseType.plain),
      );
      final content = resp.data ?? '';
      final lines = content.split('\n');
      // Same post-redirect base rule as _handlePlaylistRequest.
      final nextBase = _playlistBase(resp.realUri, nextM3u8Url);

      // Check if master playlist
      String actualMediaUrl = nextM3u8Url;
      if (content.contains('#EXT-X-STREAM-INF')) {
        for (final line in lines) {
          final t = line.trim();
          if (t.isNotEmpty && !t.startsWith('#')) {
            actualMediaUrl = Uri.parse(nextBase).resolve(t).toString();
            break;
          }
        }
        final subResp = await _dio.get<String>(
          actualMediaUrl,
          options: Options(responseType: ResponseType.plain),
        );
        final subLines = (subResp.data ?? '').split('\n');
        final subBase = _playlistBase(subResp.realUri, actualMediaUrl);
        for (final l in subLines) {
          final st = l.trim();
          if (st.isNotEmpty && !st.startsWith('#')) {
            _nextOrderedSegments.add(Uri.parse(subBase).resolve(st).toString());
          }
        }
      } else {
        for (final l in lines) {
          final st = l.trim();
          if (st.isNotEmpty && !st.startsWith('#')) {
            _nextOrderedSegments.add(
              Uri.parse(nextBase).resolve(st).toString(),
            );
          }
        }
      }

      // Preload only the FIRST slices of the next episode into disk cache.
      // Writing a whole episode (up to ~1GB) to the TV's flash while decoding
      // the current one was a major source of stutter.
      final total = _nextOrderedSegments.length;
      final preloadTarget = total < maxNextEpisodePreloadSegments
          ? total
          : maxNextEpisodePreloadSegments;
      debugPrint(
        '[HlsPreloadProxy] Preloading first $preloadTarget / $total segments of next episode: $nextEpisodeName',
      );
      final dir = Directory('$_cacheRootDir/$nextKey');
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }

      int nextIdx = 0;
      const int preloadWorkers =
          1; // 1 gentle worker to avoid TV CPU / disk I/O contention

      Future<void> worker() async {
        while (_nextVideoKey == nextKey && nextIdx < preloadTarget) {
          final i = nextIdx++;
          final segUrl = _nextOrderedSegments[i];
          final file = File('$_cacheRootDir/$nextKey/seg_$i.ts');
          if (file.existsSync() && file.lengthSync() > 1000) {
            continue; // Already downloaded
          }

          final cancelToken = CancelToken();
          _nextCancelTokens[i] = cancelToken;

          try {
            final segResp = await _dio.get<List<int>>(
              segUrl,
              cancelToken: cancelToken,
              options: Options(responseType: ResponseType.bytes),
            );
            if (_nextVideoKey == nextKey && segResp.data != null) {
              final bytes = Uint8List.fromList(segResp.data!);
              await file.writeAsBytes(bytes);
              if (i < 3) {
                // Keep first 3 in memory for instant start
                _nextSegmentCache[i] = bytes;
              }
              _downloadedNextCount++;
              if (_downloadedNextCount % 15 == 0 ||
                  _downloadedNextCount == total) {
                debugPrint(
                  '[HlsPreloadProxy] Next episode preload: $_downloadedNextCount / $total segments',
                );
              }
            }
          } catch (e) {
            // 下一集预加载是 best-effort：这一段没缓存下来，等真正播到它时还能现拉。
            // 但**不能一声不吭** —— 下面那句「Next episode preload finished
            // (x / total)」照样会打印，不记原因的话，看到「finished」却只有
            // 3/40 段，根本无从下手。每个分片都走这里，所以只记第一次。
            if (!_nextPreloadErrorLogged) {
              _nextPreloadErrorLogged = true;
              debugPrint(
                '[HlsPreloadProxy] Next episode segment $i download failed (后续同类失败不再重复记录): $e',
              );
            }
          } finally {
            _nextCancelTokens.remove(i);
          }
          // Yield CPU to active video player
          await Future.delayed(const Duration(milliseconds: 150));
        }
      }

      await Future.wait(List.generate(preloadWorkers, (_) => worker()));
      debugPrint(
        '[HlsPreloadProxy] Next episode preload finished for $nextEpisodeName ($_downloadedNextCount / $total segments)',
      );
    } catch (e) {
      debugPrint('[HlsPreloadProxy] Next episode preload error: $e');
    } finally {
      _isPreloadingNext = false;
    }
  }

  /// Dispatches incoming requests
  Future<void> _handleRequest(HttpRequest req) async {
    // Add CORS headers for players
    req.response.headers.set('Access-Control-Allow-Origin', '*');
    req.response.headers.set(
      'Access-Control-Allow-Methods',
      'GET, HEAD, OPTIONS',
    );
    req.response.headers.set('Access-Control-Allow-Headers', '*');

    if (req.method == 'OPTIONS') {
      req.response.statusCode = HttpStatus.ok;
      await req.response.close();
      return;
    }

    final path = req.uri.path;
    try {
      if (path.endsWith('.m3u8') || path == '/playlist.m3u8') {
        await _handlePlaylistRequest(req);
      } else if (path.endsWith('.ts') || path == '/segment.ts') {
        await _handleSegmentRequest(req);
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    } catch (e) {
      debugPrint('[HlsPreloadProxy] Error handling request $path: $e');
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  /// Base URL used to resolve relative playlist entries.
  ///
  /// Some CDN lines 302-redirect the playlist to a sibling node (same path and
  /// query, different port). Relative segment names MUST be resolved against
  /// the POST-redirect URL: the original node answers segment requests with a
  /// 3-byte `OK\n` stub instead of media bytes, so resolving against the
  /// pre-redirect URL yields a playlist whose slices never decode.
  String _playlistBase(Uri realUri, String fallback) {
    final real = realUri.toString();
    return real.isEmpty ? fallback : real;
  }

  /// Handles M3U8 playlist fetch and URL rewriting
  Future<void> _handlePlaylistRequest(HttpRequest req) async {
    final upstreamUrl = req.uri.queryParameters['url'];
    final key = req.uri.queryParameters['key'];

    if (upstreamUrl == null || upstreamUrl.isEmpty) {
      req.response.statusCode = HttpStatus.badRequest;
      req.response.write('Missing url parameter');
      await req.response.close();
      return;
    }

    if (key != null && key != _currentVideoKey) {
      resetForNewVideo(key);
    }

    // Fetch upstream M3U8
    final resp = await _dio.get<String>(
      upstreamUrl,
      options: Options(responseType: ResponseType.plain),
    );
    final content = resp.data ?? '';
    // Resolve relative entries against the FINAL (post-redirect) URL.
    final baseUrl = _playlistBase(resp.realUri, upstreamUrl);

    // Check if master playlist
    final isMaster = content.contains('#EXT-X-STREAM-INF');
    final lines = content.split('\n');
    final buffer = StringBuffer();

    if (isMaster) {
      // Rewrite sub-playlist URLs
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) {
          buffer.writeln(line);
        } else {
          final resolvedSub = Uri.parse(baseUrl).resolve(trimmed).toString();
          final localSub =
              'http://127.0.0.1:$port/playlist.m3u8?url=${Uri.encodeComponent(resolvedSub)}&key=${Uri.encodeComponent(_currentVideoKey ?? "")}';
          buffer.writeln(localSub);
        }
      }
    } else {
      // Media playlist with TS slices
      final newSegments = <String>[];
      int segIndex = 0;
      // 顺手统计总时长与是否为有限流（见 _playlistDuration 的说明）。
      var extinfMicros = 0;
      var hasEndList = false;

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) {
          if (trimmed.startsWith('#EXTINF:')) {
            final raw = trimmed.substring(8).split(',').first.trim();
            final secs = double.tryParse(raw);
            if (secs != null && secs > 0) {
              extinfMicros += (secs * 1000000).round();
            }
          } else if (trimmed.startsWith('#EXT-X-ENDLIST')) {
            hasEndList = true;
          }
          // If encryption key URI is present, keep as is or resolve to absolute
          if (trimmed.startsWith('#EXT-X-KEY:')) {
            final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(trimmed);
            if (uriMatch != null) {
              final keyUri = uriMatch.group(1)!;
              final absKeyUri = Uri.parse(baseUrl).resolve(keyUri).toString();
              buffer.writeln(trimmed.replaceAll(keyUri, absKeyUri));
              continue;
            }
          }
          buffer.writeln(line);
        } else {
          // TS segment
          final absSegUrl = Uri.parse(baseUrl).resolve(trimmed).toString();
          newSegments.add(absSegUrl);

          final localSegUrl =
              'http://127.0.0.1:$port/segment.ts?idx=$segIndex&key=${Uri.encodeComponent(_currentVideoKey ?? "")}';
          buffer.writeln(localSegUrl);
          segIndex++;
        }
      }

      _playlistDuration = Duration(microseconds: extinfMicros);
      _playlistHasEndList = hasEndList;

      // Only re-index when the playlist content actually changed.
      // Re-indexing an unchanged playlist is not harmless: ExoPlayer re-fetches
      // the playlist on retry / ABR variant switch, and a re-index would remap
      // in-flight `?idx=N` requests onto different slices (garbled video, decode
      // errors, re-buffer loops). If it DID change (variant switch), the cached
      // slices belong to the old variant and must be dropped.
      if (!_sameSegments(newSegments, _orderedSegments)) {
        for (final token in _cancelTokens.values) {
          token.cancel('Playlist changed');
        }
        _cancelTokens.clear();
        for (final completer in _pendingDownloads.values) {
          if (!completer.isCompleted) completer.complete(null);
        }
        _pendingDownloads.clear();
        _segmentCache.clear();
        _orderedSegments
          ..clear()
          ..addAll(newSegments);
        _lastRequestedIndex = 0;
        debugPrint(
          '[HlsPreloadProxy] Loaded ${_orderedSegments.length} segments. Triggering initial preload pool.',
        );
        _schedulePreload(fromIndex: 0);
      }
    }

    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentType = ContentType(
      'application',
      'vnd.apple.mpegurl',
    );
    req.response.write(buffer.toString());
    await req.response.close();
  }

  /// Handles TS segment request from the player
  Future<void> _handleSegmentRequest(HttpRequest req) async {
    final idxStr = req.uri.queryParameters['idx'];
    final idx = int.tryParse(idxStr ?? '');

    if (idx == null || idx < 0 || idx >= _orderedSegments.length) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }

    _lastRequestedIndex = idx;

    // Keep workers preloading ahead of the current position.
    // The window starts at idx + 1 on purpose: the slice the player is asking
    // for right now is served by this handler, and letting the scheduler
    // dispatch it as well would download the very same slice twice.
    _schedulePreload(fromIndex: idx + 1);

    // 0. Check if already preloaded on DISK (from next-episode preload)
    final videoKey = req.uri.queryParameters['key'] ?? _currentVideoKey ?? '';
    final diskFile = File('$_cacheRootDir/$videoKey/seg_$idx.ts');
    if (diskFile.existsSync() && diskFile.lengthSync() > 1000) {
      try {
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType('video', 'mp2t');
        req.response.headers.contentLength = diskFile.lengthSync();
        req.response.headers.add('Access-Control-Allow-Origin', '*');
        req.response.headers.add('Cache-Control', 'public, max-age=86400');
        req.response.bufferOutput = false;
        await req.response.addStream(diskFile.openRead());
        await req.response.close();
      } catch (_) {}
      return;
    }

    // 1. Check if already cached in memory
    final cached = _segmentCache[idx];
    if (cached != null) {
      _sendSegmentResponse(req, cached, videoKey, idx);
      return;
    }

    // 2. A preload worker was already fetching this slice (it was inside the
    //    window when the player asked for the previous one). Wait for it
    //    instead of firing a second parallel request. The old code gave up
    //    after 4s and started a duplicate download, which doubled bandwidth
    //    usage on slow CDNs and fed the stutter loop.
    final pending = _pendingDownloads[idx];
    if (pending != null) {
      Uint8List? downloaded;
      try {
        // Bounded by Dio's connect/receive timeouts, and released early by
        // resetForNewVideo(), so this can never hang indefinitely.
        downloaded = await pending.future;
      } catch (_) {
        // 这里**故意**不记日志：_pendingDownloads 里装的是 Completer<Uint8List?>，
        // 只会被 complete(bytes) 或 complete(null) 完成，从来没有 completeError，
        // 所以 pending.future 实际抛不出异常 —— 这个 catch 只是防御性的。
        // 真正的失败原因已经在 _startWorkerDownload 的 catchError 里记过了，
        // 这里再记一遍只会是重复噪音。
        downloaded = null;
      }
      if (downloaded != null) {
        _sendSegmentResponse(req, downloaded, videoKey, idx);
        return;
      }
    }

    // 3. Not buffered yet: stream the CDN response straight into the player.
    //    The old code downloaded the whole slice into memory first and only
    //    then forwarded it, so the decoder saw zero bytes until the proxy had
    //    the entire slice — an avoidable per-slice stall.
    await _streamSegmentToPlayer(req, idx);
  }

  /// Streams a segment straight from the CDN into the player's response body.
  ///
  /// Chunks are forwarded as they arrive (no full-slice buffering, no extra
  /// copy), so the decoder can start on the first bytes.
  Future<void> _streamSegmentToPlayer(HttpRequest req, int idx) async {
    final segUrl = _orderedSegments[idx];

    final cancelToken = CancelToken();
    _cancelTokens[idx] = cancelToken;

    ResponseBody? body;
    try {
      final resp = await _dio.get<ResponseBody>(
        segUrl,
        cancelToken: cancelToken,
        options: Options(responseType: ResponseType.stream),
      );
      body = resp.data;
    } catch (e) {
      debugPrint(
        '[HlsPreloadProxy] Failed to open stream for segment $idx: $e',
      );
    }

    if (body == null) {
      // Transparent fallback: redirect player directly to the original CDN URL
      try {
        await req.response.redirect(Uri.parse(segUrl));
      } catch (_) {
        try {
          req.response.statusCode = HttpStatus.gatewayTimeout;
          await req.response.close();
        } catch (_) {}
      }
      _cancelTokens.remove(idx);
      return;
    }

    try {
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType = ContentType('video', 'mp2t');
      req.response.headers.add('Access-Control-Allow-Origin', '*');
      req.response.headers.add('Cache-Control', 'public, max-age=86400');
      req.response.bufferOutput = false;
      await req.response.addStream(body.stream);
    } catch (e) {
      // Player closed the connection (seek / stop / source switch): drop it.
      debugPrint('[HlsPreloadProxy] Stream for segment $idx ended early: $e');
      try {
        cancelToken.cancel('Player closed connection');
      } catch (_) {}
    } finally {
      try {
        await req.response.close();
      } catch (_) {}
      _cancelTokens.remove(idx);
    }
  }

  /// True when both lists hold the same segment URLs in the same order.
  static bool _sameSegments(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _sendSegmentResponse(
    HttpRequest req,
    Uint8List bytes, [
    String? videoKey,
    int? idx,
  ]) {
    try {
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType = ContentType('video', 'mp2t');
      req.response.headers.contentLength = bytes.length;
      req.response.headers.add('Access-Control-Allow-Origin', '*');
      req.response.headers.add('Cache-Control', 'public, max-age=86400');
      req.response.bufferOutput = false;
      req.response.add(bytes);
      req.response.close();
    } catch (_) {}
  }

  /// Dynamic burst-then-gentle preload scheduler:
  /// - Burst on start-up or when the buffer is genuinely empty (< 3 slices).
  /// - Throttle to 2 gentle workers once the buffer is healthy, so the TV CPU
  ///   and the hardware decoder stay uncontended.
  void _schedulePreload({int? fromIndex}) {
    if (_orderedSegments.isEmpty) return;

    // Default window starts just after the slice the player last asked for:
    // that slice is owned by the request handler, never by the scheduler.
    final startIdx = fromIndex ?? (_lastRequestedIndex + 1);
    final endIdx = (startIdx + preloadAheadCount).clamp(
      0,
      _orderedSegments.length,
    );
    if (startIdx >= endIdx) return;

    // Clean up segments that are behind current playback position to free RAM
    _evictOldSegments(startIdx);

    // Count slices that are cached OR already being downloaded.
    // Counting in-flight downloads is essential: the previous version only
    // counted cached slices and stopped at the first gap, so a single missing
    // slice made the buffer look empty and re-armed a full burst on *every*
    // segment request — the main CPU/network contention source on TV boxes.
    int bufferedAhead = 0;
    for (int i = startIdx; i < endIdx; i++) {
      if (_segmentCache.containsKey(i) || _pendingDownloads.containsKey(i)) {
        bufferedAhead++;
      } else {
        break;
      }
    }

    // Enough buffered ahead (> 2.5 minutes): pause preloading to save resources.
    if (bufferedAhead >= preloadPauseAhead) return;

    final targetConcurrency = (bufferedAhead < 3) ? maxConcurrentWorkers : 2;

    // Check available worker slots
    final activeCount = _pendingDownloads.length;
    final availableWorkers = targetConcurrency - activeCount;
    if (availableWorkers <= 0) return;

    // Find segments needing download within the preload window
    int dispatched = 0;
    for (int i = startIdx; i < endIdx && dispatched < availableWorkers; i++) {
      if (!_segmentCache.containsKey(i) && !_pendingDownloads.containsKey(i)) {
        _startWorkerDownload(i);
        dispatched++;
      }
    }
  }

  void _startWorkerDownload(int index) {
    if (index >= _orderedSegments.length) return;

    final segUrl = _orderedSegments[index];
    final completer = Completer<Uint8List?>();
    final cancelToken = CancelToken();

    _pendingDownloads[index] = completer;
    _cancelTokens[index] = cancelToken;

    _dio
        .get<List<int>>(
          segUrl,
          cancelToken: cancelToken,
          options: Options(responseType: ResponseType.bytes),
        )
        .then((resp) {
          final bytes = Uint8List.fromList(resp.data ?? []);
          _segmentCache[index] = bytes;
          if (!completer.isCompleted) completer.complete(bytes);
        })
        .catchError((err) {
          // 这里原来把 err 整个丢掉了：worker 失败 → complete(null) →
          // _handleSegmentRequest 看到 null 就悄悄改走直连兜底。画面还能出，但
          // 「预加载为什么总是不命中、这台电视为什么特别卡」就永远查不出来了。
          // 兜底行为保持不变（仍然 complete(null)），只补可见性；每个分片一次，
          // 所以只记第一次。
          if (!_segmentDownloadErrorLogged) {
            _segmentDownloadErrorLogged = true;
            debugPrint(
              '[HlsPreloadProxy] Preload worker for segment $index failed (后续同类失败不再重复记录): $err',
            );
          }
          if (!completer.isCompleted) completer.complete(null);
        })
        .whenComplete(() {
          _pendingDownloads.remove(index);
          _cancelTokens.remove(index);

          // A worker slot has freed up: trigger next preload segment!
          _schedulePreload();
        });
  }

  /// Keeps memory usage clean by evicting segments outside the preload window.
  /// (Previously gated on `length > maxMemorySegments`, which combined with a
  /// 20-slice window let the in-memory cache grow unchecked on TV boxes.)
  void _evictOldSegments(int currentIndex) {
    if (_segmentCache.isEmpty) return;
    final keysToRemove = <int>[];
    for (final idx in _segmentCache.keys) {
      if (idx < currentIndex - 2 ||
          idx > currentIndex + preloadAheadCount + 2) {
        keysToRemove.add(idx);
      }
    }
    for (final k in keysToRemove) {
      _segmentCache.remove(k);
    }
  }

  /// Stops server and cleans up all resources
  Future<void> dispose() async {
    resetForNewVideo();
    await _server?.close(force: true);
    _server = null;
  }
}
