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
import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';

import 'dart:math';
import 'package:image/image.dart' as img;

class ServerService {
  static const _platform = MethodChannel('com.example.pocketlink/storage');
  HttpServer? _server;
  String? _ipAddress;
  final int _port = 8080;
  Directory? _documentsDir;
  Directory? _webRootDir; // Webルートディレクトリのパス
  Directory? _thumbnailCacheDir; // サムネイルキャッシュディレクトリ
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
    _router.get('/api/thumbnail/<filename>', _thumbnailHandler);
    _router.get('/api/download-all', _downloadAllHandler);
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
    
    // サムネイルキャッシュディレクトリの初期化
    final tempDir = await getTemporaryDirectory();
    _thumbnailCacheDir = Directory(p.join(tempDir.path, 'thumbnails'));
    if (!await _thumbnailCacheDir!.exists()) {
      await _thumbnailCacheDir!.create(recursive: true);
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
        
        print('Auth success: Generated token $token. Current sessions: $_sessions');

        final cookie = 'pocketlink_session=$token; Path=/; HttpOnly';
        final headers = {
          'Content-Type': 'application/json',
          'Set-Cookie': cookie,
        };

        return Response.ok(json.encode({'status': 'success'}), headers: headers);
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
    final file = await _getUniqueFilePath(_documentsDir!, sanitizedFilename);

    final sink = file.openWrite();
    try {
      await for (final chunk in request.read()) {
        sink.add(chunk);
      }
      return Response.ok('File uploaded successfully: ${p.basename(file.path)}');
    } catch (e) {
      return Response.internalServerError(body: 'Failed to save file: $e');
    }
    finally {
      await sink.close();
    }
  }

  Future<File> _getUniqueFilePath(Directory dir, String filename) async {
    var file = File(p.join(dir.path, filename));
    if (!await file.exists()) {
      return file;
    }

    // ファイルが存在する場合、連番を付けて新しいパスを試す
    final name = p.basenameWithoutExtension(filename);
    final extension = p.extension(filename);
    int counter = 1;

    while (true) {
      final newFilename = '$name ($counter)$extension';
      file = File(p.join(dir.path, newFilename));
      if (!await file.exists()) {
        return file;
      }
      counter++;
    }
  }

  Future<Response> _downloadHandler(Request request, String filename) async {
    if (_documentsDir == null) return Response.internalServerError(body: 'Documents directory not initialized.');
    
    final sanitizedFilename = p.basename(filename);
    final file = File(p.join(_documentsDir!.path, sanitizedFilename));

    if (!await file.exists()) {
      return Response.notFound('File not found: $sanitizedFilename');
    }

    final mimeType = _getMimeType(sanitizedFilename);

    // Content-Disposition を削除し、Content-Type を動的に設定
    return Response.ok(file.openRead())
        .change(headers: {'Content-Type': mimeType});
  }

  String _getMimeType(String filename) {
    final extension = p.extension(filename).toLowerCase();
    const mimeTypes = {
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.gif': 'image/gif',
      '.webp': 'image/webp',
      '.bmp': 'image/bmp',
      '.svg': 'image/svg+xml',
      '.mp4': 'video/mp4',
      '.mov': 'video/quicktime',
      '.avi': 'video/x-msvideo',
      '.mkv': 'video/x-matroska',
      '.webm': 'video/webm',
      '.mp3': 'audio/mpeg',
      '.wav': 'audio/wav',
      '.ogg': 'audio/ogg',
      '.m4a': 'audio/mp4',
      '.pdf': 'application/pdf',
      '.zip': 'application/zip',
      '.txt': 'text/plain',
    };
    return mimeTypes[extension] ?? 'application/octet-stream';
  }

  Future<Response> _thumbnailHandler(Request request, String filename) async {
    if (_documentsDir == null || _thumbnailCacheDir == null) {
      return Response.internalServerError(body: 'Server directory not initialized.');
    }

    final sanitizedFilename = p.basename(filename);
    if (!_isImageFile(sanitizedFilename)) {
      return Response.badRequest(body: 'File is not an image.');
    }

    final cacheFile = File(p.join(_thumbnailCacheDir!.path, '$sanitizedFilename.jpg'));

    // 1. キャッシュを確認
    if (await cacheFile.exists()) {
      return Response.ok(cacheFile.openRead(), headers: {'Content-Type': 'image/jpeg'});
    }

    // 2. キャッシュがない場合は生成
    final originalFile = File(p.join(_documentsDir!.path, sanitizedFilename));
    if (!await originalFile.exists()) {
      return Response.notFound('File not found: $sanitizedFilename');
    }

    try {
      final imageBytes = await originalFile.readAsBytes();
      final image = img.decodeImage(imageBytes);

      if (image == null) {
        return Response.internalServerError(body: 'Failed to decode image.');
      }

      // 幅120pxにリサイズ
      final thumbnail = img.copyResize(image, width: 120);
      final thumbnailBytes = img.encodeJpg(thumbnail, quality: 85);

      // キャッシュに保存 (非同期)
      cacheFile.writeAsBytes(thumbnailBytes);
      
      return Response.ok(thumbnailBytes, headers: {'Content-Type': 'image/jpeg'});

    } catch (e) {
      print('Thumbnail generation error: $e');
      return Response.internalServerError(body: 'Failed to generate thumbnail.');
    }
  }

  bool _isImageFile(String filename) {
    final extension = p.extension(filename).toLowerCase();
    const imageExtensions = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'};
    return imageExtensions.contains(extension);
  }

  Future<Response> _deleteFileHandler(Request request, String filename) async {
     if (_documentsDir == null || _thumbnailCacheDir == null) return Response.internalServerError(body: 'Documents directory not initialized.');

    final sanitizedFilename = p.basename(filename);
    final file = File(p.join(_documentsDir!.path, sanitizedFilename));

    if (!await file.exists()) {
      return Response.notFound('File not found: $sanitizedFilename');
    }

    try {
      await file.delete();
      // サムネイルキャッシュも削除
      final cacheFile = File(p.join(_thumbnailCacheDir!.path, '$sanitizedFilename.jpg'));
      if (await cacheFile.exists()) {
        await cacheFile.delete();
      }
      return Response.ok('File deleted successfully: $sanitizedFilename');
    } catch (e) {
      return Response.internalServerError(body: 'Failed to delete file: $e');
    }
  }

  Future<Response> _downloadAllHandler(Request request) async {
    if (_documentsDir == null) {
      return Response.internalServerError(body: 'Documents directory not initialized.');
    }

    final encoder = ZipEncoder();
    final archive = Archive();

    final files = _documentsDir!.listSync(recursive: true).whereType<File>();
    for (final file in files) {
      final bytes = await file.readAsBytes();
      final filename = p.relative(file.path, from: _documentsDir!.path);
      archive.addFile(ArchiveFile(filename, bytes.length, bytes));
    }

    final zipData = encoder.encode(archive);
    if (zipData == null) {
      return Response.internalServerError(body: 'Failed to create zip file.');
    }

    return Response.ok(zipData, headers: {
      'Content-Type': 'application/zip',
      'Content-Disposition': 'attachment; filename="pocketlink_files.zip"',
    });
  }


  // === Middleware ===

  Middleware get _authMiddleware => (innerHandler) {
    return (request) {
      final path = request.url.path;

      // /api/で始まらないパス、または認証が不要なAPIパスはそのまま通す
      if (!path.startsWith('api/') || path == 'api/info' || path == 'api/auth') {
        return innerHandler(request);
      }

      final cookieHeader = request.headers['cookie'];
      print('Auth middleware: Received cookie header: $cookieHeader');
      String? token;

      if (cookieHeader != null) {
        final cookies = cookieHeader.split(';');
        for (var cookie in cookies) {
          final trimmedCookie = cookie.trim();
          if (trimmedCookie.startsWith('pocketlink_session=')) {
            final separatorIndex = trimmedCookie.indexOf('=');
            if (separatorIndex != -1) {
              token = trimmedCookie.substring(separatorIndex + 1);
              break;
            }
          }
        }
      }
      
      print('Auth middleware: Parsed token: $token');

      // トークンを検証
      if (token != null && _sessions.contains(token)) {
        return innerHandler(request); // 認証成功
      }
      
      // 認証失敗
      return Response.unauthorized(json.encode({'error': 'Authentication required.'}),
          headers: {'Content-Type': 'application/json'});
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