import 'package:flutter/material.dart';

class TvTheme {
  /// 全局字体缩放倍率。界面上所有字号都写成 `原字号 * TvTheme.fontScale`，
  /// 想整体调大或调小，只改这一个数字即可（1.0 = 原始大小）。
  ///
  /// 调整记录：1.0（原始）→ 3.0（偏大，用户反馈"有点太大"）→ 2.1（= 3.0 × 70%）。
  ///
  /// 注意：各视图里承载文字的容器尺寸（网格列数、按钮宽高、弹窗宽度等）是按
  /// 3.0 调的，改这个数字**不会**同步改容器。字号调小只是留白变多，不会溢出；
  /// 若觉得框子太空，需要另外单独收紧容器。
  ///
  /// 之所以用「乘常数」而不是 `TvTheme.fs(x)` 函数，是因为前者仍是编译期
  /// 常量表达式，`const TextStyle(fontSize: 14 * TvTheme.fontScale)` 能正常
  /// 编译；换成函数调用就必须把所有 `const` 去掉，改动面大且易错。
  static const double fontScale = 2.1;

  static const Color background = Color(0xFF0F1117);
  static const Color surface = Color(0xFF1B1E28);
  static const Color surfaceLighter = Color(0xFF262A37);
  static const Color primary = Color(0xFF00E5FF); // Cyber Cyan
  static const Color primaryDark = Color(0xFF00B0FF);
  static const Color accent = Color(0xFFFFB300); // Amber Gold
  static const Color textPrimary = Color(0xFFF0F3F8);
  static const Color textSecondary = Color(0xFF9099A9);
  static const Color success = Color(0xFF00E676);
  static const Color error = Color(0xFFFF3D00);

  // TV Focus glow decoration
  static BoxDecoration focusDecoration({
    double borderRadius = 12.0,
    Color focusColor = primary,
  }) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(color: focusColor, width: 3.0),
      boxShadow: [
        BoxShadow(
          color: focusColor.withValues(alpha: 0.35),
          blurRadius: 6,
          spreadRadius: 1,
        ),
      ],
    );
  }

  static ThemeData get themeData {
    return ThemeData.dark().copyWith(
      scaffoldBackgroundColor: background,
      primaryColor: primary,
      colorScheme: const ColorScheme.dark(
        primary: primary,
        secondary: accent,
        surface: surface,
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          color: textPrimary,
          fontSize: 28 * fontScale,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
        headlineMedium: TextStyle(
          color: textPrimary,
          fontSize: 22 * fontScale,
          fontWeight: FontWeight.w600,
        ),
        titleLarge: TextStyle(
          color: textPrimary,
          fontSize: 18 * fontScale,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(color: textPrimary, fontSize: 16 * fontScale),
        bodyMedium: TextStyle(color: textSecondary, fontSize: 14 * fontScale),
      ),
    );
  }
}
