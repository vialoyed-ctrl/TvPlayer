import 'package:flutter/widgets.dart';

/// 全局 Navigator key。
///
/// 自动更新需要在**任何一个页面**上都能弹出「发现新版本」的确认框：启动时的
/// 自动检查可能在首页跑完，也可能在播放页跑完。有了这个 key，服务层不用拿着
/// 某个具体页面的 context 就能弹框。
///
/// 挂在 `MaterialApp.navigatorKey` 上，是它唯一的使用方式。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
