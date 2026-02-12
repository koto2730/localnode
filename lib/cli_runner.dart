import 'dart:async';
import 'dart:convert';
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

  CliRunner(this._args) : _serverService = ServerService();

  /// コマンドライン引数をパースする
  static ArgParser buildParser() {
    return ArgParser()
      ..addFlag('cli', help: 'CLIモード（ヘッドレス）で起動', negatable: false)
      ..addOption('port',
          abbr: 'p', help: 'サーバーのポート番号', defaultsTo: '8080')
      ..addOption('pin', help: '固定PIN（指定しない場合はランダム生成）')
      ..addOption('dir', abbr: 'd', help: '共有ディレクトリのパス')
      ..addOption('mode',
          abbr: 'm',
          help: '動作モード (normal/download-only)',
          defaultsTo: 'normal',
          allowed: ['normal', 'download-only'])
      ..addFlag('no-pin',
          help: 'PIN認証を無効化（信頼できるネットワーク用）', negatable: false)
      ..addFlag('help', abbr: 'h', help: 'ヘルプを表示', negatable: false);
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
      stderr.writeln('エラー: 引数のパースに失敗しました: $e');
      stderr.writeln(parser.usage);
      exit(1);
    }

    if (results['help'] as bool) {
      _printUsage(parser);
      exit(0);
    }

    final port = int.tryParse(results['port'] as String);
    if (port == null || port < 1 || port > 65535) {
      stderr.writeln('エラー: 無効なポート番号です。1〜65535の範囲で指定してください。');
      exit(1);
    }

    final fixedPin = results['pin'] as String?;
    final dir = results['dir'] as String?;

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
        stderr.writeln('エラー: 指定されたディレクトリが存在しません: $dir');
        exit(1);
      }
    }

    // IPアドレスの取得
    final ips = await _serverService.getAvailableIpAddresses();
    final ipAddress = ips.isNotEmpty ? ips.first : '0.0.0.0';

    stdout.writeln('LocalNode CLIモード');
    stdout.writeln('=' * 40);

    try {
      // サーバーを起動（固定PINとディレクトリを渡す）
      await _serverService.startServerCli(
        ipAddress: ipAddress,
        port: port,
        fixedPin: fixedPin,
        storagePath: dir,
        operationMode: operationMode,
        authMode: authMode,
      );

      final url = 'http://$ipAddress:$port';
      final pin = _serverService.pin;

      stdout.writeln('サーバー起動中...');
      stdout.writeln('');
      stdout.writeln('URL: $url');
      if (authMode != AuthMode.noPin) {
        stdout.writeln('PIN: $pin');
      } else {
        stdout.writeln('PIN: 無効（認証なし）');
      }
      stdout.writeln(
          'モード: ${operationMode == OperationMode.downloadOnly ? "ダウンロード専用" : "通常"}');
      stdout.writeln('');
      stdout.writeln('QRコード:');
      _printAsciiQrCode(url);
      stdout.writeln('');
      stdout.writeln('q + Enter または Ctrl+C で停止');

      // シグナルハンドラを設定
      _setupSignalHandlers();

      // クリップボードのポーリングを開始
      _startClipboardPolling();

      // stdinからの入力を待機（'q'で終了）
      await _waitForQuit();
    } catch (e) {
      stderr.writeln('エラー: サーバーの起動に失敗しました: $e');
      exit(1);
    }
  }

  void _printUsage(ArgParser parser) {
    stdout.writeln('LocalNode - ローカルファイル共有サーバー');
    stdout.writeln('');
    stdout.writeln('使用方法: localnode --cli [オプション]');
    stdout.writeln('');
    stdout.writeln('オプション:');
    stdout.writeln(parser.usage);
    stdout.writeln('');
    stdout.writeln('例:');
    stdout.writeln(
        '  localnode --cli --port 8080 --pin 1234 --dir /home/user/share');
    stdout.writeln(
        '  localnode --cli --mode download-only --no-pin --dir /home/user/share');
  }

  /// QRコードをASCIIアートとして出力
  void _printAsciiQrCode(String data) {
    final qrCode = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.L,
    );
    final qrImage = QrImage(qrCode);

    // 上余白
    stdout.writeln('');

    // QRコードの各行を出力（2行を1行にまとめて縦横比を調整）
    for (int y = 0; y < qrImage.moduleCount; y += 2) {
      final buffer = StringBuffer('  '); // 左余白
      for (int x = 0; x < qrImage.moduleCount; x++) {
        final top = qrImage.isDark(y, x);
        final bottom =
            (y + 1 < qrImage.moduleCount) ? qrImage.isDark(y + 1, x) : false;

        // Unicode ブロック文字を使って2ピクセルを1文字で表現
        if (top && bottom) {
          buffer.write('\u2588'); // █ Full block
        } else if (top && !bottom) {
          buffer.write('\u2580'); // ▀ Upper half block
        } else if (!top && bottom) {
          buffer.write('\u2584'); // ▄ Lower half block
        } else {
          buffer.write(' '); // Space
        }
      }
      stdout.writeln(buffer.toString());
    }
  }

  void _setupSignalHandlers() {
    // SIGINT (Ctrl+C) のハンドリング
    ProcessSignal.sigint.watch().listen((_) async {
      await _shutdown();
    });

    // SIGTERM・SIGHUP のハンドリング（Linux/macOSのみ）
    if (!Platform.isWindows) {
      ProcessSignal.sigterm.watch().listen((_) async {
        await _shutdown();
      });
      // ターミナルが閉じられた場合のgraceful shutdown
      ProcessSignal.sighup.watch().listen((_) async {
        await _shutdown();
      });
    }
  }

  /// クリップボードのポーリングを開始
  void _startClipboardPolling() {
    _lastClipboardModified = _serverService.clipboardLastModified;
    _clipboardTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final currentModified = _serverService.clipboardLastModified;
      if (currentModified != _lastClipboardModified) {
        final items = _serverService.clipboardItems;
        if (items.isNotEmpty) {
          final latest = items.first;
          stdout.writeln('');
          final tagLabel = latest.tag != null ? '[${latest.tag}] ' : '';
          stdout.writeln(
              '[クリップボード受信] $tagLabel${latest.createdAt.toLocal().toString().substring(11, 19)}');
          // 長いテキストは省略して表示
          final text = latest.text;
          if (text.length > 200) {
            stdout.writeln('  ${text.substring(0, 200)}...');
          } else {
            stdout.writeln('  $text');
          }
        }
        _lastClipboardModified = currentModified;
      }
    });
  }

  /// stdinからの入力を待機し、'q'で終了
  Future<void> _waitForQuit() async {
    try {
      await for (final line in stdin
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())) {
        if (line.trim().toLowerCase() == 'q') {
          await _shutdown();
          return;
        }
      }
      // stdinが閉じられた場合（nohup、ターミナル切断等）はシグナルで停止するまで待機
      await _waitForever();
    } catch (_) {
      // stdin読み取りエラー時もシグナルハンドラに任せる
      await _waitForever();
    }
  }

  /// サーバーを停止して終了
  Future<void> _shutdown() async {
    _clipboardTimer?.cancel();
    stdout.writeln('\nシャットダウン中...');
    await _serverService.stopServer();
    stdout.writeln('サーバーを停止しました。');
    exit(0);
  }

  Future<void> _waitForever() async {
    final completer = Completer<void>();
    // 永久に待機（シグナルハンドラで終了）
    await completer.future;
  }
}
