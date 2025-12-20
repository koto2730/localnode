import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class ServerService {
  HttpServer? _server;
  String? _ipAddress;
  final int _port = 8080;
  Directory? _documentsDir;
  Directory? _webRootDir; // Webルートディレクトリのパス

  final _router = Router();

  String? get ipAddress => _ipAddress;
  bool get isRunning => _server != null;

  ServerService() {
    _router.get('/api/info', _infoHandler);
    _router.get('/api/files', _getFilesHandler);
    _router.post('/api/upload', _uploadHandler);
    _router.get('/api/download/<filename>', _downloadHandler);
    _router.delete('/api/files/<filename>', _deleteFileHandler);
  }

  Future<void> _init() async {
    // Downloadsフォルダのパスを取得
    final downloadsDir = await getDownloadsDirectory();
    if (downloadsDir == null) {
      throw Exception('Downloadsフォルダが見つかりません。');
    }
    _documentsDir = downloadsDir;
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


  // === Server Control ===

  Future<void> startServer() async {
    if (_server != null) return;

    try {
      await _init();
      await _deployAssets(); // アセットを展開
      WakelockPlus.enable();
      
      _ipAddress = await NetworkInfo().getWifiIP();
      if (_ipAddress == null) throw Exception('Failed to get Wi-Fi IP address.');

      // 展開先の一時ディレクトリを指すように変更
      final staticHandler = createStaticHandler(_webRootDir!.path, defaultDocument: 'index.html');

      final cascade = Cascade()
          .add(_router.call)
          .add(staticHandler);

      final handler = const Pipeline()
          .addMiddleware(logRequests())
          .addHandler(cascade.handler);

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
    WakelockPlus.disable();
    print('Server stopped.');
  }
}