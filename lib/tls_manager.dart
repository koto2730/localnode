// tls_manager.dart
//
// CA 証明書とサーバー証明書を管理するクラス。
// openssl CLI を使用して証明書を生成し、SecurityContext を構築する。
// Flutter 非依存（path_provider を使わない）の純 Dart 実装。

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// LocalNode の HTTPS モードで使用する TLS 証明書マネージャー。
///
/// 使用方法:
/// ```dart
/// final mgr = TlsManager(Directory('/path/to/tls'));
/// await mgr.init();                           // CA 証明書を生成/ロード
/// final ctx = await mgr.ensureServerCert(ip); // サーバー証明書を生成/ロード
/// ```
class TlsManager {
  final Directory tlsDir;

  TlsManager(this.tlsDir);

  String? _caCertPem;

  // ---------------------------------------------------------------------------
  // ファイルパス
  // ---------------------------------------------------------------------------
  File get _caKeyFile => File(p.join(tlsDir.path, 'ca.key'));
  File get _caCertFile => File(p.join(tlsDir.path, 'ca.crt'));
  File get _serverKeyFile => File(p.join(tlsDir.path, 'server.key'));
  File get _serverCertFile => File(p.join(tlsDir.path, 'server.crt'));
  File get _serverCsrFile => File(p.join(tlsDir.path, 'server.csr'));
  File get _serverExtFile => File(p.join(tlsDir.path, 'server.ext'));
  File get _serverIpFile => File(p.join(tlsDir.path, 'server.ip'));

  // ---------------------------------------------------------------------------
  // 公開 API
  // ---------------------------------------------------------------------------

  /// openssl コマンドが使用可能か確認する。
  static Future<bool> isOpensslAvailable() async {
    try {
      final result = await Process.run('openssl', ['version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// TLS ディレクトリを作成し、CA 証明書を生成（なければ）する。
  Future<void> init() async {
    await tlsDir.create(recursive: true);
    await _ensureCa();
  }

  /// 指定した IP アドレス用のサーバー証明書を生成/ロードし、
  /// [SecurityContext] を返す。IP が変わった場合は証明書を再生成する。
  Future<SecurityContext> ensureServerCert(String ipAddress) async {
    await _ensureServerCert(ipAddress);

    final ctx = SecurityContext()
      ..useCertificateChain(_serverCertFile.path)
      ..usePrivateKey(_serverKeyFile.path);
    return ctx;
  }

  /// CA 証明書の PEM 文字列を返す。[init] 呼び出し後に有効。
  String get caCertPem => _caCertPem ?? '';

  /// CA 証明書のバイト列（DER）を返す。クライアントへの配布に使用。
  Future<List<int>> get caCertDerBytes async =>
      await _caCertFile.readAsBytes();

  /// iOS 向け .mobileconfig プロファイルの XML 文字列を生成して返す。
  Future<String> buildMobileconfig() async {
    final derBytes = await caCertDerBytes;
    final base64Cert = base64.encode(derBytes);
    final uuid1 = _generateUuid();
    final uuid2 = _generateUuid();
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadCertificateFileName</key>
      <string>LocalNodeCA.crt</string>
      <key>PayloadContent</key>
      <data>$base64Cert</data>
      <key>PayloadDescription</key>
      <string>LocalNode ローカルサーバーの CA 証明書</string>
      <key>PayloadDisplayName</key>
      <string>LocalNode CA</string>
      <key>PayloadIdentifier</key>
      <string>com.localnode.ca.$uuid1</string>
      <key>PayloadType</key>
      <string>com.apple.security.root</string>
      <key>PayloadUUID</key>
      <string>$uuid1</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
    </dict>
  </array>
  <key>PayloadDescription</key>
  <string>LocalNode CA 証明書をインストールします</string>
  <key>PayloadDisplayName</key>
  <string>LocalNode</string>
  <key>PayloadIdentifier</key>
  <string>com.localnode.$uuid2</string>
  <key>PayloadRemovalDisallowed</key>
  <false/>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>$uuid2</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>''';
  }

  // ---------------------------------------------------------------------------
  // 内部実装
  // ---------------------------------------------------------------------------

  Future<void> _ensureCa() async {
    if (await _caKeyFile.exists() && await _caCertFile.exists()) {
      _caCertPem = await _caCertFile.readAsString();
      return;
    }

    // CA 秘密鍵を生成
    await _run('openssl', ['genrsa', '-out', _caKeyFile.path, '2048']);

    // 自己署名 CA 証明書を生成（10年有効）
    await _run('openssl', [
      'req', '-new', '-x509',
      '-key', _caKeyFile.path,
      '-out', _caCertFile.path,
      '-days', '3650',
      '-subj', '/CN=LocalNode CA/O=LocalNode',
    ]);

    _caCertPem = await _caCertFile.readAsString();
  }

  Future<void> _ensureServerCert(String ipAddress) async {
    // IP が同じであれば既存の証明書を再利用
    if (await _serverIpFile.exists() &&
        await _serverKeyFile.exists() &&
        await _serverCertFile.exists()) {
      final savedIp = (await _serverIpFile.readAsString()).trim();
      if (savedIp == ipAddress) return;
    }

    // サーバー秘密鍵を生成
    await _run('openssl', ['genrsa', '-out', _serverKeyFile.path, '2048']);

    // CSR を生成
    await _run('openssl', [
      'req', '-new',
      '-key', _serverKeyFile.path,
      '-out', _serverCsrFile.path,
      '-subj', '/CN=$ipAddress',
    ]);

    // SAN 拡張ファイルを書き出す（IP アドレス SAN + serverAuth EKU）
    await _serverExtFile.writeAsString(
      'subjectAltName=IP:$ipAddress,IP:127.0.0.1\n'
      'extendedKeyUsage=serverAuth\n',
    );

    // CA で署名してサーバー証明書を発行（1年有効）
    await _run('openssl', [
      'x509', '-req',
      '-in', _serverCsrFile.path,
      '-CA', _caCertFile.path,
      '-CAkey', _caKeyFile.path,
      '-CAcreateserial',
      '-out', _serverCertFile.path,
      '-days', '365',
      '-extfile', _serverExtFile.path,
    ]);

    await _serverIpFile.writeAsString(ipAddress);
  }

  /// openssl コマンドを実行し、失敗時は例外を投げる。
  static Future<void> _run(String cmd, List<String> args) async {
    final result = await Process.run(cmd, args);
    if (result.exitCode != 0) {
      throw Exception('$cmd ${args.first} failed:\n${result.stderr}');
    }
  }

  /// HTTPS セットアップ案内 HTML を生成する。
  /// [ipAddress] はサーバーの IP、[httpsPort] は HTTPS ポート番号。
  static String buildSetupHtml(String ipAddress, int httpsPort) {
    final httpsUrl = 'https://$ipAddress:$httpsPort/';
    return '''<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>LocalNode - セキュリティ設定</title>
  <style>
    body{font-family:sans-serif;max-width:620px;margin:32px auto;padding:16px;color:#222}
    h1{color:#1a73e8;font-size:1.4em}
    h2{font-size:1.1em;margin-bottom:6px}
    .step{background:#f8f8f8;border:1px solid #e0e0e0;border-radius:8px;padding:16px;margin:14px 0}
    .btn{display:inline-block;background:#1a73e8;color:#fff;padding:10px 22px;
         border-radius:6px;text-decoration:none;font-size:1em;margin:8px 0}
    .btn.green{background:#2e7d32}
    .platform{display:none}
    ol{margin:6px 0;padding-left:20px}
    li{margin:4px 0}
  </style>
</head>
<body>
  <h1>LocalNode — HTTPS セットアップ</h1>
  <p>LocalNode に安全に接続するには、まず <strong>CA 証明書</strong> をこのデバイスにインストールしてください。</p>

  <div id="ios" class="step platform">
    <h2>iOS の手順</h2>
    <a class="btn" href="/ca.mobileconfig">証明書プロファイルをダウンロード</a>
    <ol>
      <li>上のボタンをタップしてプロファイルをダウンロード</li>
      <li><b>設定</b> →「プロファイルがダウンロードされました」→ <b>インストール</b></li>
      <li><b>設定</b> → <b>一般</b> → <b>情報</b> → <b>証明書信頼設定</b><br>
          「LocalNode CA」を <b>オン</b> にする</li>
    </ol>
  </div>

  <div id="android" class="step platform">
    <h2>Android の手順</h2>
    <a class="btn" href="/ca.crt" download="LocalNodeCA.crt">CA 証明書をダウンロード</a>
    <ol>
      <li>上のボタンをタップして証明書をダウンロード</li>
      <li><b>設定</b> → <b>セキュリティ</b> → <b>証明書のインストール</b> → <b>CA 証明書</b></li>
      <li>ダウンロードしたファイルを選択してインストール</li>
    </ol>
  </div>

  <div id="desktop" class="step platform">
    <h2>PC の手順</h2>
    <a class="btn" href="/ca.crt" download="LocalNodeCA.crt">CA 証明書をダウンロード</a>
    <ol>
      <li><b>Windows:</b> ダウンロードしたファイルをダブルクリック → 「信頼されたルート証明機関」にインストール</li>
      <li><b>macOS:</b> ダウンロードしたファイルをダブルクリック → キーチェーンアクセスで「常に信頼」に設定</li>
      <li><b>Linux:</b> <code>/usr/local/share/ca-certificates/</code> にコピーして <code>sudo update-ca-certificates</code> を実行</li>
    </ol>
  </div>

  <div class="step">
    <h2>インストール完了後</h2>
    <p>証明書のインストールが終わったら、下のボタンで LocalNode に接続してください。</p>
    <a class="btn green" href="$httpsUrl">LocalNode に接続する →</a>
  </div>

  <script>
    const ua = navigator.userAgent;
    let platform = 'desktop';
    if (/iPhone|iPad|iPod/.test(ua)) platform = 'ios';
    else if (/Android/.test(ua)) platform = 'android';
    const el = document.getElementById(platform);
    if (el) el.style.display = 'block';
  </script>
</body>
</html>''';
  }

  /// ランダムな UUID v4 文字列を生成する。
  static String _generateUuid() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
