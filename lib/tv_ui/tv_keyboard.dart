import 'package:flutter/material.dart';

import 'tv_theme.dart';
import 'tv_focus_widget.dart';

class TvKeyboard extends StatelessWidget {
  final ValueChanged<String> onKeyPressed;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback onSearch;
  final VoidCallback? onOpenSystemKeyboard;

  const TvKeyboard({
    super.key,
    required this.onKeyPressed,
    required this.onBackspace,
    required this.onClear,
    required this.onSearch,
    this.onOpenSystemKeyboard,
  });

  static const List<String> _keys = [
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    '0',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      // 宽度由外层 SizedBox 决定，避免两处硬编码宽度不一致
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: TvTheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        children: [
          // Key Grid (6 cols)
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.0,
            ),
            itemCount: _keys.length,
            itemBuilder: (context, index) {
              final keyChar = _keys[index];
              return TvFocusWidget(
                borderRadius: 8,
                scale: 1.12,
                onTap: () => onKeyPressed(keyChar),
                child: Container(
                  color: TvTheme.surfaceLighter,
                  alignment: Alignment.center,
                  child: Text(
                    keyChar,
                    style: const TextStyle(
                      color: TvTheme.textPrimary,
                      fontSize: 16 * TvTheme.fontScale,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          // Action Buttons
          Row(
            children: [
              Expanded(
                child: TvFocusWidget(
                  borderRadius: 8,
                  onTap: onBackspace,
                  child: Container(
                    height: 76,
                    color: TvTheme.surfaceLighter,
                    alignment: Alignment.center,
                    child: const Text(
                      '退格',
                      style: TextStyle(
                        color: TvTheme.textPrimary,
                        fontSize: 13 * TvTheme.fontScale,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TvFocusWidget(
                  borderRadius: 8,
                  onTap: onClear,
                  child: Container(
                    height: 76,
                    color: TvTheme.surfaceLighter,
                    alignment: Alignment.center,
                    child: const Text(
                      '清空',
                      style: TextStyle(
                        color: TvTheme.textSecondary,
                        fontSize: 13 * TvTheme.fontScale,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TvFocusWidget(
                  borderRadius: 8,
                  onTap: onSearch,
                  focusBorderColor: TvTheme.accent,
                  child: Container(
                    height: 76,
                    color: TvTheme.accent.withValues(alpha: 0.8),
                    alignment: Alignment.center,
                    child: const Text(
                      '搜索',
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 13 * TvTheme.fontScale,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (onOpenSystemKeyboard != null) ...[
            const SizedBox(height: 10),
            TvFocusWidget(
              borderRadius: 8,
              onTap: onOpenSystemKeyboard!,
              focusBorderColor: TvTheme.primary,
              child: Container(
                height: 72,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: TvTheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: TvTheme.primary.withValues(alpha: 0.4),
                  ),
                ),
                alignment: Alignment.center,
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.keyboard_alt_outlined,
                      color: TvTheme.primary,
                      size: 16,
                    ),
                    SizedBox(width: 6),
                    Text(
                      '呼出系统键盘 / 语音输入',
                      style: TextStyle(
                        color: TvTheme.primary,
                        fontSize: 13 * TvTheme.fontScale,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
