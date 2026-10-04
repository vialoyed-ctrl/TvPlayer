import 'package:flutter/material.dart';

import '../models/update_info.dart';
import '../services/webdav_client.dart';
import '../tv_ui/tv_theme.dart';
import '../tv_ui/ui_adaptive.dart';

/// 「发现新版本」的确认框。返回 true 表示用户点了「立即安装」。
///
/// 单独放一个文件、而不是塞进设置页：启动时的自动检查可能在任何一个页面上
/// 跑完，这个框要能从任何地方弹出来（见 `tv_ui/app_navigator.dart`）。
///
/// 这里刻意不自动跳安装界面：真正装下去是不可逆的，而且装的过程中 App 会退出。
/// 让用户明确点一次，比「打开 App 突然跳出一个安装界面」友好得多。
/// 想完全免打扰的用户可以在设置页打开「发现后直接安装」。
Future<bool?> showUpdateDialog(
  BuildContext context, {
  required ApkInfo? apk,
  required WebDavStat? remote,
  required InstalledAppInfo current,
}) {
  final sizeText = remote == null ? '' : formatBytes(remote.sizeBytes);
  final newVersion = apk?.versionDisplay ?? '未知';

  /// 版本号没变。用户很可能只是重新打了个包、没改 pubspec.yaml 里的版本号 ——
  /// 这在这个项目里是常态，所以不拦，但要说清楚，免得他以为检测错了。
  final sameVersionCode = apk != null && apk.versionCode <= current.versionCode;

  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: TvTheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Icon(Icons.system_update_alt, color: TvTheme.primary, size: 22),
          const SizedBox(width: 10),
          const Text(
            '发现新版本',
            style: TextStyle(
              color: TvTheme.textPrimary,
              fontSize: 18 * TvTheme.fontScale,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('当前版本', current.display),
          _row('云端版本', newVersion),
          if (sizeText.isNotEmpty) _row('安装包大小', sizeText),
          if (sameVersionCode) ...[
            SizedBox(height: 10 * UiAdaptive.scale),
            const Text(
              '注意：云端这个包的版本号和当前一样。如果你是重新打了包但没改 '
              'pubspec.yaml 里的版本号，这是正常的，可以继续安装。',
              style: TextStyle(
                color: TvTheme.accent,
                fontSize: 12 * TvTheme.fontScale,
                height: 1.6,
              ),
            ),
          ],
          SizedBox(height: 12 * UiAdaptive.scale),
          const Text(
            '点「立即安装」会打开系统的安装界面，需要你在那里再确认一次。'
            '安装过程中 App 会退出，装完重新打开就是新版本了。',
            style: TextStyle(
              color: TvTheme.textSecondary,
              fontSize: 12 * TvTheme.fontScale,
              height: 1.6,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text(
            '稍后',
            style: TextStyle(color: TvTheme.textSecondary),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text(
            '立即安装',
            style: TextStyle(
              color: TvTheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    ),
  );
}

Widget _row(String label, String value) {
  return Padding(
    padding: EdgeInsets.symmetric(vertical: 3 * UiAdaptive.scale),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96 * UiAdaptive.scale,
          child: Text(
            label,
            style: const TextStyle(
              color: TvTheme.textSecondary,
              fontSize: 13 * TvTheme.fontScale,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: TvTheme.textPrimary,
              fontSize: 13 * TvTheme.fontScale,
            ),
          ),
        ),
      ],
    ),
  );
}
