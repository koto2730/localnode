import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:package_info_plus/package_info_plus.dart';

import 'dart:math';

class ServerService {
  static const _platform = MethodChannel('com.example.pocketlink/storage');
  HttpServer? _server;
  String? _ipAddress;
  final int _port = 8080;
  Directory? _documentsDir;
  Directory? _webRootDir; // Webルートディレクトリのパス
  String? _pin;
  final Set<String> _sessions = {};

  final _router = Router();

  String? get ipAddress => _ipAddress;
  String? get pin => _pin;
  bool get isRunning => _server != null;

  ServerService() {
    _router.post('/api/auth', _authHandler);
    _router.get('/api/info', _infoHandler);
    _router.get('/api/files', _getFilesHandler);
    _router.post('/api/upload', _uploadHandler);
    _router.get('/api/download/<filename>', _downloadHandler);
    _router.delete('/api/files/<filename>', _deleteFileHandler);
  }

  Future<String?> _getDownloadsPathAndroid() async {
    try {
      final String? path = await _platform.invokeMethod('getDownloadsDirectory');
      return path;
    } on PlatformException catch (e) {
      print("Failed to get downloads directory: '${e.message}'.");
      return null;
    }
  }

  Future<void> _init() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final appName = packageInfo.appName;

    // プラットフォームに応じて保存先ディレクトリを決定
    if (Platform.isAndroid) {
      final downloadsPath = await _getDownloadsPathAndroid();
      if (downloadsPath != null) {
        // Downloads/AppName というパスを作成
        _documentsDir = Directory(p.join(downloadsPath, appName));
      } else {
        // フォールバック
        _documentsDir = await getExternalStorageDirectory();
      }
    } else if (Platform.isIOS) {
      // iOSではアプリのDocumentsディレクトリ内にサブディレクトリを作成
      final documentsPath = await getApplicationDocumentsDirectory();
      _documentsDir = Directory(p.join(documentsPath.path, appName));
    } else {
      // その他のデスクトップOSなど
      final documentsPath = await getApplicationDocumentsDirectory();
      _documentsDir = Directory(p.join(documentsPath.path, appName));
    }

    if (_documentsDir == null) {
      throw Exception('保存先フォルダが見つかりません。');
    }

    // ディレクトリが存在しない場合は作成
    if (!await _documentsDir!.exists()) {
      await _documentsDir!.create(recursive: true);
    }
  }

  /// アセットのWebファイルを一時ディレクトリに展開する
  Future<void> _deployAssets() async {
    final tempDir = await getTemporaryDirectory();
    _webRootDir = Directory(p.join(tempDir.path, 'web'));

    // 既存のディレクトリがあればクリーンアップ
    if (await _webRootDir!.exists()) {
      await _webRootDir!.delete(recursive: true);
    }
    await _webRootDir!.create(recursive: true);

    try {
      // index.htmlを直接読み込んで一時ディレクトリにコピーする
      const assetPath = 'assets/web/index.html';
      final byteData = await rootBundle.load(assetPath);
      final destinationFile = File(p.join(_webRootDir!.path, 'index.html'));
      await destinationFile.writeAsBytes(byteData.buffer.asUint8List());
    } catch (e) {
      print('ERROR: Failed to deploy web assets: $e');
      rethrow;
    }
  }

  // === Handlers ===

  String _generatePin() {
    return (1000 + Random().nextInt(9000)).toString();
  }

  String _generateSessionToken() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    return base64Url.encode(values);
  }

  Future<Response> _authHandler(Request request) async {
    final body = await request.readAsString();
    try {
      final params = json.decode(body) as Map<String, dynamic>;
      final submittedPin = params['pin'];

      if (submittedPin == _pin) {
        final token = _generateSessionToken();
        _sessions.add(token);
        return Response.ok(json.encode({'token': token}),
            headers: {'Content-Type': 'application/json'});
      } else {
        return Response.forbidden(json.encode({'error': 'Invalid PIN'}),
            headers: {'Content-Type': 'application/json'});
      }
    } catch (e) {
      return Response.badRequest(
          body: json.encode({'error': 'Invalid request body.'}),
          headers: {'Content-Type': 'application/json'});
    }
  }

  Response _infoHandler(Request request) {
    return Response.ok('{"version": "1.0.0", "name": "Pocket Link Server"}',
        headers: {'Content-Type': 'application/json'});
  }

  Future<Response> _getFilesHandler(Request request) async {
    if (_documentsDir == null) return Response.internalServerError(body: 'Documents directory not initialized.');

    final files = await _documentsDir!.list().where((item) => item is File).cast<File>().toList();
    final fileList = files.map((file) async {
      final stat = await file.stat();
      return {
        'name': p.basename(file.path),
        'size': stat.size,
        'modified': stat.modified.toIso8601String(),
      };
    }).toList();

    final results = await Future.wait(fileList);
    return Response.ok(jsonEncode(results), headers: {'Content-Type': 'application/json'});
  }

  Future<Response> _uploadHandler(Request request) async {
    if (_documentsDir == null) return Response.internalServerError(body: 'Documents directory not initialized.');
    
    final encodedFilename = request.headers['x-filename'];
    if (encodedFilename == null || encodedFilename.isEmpty) {
      return Response.badRequest(body: 'x-filename header is required.');
    }
    final filename = Uri.decodeComponent(encodedFilename);

    final sanitizedFilename = p.basename(filename); // Prevent path traversal
    final file = File(p.join(_documentsDir!.path, sanitizedFilename));

    final sink = file.openWrite();
    try {
      await for (final chunk in request.read()) {
        sink.add(chunk);
      }
      return Response.ok('File uploaded successfully: $sanitizedFilename');
    } catch (e) {
      return Response.internalServerError(body: 'Failed to save file: $e');
    } finally {
      await sink.close();
    }
  }

  Future<Response> _downloadHandler(Request request, String filename) async {
    if (_documentsDir == null) return Response.internalServerError(body: 'Documents directory not initialized.');
    
    final sanitizedFilename = p.basename(filename);
    final file = File(p.join(_documentsDir!.path, sanitizedFilename));

    if (!await file.exists()) {
      return Response.notFound('File not found: $sanitizedFilename');
    }

    return Response.ok(file.openRead())
        .change(headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Disposition': 'attachment; filename="$sanitizedFilename"'
        });
  }

  Future<Response> _deleteFileHandler(Request request, String filename) async {
     if (_documentsDir == null) return Response.internalServerError(body: 'Documents directory not initialized.');

    final sanitizedFilename = p.basename(filename);
    final file = File(p.join(_documentsDir!.path, sanitizedFilename));

    if (!await file.exists()) {
      return Response.notFound('File not found: $sanitizedFilename');
    }

    try {
      await file.delete();
      return Response.ok('File deleted successfully: $sanitizedFilename');
    } catch (e) {
      return Response.internalServerError(body: 'Failed to delete file: $e');
    }
  }


  // === Middleware ===

  Middleware get _authMiddleware => (innerHandler) {
    return (request) {
      final path = request.url.path;

      // /api/で始まらないパス、または認証が不要なAPIパスはそのまま通す
      if (!path.startsWith('api/') || path == 'api/info' || path == 'api/auth') {
        return innerHandler(request);
      }

      // 上記以外で/api/で始まるパスは認証が必要
      final authHeader = request.headers['Authorization'];
      if (authHeader != null && authHeader.startsWith('Bearer ')) {
        final token = authHeader.substring(7);
        if (_sessions.contains(token)) {
          return innerHandler(request); // 認証成功
        }
      }
      
      return Response.unauthorized(json.encode({'error': 'Authentication required.'}),
          headers: {'Content-Type': 'application/json'}); // 認証失敗
    };
  };


  // === Server Control ===

  Future<void> startServer() async {
    if (_server != null) return;

    _pin = _generatePin();
    _sessions.clear();
    print('Your PIN is: $_pin'); // デバッグ用

    try {
      await _init();
      await _deployAssets(); // アセットを展開
      WakelockPlus.enable();

      _ipAddress = await NetworkInfo().getWifiIP();
      if (_ipAddress == null) throw Exception('Failed to get Wi-Fi IP address.');

      // 展開先の一時ディレクトリを指すように変更
      final staticHandler =
          createStaticHandler(_webRootDir!.path, defaultDocument: 'index.html');

      final apiHandler =
          const Pipeline().addMiddleware(_authMiddleware).addHandler(_router.call);

      final cascade = Cascade().add(apiHandler).add(staticHandler);

      final handler =
          const Pipeline().addMiddleware(logRequests()).addHandler(cascade.handler);

      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, _port);
      print('Serving at http://${_server!.address.host}:${_server!.port}');
      print('Accessible via: http://$_ipAddress:$_port');
    } catch (e) {
      print('Error starting server: $e');
      await stopServer(); // Ensure cleanup on partial start
      rethrow;
    }
  }

  Future<void> stopServer() async {
    await _server?.close(force: true);
    _server = null;
    _ipAddress = null;
    _pin = null;
    _sessions.clear();
    WakelockPlus.disable();
    print('Server stopped.');
  }
}