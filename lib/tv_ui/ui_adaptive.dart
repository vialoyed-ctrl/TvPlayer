import '../services/device_profile.dart';

/// 手机 / 电视两档界面参数。
///
/// **设计约束：电视档必须逐位不变。**
/// 所以这里的电视分支返回的都是原字面量，调用点统一写成 `原值 * UiAdaptive.scale`。
/// 电视档 `scale == 1.0`，而浮点乘法 `x * 1.0 == x` 是精确成立的（IEEE 754），
/// 所以电视端算出来的每个数值都和改动前一模一样，渲染结果不会有任何偏移。
///
/// 手机档的 0.5 是「整体减半」这一个旋钮，想再调只改这一处。
class UiAdaptive {
  const UiAdaptive._();

  /// 是否手机。由 [DeviceProfile] 在启动时经原生通道探测，默认电视。
  static bool get isPhone => DeviceProfile.isPhone;

  /// 布局倍率：电视 1.0，手机 0.5。
  /// 作用于页面留白、网格间距、以及少数写死的容器尺寸（封面宽高、弹窗宽度等）。
  static double get scale => isPhone ? 0.5 : 1.0;

  /// 字号总倍率，通过 `MediaQuery.textScaler` 全局生效。
  ///
  /// 电视档是 1.0，表示「不引入任何缩放」——`main.dart` 里电视档根本不会套
  /// 那层 MediaQuery，字体与改动前完全一致。
  ///
  /// 为什么走 textScaler 而不是去改 `TvTheme.fontScale`：
  /// 界面上每一处字号都写成 `N * TvTheme.fontScale`，`fontScale` 是编译期常量，
  /// 上百处 `const TextStyle` 都依赖它。改它是全量重写；textScaler 是在绘制阶段
  /// 统一乘一次，一处生效、不可能漏。
  ///
  /// 注意 `Icon` 默认 `applyTextScaling == false`（见 IconThemeData），
  /// 所以图标不会被这层缩放影响 —— 这是刻意的：图标本来就只有 18~22 逻辑像素。
  static double get textScale => isPhone ? 0.5 : 1.0;

  /// 手机上是否隐藏电视用的屏幕软键盘。
  /// 手机有自己的系统输入法，再叠一层电视软键盘会把页面挤没。
  static bool get hideTvKeyboard => isPhone;
}
