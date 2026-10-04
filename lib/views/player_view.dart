import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';

import '../models/vod_detail.dart';
import '../models/play_source.dart';
import '../providers/player_provider.dart';
import '../tv_ui/tv_theme.dart';
import '../tv_ui/tv_focus_widget.dart';
import '../tv_ui/ui_adaptive.dart';

class PlayerView extends StatelessWidget {
  final VodDetail detail;
  final List<PlaySource> allSources;
  final int initialSourceIndex;
  final int initialEpisodeIndex;

  const PlayerView({
    super.key,
    required this.detail,
    required this.allSources,
    required this.initialSourceIndex,
    required this.initialEpisodeIndex,
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => PlayerProvider(
        detail: detail,
        allSources: allSources,
        currentSourceIndex: initialSourceIndex,
        currentEpisodeIndex: initialEpisodeIndex,
      ),
      child: const _PlayerContent(),
    );
  }
}

class _PlayerContent extends StatefulWidget {
  const _PlayerContent();

  @override
  State<_PlayerContent> createState() => _PlayerContentState();
}

class _PlayerContentState extends State<_PlayerContent> {
  final FocusNode _remoteFocusNode = FocusNode();
  final FocusNode _progressFocusNode = FocusNode();
  final FocusNode _playPauseBtnFocusNode = FocusNode();
  final FocusNode _backBtnFocusNode = FocusNode();

  /// 焦点是否落在控制栏底部的按钮行里。
  /// 用于区分「左右键该快进」还是「左右键该在按钮之间移动」。
  bool _osdOnButtonRow = false;

  LogicalKeyboardKey? _holdingSeekKey;
  Timer? _seekHoldTimer;
  Timer? _seekWatchdogTimer;
  DateTime? _seekStartTime;
  int _seekStep = 10;
  bool _lastOsd = false;

  /// 本次长按是否已经收到过 KeyRepeatEvent。
  /// 看门狗只在它为 true 之后才武装 —— 见 _resetSeekWatchdog 的说明。
  bool _sawSeekRepeat = false;

  // --- 手指滑动（手机 / 触摸屏）---
  /// 是否正在用「画面上左右滑动」的方式快进快退（区别于直接拖动进度条）。
  bool _swipeSeeking = false;
  double _swipeStartDx = 0;
  Duration _swipeStartPosition = Duration.zero;

  DateTime? _lastBackPressTime;
  bool _showExitHint = false;
  Timer? _exitHintTimer;

  @override
  void initState() {
    super.initState();
    // Hide system UI on TV
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _cancelSeekHold();
    _exitHintTimer?.cancel();
    _remoteFocusNode.dispose();
    _progressFocusNode.dispose();
    _playPauseBtnFocusNode.dispose();
    _backBtnFocusNode.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  bool _handleBackPress(PlayerProvider provider) {
    // 1. If OSD is currently showing, first back press only hides OSD (does not exit)
    if (provider.showOsd) {
      provider.toggleOsd();
      _lastBackPressTime = null;
      if (_showExitHint) {
        setState(() => _showExitHint = false);
      }
      return true;
    }

    // 2. If OSD is not showing:
    final now = DateTime.now();
    if (_lastBackPressTime == null ||
        now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
      _lastBackPressTime = now;
      setState(() => _showExitHint = true);
      _exitHintTimer?.cancel();
      _exitHintTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _showExitHint = false);
      });
      return true; // Don't pop on first back
    }

    // 3. Second back press within 2 seconds: exit player
    _exitHintTimer?.cancel();
    Navigator.of(context).pop();
    return true;
  }

  /// 看门狗：有些电视盒子不送 KeyUpEvent，靠「一段时间没有新的按键事件」来判定
  /// 用户已经松手，把预览落盘。
  ///
  /// **它只在收到过 KeyRepeatEvent 之后才武装。** 这一点是修掉「长按不加速」的关键：
  /// Android 的按键重复有**首次延迟**（`ViewConfiguration.getKeyRepeatTimeout()`，
  /// 默认 500ms）—— 按下之后要等 500ms 才开始送第一个重复事件。如果一按下就武装
  /// 一个短超时的看门狗，它必然在首次重复之前超时，把长按判成「已松手」：
  /// 加速计时器被取消、预览立刻落盘，表现就是「长按只跳一下、完全不加速」。
  /// 原来这里是固定 380ms，正好落在首次延迟里面，所以必然踩中。
  ///
  /// 收到重复事件之后，重复间隔只有 ~50ms，这时 600ms 的静默才是可靠的「松手」判据；
  /// 而只要还在按着，每个重复事件都会把它重置，永远不会触发。
  ///
  /// 万一某台盒子根本不送重复事件，看门狗就一直不武装 —— 那也没关系：
  /// 加速本来是由 140ms 的周期计时器按「按下时长」驱动的，不依赖重复事件；
  /// 松手时的 KeyUpEvent 会正常收尾，真收不到也还有「按任意其他键即收尾」兜底。
  void _resetSeekWatchdog(PlayerProvider provider) {
    if (!_sawSeekRepeat) return;
    _seekWatchdogTimer?.cancel();
    _seekWatchdogTimer = Timer(const Duration(milliseconds: 600), () {
      if (_holdingSeekKey != null) {
        _cancelSeekHold();
        provider.commitSeekPreview();
      }
    });
  }

  void _cancelSeekHold() {
    _seekHoldTimer?.cancel();
    _seekHoldTimer = null;
    _seekWatchdogTimer?.cancel();
    _seekWatchdogTimer = null;
    _holdingSeekKey = null;
    _sawSeekRepeat = false;
  }

  KeyEventResult _handleRemoteKey(PlayerProvider provider, KeyEvent event) {
    final key = event.logicalKey;

    // Handle Long-press and continuous seeking on Left / Right
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      // 只有「控制栏显示 且 焦点在底部按钮行上」时，左右键才让位给 D-pad 在
      // 按钮之间移动。其余情况（控制栏隐藏、或焦点在进度条上）左右键一律
      // 快退/快进 —— 这是电视播放器最通用的操作逻辑。
      if (provider.showOsd && _osdOnButtonRow) {
        return KeyEventResult.ignored;
      }

      final isForward = key == LogicalKeyboardKey.arrowRight;

      if (event is KeyDownEvent) {
        if (_holdingSeekKey != key) {
          _holdingSeekKey = key;
          _seekStartTime = DateTime.now();
          _seekStep = 10;
          provider.startSeekPreview(isForward);

          _seekHoldTimer?.cancel();
          _seekHoldTimer = Timer.periodic(const Duration(milliseconds: 140), (
            timer,
          ) {
            if (_holdingSeekKey == null || !mounted) {
              timer.cancel();
              return;
            }
            final elapsed = DateTime.now()
                .difference(_seekStartTime!)
                .inMilliseconds;
            // After 260ms, enter continuous fast-forward acceleration
            if (elapsed > 260) {
              if (elapsed < 1400) {
                _seekStep = 10;
              } else if (elapsed < 3200) {
                _seekStep = 20;
              } else if (elapsed < 5500) {
                _seekStep = 35;
              } else {
                _seekStep = 60;
              }
              provider.updateSeekPreview(isForward ? _seekStep : -_seekStep);
            }
          });
        }
        _resetSeekWatchdog(provider);
        return KeyEventResult.handled;
      } else if (event is KeyRepeatEvent) {
        // 收到重复事件 = 平台的首次重复延迟已经过去，从这一刻起看门狗才有意义。
        _sawSeekRepeat = true;
        _resetSeekWatchdog(provider);
        return KeyEventResult.handled;
      } else if (event is KeyUpEvent) {
        if (key == _holdingSeekKey) {
          _cancelSeekHold();
          provider.commitSeekPreview();
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }

    // When other keys are pressed, cancel any pending seek hold
    if (_holdingSeekKey != null) {
      _cancelSeekHold();
      provider.commitSeekPreview();
    }

    if (event is KeyDownEvent) {
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.backspace ||
          key == LogicalKeyboardKey.goBack) {
        _handleBackPress(provider);
        return KeyEventResult.handled;
      }

      if (provider.showOsd) {
        provider.resetOsdTimer();
        if (key == LogicalKeyboardKey.contextMenu) {
          provider.toggleOsd();
          return KeyEventResult.handled;
        }
        // 控制栏的纵向顺序是「返回按钮 → 进度条 → 按钮行」，上下键就按这个顺序走：
        //
        //   进度条  ↑ 返回按钮     ↓ 按钮行
        //   按钮行  ↑ 进度条       ↓ 收起控制栏
        //
        // 注意：以前这里写成「进度条上按下键 = 收起控制栏」，方向正好是反的 ——
        // 而按钮行在进度条**下面**，于是下键永远选不到按钮。
        if (_progressFocusNode.hasFocus) {
          if (key == LogicalKeyboardKey.arrowDown) {
            if (_playPauseBtnFocusNode.canRequestFocus) {
              _playPauseBtnFocusNode.requestFocus();
            }
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowUp) {
            if (_backBtnFocusNode.canRequestFocus) {
              _backBtnFocusNode.requestFocus();
            }
            return KeyEventResult.handled;
          }
        } else if (_osdOnButtonRow) {
          if (key == LogicalKeyboardKey.arrowDown) {
            // 焦点已经在最下面一行了，再按下键才收起控制栏
            provider.toggleOsd();
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowUp) {
            if (_progressFocusNode.canRequestFocus) {
              _progressFocusNode.requestFocus();
            }
            return KeyEventResult.handled;
          }
        }
        // 其余方向键交给 Flutter 的焦点遍历，在控制栏内部移动
        return KeyEventResult.ignored;
      }

      // --- 控制栏隐藏时 ---
      // 上下键：唤出控制栏
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.contextMenu) {
        provider.toggleOsd();
        return KeyEventResult.handled;
      }
      // OK 键：第一次按是「唤出控制栏」，不是直接暂停。
      // 控制栏出来以后焦点落在进度条上，再按一次 OK 才是播放/暂停，
      // 这和绝大多数电视播放器一致。
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.space ||
          key == LogicalKeyboardKey.gameButtonA) {
        provider.toggleOsd();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  // --- 手指滑动相关 ---

  /// 把进度条上的横向像素位置换算成播放时间（绝对映射）。
  /// [barWidth] 是进度条的实际宽度，取自 LayoutBuilder 的约束。
  Duration _scrubPositionFromDx(
    PlayerProvider provider,
    double dx,
    double barWidth,
  ) {
    final total = provider.duration;
    if (barWidth <= 0 || !barWidth.isFinite || total <= Duration.zero) {
      return provider.position;
    }
    final ratio = (dx / barWidth).clamp(0.0, 1.0);
    return Duration(milliseconds: (total.inMilliseconds * ratio).round());
  }

  /// 手指按在画面上开始左右滑动。
  void _beginSwipeSeek(PlayerProvider provider, double dx) {
    if (!provider.isInitialized) return;
    _swipeSeeking = true;
    _swipeStartDx = dx;
    _swipeStartPosition = provider.position;
    provider.beginScrub(_swipeStartPosition);
  }

  /// 滑动距离 → 时间。滑过一整屏宽 ≈ 总时长的 1/4，最少 1 分钟、最多 15 分钟，
  /// 这样短视频不会过于灵敏，长视频也不用划好几屏。
  void _updateSwipeSeek(PlayerProvider provider, double dx) {
    if (!_swipeSeeking) return;
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return;
    final total = provider.duration;
    final double spanSeconds = total > Duration.zero
        ? (total.inSeconds / 4).clamp(60.0, 900.0).toDouble()
        : 300.0;
    final deltaSeconds = ((dx - _swipeStartDx) / width * spanSeconds).round();
    provider.updateScrub(_swipeStartPosition + Duration(seconds: deltaSeconds));
  }

  void _endSwipeSeek(PlayerProvider provider) {
    if (!_swipeSeeking) return;
    _swipeSeeking = false;
    provider.endScrub();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PlayerProvider>();

    if (provider.showOsd != _lastOsd) {
      _lastOsd = provider.showOsd;
      if (provider.showOsd) {
        // 控制栏打开后焦点默认落在进度条上：左右键立刻就能快进快退，
        // 按 OK 则是播放/暂停。这与通用电视播放器一致。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _progressFocusNode.canRequestFocus) {
            _progressFocusNode.requestFocus();
          }
        });
      } else {
        _osdOnButtonRow = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _remoteFocusNode.canRequestFocus) {
            _remoteFocusNode.requestFocus();
          }
        });
      }
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBackPress(provider);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _remoteFocusNode,
          autofocus: true,
          onKeyEvent: (node, event) => _handleRemoteKey(provider, event),
          child: GestureDetector(
            // 必须显式声明 opaque。
            //
            // GestureDetector 默认是 HitTestBehavior.deferToChild：只有子节点被命中，
            // 它自己才会被加进命中路径。而控制栏隐藏时，Stack 里唯一的子节点就是
            // 视频画面，视频这一路在 platformView 模式下是
            // `IgnorePointer > PlatformViewLink > AndroidViewSurface`，
            // IgnorePointer 让整条链命中失败 → Stack 返回 false → 这个 GestureDetector
            // 根本没进命中路径 → onTap 永远不会触发（表现为「点屏幕没反应」）。
            //
            // 换 platformView 之前走的是 Texture，RenderTexture.hitTestSelf 恒为 true，
            // 命中链成立，所以那时点击是好的。这就是本次回归的根因。
            //
            // opaque 让它在自己的矩形内始终可命中，与子节点渲染方式无关。
            behavior: HitTestBehavior.opaque,
            onTap: provider.toggleOsd,
            // 手机上：控制栏隐藏时，在画面上左右滑动 = 快进 / 快退。
            // 控制栏可见时不抢手势 —— 那时用户是在操作控制栏，进度条自己会接住拖动。
            // 电视遥控器走按键通道，完全不受影响。
            onHorizontalDragStart: (d) {
              if (provider.showOsd) return;
              _beginSwipeSeek(provider, d.localPosition.dx);
            },
            onHorizontalDragUpdate: (d) {
              if (!_swipeSeeking) return;
              _updateSwipeSeek(provider, d.localPosition.dx);
            },
            onHorizontalDragEnd: (_) => _endSwipeSeek(provider),
            onHorizontalDragCancel: () => _endSwipeSeek(provider),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Native ExoPlayer Video Surface (Hardware accelerated, zero-copy, 32-bit & 64-bit TV optimized)
                Center(
                  child: provider.isInitialized && provider.controller != null
                      ? AspectRatio(
                          aspectRatio: provider.controller!.value.aspectRatio,
                          child: VideoPlayer(provider.controller!),
                        )
                      : const SizedBox.shrink(),
                ),

                // Loading / Source switching overlay
                if (provider.isLoading)
                  Container(
                    color: Colors.black.withValues(alpha: 0.7),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SpinKitDoubleBounce(
                            color: TvTheme.primary,
                            size: 60,
                          ),
                          const SizedBox(height: 24),
                          Text(
                            provider.statusMessage,
                            style: const TextStyle(
                              color: TvTheme.textPrimary,
                              fontSize: 18 * TvTheme.fontScale,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '支持并发测速与断流自动无缝切源',
                            style: TextStyle(
                              color: TvTheme.textSecondary,
                              fontSize: 13 * TvTheme.fontScale,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Quick Seek Pill Indicator (Remote Left/Right)
                if ((provider.showSeekIndicator || provider.isScrubbing) &&
                    !provider.showOsd)
                  _buildSeekPill(context, provider),

                // Double back to exit prompt overlay
                if (_showExitHint && !provider.showOsd)
                  Positioned(
                    bottom: 70,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 26 * UiAdaptive.scale,
                          vertical: 16 * UiAdaptive.scale,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(
                            color: TvTheme.primary,
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.6),
                              blurRadius: 12,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.info_outline,
                              color: TvTheme.primary,
                              size: 20,
                            ),
                            SizedBox(width: 8),
                            Text(
                              '再按一次返回键退出播放',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15 * TvTheme.fontScale,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // TV OSD Overlay
                if (provider.showOsd && !provider.isLoading)
                  _buildOsdOverlay(context, provider),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOsdOverlay(BuildContext context, PlayerProvider provider) {
    // 手指拖动进度条时，进度条和时间文字跟着手指走；遥控器长按快进/快退时，
    // 跟着「预览落点」走。两者都不能跟着实际播放位置 —— 否则长按过程中屏幕
    // 上纹丝不动，用户会以为加速没生效（这一条和「长按不加速」是一起暴露的）。
    final shownPos = provider.isScrubbing
        ? provider.scrubTarget
        : (_holdingSeekKey != null
              ? provider.seekTargetPosition
              : provider.position);
    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          provider.resetOsdTimer();
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.escape ||
              key == LogicalKeyboardKey.backspace ||
              key == LogicalKeyboardKey.goBack) {
            _handleBackPress(provider);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.contextMenu) {
            provider.toggleOsd();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.85),
              Colors.transparent,
              Colors.transparent,
              Colors.black.withValues(alpha: 0.9),
            ],
            stops: const [0.0, 0.25, 0.7, 1.0],
          ),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: 40 * UiAdaptive.scale,
          vertical: 24 * UiAdaptive.scale,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Top Bar
            Row(
              children: [
                TvFocusWidget(
                  focusNode: _backBtnFocusNode,
                  borderRadius: 8,
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: EdgeInsets.all(12 * UiAdaptive.scale),
                    color: TvTheme.surfaceLighter,
                    child: const Icon(
                      Icons.arrow_back_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
                SizedBox(width: 16 * UiAdaptive.scale),
                Text(
                  '${provider.detail.title} - ${provider.currentEpisode.name}',
                  style: const TextStyle(
                    color: TvTheme.textPrimary,
                    fontSize: 20 * TvTheme.fontScale,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                // Source Badge
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 14 * UiAdaptive.scale,
                    vertical: 8 * UiAdaptive.scale,
                  ),
                  decoration: BoxDecoration(
                    color: TvTheme.primary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: TvTheme.primary, width: 1),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.wifi_rounded,
                        color: TvTheme.primary,
                        size: 14,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        provider.currentSource.name,
                        style: const TextStyle(
                          color: TvTheme.primary,
                          fontSize: 12 * TvTheme.fontScale,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // Bottom Bar
            Column(
              children: [
                // Progress slider & Time info
                // 进度条本身可聚焦：焦点在它上面时左右键快进快退、OK 播放/暂停，
                // 上键去按钮行、下键收起控制栏。
                TvFocusWidget(
                  focusNode: _progressFocusNode,
                  borderRadius: 12,
                  scale: 1.0,
                  onTap: provider.togglePlayPause,
                  padding: EdgeInsets.symmetric(
                    horizontal: 16 * UiAdaptive.scale,
                    vertical: 12 * UiAdaptive.scale,
                  ),
                  // 手机上可以直接按住这一整块左右拖动来定位。
                  // 用 LayoutBuilder 拿到进度条的真实宽度，把手指的横向位置按比例
                  // 映射成播放时间。整块（含两侧时间文字）都可拖，手指不必精确点在
                  // 细条上；这一点对触摸屏比遥控器重要得多。
                  child: LayoutBuilder(
                    builder: (ctx, constraints) {
                      final barWidth = constraints.maxWidth;
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragStart: (d) => provider.beginScrub(
                          _scrubPositionFromDx(
                            provider,
                            d.localPosition.dx,
                            barWidth,
                          ),
                        ),
                        onHorizontalDragUpdate: (d) => provider.updateScrub(
                          _scrubPositionFromDx(
                            provider,
                            d.localPosition.dx,
                            barWidth,
                          ),
                        ),
                        onHorizontalDragEnd: (_) => provider.endScrub(),
                        onHorizontalDragCancel: provider.endScrub,
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _formatDuration(shownPos),
                                  style: const TextStyle(
                                    color: TvTheme.textPrimary,
                                    fontSize: 14 * TvTheme.fontScale,
                                  ),
                                ),
                                Text(
                                  _formatDuration(provider.duration),
                                  style: const TextStyle(
                                    color: TvTheme.textSecondary,
                                    fontSize: 14 * TvTheme.fontScale,
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: 10 * UiAdaptive.scale),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: LinearProgressIndicator(
                                value: provider.duration.inMilliseconds > 0
                                    ? (shownPos.inMilliseconds /
                                              provider.duration.inMilliseconds)
                                          .clamp(0.0, 1.0)
                                    : 0.0,
                                backgroundColor: Colors.white24,
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  TvTheme.primary,
                                ),
                                minHeight: 12,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),

                SizedBox(height: 18 * UiAdaptive.scale),

                // Control Action Buttons
                // 外面这层 Focus 只用来「感知」焦点是否进了按钮行，
                // 不参与遍历（canRequestFocus:false + skipTraversal:true）。
                Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onFocusChange: (hasFocus) {
                    _osdOnButtonRow = hasFocus;
                  },
                  child: _scrollableControlRow(
                    children: [
                      _buildControlBtn(
                        focusNode: _playPauseBtnFocusNode,
                        icon: provider.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        label: provider.isPlaying ? '暂停' : '播放',
                        focusBorderColor: TvTheme.accent,
                        onTap: provider.togglePlayPause,
                      ),
                      SizedBox(width: 16 * UiAdaptive.scale),
                      _buildControlBtn(
                        icon: Icons.replay_10_rounded,
                        label: '快退10s',
                        onTap: () => provider.seekBackward(10),
                      ),
                      SizedBox(width: 16 * UiAdaptive.scale),
                      _buildControlBtn(
                        icon: Icons.forward_10_rounded,
                        label: '快进10s',
                        onTap: () => provider.seekForward(10),
                      ),
                      SizedBox(width: 16 * UiAdaptive.scale),
                      _buildControlBtn(
                        icon: Icons.alt_route_rounded,
                        label: '换源',
                        onTap: () => _showSourceDialog(context, provider),
                      ),
                      SizedBox(width: 16 * UiAdaptive.scale),
                      _buildControlBtn(
                        icon: Icons.video_library_rounded,
                        label: '选集',
                        onTap: () => _showEpisodeDrawer(context, provider),
                      ),
                      SizedBox(width: 16 * UiAdaptive.scale),
                      _buildControlBtn(
                        icon: Icons.timer_outlined,
                        label: '片头片尾',
                        onTap: () => _showSkipSettingsDialog(context, provider),
                      ),
                      SizedBox(width: 16 * UiAdaptive.scale),
                      // 倍速：按钮上直接显示当前值，不用点开才知道。
                      _buildControlBtn(
                        icon: Icons.speed_rounded,
                        label: '倍速 ${_formatSpeed(provider.playbackSpeed)}',
                        focusBorderColor: TvTheme.accent,
                        onTap: () => _showSpeedDialog(context, provider),
                      ),
                      if (provider.currentEpisodeIndex + 1 <
                          provider.currentSource.episodes.length) ...[
                        SizedBox(width: 16 * UiAdaptive.scale),
                        _buildControlBtn(
                          icon: Icons.skip_next_rounded,
                          label: '下一集',
                          onTap: provider.playNextEpisode,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 把控制栏按钮行包成「放得下就居中、放不下就横向滚动」。
  ///
  /// **为什么必须包一层**：电视档 `TvTheme.fontScale = 2.1`，8 个按钮（图标 20 +
  /// 间距 8 + 左右内边距 40 + 标签 13*2.1）的固有宽度约 1250 逻辑像素；而 1080p
  /// 电视的逻辑宽度在 densityDpi 320/480/640 下分别只有 960/640/480。原来这里是个
  /// 裸 Row，宽度必然溢出，于是：
  ///
  /// * `RenderFlex` 在 `MainAxisAlignment.center` 下拿到的剩余空间是
  ///   `max(0, freeSpace)`（见 rendering/flex.dart 的 `_distributeSpace`），溢出时
  ///   恒为 0 → `leadingSpace = 0` → 子项从左边距开始排，右侧按钮溢出屏幕，
  ///   被外层 `Stack`（默认 `Clip.hardEdge`）裁掉；
  /// * 而方向键遍历只按 `FocusNode.rect` 挑候选 —— `_sortAndFilterHorizontally`
  ///   仅比较 `rect.center.dx`，**不排除视口外的节点**。所以焦点其实**能**移到
  ///   「换源」，只是它画在屏幕外，遥控器上表现就是「向右点不到换源，
  ///   换源右边的按钮也点不到」。
  ///
  /// **为什么这样包能修好**：`ConstrainedBox(minWidth: 视口宽)` 让内容比视口窄时
  /// 撑满视口，`MainAxisAlignment.center` 照旧居中（电视档在不溢出的机器上观感
  /// 逐位不变）；内容更宽时宽度不受限、可横向滚动，而 `TvFocusWidget` 里已有的
  /// `Scrollable.ensureVisible` 会把获得焦点的按钮滚进视野。
  ///
  /// 注：`Row` 保持默认的 `MainAxisSize.max` 即可 —— 在无界宽度下它会退化为
  /// 「按内容宽度」（flex.dart: `MainAxisSize.max when maxMainSize.isFinite` 不成立
  /// 时取 `accumulatedSize`），正是这里需要的行为。
  Widget _scrollableControlRow({required List<Widget> children}) {
    return LayoutBuilder(
      builder: (ctx, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: children,
          ),
        ),
      ),
    );
  }

  Widget _buildControlBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    FocusNode? focusNode,
    Color focusBorderColor = TvTheme.primary,
    bool autofocus = false,
  }) {
    return TvFocusWidget(
      focusNode: focusNode,
      autofocus: autofocus,
      borderRadius: 10,
      focusBorderColor: focusBorderColor,
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: 20 * UiAdaptive.scale,
          vertical: 16 * UiAdaptive.scale,
        ),
        color: TvTheme.surfaceLighter,
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13 * TvTheme.fontScale,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEpisodeDrawer(BuildContext context, PlayerProvider provider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: TvTheme.surface,
      builder: (_) => Container(
        padding: EdgeInsets.symmetric(
          horizontal: 24 * UiAdaptive.scale,
          vertical: 16 * UiAdaptive.scale,
        ),
        height: 220 * UiAdaptive.scale,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '快速选集',
                  style: TextStyle(
                    color: TvTheme.textPrimary,
                    fontSize: 16 * TvTheme.fontScale,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '共 ${provider.currentSource.episodes.length} 集',
                  style: const TextStyle(
                    color: TvTheme.textSecondary,
                    fontSize: 12 * TvTheme.fontScale,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: List.generate(
                    provider.currentSource.episodes.length,
                    (idx) {
                      final ep = provider.currentSource.episodes[idx];
                      final isCur = provider.currentEpisodeIndex == idx;
                      final numMatch = RegExp(r'第?0*(\d+)集?')
                          .firstMatch(ep.name);
                      final label = (numMatch != null && ep.name.length <= 6)
                          ? numMatch.group(1)!
                          : ep.name;
                      final isShort = label.length <= 4;

                      return Padding(
                        padding: EdgeInsets.only(right: 8 * UiAdaptive.scale),
                        child: TvFocusWidget(
                          borderRadius: 6,
                          scale: 1.08,
                          onTap: () {
                            Navigator.pop(context);
                            provider.selectEpisode(idx);
                          },
                          child: Container(
                            width: isShort ? 110 : 200,
                            height: 76,
                            decoration: BoxDecoration(
                              color: isCur
                                  ? TvTheme.primary.withValues(alpha: 0.3)
                                  : TvTheme.surfaceLighter,
                              border: isCur
                                  ? Border.all(color: TvTheme.primary, width: 2)
                                  : null,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isCur
                                    ? TvTheme.primary
                                    : TvTheme.textPrimary,
                                fontWeight: isCur
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                fontSize: 13 * TvTheme.fontScale,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSourceDialog(BuildContext context, PlayerProvider provider) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: TvTheme.surface,
        title: const Row(
          children: [
            Icon(Icons.speed_rounded, color: TvTheme.primary),
            SizedBox(width: 10),
            Text(
              '切换播放线路 (按下载速度优选排序)',
              style: TextStyle(
                color: TvTheme.textPrimary,
                fontSize: 18 * TvTheme.fontScale,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 760 * UiAdaptive.scale,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: provider.rankedSources.isNotEmpty
                ? provider.rankedSources.length
                : provider.allSources.length,
            itemBuilder: (context, idx) {
              if (provider.rankedSources.isNotEmpty) {
                final tested = provider.rankedSources[idx];
                final isCur = provider.currentSource.name == tested.source.name;
                return Padding(
                  padding: EdgeInsets.only(bottom: 8 * UiAdaptive.scale),
                  child: TvFocusWidget(
                    borderRadius: 8,
                    onTap: () {
                      Navigator.pop(context);
                      final srcIdx = provider.allSources.indexWhere(
                        (s) => s.name == tested.source.name,
                      );
                      if (srcIdx != -1) provider.selectSource(srcIdx);
                    },
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 20 * UiAdaptive.scale,
                        vertical: 18 * UiAdaptive.scale,
                      ),
                      decoration: BoxDecoration(
                        color: isCur
                            ? TvTheme.primary.withValues(alpha: 0.25)
                            : TvTheme.surfaceLighter,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            tested.source.name,
                            style: TextStyle(
                              color: isCur ? TvTheme.primary : Colors.white,
                              fontWeight: isCur
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          Text(
                            tested.isAvailable ? tested.speedLabel : '不可用',
                            style: TextStyle(
                              color: tested.isAvailable
                                  ? TvTheme.success
                                  : TvTheme.error,
                              fontSize: 13 * TvTheme.fontScale,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              } else {
                final src = provider.allSources[idx];
                final isCur = provider.currentSourceIndex == idx;
                return Padding(
                  padding: EdgeInsets.only(bottom: 8 * UiAdaptive.scale),
                  child: TvFocusWidget(
                    borderRadius: 8,
                    onTap: () {
                      Navigator.pop(context);
                      provider.selectSource(idx);
                    },
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 20 * UiAdaptive.scale,
                        vertical: 18 * UiAdaptive.scale,
                      ),
                      color: isCur
                          ? TvTheme.primary.withValues(alpha: 0.25)
                          : TvTheme.surfaceLighter,
                      child: Text(
                        src.name,
                        style: TextStyle(
                          color: isCur ? TvTheme.primary : Colors.white,
                        ),
                      ),
                    ),
                  ),
                );
              }
            },
          ),
        ),
      ),
    );
  }

  /// 可选倍速档位。0.5x ~ 3.0x，与 `StorageService` 的合法区间一致。
  static const List<double> _speedOptions = [
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
    2.5,
    3.0,
  ];

  /// 倍速显示：1.0 → `1.0x`，1.25 → `1.25x`，0.5 → `0.5x`。
  String _formatSpeed(double v) {
    if (v == v.roundToDouble()) return '${v.toInt()}.0x';
    return '${v}x';
  }

  /// 设置默认播放倍速。设置后本集立即生效，之后每一集、每次换源都按它起播。
  void _showSpeedDialog(BuildContext context, PlayerProvider provider) {
    showDialog(
      context: context,
      builder: (dialogCtx) {
        // 这里必须用 StatefulBuilder + 显式 setDialogState：
        // showDialog 的 builder context 挂在根 Navigator 上，**不在**
        // PlayerProvider 的 Provider 作用域内，`context.watch` 拿不到实例。
        // 其余几个设置弹窗也是同样的写法。
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final cur = provider.playbackSpeed;
            return AlertDialog(
              backgroundColor: TvTheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Row(
                children: [
                  Icon(Icons.speed_rounded, color: TvTheme.accent),
                  SizedBox(width: 10),
                  Text(
                    '播放倍速 (默认速度)',
                    style: TextStyle(
                      color: TvTheme.textPrimary,
                      fontSize: 18 * TvTheme.fontScale,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 760 * UiAdaptive.scale,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '当前: ${_formatSpeed(cur)}　·　设置后本集立即生效，'
                      '之后每一集、每次换源都按这个速度起播',
                      style: const TextStyle(
                        color: TvTheme.textSecondary,
                        fontSize: 13 * TvTheme.fontScale,
                      ),
                    ),
                    SizedBox(height: 16 * UiAdaptive.scale),
                    Wrap(
                      spacing: 8 * UiAdaptive.scale,
                      runSpacing: 8 * UiAdaptive.scale,
                      children: [
                        for (final v in _speedOptions)
                          TvFocusWidget(
                            borderRadius: 8,
                            onTap: () async {
                              await provider.setPlaybackSpeed(v);
                              setDialogState(() {});
                            },
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 16 * UiAdaptive.scale,
                                vertical: 14 * UiAdaptive.scale,
                              ),
                              decoration: BoxDecoration(
                                color: (cur - v).abs() < 0.001
                                    ? TvTheme.primary.withValues(alpha: 0.3)
                                    : TvTheme.surfaceLighter,
                                border: (cur - v).abs() < 0.001
                                    ? Border.all(
                                        color: TvTheme.primary,
                                        width: 2,
                                      )
                                    : null,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _formatSpeed(v),
                                style: TextStyle(
                                  color: (cur - v).abs() < 0.001
                                      ? TvTheme.primary
                                      : TvTheme.textPrimary,
                                  fontSize: 13 * TvTheme.fontScale,
                                  fontWeight: (cur - v).abs() < 0.001
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showSkipSettingsDialog(BuildContext context, PlayerProvider provider) {
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final introSec = provider.skipIntroSeconds;
            final outroSec = provider.skipOutroSeconds;

            return AlertDialog(
              backgroundColor: TvTheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Row(
                children: [
                  Icon(Icons.tune_rounded, color: TvTheme.accent),
                  SizedBox(width: 10),
                  Text(
                    '跳过片头片尾设置 (全局生效)',
                    style: TextStyle(
                      color: TvTheme.textPrimary,
                      fontSize: 18 * TvTheme.fontScale,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 760 * UiAdaptive.scale,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // --- Skip Intro ---
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '跳过片头时长:',
                          style: TextStyle(
                            color: TvTheme.textPrimary,
                            fontSize: 15 * TvTheme.fontScale,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          introSec == 0
                              ? '已关闭'
                              : '$introSec 秒 (${(introSec / 60).toStringAsFixed(1)} 分钟)',
                          style: TextStyle(
                            color: introSec > 0
                                ? TvTheme.accent
                                : TvTheme.textSecondary,
                            fontSize: 14 * TvTheme.fontScale,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final sec in [0, 30, 60, 90, 120, 150])
                            Padding(
                              padding: EdgeInsets.only(
                                right: 8 * UiAdaptive.scale,
                              ),
                              child: TvFocusWidget(
                                borderRadius: 8,
                                onTap: () {
                                  provider.updateSkipIntro(sec);
                                  setDialogState(() {});
                                },
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 16 * UiAdaptive.scale,
                                    vertical: 14 * UiAdaptive.scale,
                                  ),
                                  decoration: BoxDecoration(
                                    color: introSec == sec
                                        ? TvTheme.primary.withValues(alpha: 0.3)
                                        : TvTheme.surfaceLighter,
                                    border: introSec == sec
                                        ? Border.all(
                                            color: TvTheme.primary,
                                            width: 2,
                                          )
                                        : null,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    sec == 0
                                        ? '不跳过'
                                        : (sec == 90 ? '90s(默认)' : '${sec}s'),
                                    style: TextStyle(
                                      color: introSec == sec
                                          ? TvTheme.primary
                                          : TvTheme.textPrimary,
                                      fontSize: 13 * TvTheme.fontScale,
                                      fontWeight: introSec == sec
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Padding(
                            padding: EdgeInsets.only(
                              right: 8 * UiAdaptive.scale,
                            ),
                            child: TvFocusWidget(
                              borderRadius: 8,
                              onTap: () {
                                final newVal = (introSec - 10).clamp(0, 600);
                                provider.updateSkipIntro(newVal);
                                setDialogState(() {});
                              },
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 14 * UiAdaptive.scale,
                                  vertical: 12 * UiAdaptive.scale,
                                ),
                                color: TvTheme.surfaceLighter,
                                child: const Text(
                                  '-10s',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 13 * TvTheme.fontScale,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          TvFocusWidget(
                            borderRadius: 8,
                            onTap: () {
                              final newVal = (introSec + 10).clamp(0, 600);
                              provider.updateSkipIntro(newVal);
                              setDialogState(() {});
                            },
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 14 * UiAdaptive.scale,
                                vertical: 12 * UiAdaptive.scale,
                              ),
                              color: TvTheme.surfaceLighter,
                              child: const Text(
                                '+10s',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13 * TvTheme.fontScale,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // --- Skip Outro ---
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '跳过片尾时长:',
                          style: TextStyle(
                            color: TvTheme.textPrimary,
                            fontSize: 15 * TvTheme.fontScale,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          outroSec == 0
                              ? '已关闭'
                              : '$outroSec 秒 (${(outroSec / 60).toStringAsFixed(1)} 分钟)',
                          style: TextStyle(
                            color: outroSec > 0
                                ? TvTheme.accent
                                : TvTheme.textSecondary,
                            fontSize: 14 * TvTheme.fontScale,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final sec in [0, 30, 60, 90, 120, 150])
                            Padding(
                              padding: EdgeInsets.only(
                                right: 8 * UiAdaptive.scale,
                              ),
                              child: TvFocusWidget(
                                borderRadius: 8,
                                onTap: () {
                                  provider.updateSkipOutro(sec);
                                  setDialogState(() {});
                                },
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 16 * UiAdaptive.scale,
                                    vertical: 14 * UiAdaptive.scale,
                                  ),
                                  decoration: BoxDecoration(
                                    color: outroSec == sec
                                        ? TvTheme.primary.withValues(alpha: 0.3)
                                        : TvTheme.surfaceLighter,
                                    border: outroSec == sec
                                        ? Border.all(
                                            color: TvTheme.primary,
                                            width: 2,
                                          )
                                        : null,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    sec == 0
                                        ? '不跳过'
                                        : (sec == 90 ? '90s(默认)' : '${sec}s'),
                                    style: TextStyle(
                                      color: outroSec == sec
                                          ? TvTheme.primary
                                          : TvTheme.textPrimary,
                                      fontSize: 13 * TvTheme.fontScale,
                                      fontWeight: outroSec == sec
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Padding(
                            padding: EdgeInsets.only(
                              right: 8 * UiAdaptive.scale,
                            ),
                            child: TvFocusWidget(
                              borderRadius: 8,
                              onTap: () {
                                final newVal = (outroSec - 10).clamp(0, 600);
                                provider.updateSkipOutro(newVal);
                                setDialogState(() {});
                              },
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 14 * UiAdaptive.scale,
                                  vertical: 12 * UiAdaptive.scale,
                                ),
                                color: TvTheme.surfaceLighter,
                                child: const Text(
                                  '-10s',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 13 * TvTheme.fontScale,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          TvFocusWidget(
                            borderRadius: 8,
                            onTap: () {
                              final newVal = (outroSec + 10).clamp(0, 600);
                              provider.updateSkipOutro(newVal);
                              setDialogState(() {});
                            },
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 14 * UiAdaptive.scale,
                                vertical: 12 * UiAdaptive.scale,
                              ),
                              color: TvTheme.surfaceLighter,
                              child: const Text(
                                '+10s',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13 * TvTheme.fontScale,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),
                    const Text(
                      '设置后将永久保存并在后续播放所有视频时自动生效',
                      style: TextStyle(
                        color: TvTheme.textSecondary,
                        fontSize: 12 * TvTheme.fontScale,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TvFocusWidget(
                  autofocus: true,
                  borderRadius: 8,
                  onTap: () => Navigator.pop(ctx),
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 26 * UiAdaptive.scale,
                      vertical: 16 * UiAdaptive.scale,
                    ),
                    decoration: BoxDecoration(
                      color: TvTheme.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      '完成',
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSeekPill(BuildContext context, PlayerProvider provider) {
    // 拖动进度条 / 滑动画面时以手指落点为准；遥控器长按快进时以预览目标为准。
    final targetPos = provider.isScrubbing
        ? provider.scrubTarget
        : provider.seekTargetPosition;
    // 遥控器长按要显示「累计快进了多少秒」；手指拖动要显示「落点相对当前播放位置差多少」。
    // 不能统一用 (targetPos - position)：落盘之后 position 就等于 targetPos，
    // 提示条会变成「+0s」，把刚快进多少秒这个信息丢掉。
    final delta = provider.isScrubbing
        ? (targetPos - provider.position).inSeconds
        : provider.seekDeltaSeconds;
    final isForward = delta >= 0;
    final sign = isForward ? '+' : '';
    final total = provider.duration;

    return Center(
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: 30 * UiAdaptive.scale,
          vertical: 20 * UiAdaptive.scale,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(34),
          border: Border.all(color: TvTheme.primary, width: 2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 8,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isForward
                  ? Icons.fast_forward_rounded
                  : Icons.fast_rewind_rounded,
              color: TvTheme.primary,
              size: 28,
            ),
            const SizedBox(width: 12),
            Text(
              '$sign${delta}s',
              style: const TextStyle(
                color: TvTheme.primary,
                fontSize: 22 * TvTheme.fontScale,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(width: 16 * UiAdaptive.scale),
            Text(
              '${_formatDuration(targetPos)} / ${_formatDuration(total)}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16 * TvTheme.fontScale,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final hours = d.inHours.toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }
}
