// localnode-cli — Flutter/GTK 非依存の CLI サーバーバイナリ
//
// dart compile exe bin/localnode_cli.dart -o localnode-cli
//
// Linux ヘッドレス環境（Raspberry Pi 等）向けに localnode GUI バイナリとは
// 独立してビルド・実行できる。GTK/display への依存を一切持たない。

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:qr/qr.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

// =============================================================================
// エントリポイント
// =============================================================================

Future<void> main(List<String> args) async {
  final parser = _buildParser();

  if (args.contains('--help') || args.contains('-h')) {
    _printUsage(parser);
    _flushWindowsInput();
    exit(0);
  }

  final ArgResults results;
  try {
    results = parser.parse(args);
  } catch (e) {
    stderr.writeln('Error: $e');
    stderr.writeln('');
    _printUsage(parser);
    exit(1);
  }

  final port = int.tryParse(results['port'] as String);
  if (port == null || port < 1 || port > 65535) {
    stderr.writeln('Error: Invalid port number. Must be between 1 and 65535.');
    exit(1);
  }

  final dir = results['dir'] as String?;
  if (dir != null && !Directory(dir).existsSync()) {
    stderr.writeln('Error: Directory does not exist: $dir');
    exit(1);
  }

  final specifiedIp = results['ip'] as String?;
  final noClipboard = results['no-clipboard'] as bool;
  final verbose = results['verbose'] as bool;
  final downloadOnly = (results['mode'] as String) == 'download-only';
  final noPin = results['no-pin'] as bool;
  final fixedPin = results['pin'] as String?;
  final serverName = results['name'] as String;
  final noToken = results['no-token'] as bool;
  final fixedToken = results['token'] as String?;
  final postActionRaw = results['post-action'] as List<String>;
  final postActions = <({String pattern, String script})>[];
  for (final entry in postActionRaw) {
    final eq = entry.indexOf('=');
    if (eq <= 0) {
      stderr.writeln('Error: --post-action must be in <pattern>=<script> format: $entry');
      exit(1);
    }
    final pattern = entry.substring(0, eq).trim();
    final script = entry.substring(eq + 1).trim();
    if (pattern.isEmpty || script.isEmpty) {
      stderr.writeln('Error: --post-action pattern and script must not be empty: $entry');
      exit(1);
    }
    postActions.add((pattern: pattern, script: script));
  }
  final mentionActionRaw = results['mention-action'] as List<String>;
  final mentionActions = <String, String>{};
  for (final entry in mentionActionRaw) {
    final eq = entry.indexOf('=');
    if (eq <= 0) {
      stderr.writeln('Error: --mention-action must be in <alias>=<script> format: $entry');
      exit(1);
    }
    final alias = entry.substring(0, eq).trim();
    final script = entry.substring(eq + 1).trim();
    if (alias.isEmpty || script.isEmpty) {
      stderr.writeln('Error: --mention-action alias and script must not be empty: $entry');
      exit(1);
    }
    if (alias == 'list') {
      stderr.writeln('Error: "list" is a reserved mention name and cannot be used as an alias.');
      exit(1);
    }
    mentionActions[alias] = script;
  }
  final httpsCertPath = results['https-cert'] as String?;
  final httpsKeyPath = results['https-key'] as String?;
  if ((httpsCertPath == null) != (httpsKeyPath == null)) {
    stderr.writeln('Error: --https-cert and --https-key must be specified together.');
    exit(1);
  }
  if (httpsCertPath != null && !File(httpsCertPath).existsSync()) {
    stderr.writeln('Error: Certificate file does not exist: $httpsCertPath');
    exit(1);
  }
  if (httpsKeyPath != null && !File(httpsKeyPath).existsSync()) {
    stderr.writeln('Error: Key file does not exist: $httpsKeyPath');
    exit(1);
  }
  final bool httpsMode = httpsCertPath != null && httpsKeyPath != null;

  final authMode = noPin
      ? _AuthMode.noPin
      : fixedPin != null
          ? _AuthMode.fixedPin
          : _AuthMode.randomPin;

  // #177/#169: HTTPS モードで SAN→ホスト名→IP 解決フロー
  String ipAddress;
  String advertisedHost; // QR/URL に使うホスト名またはIP
  if (httpsMode) {
    final sanResult = await _resolveHttpsHost(
        certPath: httpsCertPath!, specifiedIp: specifiedIp);
    ipAddress = sanResult.bindIp;
    advertisedHost = sanResult.advertisedHost;
  } else {
    ipAddress = specifiedIp ?? await _selectIpAddress();
    advertisedHost = ipAddress;
  }

  stdout.writeln('');
  stdout.writeln('LocalNode CLI Server');
  stdout.writeln('=' * 40);

  // #173: アップロードトークンの決定（download-only モードでは不要）
  final String? uploadToken = (!noToken && !downloadOnly)
      ? (fixedToken ?? _generateUploadToken())
      : null;

  final server = _CliServer(verbose: verbose);

  try {
    await server.start(
      ipAddress: ipAddress,
      port: port,
      storagePath: dir,
      downloadOnly: downloadOnly,
      authMode: authMode,
      fixedPin: fixedPin,
      serverName: serverName,
      clipboardEnabled: !noClipboard,
      httpsCertPath: httpsCertPath,
      httpsKeyPath: httpsKeyPath,
      uploadToken: uploadToken,
      postActions: postActions,
      mentionActions: mentionActions,
    );
  } catch (e) {
    stderr.writeln('Error: Failed to start server: $e');
    exit(1);
  }

  final scheme = httpsMode ? 'https' : 'http';
  final serverUrl = '$scheme://$advertisedHost:$port';

  stdout.writeln('Server started.');
  stdout.writeln('');
  stdout.writeln('  URL:  $serverUrl');
  if (authMode != _AuthMode.noPin) {
    stdout.writeln('  PIN:  ${server.pin}');
  } else {
    stdout.writeln('  PIN:  disabled (no auth)');
  }
  stdout.writeln('  Name: $serverName');
  stdout.writeln('  Mode: ${downloadOnly ? "download-only" : "normal"}');
  if (postActions.isNotEmpty) {
    stdout.writeln('  Post-action(s):');
    for (final a in postActions) {
      stdout.writeln('    ${a.pattern} -> ${a.script}');
    }
  }
  if (mentionActions.isNotEmpty) {
    stdout.writeln('  Mention action(s):');
    for (final entry in mentionActions.entries) {
      stdout.writeln('    @run ${entry.key} -> ${entry.value}');
    }
  }
  if (uploadToken != null) {
    stdout.writeln('  Upload Token: $uploadToken');
    stdout.writeln('');
    stdout.writeln('  curl example:');
    stdout.writeln('    curl -H "Authorization: Bearer $uploadToken" \\');
    stdout.writeln('         -F "file=@/path/to/file" \\');
    stdout.writeln('         $serverUrl/api/upload');
  }
  stdout.writeln('');
  stdout.writeln('QR Code:');
  _printQrCode(serverUrl);
  stdout.writeln('');
  stdout.writeln('Press Ctrl+C to stop.');
  stdout.writeln('');

  _setupSignalHandlers(server);
  if (!noClipboard) _startClipboardPolling(server);
  // Windows: disable echo/line-input to prevent typed chars from appearing (#139)
  // and flush residual keystrokes to prevent prompt mid-screen (#129).
  if (Platform.isWindows) {
    _setWindowsConsoleRawMode();
    _flushWindowsInput();
  }
  await _waitForQuit(server);
}

// =============================================================================
// 引数パーサー
// =============================================================================

ArgParser _buildParser() {
  return ArgParser()
    ..addOption('port',
        abbr: 'p', help: 'Server port number', defaultsTo: '8080')
    ..addOption('ip', help: 'IP address to bind (skip auto-detection)')
    ..addOption('pin', help: 'Fixed PIN (random if not specified)')
    ..addOption('dir', abbr: 'd', help: 'Shared directory path')
    ..addOption('mode',
        abbr: 'm',
        help: 'Operation mode',
        defaultsTo: 'normal',
        allowed: ['normal', 'download-only'])
    ..addFlag('no-pin', help: 'Disable PIN authentication', negatable: false)
    ..addFlag('no-clipboard',
        help: 'Suppress clipboard output in console', negatable: false)
    ..addFlag('verbose',
        abbr: 'v', help: 'Enable verbose request logging', negatable: false)
    ..addOption('name',
        abbr: 'n', help: 'Server name shown in browser tab title', defaultsTo: 'LocalNode')
    ..addOption('https-cert', help: 'Path to TLS certificate file (cert.pem)')
    ..addOption('https-key', help: 'Path to TLS private key file (key.pem)')
    ..addMultiOption('post-action',
        help:
            'Script to run after matching uploads: <pattern>=<script> (repeatable). '
            'Pattern is a glob matched against the filename (e.g. *.zip, *.png, *). '
            'Runs as the server process user. '
            'Use only on trusted networks. If running as a systemd service, set User= to a '
            'low-privilege account.',
        valueHelp: 'pattern=script')
    ..addMultiOption('mention-action',
        help:
            'Register a clipboard mention command: <alias>=<script>. '
            'Send "@run <alias>" via clipboard to trigger the script (repeatable). '
            'Runs as the server process user.',
        valueHelp: 'alias=script')
    ..addOption('token', help: 'Fixed upload token (random if not specified)')
    ..addFlag('no-token',
        help: 'Disable token-based upload authentication', negatable: false)
    ..addFlag('help', abbr: 'h', help: 'Show this help', negatable: false);
}

void _printUsage(ArgParser parser) {
  stdout.writeln('LocalNode CLI - Local file & clipboard sharing server');
  stdout.writeln('');
  stdout.writeln('Usage: localnode-cli [options]');
  stdout.writeln('');
  stdout.writeln('Options:');
  stdout.writeln(parser.usage);
  stdout.writeln('');
  stdout.writeln('Examples:');
  stdout.writeln('  localnode-cli');
  stdout.writeln('  localnode-cli -p 3000 --pin 1234');
  stdout.writeln('  localnode-cli -d /path/to/share --ip 192.168.1.100');
  stdout.writeln('  localnode-cli --mode download-only --no-pin');
  stdout.writeln('  localnode-cli --no-clipboard --verbose');
  stdout.writeln('  localnode-cli --name "MyServer"');
  stdout.writeln('  localnode-cli --https-cert /path/to/cert.pem --https-key /path/to/key.pem');
  stdout.writeln('  localnode-cli --post-action "*.png=./resize.sh" --post-action "*.zip=./unzip.sh"');
  stdout.writeln('  localnode-cli --mention-action backup=./backup.sh --mention-action notify=./notify.sh');
  stdout.writeln('');
  stdout.writeln('Security note (--post-action / --mention-action):');
  stdout.writeln('  Scripts run with the same user privileges as the LocalNode process.');
  stdout.writeln('  If running as a systemd service, set User= to a low-privilege account.');
  stdout.writeln('  Use only on trusted networks.');
  stdout.writeln('');
  stdout.writeln('To stop: Ctrl+C');
}

// =============================================================================
// IPアドレス選択
// =============================================================================

Future<String> _selectIpAddress() async {
  final addresses = <String>[];
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        addresses.add(addr.address);
      }
    }
  } catch (_) {}

  if (addresses.isEmpty) return '0.0.0.0';
  if (addresses.length == 1) return addresses.first;

  if (stdin.hasTerminal && _isInteractiveForeground()) {
    stdout.writeln('Multiple network interfaces detected:');
    for (int i = 0; i < addresses.length; i++) {
      stdout.writeln('  [${i + 1}] ${addresses[i]}');
    }
    stdout.write('Select IP address [1-${addresses.length}] (default: 1): ');
    try {
      final input = stdin.readLineSync()?.trim();
      if (input != null && input.isNotEmpty) {
        final idx = int.tryParse(input);
        if (idx != null && idx >= 1 && idx <= addresses.length) {
          return addresses[idx - 1];
        }
      }
    } catch (_) {}
  } else {
    // Non-interactive mode (background launch with &, piped stdin, etc.).
    // Automatically select the first IP and inform the user via stdout.
    // Use --ip <address> to specify a different interface (#97).
    stdout.writeln('Multiple network interfaces detected. '
        'Running in non-interactive mode; auto-selecting ${addresses.first}.');
    stdout.writeln('Use --ip <address> to specify a different interface.');
  }

  return addresses.first;
}

// =============================================================================
// QRコード表示
// =============================================================================

void _printQrCode(String data) {
  final qrCode = QrCode.fromData(
    data: data,
    errorCorrectLevel: QrErrorCorrectLevel.L,
  );
  final qrImage = QrImage(qrCode);
  stdout.writeln('');
  for (int y = 0; y < qrImage.moduleCount; y++) {
    final buf = StringBuffer('  ');
    for (int x = 0; x < qrImage.moduleCount; x++) {
      buf.write(qrImage.isDark(y, x) ? '\u2588\u2588' : '  ');
    }
    stdout.writeln(buf.toString());
  }
}

// =============================================================================
// シグナルハンドラ・終了処理
// =============================================================================

bool _shuttingDown = false;


void _setupSignalHandlers(_CliServer server) {
  try {
    ProcessSignal.sigint.watch().listen((_) async {
      await _shutdown(server);
    });
  } catch (_) {}

  if (!Platform.isWindows) {
    for (final sig in [ProcessSignal.sigterm, ProcessSignal.sighup]) {
      try {
        sig.watch().listen((_) async {
          await _shutdown(server);
        });
      } catch (_) {}
    }
  }
}

Future<void> _waitForQuit(_CliServer server) async {
  // On Windows, avoid calling stdin.listen() as it causes PowerShell to treat
  // the process as background and show the prompt immediately (#140).
  // On other platforms, drain stdin silently to prevent buffered input from
  // leaking to the parent shell after exit.
  if (!Platform.isWindows) {
    if (stdin.hasTerminal) stdin.listen((_) {}, onError: (_) {});
  }
  await Completer<void>().future;
}

Future<void> _shutdown(_CliServer server) async {
  if (_shuttingDown) return;
  _shuttingDown = true;
  _restoreWindowsConsoleMode();
  _flushWindowsInput();
  stdout.writeln('');
  stdout.writeln('Shutting down...');
  await server.stop();
  stdout.writeln('Server stopped.');
  exit(0);
}

// =============================================================================
// クリップボードポーリング（コンソール出力）
// =============================================================================

Timer? _clipboardTimer;
int _lastClipboardModified = 0;

void _startClipboardPolling(_CliServer server) {
  _lastClipboardModified = server.clipboardLastModified;
  _clipboardTimer = Timer.periodic(const Duration(seconds: 2), (_) {
    final current = server.clipboardLastModified;
    if (current != _lastClipboardModified) {
      _lastClipboardModified = current;
      final items = server.clipboardItems;
      if (items.isNotEmpty) {
        final latest = items.first;
        stdout.writeln('');
        final tagLabel = latest.tag != null ? '[${latest.tag}] ' : '';
        stdout.writeln(
            '[Clipboard] $tagLabel${latest.createdAt.toLocal().toString().substring(11, 19)}');
        final text = latest.text;
        stdout.writeln('  ${text.length > 200 ? '${text.substring(0, 200)}...' : text}');
      }
    }
  });
}

// =============================================================================
// Windows コンソール制御（FFI）
// =============================================================================

/// Returns true if the process is in the foreground process group of its
/// controlling terminal. On Linux/macOS this detects background launch with &,
/// which causes stdin.hasTerminal to still return true but makes readLineSync
/// trigger SIGTTIN, stopping the process (#130).
/// Always returns true on Windows (not applicable).
bool _isInteractiveForeground() {
  if (Platform.isWindows) return true;
  try {
    final libc = DynamicLibrary.open(
        Platform.isMacOS ? 'libSystem.dylib' : 'libc.so.6');
    final tcgetpgrp = libc.lookupFunction<Int32 Function(Int32),
        int Function(int)>('tcgetpgrp');
    final getpgrp = libc.lookupFunction<Int32 Function(),
        int Function()>('getpgrp');
    return tcgetpgrp(0) == getpgrp();
  } catch (_) {
    return true;
  }
}

// =============================================================================
// HTTPS: SAN → ホスト名 → IP 解決 (#177, #169)
// =============================================================================

class _HttpsHostResult {
  final String bindIp;
  final String advertisedHost;
  _HttpsHostResult({required this.bindIp, required this.advertisedHost});
}

/// cert の SAN を解析し、バインド IP と広告ホストを決定する。
/// - SANのホスト名をデバイスIPに解決して候補を絞り込む
/// - 候補が1つなら自動決定、複数なら対話選択
/// - 一致しない場合はエラー終了 (#169)
Future<_HttpsHostResult> _resolveHttpsHost({
  required String certPath,
  String? specifiedIp,
}) async {
  // SAN を解析
  List<String> sans = [];
  try {
    final raw = await File(certPath).readAsString();
    final begin = '-----BEGIN CERTIFICATE-----';
    final end = '-----END CERTIFICATE-----';
    final startIdx = raw.indexOf(begin);
    final endIdx = startIdx >= 0 ? raw.indexOf(end, startIdx) : -1;
    if (startIdx >= 0 && endIdx >= 0) {
      final pem = raw.substring(startIdx, endIdx + end.length);
      final cert = X509Utils.x509CertificateFromPem(pem);
      sans = cert.subjectAlternativNames ?? [];
    }
  } catch (e) {
    stderr.writeln('Warning: Failed to parse certificate SANs: $e');
  }

  if (sans.isEmpty) {
    stderr.writeln('Error: No SANs found in certificate. Cannot determine HTTPS hostname.');
    exit(1);
  }

  // デバイスの IP 一覧を取得
  final deviceIps = <String>{};
  try {
    for (final iface in await NetworkInterface.list()) {
      for (final addr in iface.addresses) {
        deviceIps.add(addr.address);
      }
    }
  } catch (_) {}

  // --ip 指定時はその IP が SAN に含まれるか検証 (#169)
  if (specifiedIp != null) {
    bool covered = sans.contains(specifiedIp);
    if (!covered) {
      // ホスト名 SAN を DNS 解決して照合
      for (final san in sans) {
        if (InternetAddress.tryParse(san) == null) {
          try {
            final addrs = await InternetAddress.lookup(san);
            if (addrs.any((a) => a.address == specifiedIp)) {
              covered = true;
              break;
            }
          } catch (_) {}
        }
      }
    }
    if (!covered) {
      stderr.writeln(
          'Error: The certificate does not cover the specified IP "$specifiedIp".');
      stderr.writeln('  Certificate SANs: ${sans.join(', ')}');
      exit(1);
    }
    return _HttpsHostResult(bindIp: specifiedIp, advertisedHost: specifiedIp);
  }

  // SAN のホスト名をデバイス IP に解決して候補を抽出
  final candidates = <({String host, String ip})>[];
  for (final san in sans) {
    if (InternetAddress.tryParse(san) != null) {
      // IP SAN: デバイス IP と一致するか確認
      if (deviceIps.contains(san)) {
        candidates.add((host: san, ip: san));
      }
    } else {
      // ホスト名 SAN: DNS 解決してデバイス IP と照合
      try {
        final addrs = await InternetAddress.lookup(san);
        for (final addr in addrs) {
          if (deviceIps.contains(addr.address)) {
            candidates.add((host: san, ip: addr.address));
            break;
          }
        }
      } catch (_) {}
    }
  }

  if (candidates.isEmpty) {
    stderr.writeln(
        'Error: Certificate SANs do not match any device IP address. Cannot start HTTPS server.');
    stderr.writeln('  Certificate SANs: ${sans.join(', ')}');
    stderr.writeln('  Device IPs: ${deviceIps.join(', ')}');
    stderr.writeln('  Use --ip <address> to override, or fix the certificate.');
    exit(1);
  }

  if (candidates.length == 1) {
    final c = candidates.first;
    stdout.writeln('HTTPS: Using "${c.host}" (resolved to ${c.ip})');
    return _HttpsHostResult(bindIp: c.ip, advertisedHost: c.host);
  }

  // 複数候補 → 対話選択
  if (stdin.hasTerminal && _isInteractiveForeground()) {
    stdout.writeln('Multiple HTTPS hostname candidates detected:');
    for (int i = 0; i < candidates.length; i++) {
      final c = candidates[i];
      stdout.writeln('  [${i + 1}] ${c.host} (${c.ip})');
    }
    stdout.write('Select [1-${candidates.length}] (default: 1): ');
    try {
      final input = stdin.readLineSync()?.trim();
      if (input != null && input.isNotEmpty) {
        final idx = int.tryParse(input);
        if (idx != null && idx >= 1 && idx <= candidates.length) {
          final c = candidates[idx - 1];
          return _HttpsHostResult(bindIp: c.ip, advertisedHost: c.host);
        }
      }
    } catch (_) {}
  }
  final c = candidates.first;
  stdout.writeln('HTTPS: Auto-selecting "${c.host}" (${c.ip})');
  return _HttpsHostResult(bindIp: c.ip, advertisedHost: c.host);
}

/// ランダムなアップロードトークンを生成する（32文字の16進数）
String _generateUploadToken() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

void _flushWindowsInput() {
  if (!Platform.isWindows) return;
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getHandle = kernel32.lookupFunction<IntPtr Function(Uint32),
        int Function(int)>('GetStdHandle');
    final flush = kernel32.lookupFunction<Int32 Function(IntPtr),
        int Function(int)>('FlushConsoleInputBuffer');
    flush(getHandle(0xFFFFFFF6));
  } catch (_) {}
}

void _restoreWindowsConsoleMode() {
  if (!Platform.isWindows) return;
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getHandle = kernel32.lookupFunction<IntPtr Function(Uint32),
        int Function(int)>('GetStdHandle');
    final setMode = kernel32.lookupFunction<Int32 Function(IntPtr, Uint32),
        int Function(int, int)>('SetConsoleMode');
    setMode(getHandle(0xFFFFFFF6), 0x0007);
  } catch (_) {}
}

/// Disable echo and line-input so typed characters don't appear on screen
/// while the server is running (#139). ENABLE_PROCESSED_INPUT (0x1) is kept
/// so that Ctrl+C continues to work.
void _setWindowsConsoleRawMode() {
  if (!Platform.isWindows) return;
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getHandle = kernel32.lookupFunction<IntPtr Function(Uint32),
        int Function(int)>('GetStdHandle');
    final setMode = kernel32.lookupFunction<Int32 Function(IntPtr, Uint32),
        int Function(int, int)>('SetConsoleMode');
    // ENABLE_PROCESSED_INPUT (0x1) only: disables ENABLE_LINE_INPUT and ENABLE_ECHO_INPUT
    setMode(getHandle(0xFFFFFFF6), 0x0001);
  } catch (_) {}
}

// =============================================================================
// 認証モード
// =============================================================================

enum _AuthMode { randomPin, fixedPin, noPin }

// =============================================================================
// クリップボードアイテム
// =============================================================================

class _ClipboardItem {
  final String id;
  final String text;
  final String? tag;
  final DateTime createdAt;

  _ClipboardItem({
    required this.id,
    required this.text,
    this.tag,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'tag': tag,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };
}

// =============================================================================
// CLI サーバー（GTK/Flutter 非依存）
// =============================================================================

class _CliServer {
  static const int _maxClipboardItems = 10;
  static const int _maxTextLength = 10000;
  static const int _maxFailedAttempts = 5;
  static const Duration _lockoutDuration = Duration(minutes: 5);

  final bool verbose;
  HttpServer? _server;
  String? _pin;
  _AuthMode _authMode = _AuthMode.randomPin;
  bool _downloadOnly = false;
  bool _clipboardEnabled = true;
  String _serverName = 'LocalNode';
  int _startedAt = 0;

  String? _storagePath;
  Directory? _webRootDir;
  Directory? _thumbnailCacheDir;

  final List<_ClipboardItem> _clipboardItems = [];
  int _clipboardLastModified = 0;

  final Set<String> _sessions = {};
  final Map<String, int> _failedAttempts = {};
  final Map<String, DateTime> _lockoutUntil = {};
  String? _uploadToken;
  List<({String pattern, String script})> _postActions = [];
  Map<String, String> _mentionActions = {};

  late final Router _router;

  String? get pin => _pin;
  List<_ClipboardItem> get clipboardItems => List.unmodifiable(_clipboardItems);
  int get clipboardLastModified => _clipboardLastModified;

  _CliServer({required this.verbose}) {
    _router = Router()
      ..post('/api/auth', _authHandler)
      ..get('/api/health', _healthHandler)
      ..get('/api/info', _infoHandler)
      ..get('/api/files', _getFilesHandler)
      ..post('/api/upload', _uploadHandler)
      ..get('/api/download/<id>', _downloadHandler)
      ..get('/api/thumbnail/<id>', _thumbnailHandler)
      ..get('/api/download-all', _downloadAllHandler)
      ..delete('/api/files/<id>', _deleteFileHandler)
      ..delete('/api/files', _deleteAllFilesHandler)
      ..get('/api/clipboard', _getClipboardHandler)
      ..post('/api/clipboard', _postClipboardHandler)
      ..delete('/api/clipboard/<id>', _deleteClipboardItemHandler)
      ..delete('/api/clipboard', _clearClipboardHandler);
  }

  void _log(String message) {
    if (verbose) print(message);
  }

  // --- 起動 ---

  Future<void> start({
    required String ipAddress,
    required int port,
    String? storagePath,
    bool downloadOnly = false,
    _AuthMode authMode = _AuthMode.randomPin,
    String? fixedPin,
    String serverName = 'LocalNode',
    bool clipboardEnabled = true,
    String? httpsCertPath,
    String? httpsKeyPath,
    String? uploadToken,
    List<({String pattern, String script})> postActions = const [],
    Map<String, String> mentionActions = const {},
  }) async {
    _authMode = authMode;
    _downloadOnly = downloadOnly;
    _uploadToken = uploadToken;
    _postActions = postActions;
    _mentionActions = mentionActions;
    _clipboardEnabled = clipboardEnabled;
    _serverName = serverName;
    _startedAt = DateTime.now().millisecondsSinceEpoch;

    switch (authMode) {
      case _AuthMode.randomPin:
        _pin = _generatePin();
      case _AuthMode.fixedPin:
        _pin = fixedPin ?? _generatePin();
      case _AuthMode.noPin:
        _pin = null;
    }

    await _init(storagePath);
    await _deployAssets();

    final staticHandler =
        createStaticHandler(_webRootDir!.path, defaultDocument: 'index.html');
    final apiHandler = const Pipeline()
        .addMiddleware(_authMiddleware)
        .addHandler(_router.call);
    final cascade = Cascade().add(apiHandler).add(staticHandler);

    final handler = verbose
        ? const Pipeline()
            .addMiddleware(logRequests())
            .addHandler(cascade.handler)
        : const Pipeline().addHandler(cascade.handler);

    if (httpsCertPath != null && httpsKeyPath != null) {
      final secCtx = SecurityContext()
        ..useCertificateChain(httpsCertPath)
        ..usePrivateKey(httpsKeyPath);
      _server = await shelf_io.serve(
        handler, InternetAddress.anyIPv4, port,
        securityContext: secCtx,
      );
      _log('Serving at https://$ipAddress:$port');
    } else {
      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
      _log('Serving at http://$ipAddress:$port');
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  // --- 初期化 ---

  Future<void> _init(String? storagePath) async {
    if (storagePath != null) {
      _storagePath = storagePath;
    } else {
      _storagePath = Directory.current.path;
    }

    final dir = Directory(_storagePath!);
    if (!await dir.exists()) await dir.create(recursive: true);

    final tmpBase = Platform.environment['TMPDIR'] ??
        Platform.environment['TEMP'] ??
        '/tmp';
    _thumbnailCacheDir =
        Directory(p.join(tmpBase, 'localnode_cli_thumbnails'));
    if (!await _thumbnailCacheDir!.exists()) {
      await _thumbnailCacheDir!.create(recursive: true);
    }
  }

  Future<void> _deployAssets() async {
    final tmpBase = Platform.environment['TMPDIR'] ??
        Platform.environment['TEMP'] ??
        '/tmp';
    _webRootDir = Directory(p.join(tmpBase, 'localnode_cli_web'));
    if (await _webRootDir!.exists()) {
      await _webRootDir!.delete(recursive: true);
    }
    await _webRootDir!.create(recursive: true);

    final exeDir = p.dirname(Platform.resolvedExecutable);
    final candidates = [
      // Linux bundle: data/flutter_assets/assets/web/index.html
      p.join(exeDir, 'data', 'flutter_assets', 'assets', 'web', 'index.html'),
      // Windows bundle
      p.join(exeDir, 'data', 'flutter_assets', 'assets', 'web', 'index.html'),
      // macOS .app
      p.join(exeDir, '..', 'Frameworks', 'App.framework', 'Versions', 'A',
          'Resources', 'flutter_assets', 'assets', 'web', 'index.html'),
      // generic fallback
      p.join(exeDir, 'assets', 'web', 'index.html'),
      p.join(Directory.current.path, 'assets', 'web', 'index.html'),
    ];

    File? src;
    for (final candidate in candidates) {
      final f = File(candidate);
      if (f.existsSync()) {
        src = f;
        break;
      }
    }

    final dest = File(p.join(_webRootDir!.path, 'index.html'));
    if (src != null) {
      await src.copy(dest.path);
    } else {
      await dest.writeAsString(_minimalHtml());
      stderr.writeln('Warning: Web assets not found. Using minimal HTML.');
    }
  }

  String _minimalHtml() => '''<!DOCTYPE html>
<html><head><meta charset="UTF-8">
<title>LocalNode</title></head>
<body><h1>LocalNode Server</h1><p>Web UI assets not found.</p></body>
</html>''';

  // --- ユーティリティ ---

  String _generatePin() => (1000 + Random().nextInt(9000)).toString();

  String _generateToken() {
    final r = Random.secure();
    return base64Url.encode(List.generate(16, (_) => r.nextInt(256)));
  }

  String _generateId() {
    final r = Random.secure();
    return base64Url.encode(List.generate(8, (_) => r.nextInt(256)));
  }

  String _getClientIp(Request req) {
    final fwd = req.headers['x-forwarded-for'];
    if (fwd != null && fwd.isNotEmpty) return fwd.split(',').first.trim();
    return req.headers['x-real-ip'] ?? 'unknown';
  }

  String _getMimeType(String filename) {
    const types = {
      '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
      '.gif': 'image/gif', '.webp': 'image/webp', '.bmp': 'image/bmp',
      '.svg': 'image/svg+xml', '.mp4': 'video/mp4', '.mov': 'video/quicktime',
      '.avi': 'video/x-msvideo', '.mkv': 'video/x-matroska',
      '.webm': 'video/webm', '.mp3': 'audio/mpeg', '.wav': 'audio/wav',
      '.ogg': 'audio/ogg', '.m4a': 'audio/mp4', '.pdf': 'application/pdf',
      '.zip': 'application/zip', '.txt': 'text/plain',
    };
    return types[p.extension(filename).toLowerCase()] ??
        'application/octet-stream';
  }

  bool _isImage(String filename) {
    const exts = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'};
    return exts.contains(p.extension(filename).toLowerCase());
  }

  Future<File> _uniqueFile(Directory dir, String filename) async {
    var file = File(p.join(dir.path, filename));
    if (!await file.exists()) return file;
    final name = p.basenameWithoutExtension(filename);
    final ext = p.extension(filename);
    for (int i = 1;; i++) {
      file = File(p.join(dir.path, '$name ($i)$ext'));
      if (!await file.exists()) return file;
    }
  }

  Response? _guardDownloadOnly() {
    if (!_downloadOnly) return null;
    return Response.forbidden(
      json.encode({'error': 'This server is in download-only mode.'}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  // --- 認証ミドルウェア ---

  Middleware get _authMiddleware => (inner) {
        return (req) {
          final path = req.url.path;
          if (!path.startsWith('api/') ||
              path == 'api/info' ||
              path == 'api/auth' ||
              path == 'api/health') {
            return inner(req);
          }
          if (_authMode == _AuthMode.noPin) return inner(req);

          final cookieHeader = req.headers['cookie'];
          String? token;
          if (cookieHeader != null) {
            for (final c in cookieHeader.split(';')) {
              final t = c.trim();
              if (t.startsWith('localnode_session=')) {
                token = t.substring(t.indexOf('=') + 1);
                break;
              }
            }
          }
          if (token != null && _sessions.contains(token)) return inner(req);

          // #173: Bearer トークンによるアップロード認証
          if (_uploadToken != null &&
              req.method == 'POST' &&
              path == 'api/upload') {
            final authHeader = req.headers['authorization'] ?? '';
            if (authHeader == 'Bearer $_uploadToken') return inner(req);
          }

          return Response.unauthorized(
            json.encode({'error': 'Authentication required.'}),
            headers: {'Content-Type': 'application/json'},
          );
        };
      };

  // --- ハンドラ ---

  Future<Response> _authHandler(Request req) async {
    if (_authMode == _AuthMode.noPin) {
      final token = _generateToken();
      _sessions.add(token);
      return Response.ok(json.encode({'status': 'success'}), headers: {
        'Content-Type': 'application/json',
        'Set-Cookie': 'localnode_session=$token; Path=/; HttpOnly',
      });
    }

    final clientIp = _getClientIp(req);
    final lockout = _lockoutUntil[clientIp];
    if (lockout != null && DateTime.now().isBefore(lockout)) {
      final rem = lockout.difference(DateTime.now()).inSeconds;
      return Response.forbidden(
        json.encode({'error': 'Locked out. Try again in $rem seconds.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final body = await req.readAsString();
    try {
      final params = json.decode(body) as Map<String, dynamic>;
      if (params['pin'] == _pin) {
        _failedAttempts.remove(clientIp);
        _lockoutUntil.remove(clientIp);
        final token = _generateToken();
        _sessions.add(token);
        return Response.ok(json.encode({'status': 'success'}), headers: {
          'Content-Type': 'application/json',
          'Set-Cookie': 'localnode_session=$token; Path=/; HttpOnly',
        });
      } else {
        final attempts = (_failedAttempts[clientIp] ?? 0) + 1;
        _failedAttempts[clientIp] = attempts;
        if (attempts >= _maxFailedAttempts) {
          _lockoutUntil[clientIp] =
              DateTime.now().add(_lockoutDuration);
          _failedAttempts.remove(clientIp);
          return Response.forbidden(
            json.encode({'error': 'Locked out for ${_lockoutDuration.inMinutes} minutes.'}),
            headers: {'Content-Type': 'application/json'},
          );
        }
        return Response.forbidden(json.encode({'error': 'Invalid PIN'}),
            headers: {'Content-Type': 'application/json'});
      }
    } catch (_) {
      return Response.badRequest(
        body: json.encode({'error': 'Invalid request body.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  Response _healthHandler(Request _) =>
      Response.ok(json.encode({'startedAt': _startedAt}),
          headers: {'Content-Type': 'application/json'});

  Response _infoHandler(Request _) => Response.ok(
        json.encode({
          'version': '1.1.2',
          'name': _serverName,
          'serverName': _serverName,
          'operationMode': _downloadOnly ? 'downloadOnly' : 'normal',
          'authMode': _authMode == _AuthMode.fixedPin
              ? 'fixedPin'
              : _authMode == _AuthMode.noPin
                  ? 'noPin'
                  : 'randomPin',
          'requiresAuth': _authMode != _AuthMode.noPin,
          'clipboardEnabled': _clipboardEnabled,
        }),
        headers: {'Content-Type': 'application/json'},
      );

  Future<Response> _getFilesHandler(Request _) async {
    final dir = Directory(_storagePath!);
    if (!await dir.exists()) {
      return Response.internalServerError(body: 'Storage directory not found.');
    }
    final files = await dir
        .list()
        .where((e) => e is File)
        .cast<File>()
        .toList();
    final list = await Future.wait(files.map((f) async {
      final stat = await f.stat();
      return {
        'name': p.basename(f.path),
        'size': stat.size,
        'modified': stat.modified.toIso8601String(),
        'id': base64Url.encode(utf8.encode(f.path)),
      };
    }));
    return Response.ok(jsonEncode(list),
        headers: {'Content-Type': 'application/json'});
  }

  Future<Response> _uploadHandler(Request req) async {
    final guard = _guardDownloadOnly();
    if (guard != null) return guard;

    final encodedName = req.headers['x-filename'];
    if (encodedName == null || encodedName.isEmpty) {
      return Response.badRequest(body: 'x-filename header is required.');
    }
    final filename = p.basename(Uri.decodeComponent(encodedName));
    final dir = Directory(_storagePath!);
    if (!await dir.exists()) {
      return Response.internalServerError(body: 'Storage directory not found.');
    }

    final file = await _uniqueFile(dir, filename);
    final sink = file.openWrite();
    try {
      await for (final chunk in req.read()) {
        sink.add(chunk);
      }
      await sink.close();
      if (_postActions.isNotEmpty) {
        _runPostActions(file.path);
      }
      return Response.ok('File uploaded: ${p.basename(file.path)}');
    } catch (e) {
      await sink.close();
      return Response.internalServerError(body: 'Upload failed: $e');
    }
  }

  bool _globMatch(String pattern, String filename) {
    final regexStr = RegExp.escape(pattern)
        .replaceAll(r'\*', '.*')
        .replaceAll(r'\?', '.');
    return RegExp('^$regexStr\$', caseSensitive: !Platform.isWindows)
        .hasMatch(filename);
  }

  void _runPostActions(String filePath) {
    final filename = p.basename(filePath);
    for (final action in _postActions) {
      if (!_globMatch(action.pattern, filename)) continue;
      () async {
        try {
          final result = await Process.run(
            Platform.isWindows ? 'cmd' : action.script,
            Platform.isWindows
                ? ['/c', action.script, filePath]
                : [filePath],
            runInShell: !Platform.isWindows,
          );
          if (result.exitCode != 0) {
            stderr.writeln(
                '[post-action] "${action.script}" exited ${result.exitCode}');
            if ((result.stderr as String).isNotEmpty) {
              stderr.writeln(result.stderr);
            }
          } else {
            _log('[post-action] "${action.script}" completed for $filename');
          }
        } catch (e) {
          stderr.writeln('[post-action] Failed to run "${action.script}": $e');
        }
      }();
    }
  }

  String _buildMentionList() {
    final lines = <String>[];

    lines.add('Mention commands:');
    lines.add('  @list — show this list');
    if (_mentionActions.isEmpty) {
      lines.add('  (no @run actions registered)');
    } else {
      lines.addAll(_mentionActions.keys.map((a) => '  @run $a'));
    }

    if (_postActions.isNotEmpty) {
      lines.add('');
      lines.add('Post-upload actions:');
      for (final a in _postActions) {
        lines.add('  ${a.pattern} -> ${a.script}');
      }
    }

    return lines.join('\n');
  }

  void _replyToClipboard(String text) {
    final item = _ClipboardItem(
      id: _generateId(),
      text: text,
      tag: 'mention-result',
      createdAt: DateTime.now(),
    );
    _clipboardItems.insert(0, item);
    while (_clipboardItems.length > _maxClipboardItems) {
      _clipboardItems.removeLast();
    }
    _clipboardLastModified = DateTime.now().millisecondsSinceEpoch;
  }

  void _runMentionAction(String alias, String script) {
    () async {
      try {
        final result = await Process.run(
          Platform.isWindows ? 'cmd' : script,
          Platform.isWindows ? ['/c', script] : [],
          runInShell: !Platform.isWindows,
        );
        final resultText = result.exitCode == 0
            ? '@run $alias: OK'
            : '@run $alias: FAILED (exit ${result.exitCode})';
        if (result.exitCode != 0 && (result.stderr as String).isNotEmpty) {
          stderr.writeln('[mention-action] "$alias" stderr: ${result.stderr}');
        }
        _replyToClipboard(resultText);
        _log('[mention-action] "$alias" -> $resultText');
      } catch (e) {
        stderr.writeln('[mention-action] Failed to run "$alias": $e');
      }
    }();
  }

  Future<Response> _downloadHandler(Request req, String id) async {
    try {
      final filePath = utf8.decode(base64Url.decode(id));
      final file = File(filePath);
      if (!await file.exists()) return Response.notFound('File not found.');
      return Response.ok(file.openRead())
          .change(headers: {'Content-Type': _getMimeType(p.basename(filePath))});
    } catch (e) {
      return Response.internalServerError(body: 'Download failed: $e');
    }
  }

  Future<Response> _thumbnailHandler(Request req, String id) async {
    if (_thumbnailCacheDir == null) {
      return Response.internalServerError(body: 'Server not initialized.');
    }
    try {
      final filePath = utf8.decode(base64Url.decode(id));
      final filename = p.basename(filePath);
      if (!_isImage(filename)) {
        return Response.badRequest(body: 'Not an image.');
      }
      final cache = File(p.join(_thumbnailCacheDir!.path, '$filename.jpg'));
      if (await cache.exists()) {
        return Response.ok(cache.openRead(),
            headers: {'Content-Type': 'image/jpeg'});
      }
      final src = File(filePath);
      if (!await src.exists()) return Response.notFound('File not found.');
      final bytes = await src.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) {
        return Response.internalServerError(body: 'Failed to decode image.');
      }
      final thumb = img.copyResize(image, width: 120);
      final thumbBytes = img.encodeJpg(thumb, quality: 85);
      cache.writeAsBytes(thumbBytes);
      return Response.ok(thumbBytes, headers: {'Content-Type': 'image/jpeg'});
    } catch (e) {
      return Response.internalServerError(body: 'Thumbnail failed: $e');
    }
  }

  Future<Response> _downloadAllHandler(Request _) async {
    final dir = Directory(_storagePath!);
    if (!await dir.exists()) {
      return Response.internalServerError(body: 'Storage directory not found.');
    }
    final archive = Archive();
    final files = dir.listSync(recursive: true).whereType<File>();
    for (final f in files) {
      final bytes = await f.readAsBytes();
      archive.addFile(ArchiveFile(
          p.relative(f.path, from: dir.path), bytes.length, bytes));
    }
    final zip = ZipEncoder().encode(archive);
    if (zip == null) {
      return Response.internalServerError(body: 'Failed to create zip.');
    }
    return Response.ok(zip, headers: {
      'Content-Type': 'application/zip',
      'Content-Disposition': 'attachment; filename="localnode_files.zip"',
    });
  }

  Future<Response> _deleteFileHandler(Request req, String id) async {
    final guard = _guardDownloadOnly();
    if (guard != null) return guard;
    try {
      final filePath = utf8.decode(base64Url.decode(id));
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        final cache = File(
            p.join(_thumbnailCacheDir!.path, '${p.basename(filePath)}.jpg'));
        if (await cache.exists()) await cache.delete();
        return Response.ok('File deleted.');
      }
      return Response.internalServerError(body: 'File not found.');
    } catch (e) {
      return Response.internalServerError(body: 'Delete failed: $e');
    }
  }

  Future<Response> _deleteAllFilesHandler(Request req) async {
    final guard = _guardDownloadOnly();
    if (guard != null) return guard;
    final dir = Directory(_storagePath!);
    int deleted = 0, failed = 0;
    if (await dir.exists()) {
      final files =
          await dir.list().where((e) => e is File).cast<File>().toList();
      for (final f in files) {
        try {
          await f.delete();
          deleted++;
          final cache = File(p.join(
              _thumbnailCacheDir!.path, '${p.basename(f.path)}.jpg'));
          if (await cache.exists()) await cache.delete();
        } catch (_) {
          failed++;
        }
      }
    }
    return Response.ok(json.encode({'deleted': deleted, 'failed': failed}),
        headers: {'Content-Type': 'application/json'});
  }

  // --- クリップボードハンドラ ---

  Response _getClipboardHandler(Request _) => Response.ok(
        json.encode({
          'items': _clipboardItems.map((i) => i.toJson()).toList(),
          'lastModified': _clipboardLastModified,
        }),
        headers: {'Content-Type': 'application/json'},
      );

  Future<Response> _postClipboardHandler(Request req) async {
    try {
      final params =
          json.decode(await req.readAsString()) as Map<String, dynamic>;
      final text = (params['text'] as String?)?.trim();
      final rawTag = (params['tag'] as String?)?.trim();
      final tag = (rawTag != null && rawTag.isNotEmpty) ? rawTag : null;

      if (text == null || text.isEmpty) {
        return Response.badRequest(
          body: json.encode({'error': 'Text is required.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      if (text.length > _maxTextLength) {
        return Response.badRequest(
          body: json.encode({'error': 'Text too long.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final item = _ClipboardItem(
        id: _generateId(),
        text: text,
        tag: tag,
        createdAt: DateTime.now(),
      );
      _clipboardItems.insert(0, item);
      while (_clipboardItems.length > _maxClipboardItems) {
        _clipboardItems.removeLast();
      }
      _clipboardLastModified = DateTime.now().millisecondsSinceEpoch;

      // #174: メンションコマンド検出
      if (text == '@list') {
        _replyToClipboard(_buildMentionList());
      } else {
        final match = RegExp(r'^@run\s+(\S+)$').firstMatch(text);
        if (match != null) {
          final alias = match.group(1)!;
          final script = _mentionActions[alias];
          if (script != null) {
            _runMentionAction(alias, script);
          }
        }
      }

      return Response.ok(json.encode(item.toJson()),
          headers: {'Content-Type': 'application/json'});
    } catch (_) {
      return Response.badRequest(
        body: json.encode({'error': 'Invalid request body.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  Response _deleteClipboardItemHandler(Request req, String id) {
    final idx = _clipboardItems.indexWhere((i) => i.id == id);
    if (idx == -1) {
      return Response.notFound(json.encode({'error': 'Item not found.'}),
          headers: {'Content-Type': 'application/json'});
    }
    _clipboardItems.removeAt(idx);
    _clipboardLastModified = DateTime.now().millisecondsSinceEpoch;
    return Response.ok(json.encode({'status': 'deleted'}),
        headers: {'Content-Type': 'application/json'});
  }

  Response _clearClipboardHandler(Request req) {
    final count = _clipboardItems.length;
    _clipboardItems.clear();
    _clipboardLastModified = DateTime.now().millisecondsSinceEpoch;
    return Response.ok(json.encode({'status': 'cleared', 'count': count}),
        headers: {'Content-Type': 'application/json'});
  }
}
