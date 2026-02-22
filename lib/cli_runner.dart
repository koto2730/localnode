import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:args/args.dart';
import 'package:qr/qr.dart';

import 'server_service.dart';

/// CLIモードでサーバーを起動するためのランナー
class CliRunner {
  final ServerService _serverService;
  final List<String> _args;
  Timer? _clipboardTimer;
  int _lastClipboardModified = 0;
  bool _shuttingDown = false;

  CliRunner(this._args) : _serverService = ServerService();

  /// コマンドライン引数をパースする
  static ArgParser buildParser() {
    return ArgParser()
      ..addFlag('cli', help: 'Run in CLI (headless) mode', negatable: false)
      ..addOption('port',
          abbr: 'p', help: 'Server port number', defaultsTo: '8080')
      ..addOption('ip', help: 'IP address to advertise (skip auto-detection)')
      ..addOption('pin', help: 'Fixed PIN (random if not specified)')
      ..addOption('dir', abbr: 'd', help: 'Shared directory path')
      ..addOption('mode',
          abbr: 'm',
          help: 'Operation mode (normal/download-only)',
          defaultsTo: 'normal',
          allowed: ['normal', 'download-only'])
      ..addFlag('no-pin',
          help: 'Disable PIN authentication', negatable: false)
      ..addFlag('no-clipboard',
          help: 'Hide clipboard content from console output', negatable: false)
      ..addFlag('verbose',
          abbr: 'v', help: 'Enable verbose request logging', negatable: false)
      ..addFlag('help', abbr: 'h', help: 'Show help', negatable: false);
  }

  /// 引数が--cliを含むかチェック
  static bool isCliMode(List<String> args) {
    return args.contains('--cli');
  }

  /// CLIモードでサーバーを起動
  Future<void> run() async {
    final parser = buildParser();
    final ArgResults results;

    try {
      results = parser.parse(_args);
    } catch (e) {
      stderr.writeln('Error: Failed to parse arguments: $e');
      stderr.writeln('');
      _printUsage(parser);
      exit(1);
    }

    if (results['help'] as bool) {
      _printUsage(parser);
      _flushWindowsConsoleInput(); // 余剰入力がシェルに渡るのを防ぐ (#84)
      exit(0);
    }

    final port = int.tryParse(results['port'] as String);
    if (port == null || port < 1 || port > 65535) {
      stderr.writeln('Error: Invalid port number. Must be between 1 and 65535.');
      exit(1);
    }

    final fixedPin = results['pin'] as String?;
    final dir = results['dir'] as String?;
    final specifiedIp = results['ip'] as String?;
    final noClipboard = results['no-clipboard'] as bool;
    final verbose = results['verbose'] as bool;

    // モード設定
    final modeStr = results['mode'] as String;
    final operationMode = modeStr == 'download-only'
        ? OperationMode.downloadOnly
        : OperationMode.normal;

    final noPin = results['no-pin'] as bool;
    final AuthMode authMode;
    if (noPin) {
      authMode = AuthMode.noPin;
    } else if (fixedPin != null) {
      authMode = AuthMode.fixedPin;
    } else {
      authMode = AuthMode.randomPin;
    }

    // ディレクトリの検証
    if (dir != null) {
      final directory = Directory(dir);
      if (!await directory.exists()) {
        stderr.writeln('Error: Directory does not exist: $dir');
        exit(1);
      }
    }

    // IPアドレスの決定
    final String ipAddress;
    if (specifiedIp != null) {
      ipAddress = specifiedIp;
    } else {
      ipAddress = await _selectIpAddress();
    }

    stdout.writeln('');
    stdout.writeln('LocalNode CLI Server');
    stdout.writeln('=' * 40);

    try {
      // サーバーを起動
      await _serverService.startServerCli(
        ipAddress: ipAddress,
        port: port,
        fixedPin: fixedPin,
        storagePath: dir,
        operationMode: operationMode,
        authMode: authMode,
        verboseLogging: verbose,
      );

      final url = 'http://$ipAddress:$port';
      final pin = _serverService.pin;

      stdout.writeln('Server started.');
      stdout.writeln('');
      stdout.writeln('  URL:  $url');
      if (authMode != AuthMode.noPin) {
        stdout.writeln('  PIN:  $pin');
      } else {
        stdout.writeln('  PIN:  disabled (no auth)');
      }
      stdout.writeln(
          '  Mode: ${operationMode == OperationMode.downloadOnly ? "download-only" : "normal"}');
      stdout.writeln('');

      // QRコード表示
      stdout.writeln('QR Code:');
      _printAsciiQrCode(url);
      stdout.writeln('');
      stdout.writeln('Press Ctrl+C or type q + Enter to stop.');
      stdout.writeln('');

      // シグナルハンドラを設定
      _setupSignalHandlers();

      // クリップボードのポーリングを開始
      if (!noClipboard) {
        _startClipboardPolling();
      }

      // stdinからの入力を待機（'q'で終了）
      await _waitForQuit();
    } catch (e) {
      stderr.writeln('Error: Failed to start server: $e');
      exit(1);
    }
  }

  /// IPアドレスの自動検出・選択
  Future<String> _selectIpAddress() async {
    final ips = await _serverService.getAvailableIpAddresses();

    if (ips.isEmpty) return '0.0.0.0';
    if (ips.length == 1) return ips.first;

    // 複数IPが検出された場合、ターミナルならユーザーに選択させる
    if (stdin.hasTerminal) {
      stdout.writeln('Multiple network interfaces detected:');
      for (int i = 0; i < ips.length; i++) {
        stdout.writeln('  [${i + 1}] ${ips[i]}');
      }
      stdout.write('Select IP address [1-${ips.length}] (default: 1): ');

      try {
        final input = stdin.readLineSync()?.trim();
        _flushWindowsConsoleInput(); // IP選択後の余剰入力をクリア (#84)
        if (input != null && input.isNotEmpty) {
          final index = int.tryParse(input);
          if (index != null && index >= 1 && index <= ips.length) {
            return ips[index - 1];
          }
          stdout.writeln('Invalid selection, using ${ips.first}');
        }
      } catch (_) {
        // stdin読み取りエラー時はデフォルト
      }
    }

    return ips.first;
  }

  void _printUsage(ArgParser parser) {
    stdout.writeln('LocalNode - Local file & clipboard sharing server');
    stdout.writeln('');
    stdout.writeln('Usage: localnode --cli [options]');
    stdout.writeln('');
    stdout.writeln('Options:');
    stdout.writeln(parser.usage);
    stdout.writeln('');
    stdout.writeln('Examples:');
    stdout.writeln('  localnode --cli');
    stdout.writeln('  localnode --cli -p 3000 --pin 1234');
    stdout.writeln('  localnode --cli -d /path/to/share --ip 192.168.1.100');
    stdout.writeln('  localnode --cli --mode download-only --no-pin');
    stdout.writeln('  localnode --cli --no-clipboard --verbose');
    stdout.writeln('');
    stdout.writeln('To stop the server: Ctrl+C or type q + Enter');
  }

  /// QRコードをASCIIアートとして出力
  void _printAsciiQrCode(String data) {
    final qrCode = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.L,
    );
    final qrImage = QrImage(qrCode);

    stdout.writeln('');

    // 全プラットフォーム共通: Unicode全角ブロック文字を使用。
    // モジュールあたり2文字幅×1行高で、等幅フォントでほぼ正方形になる。
    // 半ブロック文字(▀/▄)の行間接合で発生する黒線アーティファクトを回避。
    for (int y = 0; y < qrImage.moduleCount; y++) {
      final buffer = StringBuffer('  ');
      for (int x = 0; x < qrImage.moduleCount; x++) {
        buffer.write(qrImage.isDark(y, x) ? '\u2588\u2588' : '  ');
      }
      stdout.writeln(buffer.toString());
    }
  }

  void _setupSignalHandlers() {
    // SIGINT (Ctrl+C)
    try {
      ProcessSignal.sigint.watch().listen((_) async {
        await _shutdown();
      });
    } catch (_) {
      // Windows: ProcessSignal.sigint.watch() が未サポートの場合がある
      // stdinの'q'入力またはプロセス終了に任せる
    }

    // SIGTERM・SIGHUP（macOS/Linuxのみ）
    if (!Platform.isWindows) {
      try {
        ProcessSignal.sigterm.watch().listen((_) async {
          await _shutdown();
        });
        ProcessSignal.sighup.watch().listen((_) async {
          await _shutdown();
        });
      } catch (_) {
        // シグナル監視失敗時は無視
      }
    }
  }

  /// クリップボードのポーリングを開始
  void _startClipboardPolling() {
    _lastClipboardModified = _serverService.clipboardLastModified;
    _clipboardTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final currentModified = _serverService.clipboardLastModified;
      if (currentModified != _lastClipboardModified) {
        _lastClipboardModified = currentModified;
        final items = _serverService.clipboardItems;
        if (items.isNotEmpty) {
          final latest = items.first;
          stdout.writeln('');
          final tagLabel = latest.tag != null ? '[${latest.tag}] ' : '';
          stdout.writeln(
              '[Clipboard] $tagLabel${latest.createdAt.toLocal().toString().substring(11, 19)}');
          final text = latest.text;
          if (text.length > 200) {
            stdout.writeln('  ${text.substring(0, 200)}...');
          } else {
            stdout.writeln('  $text');
          }
        }
      }
    });
  }

  /// stdinからの入力を待機し、'q'で終了
  Future<void> _waitForQuit() async {
    try {
      if (!stdin.hasTerminal) {
        // 非対話的環境（nohup等）ではシグナルハンドラに任せる
        await _waitForever();
        return;
      }

      await for (final line in stdin
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (line.trim().toLowerCase() == 'q') {
          await _shutdown();
          return;
        }
      }
      // stdinが閉じられた場合
      await _waitForever();
    } catch (_) {
      // stdin読み取りエラー時もシグナルハンドラに任せる
      await _waitForever();
    }
  }

  /// サーバーを停止して終了
  Future<void> _shutdown() async {
    if (_shuttingDown) return;
    _shuttingDown = true;

    _clipboardTimer?.cancel();

    _restoreWindowsConsoleMode(); // 終了前にコンソールモードを復元 (#84)
    _flushWindowsConsoleInput(); // 余剰入力（'q'等）がシェルに渡るのを防ぐ (#84)

    stdout.writeln('');
    stdout.writeln('Shutting down...');
    await _serverService.stopServer();
    stdout.writeln('Server stopped.');
    exit(0);
  }

  Future<void> _waitForever() async {
    final completer = Completer<void>();
    await completer.future;
  }

  /// [#84] --help 後の余剰入力（q など）がシェルに流れないよう入力バッファを空にする
  void _flushWindowsConsoleInput() {
    if (!Platform.isWindows) return;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final getStdHandle = kernel32.lookupFunction<
          IntPtr Function(Uint32), int Function(int)>('GetStdHandle');
      final flushInput = kernel32.lookupFunction<
          Int32 Function(IntPtr), int Function(int)>('FlushConsoleInputBuffer');
      flushInput(getStdHandle(0xFFFFFFF6)); // STD_INPUT_HANDLE = (DWORD)(-10)
    } catch (_) {}
  }

  /// [#84] 終了前にコンソール入力モードを通常状態に戻す
  /// Dart の exit() は ExitProcess() 経由のため C++ atexit が保証されない
  void _restoreWindowsConsoleMode() {
    if (!Platform.isWindows) return;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final getStdHandle = kernel32.lookupFunction<
          IntPtr Function(Uint32), int Function(int)>('GetStdHandle');
      final setMode = kernel32.lookupFunction<
          Int32 Function(IntPtr, Uint32),
          int Function(int, int)>('SetConsoleMode');
      // ENABLE_PROCESSED_INPUT(0x1) | ENABLE_LINE_INPUT(0x2) | ENABLE_ECHO_INPUT(0x4)
      setMode(getStdHandle(0xFFFFFFF6), 0x0007);
    } catch (_) {}
  }
}
