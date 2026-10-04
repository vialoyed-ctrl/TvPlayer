import 'dart:convert';

import 'package:crypto/crypto.dart';

class CdndefendSolver {
  /// Solves the cdndefend SHA-1 Proof-of-Work challenge
  static String? solve(String html) {
    final regex = RegExp(r'''['"]([0-9A-Fa-f]{32,})['"]''');
    final match = regex.firstMatch(html);
    if (match == null) return null;

    final seed = match.group(1)!;
    final n1 = int.parse(seed[0], radix: 16);

    final seedBytes = utf8.encode(seed);

    for (int i = 0; i < 3000000; i++) {
      final iBytes = utf8.encode(i.toString());
      final combined = [...seedBytes, ...iBytes];
      final digest = sha1.convert(combined);
      final bytes = digest.bytes;

      if (n1 + 1 < bytes.length && bytes[n1] == 0xb0 && bytes[n1 + 1] == 0x0b) {
        return 'cdndefend_js_cookie=$seed$i';
      }
    }
    return null;
  }
}
