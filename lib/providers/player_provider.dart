import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/vod_detail.dart';
import '../models/play_source.dart';
import '../models/history_item.dart';
import '../services/video_site_scraper.dart';
import '../services/source_speed_tester.dart';
import '../services/storage_service.dart';
import '../services/hls_preload_proxy.dart';
import '../services/sync_service.dart';
import '../services/playback_watchdog.dart';
import '../services/playback_resume.dart';

/// TV Player Provider powered by Google's native ExoPlayer (video_player)
/// Features:
/// 1. Native ExoPlayer hardware decoding with zero memory leak and zero flower-screen artifacts.
/// 2. Integrates with localhost HlsPreloadProxy for 10-concurrency extreme fast pre-buffering.
/// 3. Fully optimized for 32-bit (armeabi-v7a) and 64-bit Android TVs and mobile phones.
/// 4. Auto-failover on stream errors, breakpoint resume, and customizable skip intro/outro.
class PlayerProvider extends ChangeNotifier with WidgetsBindingObserver {
  final VideoSiteScraper _scraper = VideoSiteScraper();
  final StorageService _storage = StorageService.instance;

  VideoPlayerController? _controller;
  VideoPlayerController? get controller => _controller;

  final VodDetail detail;
  final List<PlaySource> allSources;
  int currentEpisodeIndex;
  int currentSourceIndex;

  bool _isDisposed = false;
  bool _isLoading = true;
  bool get isLoading => _isLoading;

  String? _currentPlayUrl;
  String? get currentPlayUrl => _currentPlayUrl;

  String _statusMessage = '正在优选可播放线路...';
  String get statusMessage => _statusMessage;

  // Tested & sorted sources
  List<TestedPlaySource> _rankedSources = [];
  List<TestedPlaySource> get rankedSources => _rankedSources;
  int _activeRankedIndex = 0;

  // TV OSD Controls visibility
  bool _showOsd = false;
  bool get showOsd => _showOsd;
  Timer? _osdTimer;

  // TV Quick Seek Indicator (Continuous long-press seek support)
  bool _showSeekIndicator = false;
  bool get showSeekIndicator => _showSeekIndicator;
  int _seekDeltaSeconds = 0;
  int get seekDeltaSeconds => _seekDeltaSeconds;
  Duration _baseSeekPosition = Duration.zero;

  Duration get seekTargetPosition {
    if (!_showSeekIndicator) return position;
    final base = _baseSeekPosition > Duration.zero
        ? _baseSeekPosition
        : position;
    final target = base + Duration(seconds: _seekDeltaSeconds);
    final total = duration;
    if (target < Duration.zero) return Duration.zero;
    if (total > Duration.zero && target > total) return total;
    return target;
  }

  Timer? _seekIndicatorTimer;

  // Playback state helpers
  bool get isInitialized =>
      _controller != null && _controller!.value.isInitialized;
  bool get isPlaying => _controller != null && _controller!.value.isPlaying;
  Duration get position =>
      _controller != null ? _controller!.value.position : _lastPosition;

  /// 对外暴露的时长（进度条、快进快退的边界、拖动落点都用它）。
  ///
  /// 必须和自动续播用同一套取值（见 [_effectiveDuration]）：播放器上报 0 时
  /// 退回代理统计的 `#EXTINF` 总和。否则会出现很别扭的自相矛盾 ——
  /// 续播逻辑认为「这一集有 121 秒」，而进度条和拖动用的是 0 秒，
  /// 于是进度条永远是空的、拖到底也算不出落点，
  /// 用户根本没法「拖到最后 2 秒」，快进也没有上界。
  Duration get duration => _controller != null
      ? _effectiveDuration(_controller!.value.duration)
      : Duration.zero;
  bool get isBuffering => _controller != null && _controller!.value.isBuffering;

  // 线路「加载超时」看门狗：某条线路开始加载后 10 秒仍没起来就自动换源。
  // 之前这里叫 _stallTimer（缓冲卡顿检测），但从未被 start 过，是死代码；
  // 现在把它改成真正会启动的加载看门狗。
  Timer? _loadWatchdog;
  Timer? _playbackWatchdogTimer;
  final PlaybackWatchdog _playbackWatchdog = PlaybackWatchdog();
  final Stopwatch _playbackClock = Stopwatch();
  bool _playRequested = true;
  bool _appForeground = true;
  bool _isRecovering = false;
  int _recoveryToken = 0;
  int _sameSourceReconnects = 0;
  Duration _reconnectPosition = Duration.zero;
  static const Duration sourceLoadTimeout = Duration(seconds: 10);
  // 已经试过并失败的线路名，避免自动切源在 allSources 里绕圈。
  final Set<String> _failedSourceNames = <String>{};

  // --- 切换闸门 ---------------------------------------------------------
  //
  // 一次「切集 / 换源」正在飞行中。
  //
  // 为什么必须有：触发自动续播的入口有四个（片尾跳过、播完、解码错误、加载超时），
  // 而 selectEpisode / selectSource 都是在**第一个 await 之前**就把
  // currentEpisodeIndex / currentSourceIndex 改掉、然后去解析 m3u8 的。解析一次要
  // 1~3 秒；这段时间里旧控制器仍挂在监听器上、仍会回调，于是第二个入口又触发一次、
  // 索引再加一 —— 表现为「第 1 集直接跳到第 12 集」。错误路径上的
  // autoSwitchNextSource 同理，会被连按、一口气烧掉所有线路。
  //
  // 注意：这**不是**「video_player 播完后位置轮询不停」造成的。查过源码，
  // completed 事件会走 pause()，那个 100ms 的位置定时器随之取消；真正的成因是
  // 上面这条重入路径。
  bool _isSwitching = false;

  // 每次 _playUrl 递增，只有最后一次能真正创建播放器。
  //
  // 并发起来的多个 _playUrl 会各自 new 一个 controller，而前一个 controller 的
  // 引用已经被「上一次把 _controller 置空」丢掉了，于是没人 dispose 它 ——
  // 旧播放器继续出声，用户就能听到「后台还有其他视频的声音」。
  int _playGeneration = 0;

  // 本集真正开始播放的时刻，用来给自动续播加一道「最小停留时间」。
  //
  // 为什么不靠 duration 判断就够：上面两个闸门都建立在「播放器上报的 duration
  // 是可信的」这个前提上。但 duration 有可能不可信 —— 比如线路给的是滚动窗口
  // 型播放列表（没有 #EXT-X-ENDLIST），ExoPlayer 上报的 duration 就只是当前
  // 窗口的长度（实测该 2K 线路是 54~133 秒）。此时「position 已经到底」并不
  // 代表这一集真的播完了，仅靠 duration 做判断会误判。
  //
  // 这道闸门不看 duration，只看「这一集是不是刚开播」：真实的一集不可能在
  // 20 秒内播完，所以 20 秒内的任何「已到片尾 / 已播完」都一定是误判。
  DateTime? _episodeStartedAt;
  static const Duration minEpisodeDwell = Duration(seconds: 20);

  /// 「这一集快放完了」的兜底窗口：位置进入片尾最后 [autoNextTail] 就切下一集。
  ///
  /// 为什么是 2 秒而不是原来那 600 毫秒：不同机型 / 解码器上，最后一次位置回调
  /// 与 completed 事件之间差个几百毫秒是常态，600ms 的窗口会漏掉 ——
  /// 表现就是「一集放完了不会自动下一集」。
  ///
  /// 为什么同时保留 `value.isCompleted` 这个信号：duration 拿不到时（播放器报 0、
  /// 代理也没统计到）位置比较无从谈起，只有 completed 是可信的。两个信号取「或」，
  /// 互为兜底。
  static const Duration autoNextTail = Duration(seconds: 2);

  /// 敢用「片尾 2 秒」做续播判断所需的最短片长。
  ///
  /// 真实剧集不可能短于 30 秒；报出更短的时长只可能是站点或播放器给错了。
  /// 这种情况下任何「位置已经到片尾」的判断都不可信 —— 会在第 3 秒就一路续播，
  /// 把整季瞬间跳完。
  ///
  /// 用「时长下限」而不是「本集已播够 20 秒」来挡这种误判，是为了放行用户
  /// 明确要的场景：**刚点开就快进 / 拖进度条到片尾**。
  static const Duration minPlausibleEpisode = Duration(seconds: 30);

  /// 本集是否已经为「播放结束」打过诊断日志（每集只打一次，避免刷屏）。
  bool _loggedCompleted = false;

  /// 是否已经打过「播放器上报 0 时长」的诊断日志（每集只打一次）。
  bool _loggedZeroDuration = false;

  /// 是否已经打过「已经是最后一集」的诊断日志。
  bool _loggedLastEpisode = false;

  Duration _lastPosition = Duration.zero;
  DateTime? _lastSeekTime;
  bool _isSeeking = false;
  bool _hasTriggeredOutroSkip = false;
  bool _lastPlaying = false;
  bool _lastBuffering = false;
  // 上一次打过诊断日志的整十秒，避免同一秒内重复打印。
  int _lastDiagSecond = -1;

  int get skipIntroSeconds => _storage.getSkipIntroSeconds();
  int get skipOutroSeconds => _storage.getSkipOutroSeconds();

  Future<void> updateSkipIntro(int seconds) async {
    await _storage.setSkipIntroSeconds(seconds);
    notifyListeners();
  }

  Future<void> updateSkipOutro(int seconds) async {
    await _storage.setSkipOutroSeconds(seconds);
    notifyListeners();
  }

  // --- 播放倍速 -----------------------------------------------------------
  //
  // 这是一项**默认值**：设置一次，之后每一集、每一次换源都按它起播。
  // 每次 `_playUrl` 新建的控制器默认是 1.0x，所以必须在 `initialize()` 之后
  // 重新下发一次（见 `_playUrl` 里的 `setPlaybackSpeed`）。

  double get playbackSpeed => _storage.getPlaybackSpeed();

  /// 设置倍速。立即作用于当前这一集，并作为后续每一集的默认值。
  Future<void> setPlaybackSpeed(double speed) async {
    final clamped = speed.clamp(
      StorageService.minPlaybackSpeed,
      StorageService.maxPlaybackSpeed,
    );
    await _storage.setPlaybackSpeed(clamped);
    // 还没 initialize 的控制器不能收倍速（插件那边 _playerId 还没分配）。
    final c = _controller;
    if (c != null && c.value.isInitialized) {
      await c.setPlaybackSpeed(clamped);
    }
    debugPrint('[PlayerProvider] Playback speed set to ${clamped}x');
    notifyListeners();
  }

  PlayerProvider({
    required this.detail,
    required this.allSources,
    required this.currentSourceIndex,
    required this.currentEpisodeIndex,
  }) {
    WidgetsBinding.instance.addObserver(this);
    _playbackClock.start();
    _playbackWatchdogTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _checkPlaybackHealth(),
    );
    _startSourceOptimization();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appForeground = state == AppLifecycleState.resumed;
    _playbackWatchdog.reset();
  }

  void _checkPlaybackHealth() {
    if (_isDisposed) return;
    // A failed seek may stop callbacks too; the timer must release this guard.
    if (_isSeeking &&
        _lastSeekTime != null &&
        DateTime.now().difference(_lastSeekTime!) >
            const Duration(seconds: 5)) {
      _isSeeking = false;
    }
    final value = _controller?.value;
    final enabled =
        value != null &&
        value.isInitialized &&
        _playRequested &&
        _appForeground &&
        !_isLoading &&
        !_isSwitching &&
        !_isRecovering &&
        !_isSeeking &&
        !_isScrubbing &&
        !_showSeekIndicator &&
        !value.isCompleted &&
        (_lastSeekTime == null ||
            DateTime.now().difference(_lastSeekTime!) >
                const Duration(seconds: 5));
    if (enabled &&
        value.position - _reconnectPosition >= const Duration(seconds: 30)) {
      _sameSourceReconnects = 0;
    }
    if (_playbackWatchdog.check(
      now: _playbackClock.elapsed,
      position: value?.position ?? _lastPosition,
      enabled: enabled,
    )) {
      unawaited(_reconnectCurrentEpisode());
    }
  }

  void _cancelRecovery() {
    _recoveryToken++;
    _isRecovering = false;
    _playbackWatchdog.reset();
  }

  Future<void> _reconnectCurrentEpisode() async {
    if (_isDisposed || _isSwitching || _isRecovering || !_playRequested) return;
    if (_sameSourceReconnects >= 2) {
      await autoSwitchNextSource(reason: '播放持续卡住，正在切换线路并恢复进度');
      return;
    }
    _isRecovering = true;
    _isSwitching = true;
    _isLoading = true;
    final token = ++_recoveryToken;
    final sourceName = currentSource.name;
    final playPath = currentEpisode.playPath;
    final resume = position > Duration.zero ? position : _lastPosition;
    _lastPosition = resume;
    _reconnectPosition = resume;
    _sameSourceReconnects++;
    _saveCurrentHistory();
    _statusMessage = '播放卡住，正在重新连接并恢复进度...';
    notifyListeners();
    try {
      // Refresh expiring stream URLs, not just the existing connection.
      final url = await _scraper
          .resolvePlayM3u8(playPath)
          .timeout(const Duration(seconds: 12), onTimeout: () => null);
      if (_isDisposed || token != _recoveryToken) return;
      if (url == null) {
        _isSwitching = false;
        await autoSwitchNextSource(reason: '重新连接失败，正在切换线路并恢复进度');
        return;
      }
      // Recreate the native decoder/surface and discard stalled proxy work.
      HlsPreloadProxy.instance.resetForNewVideo();
      await _playUrl(url, sourceName, resume);
    } catch (error) {
      if (_isDisposed || token != _recoveryToken) return;
      debugPrint('[PlayerProvider] Reconnect failed: $error');
      _isSwitching = false;
      await autoSwitchNextSource(reason: '重新连接失败，正在切换线路并恢复进度');
    } finally {
      if (!_isDisposed && token == _recoveryToken) {
        _isRecovering = false;
        _isSwitching = false;
        _playbackWatchdog.reset();
      }
    }
  }

  /// 本集是否已经播了足够久，久到「已到片尾 / 已播完」可以当真。
  ///
  /// 见 [_episodeStartedAt] 的说明：这道判断不依赖播放器上报的 duration，
  /// 所以即使 duration 不可信（滚动窗口型播放列表）也不会误判。
  bool _hasSettled() {
    final started = _episodeStartedAt;
    if (started == null) return false;
    return DateTime.now().difference(started) >= minEpisodeDwell;
  }

  /// 判断「这一集播完了」时应该用的时长。
  ///
  /// 优先用播放器上报的值（更精确）。但它并不可靠：滚动窗口型的播放列表
  /// （没有 #EXT-X-ENDLIST）会让 ExoPlayer 上报 0 或不断变化的值，而一旦为 0，
  /// 所有 `position >= dur - 600ms` 的判断就永远不会成立 ——
  /// 表现就是「一集放完了不会自动下一集」，且时好时坏（取决于当次拿到的列表类型）。
  ///
  /// 兜底用代理统计出来的 `#EXTINF` 总和：代理本来就要逐行重写播放列表，
  /// 这份数据是免费的，且对滚动窗口来说它等于「当前窗口的长度」，
  /// 随着窗口滚动一起增长，位置追上它就说明这一集确实到头了。
  Duration _effectiveDuration(Duration reported) {
    if (reported > Duration.zero) return reported;
    final fromProxy = HlsPreloadProxy.instance.playlistDuration;
    // 只打一次：这个方法也会被 UI 的 `duration` getter 每帧调到，不设闸门会刷屏。
    if (fromProxy > Duration.zero && !_loggedZeroDuration) {
      _loggedZeroDuration = true;
      debugPrint(
        '[PlayerProvider] Player reported zero duration — '
        'falling back to playlist EXTINF sum (${fromProxy.inSeconds}s, '
        'endlist=${HlsPreloadProxy.instance.playlistHasEndList})',
      );
    }
    return fromProxy;
  }

  void _onControllerUpdate() {
    if (_isDisposed || _controller == null) return;
    final value = _controller!.value;

    if (value.hasError) {
      debugPrint(
        '[PlayerProvider] Native ExoPlayer error: ${value.errorDescription}',
      );

      // 片尾处的取片/解码错误，本质上是「这一集放完了」的另一种表现形式：
      // 最后几秒的分片在 CDN 上经常缺失或签名已过期，ExoPlayer 于是直接报错。
      // 这时该续播下一集，而不是切线路 —— 切过去还是同一段内容，
      // 只会把好线路一条条烧掉，最后报「所有线路都不可用」。
      final errDur = _effectiveDuration(value.duration);
      // 与下面的片尾续播用同一条判据：不看「已播多久」，只看「时长可信 + 位置在片尾」。
      // 这样「快进到片尾时最后一片取不到」也会正常续播，而不是去烧线路。
      final errNearEnd =
          errDur >= minPlausibleEpisode &&
          value.position >= errDur - autoNextTail;
      if (errNearEnd &&
          currentEpisodeIndex + 1 < currentSource.episodes.length) {
        if (_isSwitching) return;
        _isSwitching = true;
        debugPrint(
          '[PlayerProvider] Error near end of episode '
          '(pos=${value.position.inSeconds}s dur=${errDur.inSeconds}s) '
          '— treating as finished, playing next episode.',
        );
        _statusMessage = '正在播放下一集...';
        notifyListeners();
        playNextEpisode();
        return;
      }

      if (!_isSwitching &&
          !_isSeeking &&
          (_lastSeekTime == null ||
              DateTime.now().difference(_lastSeekTime!) >
                  const Duration(seconds: 5))) {
        if (_isRecovering || !_playRequested || !_appForeground) return;
        if (value.isInitialized && !_isLoading) {
          unawaited(_reconnectCurrentEpisode());
        } else {
          autoSwitchNextSource(reason: '当前线路播放失败，已自动切源');
        }
      }
      return;
    }

    if (value.position > Duration.zero) {
      _lastPosition = value.position;
    }

    if (_isSeeking &&
        _lastSeekTime != null &&
        DateTime.now().difference(_lastSeekTime!) >
            const Duration(seconds: 3)) {
      _isSeeking = false;
    }

    // Auto save history periodically
    if (value.position.inSeconds > 0 && value.position.inSeconds % 10 == 0) {
      _saveCurrentHistory();
    }

    // 诊断用：播放中每 10 秒打一行状态。
    // 用于从 logcat 直接判断「为什么没有自动续播」：position/dur 是否在推进、
    // 播放器是不是自己停了、上报的 duration 是不是 0（走没走兜底）。
    if (value.position.inSeconds > 0 &&
        value.position.inSeconds % 10 == 0 &&
        value.position.inSeconds != _lastDiagSecond) {
      _lastDiagSecond = value.position.inSeconds;
      debugPrint(
        '[PlayerProvider] pos=${value.position.inSeconds}s '
        'dur=${_effectiveDuration(value.duration).inSeconds}s'
        '(reported=${value.duration.inSeconds}s) '
        'playing=${value.isPlaying} buffering=${value.isBuffering} '
        'ep=${currentEpisode.name} src=${currentSource.name}',
      );
    }

    // ── 自动续播 ─────────────────────────────────────────────────────────
    final dur = _effectiveDuration(value.duration);
    final reportedDur = value.duration;
    final skipOutro = _storage.getSkipOutroSeconds();
    final introSkip = _storage.getSkipIntroSeconds();
    // 只有「片头 + 片尾」明显短于片长时，跳过片尾才有意义。
    // 旧代码的门槛是固定的 `dur > 120s`：当片长本身只有 1~2 分钟时，片尾阈值
    // `dur - 90s`（如 121.3-90=31.3s）会落在片头跳过的落点（90s）之前，
    // 于是开播瞬间就判「已到片尾」，一集接一集地跳。
    final outroMeaningful = dur > Duration(seconds: introSkip + skipOutro + 10);
    // 不依赖 duration 的兜底：刚开播 20 秒内的「已到片尾」一律视为误判。
    final settled = _hasSettled();
    final hasNext = currentEpisodeIndex + 1 < currentSource.episodes.length;

    // 位置进入片尾最后 [autoNextTail]（默认 2 秒）。
    //
    // 这条**不看** [_hasSettled]（本集已经播了多久）：用户快进、或者手动把
    // 进度条拖到片尾时，本集可能才开播几秒，按「已播时长」判断会拒绝续播，
    // 而这正是用户明确要的行为（「快进到最后 2 秒 / 拖到最后 2 秒 → 下一集」）。
    // 失去的那层保护改用「时长下限」顶上，见 [minPlausibleEpisode]。
    final tailReached =
        dur >= minPlausibleEpisode && value.position >= dur - autoNextTail;
    // 两个信号取「或」，互为兜底：
    //   ① value.isCompleted —— 播放器自己说这一集结束了。
    //      video_player 的实现里，位置更新会被 clamp 到 duration
    //      （_updatePosition：`isCompleted: position == value.duration`），
    //      所以放完时它一定是 true，且不依赖我们这边的时长计算。
    //      这条仍然要求 [settled]：时长报错时它会立刻为 true，是最容易误判的信号。
    //   ② position >= dur - 2s —— 位置兜底。用户要的就是「最后两秒自动下一集」，
    //      比原来 600ms 的窗口宽松得多，最后一次位置回调差几百毫秒也不会漏。
    final reachedEnd = tailReached || (settled && value.isCompleted);

    // 诊断用：播放器报「本集结束」的那一刻打一行，把全部判定依据列出来。
    // 下一轮排查「为什么没自动续播」有这一行就够了。
    if (value.isCompleted && !_loggedCompleted) {
      _loggedCompleted = true;
      debugPrint(
        '[PlayerProvider] COMPLETED '
        'pos=${value.position.inSeconds}s dur=${dur.inSeconds}s '
        'reported=${reportedDur.inSeconds}s '
        'proxy=${HlsPreloadProxy.instance.playlistDuration.inSeconds}s '
        'endlist=${HlsPreloadProxy.instance.playlistHasEndList} '
        'settled=$settled tailReached=$tailReached '
        'epIndex=$currentEpisodeIndex epCount=${currentSource.episodes.length} '
        'switching=$_isSwitching',
      );
    }
    if (reachedEnd && !hasNext && !_loggedLastEpisode) {
      _loggedLastEpisode = true;
      debugPrint(
        '[PlayerProvider] Reached end of last episode '
        '(epIndex=$currentEpisodeIndex, epCount=${currentSource.episodes.length}) '
        '— nothing to advance to.',
      );
    }

    // ① 片尾跳过：用户配置的「提前跳过片尾」（默认 90 秒）。
    //    只在列表足够长时才启用（见 outroMeaningful）。
    if (outroMeaningful &&
        settled &&
        skipOutro > 0 &&
        !_hasTriggeredOutroSkip &&
        hasNext) {
      final outroThreshold = dur - Duration(seconds: skipOutro);
      if (value.position >= outroThreshold) {
        _hasTriggeredOutroSkip = true;
        // 已经在切下一集了就不要再发一次（见 _isSwitching 的说明）。
        if (_isSwitching) return;
        _isSwitching = true;
        debugPrint(
          '[PlayerProvider] Reached outro (last $skipOutro s). '
          'Auto skipping to next episode.',
        );
        _statusMessage = '已到达片尾，自动播放下一集...';
        notifyListeners();
        playNextEpisode();
        return;
      }
    }

    // ② 放到片尾最后 [autoNextTail] / 播放器报告已结束 → 自动下一集。
    if (reachedEnd && hasNext) {
      // 解析下一集要 1~3 秒，期间本次「已播完」的状态会被再次回调到；
      // 没有这道闸门就会一次触发跳好几集（见 _isSwitching 的说明）。
      if (_isSwitching) return;
      _isSwitching = true;
      debugPrint(
        '[PlayerProvider] Episode finished '
        '(isCompleted=${value.isCompleted}, pos=${value.position.inSeconds}s, '
        'dur=${dur.inSeconds}s, reported=${reportedDur.inSeconds}s) '
        '— auto playing next episode.',
      );
      _statusMessage = '正在播放下一集...';
      notifyListeners();
      playNextEpisode();
      return;
    }

    final isPlayingChanged = value.isPlaying != _lastPlaying;
    final isBufferingChanged = value.isBuffering != _lastBuffering;
    _lastPlaying = value.isPlaying;
    _lastBuffering = value.isBuffering;

    // Only notify listeners when UI is visible or critical state changes.
    // Suppressing 60Hz/5Hz full widget tree rebuilds during steady fullscreen playback
    // frees 100% of TV CPU/GPU resources to the hardware video decoder!
    if (_showOsd || _isSeeking || isPlayingChanged || isBufferingChanged) {
      notifyListeners();
    }
  }

  Episode get currentEpisode {
    final src = allSources[currentSourceIndex];
    if (currentEpisodeIndex >= src.episodes.length) {
      return src.episodes.first;
    }
    return src.episodes[currentEpisodeIndex];
  }

  PlaySource get currentSource => allSources[currentSourceIndex];

  /// Prioritizes user's selected/history source, while background testing speeds for failover
  Future<void> _startSourceOptimization() async {
    _isLoading = true;
    notifyListeners();

    try {
      // 1. Retrieve history breakpoint
      final history = _storage.getHistoryForVod(detail.id);
      Duration? resumePos;
      if (history != null && history.positionMs > 2000) {
        final curEpNum = RegExp(r'\d+')
            .firstMatch(currentEpisode.name)
            ?.group(0);
        final histEpNum = RegExp(r'\d+')
            .firstMatch(history.episodeName)
            ?.group(0);
        if (history.episodeName == currentEpisode.name ||
            (curEpNum != null && curEpNum == histEpNum)) {
          resumePos = Duration(milliseconds: history.positionMs);
          debugPrint(
            '[PlayerProvider] Found breakpoint resume: ${history.positionMs}ms for ${history.episodeName}',
          );
        }
      }

      // 1.5 Avoid 2K/4K heavy sources by default if non-heavy sources exist
      if (SourceSpeedTester.isHeavySource(currentSource)) {
        final nonHeavyIdx = allSources.indexWhere(
          (s) => !SourceSpeedTester.isHeavySource(s),
        );
        if (nonHeavyIdx != -1) {
          debugPrint(
            '[PlayerProvider] Bypassing default 2K/4K source ${currentSource.name} in favor of ${allSources[nonHeavyIdx].name}',
          );
          currentSourceIndex = nonHeavyIdx;
        }
      }

      // 2. Play the preferred / history source directly!
      final preferredSource = currentSource;
      _statusMessage = '正在连接线路: ${preferredSource.name} ...';
      notifyListeners();

      final url = await _scraper.resolvePlayM3u8(currentEpisode.playPath);
      if (url != null) {
        await _playUrl(url, preferredSource.name, resumePos);

        // Run the background speed tester to rank backup sources.
        // Delayed on purpose: the probe issues ~30 extra HTTP requests and a few
        // MB of downloads per source list. Running it immediately after start-up
        // stole bandwidth/CPU from the initial buffering and was a visible cause
        // of stutter in the first minute of playback on TV boxes.
        Future.delayed(const Duration(seconds: 30), () {
          if (_isDisposed) return;
          SourceSpeedTester.probeAndRankSources(
            sources: allSources,
            episodeIndex: currentEpisodeIndex,
            scraper: _scraper,
          ).then((ranked) {
            if (!_isDisposed) {
              _rankedSources = ranked;
              notifyListeners();
            }
          });
        });
        return;
      }

      // 3. Fallback: if preferred source failed to resolve, test all sources by download speed
      _statusMessage = '首选线路连接中，正在测速优选最快备用线路...';
      notifyListeners();
      _rankedSources = await SourceSpeedTester.probeAndRankSources(
        sources: allSources,
        episodeIndex: currentEpisodeIndex,
        scraper: _scraper,
        onFirstWorkingSource: (fastest) {
          if (!_isDisposed && _currentPlayUrl == null) {
            final srcIdx = allSources.indexWhere(
              (s) => s.name == fastest.source.name,
            );
            if (srcIdx != -1) currentSourceIndex = srcIdx;
            _playUrl(fastest.playUrl, fastest.source.name, resumePos);
          }
        },
      );

      if (_currentPlayUrl == null && _rankedSources.isNotEmpty) {
        final top = _rankedSources.firstWhere(
          (s) => s.isAvailable,
          orElse: () => _rankedSources.first,
        );
        final srcIdx = allSources.indexWhere((s) => s.name == top.source.name);
        if (srcIdx != -1) currentSourceIndex = srcIdx;
        await _playUrl(top.playUrl, top.source.name, resumePos);
      }
    } catch (e) {
      debugPrint('[PlayerProvider] Source optimization error: $e');
      final url = await _scraper.resolvePlayM3u8(currentEpisode.playPath);
      if (url != null) {
        await _playUrl(url, currentSource.name, null);
      } else {
        _statusMessage = '视频线路解析失败，请按返回键重试';
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _playUrl(
    String m3u8Url,
    String sourceName,
    Duration? startPosition,
  ) async {
    if (_isDisposed) return;
    // 本次播放请求的代号。任何更晚发起的 _playUrl 都会让本次作废。
    final gen = ++_playGeneration;
    _playbackWatchdog.reset();
    _currentPlayUrl = m3u8Url;
    _isLoading = true;
    _hasTriggeredOutroSkip = false;
    // 诊断日志的「每集只打一次」标记也要跟着复位，否则第二集起就看不到日志了。
    _loggedCompleted = false;
    _loggedLastEpisode = false;
    _loggedZeroDuration = false;
    _statusMessage = '正在极速缓冲: $sourceName (${currentEpisode.name})';
    // 起 10 秒加载看门狗：线路起来之前必须有人兜底换源。
    _armLoadWatchdog(sourceName);

    // Apply skip intro if starting from beginning
    final skipIntro = _storage.getSkipIntroSeconds();
    // 片尾秒数在这里只用来判断「这条列表够不够长、配不配跳过片头」（见下方夹取）。
    final skipOutro = _storage.getSkipOutroSeconds();
    Duration? effectiveStart = startPosition;
    if (startPosition == null) {
      if (skipIntro > 0) {
        effectiveStart = Duration(seconds: skipIntro);
        debugPrint(
          '[PlayerProvider] Automatically skipping intro: $skipIntro seconds',
        );
      }
    }

    if (effectiveStart != null && effectiveStart > Duration.zero) {
      _lastPosition = effectiveStart;
    }
    notifyListeners();

    // 1. Ensure 10-worker preload proxy server is started
    await HlsPreloadProxy.instance.ensureStarted();

    // 2. Automatically clear previous video cache and get 10-concurrency proxied URL
    final proxiedUrl = HlsPreloadProxy.instance.getProxiedM3u8Url(
      m3u8Url,
      videoId: detail.id,
      episodeName: currentEpisode.name,
    );

    // 3. Dispose old ExoPlayer controller
    final oldController = _controller;
    _controller = null;
    if (oldController != null) {
      oldController.removeListener(_onControllerUpdate);
      await oldController.dispose();
    }

    // 期间可能有更晚的一次 _playUrl 抢跑。此时必须在这里收手：
    // 再往下走就会 new 出一个没有任何人持有引用的播放器，它会一直出声。
    if (_isDisposed || gen != _playGeneration) return;

    // 到这里本次请求已经赢了：解除切换闸门，允许下一次自动续播。
    _isSwitching = false;

    // 4. Initialize native ExoPlayer
    // 声明在 try 外：catch 里需要用 identical 判断「失败的还是不是当前控制器」。
    VideoPlayerController? newController;
    try {
      newController = VideoPlayerController.networkUrl(
        Uri.parse(proxiedUrl),
        httpHeaders: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        },
        // 用平台视图（真实 SurfaceView）而不是插件默认的 Texture 渲染。
        //
        // 原因：Android 硬解的输出缓冲区要按 16 像素对齐。1080 高的视频，解码器
        // 实际写的是 1088 行；插件把这个「对齐后」的尺寸设成了纹理大小，而
        // AspectRatio 用的是上报的 1080，多出来的那几行就被压进画面下沿，
        // 表现为一条绿边。这是 Flutter 官方长期未修的 issue（flutter/flutter#46628），
        // 电视盒子上尤其常见（见该 issue 日志 set up nativeWindow 590x1046 → 592x1056）。
        //
        // platformView 走的是真正的 SurfaceView，由系统按 VideoSize 裁剪，不存在
        // 这个问题；Flutter 侧用 TLHC / 混合合成，控制栏依然画在视频画面之上。
        //
        // 万一某台设备上出现「全黑」或「控制栏被视频盖住」，把这一行删掉即可
        // 逐位退回原行为（默认值就是 VideoViewType.textureView）。
        viewType: VideoViewType.platformView,
      );

      _controller = newController;
      newController.addListener(_onControllerUpdate);

      await newController.initialize();
      // 期间又被更晚的一次 _playUrl 取代 → 不要再改 UI 状态，也不要 play。
      if (_isDisposed || gen != _playGeneration) return;
      _loadWatchdog?.cancel();
      _loadWatchdog = null;
      _isLoading = false;
      _statusMessage = '正在播放: $sourceName (${currentEpisode.name})';

      // 片头跳过必须在「这条播放列表配得上跳过」时才生效。
      //
      // 默认片头跳过是 90 秒。如果这条线路给的列表只有 1~2 分钟，跳 90 秒就会
      // 只剩几十秒内容，然后立刻「已播完」续下一集 —— 实测日志
      // 16:12:38 第2集 → 16:12:58 第6集 → 16:13:16 第7集，38 秒连跳 4 集。
      //
      // 判据与片尾跳过用同一条：列表短到连「片头 + 片尾」都装不下时，
      // 片头片尾都不跳，老老实实从头播。
      final knownDur = _effectiveDuration(newController.value.duration);
      final safeStart = playbackStartPosition(
        resume: startPosition,
        duration: knownDur,
        skipIntroSeconds: skipIntro,
        skipOutroSeconds: skipOutro,
        tailReserve: autoNextTail,
      );
      _lastPosition = safeStart;
      if (safeStart > Duration.zero) {
        await newController.seekTo(safeStart);
      }
      if (_isDisposed || gen != _playGeneration) return;

      // 恢复用户设定的倍速。新建的控制器一律从 1.0x 起，所以必须每一集都重新
      // 下发一次，否则「设置默认速度」只会对设置的那一集生效。
      final speed = _storage.getPlaybackSpeed();
      if (speed != 1.0) {
        await newController.setPlaybackSpeed(speed);
        debugPrint(
          '[PlayerProvider] Applied playback speed ${speed}x '
          'to ${currentEpisode.name}',
        );
      }

      // 这一集从此刻开始计时。自动续播的两个分支都要求 [_hasSettled]，
      // 所以「刚开播就判已播完」在结构上不可能发生（见 _episodeStartedAt）。
      _episodeStartedAt = DateTime.now();

      if (_isDisposed || gen != _playGeneration) return;
      if (_playRequested) await newController.play();
      if (_isDisposed || gen != _playGeneration) return;
      _playbackWatchdog.reset();
      _showOsdBriefly();
      notifyListeners();

      _checkAndPreloadNextEpisode();
    } catch (e) {
      debugPrint('[PlayerProvider] ExoPlayer initialize error: $e');
      // 只有「这次 _playUrl 创建的控制器仍是当前控制器」时才切源。
      // 若看门狗已经超时切到别的源，本次 initialize() 会因为旧控制器被 dispose
      // 而抛异常，这里再切一次就会变成连环切源、把所有线路一口气试完。
      if (!_isDisposed && identical(_controller, newController)) {
        autoSwitchNextSource(reason: '当前线路解码异常，已自动切源');
      }
    }
  }

  /// Automatically pre-resolves and pre-downloads next episode's first slices in background
  Future<void> _checkAndPreloadNextEpisode() async {
    if (currentEpisodeIndex + 1 >= currentSource.episodes.length) return;
    final gen = _playGeneration;
    final nextEp = currentSource.episodes[currentEpisodeIndex + 1];

    // Wait so current episode buffering gets top priority
    await Future.delayed(const Duration(seconds: 20));
    if (_isDisposed || gen != _playGeneration) return;

    try {
      debugPrint(
        '[PlayerProvider] Resolving next episode: ${nextEp.name} for 10-concurrency preload',
      );
      final nextUrl = await _scraper.resolvePlayM3u8(nextEp.playPath);
      if (nextUrl != null && !_isDisposed && gen == _playGeneration) {
        await HlsPreloadProxy.instance.preloadNextEpisode(
          nextM3u8Url: nextUrl,
          videoId: detail.id,
          nextEpisodeName: nextEp.name,
        );
      }
    } catch (e) {
      debugPrint('[PlayerProvider] Auto-preload next episode error: $e');
    }
  }

  /// 起（或重起）10 秒加载看门狗。
  ///
  /// 触发条件：这条线路开始加载后 [_loadWatchdog] 到点，且期间没有人换过源。
  /// 只有 initialize() 成功才会撤掉它，所以「10 秒没出画面」必然会被兜住。
  void _armLoadWatchdog(String sourceName) {
    _loadWatchdog?.cancel();
    _loadWatchdog = Timer(sourceLoadTimeout, () {
      if (_isDisposed) return;
      // 用户/上一次超时已经换到别的线路了，这次不再重复触发。
      if (currentSource.name != sourceName) return;
      if (isInitialized) return;
      debugPrint(
        '[PlayerProvider] Source load timeout after ${sourceLoadTimeout.inSeconds}s: $sourceName',
      );
      autoSwitchNextSource(
        reason: '线路加载超时（${sourceLoadTimeout.inSeconds}秒），已自动切源',
      );
    });
  }

  /// 测速榜还没出来时的兜底选源。
  ///
  /// [SourceSpeedTester.probeAndRankSources] 是启动 30 秒后才跑的，而 10 秒超时
  /// 恰好落在这个空窗里 —— 此时 [_rankedSources] 还是空列表，旧逻辑会直接判
  /// 「所有线路均尝试完毕」然后卡死。这里直接从 [allSources] 里挑下一条：跳过
  /// 当前线路和已经失败过的，优先非 2K/4K 线路。
  int? _nextFallbackSourceIndex() {
    final cur = currentSource.name;
    int? firstAny;
    for (var i = 0; i < allSources.length; i++) {
      final name = allSources[i].name;
      if (name == cur || _failedSourceNames.contains(name)) continue;
      if (!SourceSpeedTester.isHeavySource(allSources[i])) return i;
      firstAny ??= i;
    }
    return firstAny;
  }

  /// Automatic failover: switches seamlessly to next working source
  Future<void> autoSwitchNextSource({String? reason}) async {
    if (_isDisposed) return;
    // 已经有切换在飞行中：旧播放器的错误回调会连着打，放行会一口气烧掉所有线路。
    if (_isSwitching) return;
    _cancelRecovery();
    _sameSourceReconnects = 0;
    _isSwitching = true;
    _loadWatchdog?.cancel();
    _loadWatchdog = null;

    final currentPos = position;
    final resumePos = currentPos > Duration.zero ? currentPos : _lastPosition;
    _reconnectPosition = resumePos;
    _lastPosition = resumePos;
    _failedSourceNames.add(currentSource.name);
    _activeRankedIndex++;

    // 跳过测速阶段已判定不可用的线路。站点没配源的线路（实测「4K」全站为
    // `src: ""`）在 probeAndRankSources 里会得到 isAvailable=false、playUrl=''，
    // 旧逻辑会拿空 URL 去起一次播放器、失败、再切下一条，白白多等一个来回。
    while (_activeRankedIndex < _rankedSources.length &&
        !_rankedSources[_activeRankedIndex].isAvailable) {
      _activeRankedIndex++;
    }

    if (_activeRankedIndex < _rankedSources.length) {
      final nextSrc = _rankedSources[_activeRankedIndex];
      _statusMessage = reason ?? '线路切换中: ${nextSrc.source.name}';
      notifyListeners();

      final srcIdx = allSources.indexWhere(
        (s) => s.name == nextSrc.source.name,
      );
      if (srcIdx != -1) {
        currentSourceIndex = srcIdx;
      }

      await _playUrl(nextSrc.playUrl, nextSrc.source.name, resumePos);
      return;
    }

    // 测速榜为空（启动 30 秒内）或已用完 —— 直接从原始线路表里挑下一条。
    final fbIdx = _nextFallbackSourceIndex();
    if (fbIdx != null) {
      currentSourceIndex = fbIdx;
      _statusMessage = reason ?? '线路切换中: ${allSources[fbIdx].name}';
      notifyListeners();

      HlsPreloadProxy.instance.resetForNewVideo();
      final url = await _scraper.resolvePlayM3u8(currentEpisode.playPath);
      if (url != null && !_isDisposed) {
        // 同上：await 之后再上一次闸。
        _isSwitching = true;
        await _playUrl(url, allSources[fbIdx].name, resumePos);
        return;
      }
    }

    // 没有下一条可切了：解除闸门，否则后面永远不再自动续播。
    _isSwitching = false;
    _isLoading = false;
    _playRequested = false;
    _statusMessage = '所有线路均尝试完毕，暂无法流畅播放';
    notifyListeners();
  }

  /// Manually select a source
  Future<void> selectSource(int sourceIndex) async {
    if (sourceIndex >= allSources.length) return;
    _cancelRecovery();
    _sameSourceReconnects = 0;
    _reconnectPosition = position;
    _playRequested = true;
    _isSwitching = true;
    currentSourceIndex = sourceIndex;
    _currentPlayUrl = null;
    _isLoading = true;
    _statusMessage = '正在切换至: ${allSources[sourceIndex].name}';
    // 用户手动选的线路 = 重新开始，清掉失败记录，让超时兜底能再挑别的线路。
    _failedSourceNames.clear();
    _loadWatchdog?.cancel();
    _loadWatchdog = null;

    final currentPos = position;
    final resumePos = currentPos > Duration.zero ? currentPos : _lastPosition;
    _lastPosition = resumePos;
    HlsPreloadProxy.instance.resetForNewVideo();
    notifyListeners();

    final url = await _scraper.resolvePlayM3u8(currentEpisode.playPath);
    if (url != null) {
      // 上面这个 await 期间，可能有更早的一次 _playUrl 走到「解除闸门」那一步。
      // 进 _playUrl 之前再上一次闸，保证从此刻到新播放器就位期间闸门一定是关的。
      _isSwitching = true;
      await _playUrl(url, currentSource.name, resumePos);
    } else {
      _isSwitching = false;
      _statusMessage = '该线路解析失败，请尝试其他线路';
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Manually select an episode
  Future<void> selectEpisode(int episodeIndex) async {
    if (episodeIndex >= currentSource.episodes.length) return;
    _cancelRecovery();
    _sameSourceReconnects = 0;
    _reconnectPosition = Duration.zero;
    _playRequested = true;
    // 立刻上闸：从这一刻起到新播放器就位，旧的播放器还挂在监听器上，
    // 它「已播到底」的状态会把自动续播反复唤醒（见 _isSwitching 的说明）。
    _isSwitching = true;
    currentEpisodeIndex = episodeIndex;
    _currentPlayUrl = null;
    _isLoading = true;
    _statusMessage = '正在加载: ${currentEpisode.name}';
    _failedSourceNames.clear();
    _loadWatchdog?.cancel();
    _loadWatchdog = null;

    // Clear previous video's cache and reset proxy
    HlsPreloadProxy.instance.resetForNewVideo();
    _lastPosition = Duration.zero;
    notifyListeners();

    final url = await _scraper.resolvePlayM3u8(currentEpisode.playPath);
    if (url != null) {
      // 同上：await 之后再上一次闸，堵住「更早的 _playUrl 解除闸门」这个窄窗口。
      _isSwitching = true;
      await _playUrl(url, currentSource.name, null);
    } else {
      _isSwitching = false;
      _statusMessage = '选集线路解析失败';
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> playNextEpisode() async {
    if (currentEpisodeIndex + 1 < currentSource.episodes.length) {
      await selectEpisode(currentEpisodeIndex + 1);
    } else {
      // 已经是最后一集：解除闸门，别把自动续播永久锁死。
      _isSwitching = false;
    }
  }

  Future<void> playPreviousEpisode() async {
    if (currentEpisodeIndex > 0) {
      await selectEpisode(currentEpisodeIndex - 1);
    }
  }

  // --- Remote Control OSD ---
  void toggleOsd() {
    _showOsd = !_showOsd;
    notifyListeners();
    if (_showOsd) {
      _resetOsdTimer();
    }
  }

  void _showOsdBriefly() {
    _showOsd = true;
    notifyListeners();
    _resetOsdTimer();
  }

  void _resetOsdTimer() {
    _osdTimer?.cancel();
    // 10 秒：5 秒对遥控器操作来说太短，用户还没走到「换源 / 选集」控制栏就消失了。
    _osdTimer = Timer(const Duration(seconds: 10), () {
      if (!_isDisposed && _showOsd) {
        _showOsd = false;
        notifyListeners();
      }
    });
  }

  void resetOsdTimer() {
    _resetOsdTimer();
  }

  // --- Remote Control Fast-Forward / Continuous Long-press Seeking ---
  void seekForward([int seconds = 10]) {
    final cur = position;
    final total = duration;
    final target = cur + Duration(seconds: seconds);
    final clamped = (total > Duration.zero && target > total) ? total : target;
    seekTo(clamped);
    showQuickSeekPill(seconds);
  }

  void seekBackward([int seconds = 10]) {
    final cur = position;
    final target = cur - Duration(seconds: seconds);
    final clamped = target < Duration.zero ? Duration.zero : target;
    seekTo(clamped);
    showQuickSeekPill(-seconds);
  }

  void startSeekPreview(bool isForward) {
    _seekIndicatorTimer?.cancel();
    _showSeekIndicator = true;
    _baseSeekPosition = position;
    _seekDeltaSeconds = isForward ? 10 : -10;
    notifyListeners();
  }

  void updateSeekPreview(int deltaSeconds) {
    _seekIndicatorTimer?.cancel();
    _showSeekIndicator = true;
    _seekDeltaSeconds += deltaSeconds;
    notifyListeners();
  }

  void commitSeekPreview() {
    if (!_showSeekIndicator && _seekDeltaSeconds == 0) return;
    final target = seekTargetPosition;
    seekTo(target);

    // Keep the pill visible for 1.2s to show confirmed target position
    _seekIndicatorTimer?.cancel();
    _seekIndicatorTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!_isDisposed) {
        _showSeekIndicator = false;
        _seekDeltaSeconds = 0;
        _baseSeekPosition = Duration.zero;
        notifyListeners();
      }
    });
  }

  void showQuickSeekPill(int deltaSeconds) {
    _showSeekIndicator = true;
    _seekDeltaSeconds = deltaSeconds;
    notifyListeners();

    _seekIndicatorTimer?.cancel();
    _seekIndicatorTimer = Timer(const Duration(milliseconds: 1400), () {
      if (!_isDisposed) {
        _showSeekIndicator = false;
        _seekDeltaSeconds = 0;
        _baseSeekPosition = Duration.zero;
        notifyListeners();
      }
    });
  }

  void applySeekDelta(int deltaSeconds) {
    if (deltaSeconds == 0) return;
    final cur = position;
    final total = duration;
    final target = cur + Duration(seconds: deltaSeconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : ((total > Duration.zero && target > total) ? total : target);

    seekTo(clamped);
    showQuickSeekPill(deltaSeconds);
  }

  void seekTo(Duration target) {
    _playbackWatchdog.reset();
    _isSeeking = true;
    _lastSeekTime = DateTime.now();
    // 只在「已经出画面」时才撤掉加载看门狗。加载阶段用户按快进不应该把
    // 10 秒超时换源的保护一并取消掉（否则线路加载失败就再没人兜底了）。
    if (isInitialized) {
      _loadWatchdog?.cancel();
      _loadWatchdog = null;
    }
    _lastPosition = target;
    _controller?.seekTo(target);
    // 注意：这里**不再**调用 _showOsdBriefly()。
    // 控制栏隐藏状态下快进/快退只弹一个轻量提示条（seek pill），
    // 不该把整条控制栏顶出来 —— 那是旧逻辑里让人困惑的地方之一。
  }

  // --- 手指拖动进度 / 左右滑动画面（手机、触摸屏） ---
  // 与遥控器的 startSeekPreview 那套「相对秒数」机制分开：手指拖动是**绝对定位**
  // （按手指在进度条上的比例直接映射到时间），用相对秒数算会漂。
  bool _isScrubbing = false;
  bool get isScrubbing => _isScrubbing;

  Duration _scrubTarget = Duration.zero;

  /// 拖动过程中手指所在的落点。不在拖动中时等于当前播放位置。
  Duration get scrubTarget => _isScrubbing ? _scrubTarget : position;

  bool _wasPlayingBeforeScrub = false;

  Duration _clampToDuration(Duration t) {
    if (t < Duration.zero) return Duration.zero;
    final total = duration;
    if (total > Duration.zero && t > total) return total;
    return t;
  }

  /// 手指按下开始拖动。拖动期间先暂停，落点才看得准；松手后按原状态恢复。
  void beginScrub(Duration target) {
    if (_controller == null || !isInitialized) return;
    _isScrubbing = true;
    _scrubTarget = _clampToDuration(target);
    _wasPlayingBeforeScrub = isPlaying;
    if (_wasPlayingBeforeScrub) {
      _controller!.pause();
    }
    // 拖动期间不让控制栏自动消失（_resetOsdTimer 是私有方法，这里直接取消）。
    _osdTimer?.cancel();
    notifyListeners();
  }

  void updateScrub(Duration target) {
    if (!_isScrubbing) return;
    _scrubTarget = _clampToDuration(target);
    notifyListeners();
  }

  /// 手指抬起：真正落盘 seek，并按拖动前的播放状态恢复。
  void endScrub() {
    if (!_isScrubbing) return;
    final target = _scrubTarget;
    _isScrubbing = false;
    seekTo(target);
    if (_wasPlayingBeforeScrub) {
      _controller?.play();
    }
    _resetOsdTimer();
    notifyListeners();
  }

  void togglePlayPause() {
    if (_controller == null) return;
    if (_controller!.value.isPlaying) {
      _playRequested = false;
      _controller!.pause();
    } else {
      _playRequested = true;
      _controller!.play();
    }
    _playbackWatchdog.reset();
    _showOsdBriefly();
    notifyListeners();
  }

  void _saveCurrentHistory() {
    if (_lastPosition.inSeconds <= 0) return;
    _storage.saveHistory(
      HistoryItem(
        vodId: detail.id,
        title: detail.title,
        cover: detail.cover,
        sourceName: currentSource.name,
        episodeName: currentEpisode.name,
        playPath: currentEpisode.playPath,
        positionMs: _lastPosition.inMilliseconds,
        durationMs: duration.inMilliseconds,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  void dispose() {
    _isDisposed = true;
    _cancelRecovery();
    WidgetsBinding.instance.removeObserver(this);
    _playbackWatchdogTimer?.cancel();
    _playbackClock.stop();
    HlsPreloadProxy.instance.resetForNewVideo();
    _saveCurrentHistory();
    // 退出播放器 = 「我就看到这儿」，是安排一次同步上传最合适的时机。
    // 这里只排一次防抖计时器，不上传：一轮播放会写很多次进度，
    // 真正的上传由 SyncService 的防抖合并成一次。
    SyncService.instance.markDirty();
    _loadWatchdog?.cancel();
    _osdTimer?.cancel();
    _seekIndicatorTimer?.cancel();
    _controller?.removeListener(_onControllerUpdate);
    _controller?.dispose();
    super.dispose();
  }
}
