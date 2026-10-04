import 'package:flutter/services.dart';

/// 设备档位：电视 / 手机。
///
/// 为什么不用「屏幕尺寸」猜：
/// Android TV 的常见密度档就是 xhdpi(320dpi)，1080p 电视的逻辑分辨率因此只有
/// 960×540 —— 最短边 540 < 600，任何基于逻辑尺寸的阈值都会把这类电视误判成手机。
/// 所以判定必须由 Android 侧给出（UiModeManager + PackageManager 的系统特性）。
///
/// 安全默认值：**电视**。通道不存在、平台不是 Android、原生抛异常、字段缺失，
/// 一律退回电视档 —— 也就是加这个功能之前的行为。手机档只有在
/// 「明确不是电视」且「确实有触摸屏」两个条件同时成立时才会启用，
/// 因此电视端不存在被误伤的可能。
class DeviceProfile {
  const DeviceProfile._();

  static const MethodChannel _channel = MethodChannel('tvplayer/device');

  static bool _isTv = true;
  static bool _isPhone = false;

  static bool get isTv => _isTv;
  static bool get isPhone => _isPhone;

  /// 在 `runApp` 之前调用一次。
  ///
  /// 必须在第一帧之前完成：如果放到第一帧之后再刷新，手机会先按电视档渲染一帧，
  /// 然后整屏跳变，看起来像闪一下。
  static Future<void> init() async {
    try {
      final Map<String, dynamic>? info = await _channel
          .invokeMapMethod<String, dynamic>('deviceInfo');
      final bool isTelevision = info?['isTelevision'] == true;
      final bool hasTouchScreen = info?['hasTouchScreen'] == true;
      _isTv = isTelevision;
      _isPhone = !isTelevision && hasTouchScreen;
    } catch (_) {
      _isTv = true;
      _isPhone = false;
    }
  }
}
