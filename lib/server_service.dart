import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class ServerService {
  static const _safPlatform = MethodChannel('com.ictglab.localnode/saf_storage');
  String? _safDirectoryUri; // 選択されたSAFディレクトリURI
  HttpServer? _server;
  String? _ipAddress;
  int? _port;
  String? _fallbackStoragePath; // SAFが使えない場合のストレージパス
  String? _displayPath; // 表示用のパス
  Directory? _webRootDir; // Webルートディレクトリのパス
  Directory? _thumbnailCacheDir; // サムネイルキャッシュディレクトリ
  String? _pin;
  final Set<String> _sessions = {};

  final _router = Router();

  String? get ipAddress => _ipAddress;
  int? get port => _port;
  String? get pin => _pin;
  bool get isRunning => _server != null;
  String? get documentsPath => _fallbackStoragePath;
  String? get displayPath => _displayPath;

  Future<List<String>> getAvailableIpAddresses() async {
    final addresses = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          addresses.add(addr.address);
        }
      }
    } catch (e) {
      print('Error getting IP addresses: $e');
      // フォールバックとしてWi-Fi IPを試す
      final wifiIP = await NetworkInfo().getWifiIP();
      if (wifiIP != null) {
        addresses.add(wifiIP);
      }
    }
    return addresses.isEmpty ? ['0.0.0.0'] : addresses;
  }

  ServerService() {
    _router.post('/api/auth', _authHandler);
    _router.get('/api/info', _infoHandler);
    _router.get('/api/files', _getFilesHandler);
    _router.post('/api/upload', _uploadHandler);
    _router.get('/api/download/<id>', _downloadHandler);
    _router.get('/api/thumbnail/<id>', _thumbnailHandler);
    _router.get('/api/download-all', _downloadAllHandler);
    _router.delete('/api/files/<id>', _deleteFileHandler);
  }

  Future<void> _init() async {
    if (kIsWeb) {
      print("Web platform detected. No file system access.");
      return;
    }

    final packageInfo = await PackageInfo.fromPlatform();
    final appName = packageInfo.appName;

    // アプリケーションサンドボックス内のディレクトリをフォールバックとして設定
    final docDir = await getApplicationDocumentsDirectory();
    if (Platform.isIOS) {
      _displayPath = 'On My iPhone/$appName'; // iOSではよりユーザーフレンドリーなパスを表示
    } else {
      _displayPath = p.join(docDir.path, appName);
    }
    _fallbackStoragePath = p.join(docDir.path, appName);

    if (_fallbackStoragePath != null) {
      final tempDocumentDir = Directory(_fallbackStoragePath!);
      if (!await tempDocumentDir.exists()) {
        await tempDocumentDir.create(recursive: true);
      }
    }

    // サムネイルキャッシュディレクトリの初期化
    if (!kIsWeb) {
      await loadPersistedSafUri(); // SAF URIを読み込む
      final tempDir = await getTemporaryDirectory();
      _thumbnailCacheDir = Directory(p.join(tempDir.path, 'thumbnails'));
      if (!await _thumbnailCacheDir!.exists()) {
        await _thumbnailCacheDir!.create(recursive: true);
      }
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

        final cookie = 'localnode_session=$token; Path=/; HttpOnly';
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
    return Response.ok('{"version": "1.0.0", "name": "LocalNode Server"}',
        headers: {'Content-Type': 'application/json'});
  }

  Future<Response> _getFilesHandler(Request request) async {
    final storagePath = _safDirectoryUri ?? _fallbackStoragePath;
    if (storagePath == null) {
      return Response.internalServerError(body: 'Documents directory not initialized.');
    }

    // AndroidでSAF URIが設定されている場合は、Platform Channel経由でファイルリストを取得
    if (Platform.isAndroid && _safDirectoryUri != null) {
      try {
        final List<dynamic>? files = await _safPlatform.invokeMethod('listFiles', {'uri': _safDirectoryUri});
        if (files == null) {
          return Response.internalServerError(body: 'Failed to list files.');
        }
        // URIをBase64エンコードしてIDとして追加
        final filesWithId = files.map((file) {
          final uri = file['uri'] as String;
          final id = base64Url.encode(utf8.encode(uri));
          return {...file, 'id': id};
        }).toList();
        return Response.ok(jsonEncode(filesWithId), headers: {'Content-Type': 'application/json'});
      } on PlatformException catch (e) {
        return Response.internalServerError(body: "Failed to list files: ${e.message}");
      }
    }
    // 他のプラットフォーム、またはSAFが設定されていないAndroidの場合は、従来のdart:ioを使用
    else {
      final directory = Directory(storagePath);
      if (!await directory.exists()) {
        return Response.internalServerError(body: 'Documents directory not found.');
      }
      final files = await directory.list().where((item) => item is File).cast<File>().toList();
      final fileList = files.map((file) async {
        final stat = await file.stat();
        // パスをBase64エンコードしてIDとして追加
        final id = base64Url.encode(utf8.encode(file.path));
        return {
          'name': p.basename(file.path),
          'size': stat.size,
          'modified': stat.modified.toIso8601String(),
          'id': id,
        };
      }).toList();

      final results = await Future.wait(fileList);
      return Response.ok(jsonEncode(results), headers: {'Content-Type': 'application/json'});
    }
  }
  Future<Response> _uploadHandler(Request request) async {
    final storagePath = _safDirectoryUri ?? _fallbackStoragePath;
    if (storagePath == null) {
      return Response.internalServerError(body: 'Documents directory not initialized.');
    }

    final encodedFilename = request.headers['x-filename'];
    if (encodedFilename == null || encodedFilename.isEmpty) {
      return Response.badRequest(body: 'x-filename header is required.');
    }
    final filename = Uri.decodeComponent(encodedFilename);
    final sanitizedFilename = p.basename(filename);

    // AndroidでSAF URIが設定されている場合
    if (Platform.isAndroid && _safDirectoryUri != null) {
      try {
        final bytes = await request.read().fold<List<int>>([], (prev, chunk) => prev..addAll(chunk));
        final mimeType = _getMimeType(sanitizedFilename);

        final String? newFileUri = await _safPlatform.invokeMethod('createFile', {
          'uri': _safDirectoryUri,
          'filename': sanitizedFilename,
          'mimeType': mimeType,
          'bytes': Uint8List.fromList(bytes),
        });

        if (newFileUri != null) {
          return Response.ok('File uploaded successfully: $sanitizedFilename');
        } else {
          return Response.internalServerError(body: 'Failed to create file via SAF.');
        }
      } on PlatformException catch (e) {
        return Response.internalServerError(body: "Failed to save file: ${e.message}");
      }
    }
    // 他のプラットフォーム、またはSAFが設定されていないAndroidの場合
    else {
      final directory = Directory(storagePath);
      if (!await directory.exists()) {
        print('Upload error: storage directory missing -> $storagePath');
        return Response.internalServerError(body: 'Documents directory not found.');
      }

      final file = await _getUniqueFilePath(directory, sanitizedFilename);
      final sink = file.openWrite();
      try {
        int totalBytes = 0;
        await for (final chunk in request.read()) {
          totalBytes += chunk.length;
          sink.add(chunk);
        }
        await sink.close();
        print('Upload success: ${p.basename(file.path)} bytes=$totalBytes');
        return Response.ok('File uploaded successfully: ${p.basename(file.path)}');
      } catch (e, st) {
        await sink.close();
        print('Upload error: $e\n$st');
        return Response.internalServerError(body: 'Failed to save file: $e');
      }
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

  Future<Response> _downloadHandler(Request request, String id) async {
    final storagePath = _safDirectoryUri ?? _fallbackStoragePath;
    if (storagePath == null) {
      return Response.internalServerError(body: 'Documents directory not initialized.');
    }

    try {
      final decoded = utf8.decode(base64Url.decode(id));
      
      // AndroidでSAF URIが設定されている場合
      if (Platform.isAndroid && _safDirectoryUri != null) {
        final fileUri = decoded;
        final Uint8List? bytes = await _safPlatform.invokeMethod('readFile', {'uri': fileUri});

        if (bytes == null) {
          return Response.internalServerError(body: 'Failed to read file.');
        }
        
        final filename = Uri.parse(fileUri).pathSegments.last;
        final mimeType = _getMimeType(filename);
        return Response.ok(bytes, headers: {'Content-Type': mimeType});

      } 
      // 他のプラットフォーム、またはSAFが設定されていないAndroidの場合
      else {
        final filePath = decoded;
        final file = File(filePath);
        if (!await file.exists()) {
          return Response.notFound('File not found: $filePath');
        }
        final mimeType = _getMimeType(p.basename(filePath));
        return Response.ok(file.openRead())
            .change(headers: {'Content-Type': mimeType});
      }
    } catch (e) {
      return Response.internalServerError(body: "Failed to process download request: $e");
    }
  }

  // iOS向けの表示パスを整形するヘルパー
  String _getIosDisplayPath(String fullPath, String appName, String appDocDirPath) {
    // アプリのデフォルトのドキュメントディレクトリ、またはその直下のアプリ名フォルダの場合
    if (fullPath == appDocDirPath || fullPath == p.join(appDocDirPath, appName)) {
      return 'On My iPhone/$appName (App Storage)';
    }

    // パスに '/Downloads' が含まれる場合
    final downloadsIndex = fullPath.indexOf('/Downloads');
    if (downloadsIndex != -1) {
      String relativePath = fullPath.substring(downloadsIndex); // 例: /Downloads/MyFolder
      // 最初の '/' を取り除いて、On My iPhone/Downloads/MyFolder の形式にする
      if (relativePath.startsWith('/')) {
        relativePath = relativePath.substring(1);
      }
      return 'On My iPhone/$relativePath';
    }

    // その他のカスタムフォルダの場合: 最後のフォルダ名のみ表示
    return 'On My iPhone/${p.basename(fullPath)}';
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

  Future<Response> _thumbnailHandler(Request request, String id) async {
    final storagePath = _safDirectoryUri ?? _fallbackStoragePath;
    if (storagePath == null || _thumbnailCacheDir == null) {
      return Response.internalServerError(body: 'Server directory not initialized.');
    }

    try {
      final decoded = utf8.decode(base64Url.decode(id));
      final filename = Platform.isAndroid && _safDirectoryUri != null 
          ? Uri.parse(decoded).pathSegments.last 
          : p.basename(decoded);

      if (!_isImageFile(filename)) {
        return Response.badRequest(body: 'File is not an image.');
      }

      final cacheFile = File(p.join(_thumbnailCacheDir!.path, '$filename.jpg'));

      if (await cacheFile.exists()) {
        return Response.ok(cacheFile.openRead(), headers: {'Content-Type': 'image/jpeg'});
      }
      
      Uint8List? imageBytes;

      if (Platform.isAndroid && _safDirectoryUri != null) {
        imageBytes = await _safPlatform.invokeMethod('readFile', {'uri': decoded});
      } else {
        final file = File(decoded);
        if (!await file.exists()) {
          return Response.notFound('File not found: $filename');
        }
        imageBytes = await file.readAsBytes();
      }

      if (imageBytes == null) {
        return Response.internalServerError(body: 'Failed to read image bytes.');
      }

      final image = img.decodeImage(imageBytes);
      if (image == null) {
        return Response.internalServerError(body: 'Failed to decode image.');
      }

      final thumbnail = img.copyResize(image, width: 120);
      final thumbnailBytes = img.encodeJpg(thumbnail, quality: 85);

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

  Future<Response> _deleteFileHandler(Request request, String id) async {
    final storagePath = _safDirectoryUri ?? _fallbackStoragePath;
    if (storagePath == null || _thumbnailCacheDir == null) {
      return Response.internalServerError(body: 'Documents directory not initialized.');
    }

    try {
      final decoded = utf8.decode(base64Url.decode(id));
      bool? deleted = false;

      // AndroidでSAF URIが設定されている場合
      if (Platform.isAndroid && _safDirectoryUri != null) {
        final fileUri = decoded;
        deleted = await _safPlatform.invokeMethod('deleteFile', {'uri': fileUri});
      } 
      // 他のプラットフォーム、またはSAFが設定されていないAndroidの場合
      else {
        final filePath = decoded;
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
          deleted = true;
        }
      }

      if (deleted == true) {
        // サムネイルキャッシュも削除
        final filename = Platform.isAndroid && _safDirectoryUri != null 
            ? Uri.parse(decoded).pathSegments.last 
            : p.basename(decoded);
        final cacheFile = File(p.join(_thumbnailCacheDir!.path, '$filename.jpg'));
        if (await cacheFile.exists()) {
          await cacheFile.delete();
        }
        return Response.ok('File deleted successfully');
      } else {
        return Response.internalServerError(body: 'Failed to delete file.');
      }
    } catch (e) {
      return Response.internalServerError(body: "Failed to process delete request: $e");
    }
  }

  Future<Response> _downloadAllHandler(Request request) async {
    final storagePath = _safDirectoryUri ?? _fallbackStoragePath;
    if (storagePath == null) {
      return Response.internalServerError(body: 'Documents directory not initialized.');
    }

    final encoder = ZipEncoder();
    final archive = Archive();

    // AndroidでSAF URIが設定されている場合
    if (Platform.isAndroid && _safDirectoryUri != null) {
      try {
        final List<dynamic>? files = await _safPlatform.invokeMethod('listFiles', {'uri': _safDirectoryUri});
        if (files == null) {
          return Response.internalServerError(body: 'Failed to list files for zipping.');
        }

        for (final fileInfo in files) {
          final String fileUri = fileInfo['uri'];
          final String filename = fileInfo['name'];
          final Uint8List? bytes = await _safPlatform.invokeMethod('readFile', {'uri': fileUri});
          if (bytes != null) {
            archive.addFile(ArchiveFile(filename, bytes.length, bytes));
          }
        }
      } on PlatformException catch(e) {
        return Response.internalServerError(body: 'Failed to read files for zipping: ${e.message}');
      }
    }
    // 他のプラットフォーム、またはSAFが設定されていないAndroidの場合
    else {
      final directory = Directory(storagePath);
      if (!await directory.exists()) {
        return Response.internalServerError(body: 'Documents directory not found.');
      }
      final files = directory.listSync(recursive: true).whereType<File>();
      for (final file in files) {
        final bytes = await file.readAsBytes();
        final filename = p.relative(file.path, from: directory.path);
        archive.addFile(ArchiveFile(filename, bytes.length, bytes));
      }
    }

    final zipData = encoder.encode(archive);
    if (zipData == null) {
      return Response.internalServerError(body: 'Failed to create zip file.');
    }

    return Response.ok(zipData, headers: {
      'Content-Type': 'application/zip',
      'Content-Disposition': 'attachment; filename="localnode_files.zip"',
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
          if (trimmedCookie.startsWith('localnode_session=')) {
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

  Future<void> startServer({required String ipAddress, required int port}) async {
    if (_server != null) return;

    _pin = _generatePin();
    _sessions.clear();
    print('Your PIN is: $_pin'); // デバッグ用

    try {
      await _init();
      await _deployAssets(); // アセットを展開
      WakelockPlus.enable();

      _ipAddress = ipAddress;
      _port = port;

      // 展開先の一時ディレクトリを指すように変更
      final staticHandler =
          createStaticHandler(_webRootDir!.path, defaultDocument: 'index.html');

      final apiHandler =
          const Pipeline().addMiddleware(_authMiddleware).addHandler(_router.call);

      final cascade = Cascade().add(apiHandler).add(staticHandler);

      final handler =
          const Pipeline().addMiddleware(logRequests()).addHandler(cascade.handler);

      // anyIPv4でリッスンすることで、Tailscale IPなど特定のインターフェースにもアクセス可能
      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
      print('Serving at http://${_server!.address.host}:${_server!.port}');
      print('Selected IP for display: http://$_ipAddress:$port');
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
    _port = null;
    _pin = null;
    _displayPath = null;
    _sessions.clear();
    WakelockPlus.disable();
    print('Server stopped.');
  }

  // SAF ディレクトリを選択するメソッド
  Future<void> selectSafDirectory() async {
    try {
      if (Platform.isAndroid) {
        // Android: SAF (Storage Access Framework) を使用
        final String? uri = await _safPlatform.invokeMethod('requestSafDirectory');
        if (uri != null) {
          _safDirectoryUri = uri;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('saf_directory_uri', uri);
          print('SAF Directory URI selected and persisted: $uri');
        } else {
          print('SAF Directory selection cancelled.');
        }
      } else if (Platform.isIOS) {
        // iOS: file_picker を使用してディレクトリを選択させる
        final String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
        if (selectedDirectory != null && selectedDirectory.isNotEmpty) {
          await _ensureDirectoryExists(selectedDirectory);
          _fallbackStoragePath = selectedDirectory;
          
          final packageInfo = await PackageInfo.fromPlatform();
          final docDir = await getApplicationDocumentsDirectory();

          _displayPath = _getIosDisplayPath(selectedDirectory, packageInfo.appName, docDir.path);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('selected_directory_path', selectedDirectory);
          print('iOS directory selected and persisted: $selectedDirectory');
        } else {
          print('Directory selection cancelled.');
        } 
        // Windows, macOS, Linux: file_picker を使用
      } else {
        final String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
        if (selectedDirectory != null && selectedDirectory.isNotEmpty) {
          await _ensureDirectoryExists(selectedDirectory);
          _fallbackStoragePath = selectedDirectory;
          _displayPath = selectedDirectory;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('selected_directory_path', selectedDirectory);
          print('Directory selected and persisted: $selectedDirectory');
        } else {
          print('Directory selection cancelled.');
        }
      }
    } on PlatformException catch (e) {
      print("Failed to select directory: '${e.message}'.");
    }
  }

  Future<void> _ensureDirectoryExists(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  // 永続化されたSAFディレクトリURIを読み込むメソッド
  Future<void> loadPersistedSafUri() async {
    final prefs = await SharedPreferences.getInstance();
    _safDirectoryUri = prefs.getString('saf_directory_uri');
    if (_safDirectoryUri != null) {
      print('Loaded persisted SAF Directory URI: $_safDirectoryUri');
      // ここでネイティブ側にもURIを渡し、アクセス権を再確認させるなどの処理が必要になる可能性
    }
  }
}
