// 証明書 SAN とホスト名の照合（ワイルドカード対応）。
//
// RFC 6125 §6.4.3 に沿った保守的な実装:
//   - 大文字小文字は区別しない。末尾ドットは無視する
//   - ワイルドカードは左端ラベルが "*" ちょうどの場合のみ有効
//     （"f*o.example.com" のような部分ワイルドカードは扱わない）
//   - "*" は 1 ラベルにだけ一致する
//       *.example.com  →  a.example.com      : 一致
//       *.example.com  →  a.b.example.com    : 不一致
//       *.example.com  →  example.com        : 不一致
//   - "*.com" のようにワイルドカード以下が 1 ラベルしかないものは拒否
//   - IP アドレス SAN は完全一致のみ（ワイルドカード不可）

import 'dart:io';

/// [host] が SAN エントリ [san] にカバーされるか。
bool sanMatchesHost(String san, String host) {
  final s = _normalize(san);
  final h = _normalize(host);
  if (s.isEmpty || h.isEmpty) return false;

  // IP アドレスはどちらか一方でも IP なら完全一致のみ
  final sIp = InternetAddress.tryParse(s);
  final hIp = InternetAddress.tryParse(h);
  if (sIp != null || hIp != null) {
    if (sIp == null || hIp == null) return false;
    // IPv6 の表記ゆれ (::1 / 0:0:...:1) を吸収するためバイト列で比較
    final a = sIp.rawAddress, b = hIp.rawAddress;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  if (!s.startsWith('*.')) return s == h;

  final base = s.substring(2);
  // "*.com" 等、ワイルドカード以下が 1 ラベルのみは拒否
  if (!base.contains('.')) return false;
  if (base.contains('*')) return false;
  if (!h.endsWith('.$base')) return false;
  final label = h.substring(0, h.length - base.length - 1);
  return label.isNotEmpty && !label.contains('.') && label != '*';
}

/// [host] が [sans] のいずれかにカバーされるか。
bool sansCoverHost(Iterable<String> sans, String host) =>
    sans.any((san) => sanMatchesHost(san, host));

String _normalize(String v) {
  var x = v.trim().toLowerCase();
  if (x.endsWith('.')) x = x.substring(0, x.length - 1);
  return x;
}
