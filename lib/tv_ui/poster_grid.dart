import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/storage_service.dart';
import 'ui_adaptive.dart';

/// 本机列数设置用于所有海报列表；触摸设备按屏幕方向选择较宽的卡片。
class PosterGrid {
  static SliverGridDelegateWithFixedCrossAxisCount delegate(
    BuildContext context, {
    required int tvColumns,
    required double aspectRatio,
    required double tvMainSpacing,
    required double tvCrossSpacing,
  }) {
    final selected = context.watch<StorageService>().posterColumns;
    final size = MediaQuery.sizeOf(context);
    final automatic = UiAdaptive.isPhone
        ? (size.width > size.height ? 4 : 3)
        : tvColumns;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: selected == 0 ? automatic : selected,
      mainAxisSpacing: UiAdaptive.isPhone ? 12 : tvMainSpacing,
      crossAxisSpacing: UiAdaptive.isPhone ? 10 : tvCrossSpacing,
      childAspectRatio: aspectRatio,
    );
  }
}
