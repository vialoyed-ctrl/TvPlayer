import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'tv_ui/tv_theme.dart';
import 'tv_ui/ui_adaptive.dart';
import 'tv_ui/app_navigator.dart';
import 'services/storage_service.dart';
import 'services/device_profile.dart';
import 'services/download_service.dart';
import 'services/sync_service.dart';
import 'services/update_service.dart';
import 'providers/home_provider.dart';
import 'providers/history_provider.dart';
import 'views/home_view.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialize Local Storage (history & favorites)
  await StorageService.instance.init();

  // 2. 探测设备档位（电视 / 手机）。必须在 runApp 之前完成，
  //    否则手机会先按电视档渲染一帧再跳变，看起来像闪一下。
  //    探测失败时默认电视档，行为与加这个功能之前完全一致。
  await DeviceProfile.init();

  // 3. 下载引擎：读回上次的任务列表，并把「上次没下完」的重新排队。
  //    放在 runApp 之前，是为了避免下载管理页先渲染一帧空列表。
  //    它内部不会阻塞 —— 真正的下载是排队之后异步跑的。
  await DownloadService.instance.init();

  // 4. 同步服务：只挂监听 + 排一个延迟同步，不阻塞启动。
  //    没配置 WebDAV 或没打开自动同步时它什么都不做。
  await SyncService.instance.init();

  // 5. 更新服务：读一下本机版本号，并按需排一个延迟检查。
  //    没配置 WebDAV 或关掉了自动检查时它什么都不做。
  await UpdateService.instance.init();

  // 6. Enforce TV landscape orientation
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  runApp(const TvPlayerApp());
}

class TvPlayerApp extends StatefulWidget {
  const TvPlayerApp({super.key});

  @override
  State<TvPlayerApp> createState() => _TvPlayerAppState();
}

class _TvPlayerAppState extends State<TvPlayerApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // 退到后台时同步一次，不等那 25 秒防抖。
    // 系统随时可能冻结甚至杀掉进程，定时器不保证会响，所以这一刻必须主动推。
    _lifecycle = AppLifecycleListener(
      onPause: () => unawaited(SyncService.instance.onAppBackgrounded()),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => HomeProvider()),
        ChangeNotifierProvider(create: (_) => HistoryProvider()),
        // 下载引擎是全局单例（下载要在页面之间持续跑），所以用 .value 挂上去，
        // 而不是 create —— 否则离开下载页时 Provider 会把它 dispose 掉。
        ChangeNotifierProvider<DownloadService>.value(
          value: DownloadService.instance,
        ),
        // 同步服务同理：设置页可能被关掉，但同步还要继续。
        ChangeNotifierProvider<SyncService>.value(value: SyncService.instance),
        // 更新服务也一样：自动检查可能在首页跑完，然后要从任何页面上弹确认框。
        ChangeNotifierProvider<UpdateService>.value(
          value: UpdateService.instance,
        ),
      ],
      child: MaterialApp(
        title: 'TvPlayer',
        debugShowCheckedModeBanner: false,
        // 自动更新要能从任何一个页面弹「发现新版本」，所以挂一个全局 key。
        navigatorKey: appNavigatorKey,
        theme: TvTheme.themeData,
        // 手机档：全局压一次字号。
        //
        // 界面上每一处字号都写成 `N * TvTheme.fontScale`，而 fontScale = 2.1 是
        // 按电视定的。手机直接沿用会大得离谱（14 * 2.1 = 29.4 逻辑像素，
        // 在横屏手机只有 360 逻辑高度的情况下，一行字就占了 8% 屏高）。
        //
        // 用 MediaQuery.textScaler 在绘制阶段统一乘一次，比去改上百处 TextStyle
        // 安全得多，也不可能漏。Icon 默认 applyTextScaling == false，
        // 所以图标不受影响。
        //
        // 电视档直接返回 child 原样 —— 连一层 MediaQuery 都不套，
        // 渲染路径与改动前完全一致。
        builder: (context, child) {
          if (!UiAdaptive.isPhone) return child!;
          return MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(UiAdaptive.textScale)),
            child: child!,
          );
        },
        home: const HomeView(),
      ),
    );
  }
}
