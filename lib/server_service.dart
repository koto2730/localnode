import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
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

/// 動作モード
enum OperationMode { normal, downloadOnly }

/// 認証モード
enum AuthMode { randomPin, fixedPin, noPin }

/// クリップボード共有アイテム
class ClipboardItem {
  final String id;
  final String text;
  final String? tag;
  final DateTime createdAt;
  // #220 / #230: @up 付きで投稿された / federation 経由で「重要」マーク済み
  final bool important;

  ClipboardItem({
    required this.id,
    required this.text,
    this.tag,
    required this.createdAt,
    this.important = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'tag': tag,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'important': important,
  };
}

// #218: UUID v4 (random) を生成して `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` 形式で返す
String _generateUuidV4() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class ServerService {
  static const _safPlatform = MethodChannel('com.ictglab.localnode/saf_storage');
  static const _folderPlatform = MethodChannel('com.ictglab.localnode/folder');
  static const _storagePlatform = MethodChannel('com.ictglab.localnode/storage');
  String? _safDirectoryUri; // 選択されたSAFディレクトリURI
  HttpServer? _server;
  String? _httpsCertPath;
  String? _httpsKeyPath;
  String? _httpsHostname;
  String? _ipAddress;
  int? _port;
  String? _fallbackStoragePath; // SAFが使えない場合のストレージパス
  String? _displayPath; // 表示用のパス
  Directory? _webRootDir; // Webルートディレクトリのパス
  // #304: 管理者テーマ CSS のソースパス（未指定なら空ファイルを配信＝従来の見た目）
  String? _themeCssPath;
  Directory? _thumbnailCacheDir; // サムネイルキャッシュディレクトリ
  // #287: CLI (`localnode --cli`) の --cache-dir。null なら OS の一時ディレクトリ。
  String? _cacheDir;
  static final Uint8List _placeholderThumbBytes = _buildPlaceholderJpeg();
  String? _pin;
  // #261: セッショントークン -> 失効エポックミリ秒。TTL 超過で無効化する。
  final Map<String, int> _sessions = {};
  static const Duration _sessionTtl = Duration(hours: 24);
  static const int _maxNoPinSessions = 1000;
  // #258: DNS rebinding 対策で許可する Host 値（IP / localhost）。空なら無効。
  Set<String> _allowedHosts = {};
  // #6: TLS 有効時のみ Set-Cookie に Secure 属性を付ける。
  bool _httpsEnabled = false;
  // #285: 直接アップロードの上限バイト数（null = 無制限）。ストレージ枯渇 DoS 対策。
  int? _maxUploadBytes;
  OperationMode _operationMode = OperationMode.normal;
  AuthMode _authMode = AuthMode.randomPin;
  bool _verboseLogging = false;
  bool _clipboardEnabled = true;
  String _serverName = 'LocalNode';
  String _appVersion = '';
  // #218 / §1.11: 端末識別 UUID。SharedPreferences で永続化。
  String _deviceId = '';
  int _startedAt = 0; // サーバ起動タイムスタンプ（エポックミリ秒）

  // クリップボード共有用
  final List<ClipboardItem> _clipboardItems = [];
  int _clipboardLastModified = 0;
  // #228: 削除リングバッファ
  static const int _maxDeletionLog = 200;
  final List<({String id, int deletedAtMs})> _clipboardDeletes = [];

  void _recordDeletion(String id) {
    _clipboardDeletes.add((
      id: id,
      deletedAtMs: DateTime.now().millisecondsSinceEpoch,
    ));
    if (_clipboardDeletes.length > _maxDeletionLog) {
      _clipboardDeletes.removeAt(0);
    }
  }

  // #230: 件数超過時の退避。非 important から先に削る。全部 important なら最古から退避。
  ClipboardItem _evictClipboardItem() {
    for (var i = _clipboardItems.length - 1; i >= 0; i--) {
      if (!_clipboardItems[i].important) {
        return _clipboardItems.removeAt(i);
      }
    }
    return _clipboardItems.removeLast();
  }
  // #227: 1.6.0 で 10 → 1000 にデフォルト値を引き上げ
  // GUI アプリは現状 YAML config を読み込まないので hardcoded。
  // federation (#218) で GUI 側の config 配線が入った時点で設定化される予定。
  static const int _maxClipboardItems = 1000;
  static const int _maxTextLength = 10000;

  // クリップボードアイテムへの外部アクセス用ゲッター
  List<ClipboardItem> get clipboardItems => List.unmodifiable(_clipboardItems);
  int get clipboardLastModified => _clipboardLastModified;

  // ブルートフォース保護用
  final Map<String, int> _failedAttempts = {};
  final Map<String, DateTime> _lockoutUntil = {};
  static const int _maxFailedAttempts = 3;
  static const Duration _lockoutDuration = Duration(minutes: 10);

  final _router = Router();

  String? get ipAddress => _ipAddress;
  int? get port => _port;
  String? get pin => _pin;
  bool get isRunning => _server != null;
  bool get isHttpsMode => _httpsCertPath != null && _httpsCertPath!.isNotEmpty &&
      _httpsKeyPath != null && _httpsKeyPath!.isNotEmpty;

  /// HTTPS 用 cert/key パスを検証する。問題があれば例外を投げる。
  Future<void> _validateHttpsPaths(String? certPath, String? keyPath) async {
    final hasCert = certPath != null && certPath.isNotEmpty;
    final hasKey = keyPath != null && keyPath.isNotEmpty;
    if (hasCert != hasKey) {
      throw ArgumentError('証明書ファイルと秘密鍵ファイルは両方指定してください。');
    }
    if (hasCert) {
      if (!await File(certPath!).exists()) {
        throw ArgumentError('証明書ファイルが見つかりません: $certPath');
      }
      if (!await File(keyPath!).exists()) {
        throw ArgumentError('秘密鍵ファイルが見つかりません: $keyPath');
      }
    }
  }

  /// QR コードに埋め込む URL。HTTPS モードでホスト名が設定されている場合はホスト名を優先する。
  String? get qrUrl {
    if (_ipAddress == null || _port == null) return null;
    final scheme = isHttpsMode ? 'https' : 'http';
    final host = (isHttpsMode && _httpsHostname != null && _httpsHostname!.isNotEmpty)
        ? _httpsHostname!
        : _ipAddress!;
    return '$scheme://$host:$_port';
  }
  String? get documentsPath => _fallbackStoragePath;

  /// verbose有効時のみ出力するログ
  void _log(String message) {
    if (_verboseLogging) print(message);
  }
  String? get displayPath => _displayPath;
  OperationMode get operationMode => _operationMode;
  AuthMode get authMode => _authMode;

  /// アプリ起動時にデフォルトパスの設定と永続化されたフォルダ選択を復元する
  Future<void> initializePaths() async {
    if (kIsWeb) return;
    final packageInfo = await PackageInfo.fromPlatform();
    final appName = packageInfo.appName;
    _appVersion = packageInfo.version;

    // #218: 端末識別 UUID を SharedPreferences から復元、無ければ生成して保存
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('device_id');
    if (stored != null && stored.isNotEmpty) {
      _deviceId = stored;
    } else {
      _deviceId = _generateUuidV4();
      await prefs.setString('device_id', _deviceId);
    }

    final docDir = await getApplicationDocumentsDirectory();

    // デフォルトパスを設定
    if (Platform.isIOS) {
      _fallbackStoragePath = docDir.path;
      _displayPath = 'On My iPhone/$appName';
    } else if (Platform.isMacOS) {
      // macOS: ユーザーのDownloadsフォルダをデフォルトに使用
      try {
        final downloadsPath = await _storagePlatform.invokeMethod<String>('getDownloadsDirectory');
        if (downloadsPath != null) {
          _fallbackStoragePath = downloadsPath;
          _displayPath = downloadsPath;
        }
      } catch (_) {}
      // フォールバック: Downloadsが取得できなかった場合はDocumentsを使用
      if (_fallbackStoragePath == null) {
        _fallbackStoragePath = p.join(docDir.path, appName);
        _displayPath = p.join(docDir.path, appName);
      }
    } else {
      _fallbackStoragePath = p.join(docDir.path, appName);
      _displayPath = p.join(docDir.path, appName);
    }

    // デフォルトフォルダの作成
    if (_fallbackStoragePath != null) {
      final dir = Directory(_fallbackStoragePath!);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }

    // 永続化されたフォルダ選択を復元（デフォルトを上書き）
    await loadPersistedSafUri();
  }

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
    _router.get('/api/health', _healthHandler);
    _router.get('/api/info', _infoHandler);
    _router.get('/api/check-auth', _checkAuthHandler);
    _router.get('/api/files', _getFilesHandler);
    _router.post('/api/upload', _uploadHandler);
    _router.get('/api/download/<id>', _downloadHandler);
    _router.get('/api/thumbnail/<id>', _thumbnailHandler);
    _router.get('/api/thumbnail-by-path', _thumbnailByPathHandler);
    _router.get('/api/text-preview/<id>', _textPreviewHandler);
    _router.get('/api/download-all', _downloadAllHandler);
    _router.delete('/api/files/<id>', _deleteFileHandler);
    _router.post('/api/files/delete-batch', _deleteBatchHandler);
    // クリップボード共有API
    _router.get('/api/clipboard', _getClipboardHandler);
    _router.post('/api/clipboard', _postClipboardHandler);
    _router.delete('/api/clipboard/<id>', _deleteClipboardItemHandler);
    _router.delete('/api/clipboard', _clearClipboardHandler);
  }

  Future<void> _init() async {
    if (kIsWeb) {
      _log("Web platform detected. No file system access.");
      return;
    }

    final packageInfo = await PackageInfo.fromPlatform();
    final appName = packageInfo.appName;

    // アプリケーションサンドボックス内のディレクトリをフォールバックとして設定
    // ユーザーが既にフォルダを選択済みの場合はデフォルト値で上書きしない
    final docDir = await getApplicationDocumentsDirectory();
    if (_fallbackStoragePath == null) {
      if (Platform.isIOS) {
        _displayPath = 'On My iPhone/$appName'; // iOSではよりユーザーフレンドリーなパスを表示
        _fallbackStoragePath = docDir.path;
      } else {
        _displayPath = p.join(docDir.path, appName);
        _fallbackStoragePath = p.join(docDir.path, appName);
      }
    }

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
      _chmodDir(_thumbnailCacheDir!); // #269: 共有 temp のデスクトップ環境向けに 700 制限
    }
  }

  /// アセットのWebファイルを一時ディレクトリに展開する
  Future<void> _deployAssets() async {
    final tempDir = await getTemporaryDirectory();
    // #242: 同ホストで複数 LocalNode サーバ (CLI / 別 GUI プロセス) が共存しても
    //       互いの serving content を上書きしないように PID 別ディレクトリへ。
    const prefix = 'web_';
    _reapStaleWebDirs(tempDir, prefix);
    _webRootDir = Directory(p.join(tempDir.path, '$prefix$pid'));

    // 既存のディレクトリがあればクリーンアップ
    if (await _webRootDir!.exists()) {
      await _webRootDir!.delete(recursive: true);
    }
    await _webRootDir!.create(recursive: true);
    _chmodDir(_webRootDir!); // #269

    try {
      // index.htmlを直接読み込んで一時ディレクトリにコピーする
      const assetPath = 'assets/web/index.html';
      final byteData = await rootBundle.load(assetPath);
      final destinationFile = File(p.join(_webRootDir!.path, 'index.html'));
      await destinationFile.writeAsBytes(byteData.buffer.asUint8List());
      await _deployThemeFiles(); // #304
    } catch (e) {
      print('ERROR: Failed to deploy web assets: $e');
      rethrow;
    }
  }

  // #304: 管理者テーマ CSS（theme.css）を web ルートに配置。指定があればその内容を、
  // 無ければ空ファイルを書き出す（空＝no-op で従来の見た目のまま）。index.html は
  // 常に theme.css を参照するので 404 を避ける意味もある。
  Future<void> _deployThemeFiles() async {
    final dest = File(p.join(_webRootDir!.path, 'theme.css'));
    try {
      if (_themeCssPath != null && await File(_themeCssPath!).exists()) {
        await File(_themeCssPath!).copy(dest.path);
      } else {
        await dest.writeAsString('');
      }
    } catch (_) {
      // テーマ配置に失敗しても UI 本体は動かす（空で継続）
      try {
        await dest.writeAsString('');
      } catch (_) {}
    }
  }

  // === Handlers ===

  String _generatePin() {
    return (1000 + Random.secure().nextInt(9000)).toString();
  }

  String _generateSessionToken() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    return base64Url.encode(values);
  }

  Future<Response> _authHandler(Request request) async {
    // PINなしモードでは自動認証
    if (_authMode == AuthMode.noPin) {
      final token = _issueSession();
      return Response.ok(json.encode({'status': 'success'}), headers: {
        'Content-Type': 'application/json',
        'Set-Cookie': _buildSessionCookie(token),
      });
    }

    // クライアントIPを取得
    final clientIp = _getClientIp(request);

    // ロックアウト中かチェック
    final lockout = _lockoutUntil[clientIp];
    if (lockout != null && DateTime.now().isBefore(lockout)) {
      final remaining = lockout.difference(DateTime.now()).inSeconds;
      return Response.forbidden(
          json.encode({
            'error': 'Too many failed attempts. Try again in $remaining seconds.'
          }),
          headers: {'Content-Type': 'application/json'});
    }

    final body = await request.readAsString();
    try {
      final params = json.decode(body) as Map<String, dynamic>;
      final submittedPin = params['pin'] as String? ?? '';

      // #260: 定数時間比較でタイミング攻撃を防ぐ
      if (_pin != null && _constantTimeEquals(submittedPin, _pin!)) {
        // 認証成功: 失敗カウントをリセット
        _failedAttempts.remove(clientIp);
        _lockoutUntil.remove(clientIp);

        final token = _issueSession();

        _log('Auth success. Active sessions: ${_sessions.length}');

        return Response.ok(json.encode({'status': 'success'}), headers: {
          'Content-Type': 'application/json',
          'Set-Cookie': _buildSessionCookie(token),
        });
      } else {
        // 認証失敗: 失敗カウントを増加
        final attempts = (_failedAttempts[clientIp] ?? 0) + 1;
        _failedAttempts[clientIp] = attempts;

        _log('Auth failed from $clientIp. Attempt $attempts of $_maxFailedAttempts');

        if (attempts >= _maxFailedAttempts) {
          _lockoutUntil[clientIp] = DateTime.now().add(_lockoutDuration);
          _failedAttempts.remove(clientIp);
          _log('IP $clientIp locked out for ${_lockoutDuration.inMinutes} minutes');
          return Response.forbidden(
              json.encode({
                'error':
                    'Too many failed attempts. Locked out for ${_lockoutDuration.inMinutes} minutes.'
              }),
              headers: {'Content-Type': 'application/json'});
        }

        return Response.forbidden(json.encode({'error': 'Invalid PIN'}),
            headers: {'Content-Type': 'application/json'});
      }
    } catch (e) {
      return Response.badRequest(
          body: json.encode({'error': 'Invalid request body.'}),
          headers: {'Content-Type': 'application/json'});
    }
  }

  // ブルートフォースのロックアウト等で使うクライアント識別子。
  // X-Forwarded-For / X-Real-IP はクライアントが自由に詐称でき、LocalNode は
  // 信頼できるリバースプロキシ配下にいる前提ではないため **使わない**。
  // shelf が握っている実 TCP リモートアドレスを使う (詐称不能)。
  String _getClientIp(Request request) {
    final conn = request.context['shelf.io.connection_info'];
    if (conn is HttpConnectionInfo) {
      return conn.remoteAddress.address;
    }
    return 'unknown';
  }

  /// ヘルスチェック: 認証不要。クライアントがサーバ再起動を検知するために使用
  Response _healthHandler(Request request) {
    return Response.ok(json.encode({'startedAt': _startedAt}),
        headers: {'Content-Type': 'application/json'});
  }

  // #201: 認証チェック専用エンドポイント。
  // 認証ミドルウェアがセッション未確立時に 401 を返すので、
  // 200 で来ればセッションは有効。downloadFile の事前チェック用。
  Response _checkAuthHandler(Request request) {
    return Response.ok(json.encode({'ok': true}),
        headers: {'Content-Type': 'application/json'});
  }

  Response _infoHandler(Request request) {
    final info = {
      'version': _appVersion,
      'name': 'LocalNode Server',
      'serverName': _serverName,
      'operationMode': _operationMode == OperationMode.downloadOnly ? 'downloadOnly' : 'normal',
      'authMode': _authMode == AuthMode.fixedPin ? 'fixedPin' : _authMode == AuthMode.noPin ? 'noPin' : 'randomPin',
      'requiresAuth': _authMode != AuthMode.noPin,
      'clipboardEnabled': _clipboardEnabled,
      // #206: Web UI が PIN 入力モードを切り替えるためのヒント。
      // GUI アプリは現状デフォルト固定 (CLI が --pin-length / --pin-charset を持つ)
      'pinCharset': 'digits',
      'pinLength': 4,
    };
    // #265: 端末識別子は認証済みリクエストにのみ返す（未認証への情報漏洩を防ぐ）。
    if (_isAuthenticatedRequest(request)) {
      info['deviceId'] = _deviceId;
    }
    return Response.ok(json.encode(info),
        headers: {'Content-Type': 'application/json'});
  }

  Future<Response> _getFilesHandler(Request request) async {
    final storagePath = _safDirectoryUri ?? _fallbackStoragePath;
    if (storagePath == null) {
      return Response.internalServerError(body: 'Documents directory not initialized.');
    }

    // AndroidでSAF URIが設定されている場合は、Platform Channel経由でファイルリストを取得
    if (Platform.isAndroid && _safDirectoryUri != null) {
      // #209+ : ?path= でサブフォルダもナビゲートできるようにする。SAF はパスでなく
      //         tree URI ベースなので、Kotlin 側でルートから相対パスを辿って中身を返す。
      final relPath = request.requestedUri.queryParameters['path'] ?? '';
      try {
        final List<dynamic>? entries = await _safPlatform.invokeMethod(
          'listFilesAtPath',
          {'uri': _safDirectoryUri, 'path': relPath},
        );
        if (entries == null) {
          return Response.internalServerError(body: 'Failed to list files.');
        }
        // URI を Base64 エンコードして ID に。ディレクトリには type を付与。
        final list = entries.map((e) {
          final m = Map<String, dynamic>.from(e as Map);
          final uri = m['uri'] as String;
          final id = base64Url.encode(utf8.encode(uri));
          if (m['isDirectory'] == true) {
            return {'name': m['name'], 'type': 'directory', 'id': id};
          }
          return {
            'name': m['name'],
            'type': 'file',
            'size': m['size'],
            'modified': m['modified'],
            'id': id,
          };
        }).toList();
        // ディレクトリを先頭に、その後ファイル。各群で名前順。
        list.sort((a, b) {
          if (a['type'] != b['type']) return a['type'] == 'directory' ? -1 : 1;
          return (a['name'] as String? ?? '').compareTo(b['name'] as String? ?? '');
        });
        return Response.ok(jsonEncode(list), headers: {'Content-Type': 'application/json'});
      } on PlatformException catch (e) {
        if (e.code == 'NOT_FOUND') {
          return Response.notFound('Directory not found.');
        }
        if (e.code == 'INVALID_PATH') {
          return Response.badRequest(body: 'Invalid path.');
        }
        return Response.internalServerError(body: "Failed to list files: ${e.message}");
      }
    }
    // 他のプラットフォーム、またはSAFが設定されていないAndroidの場合は、従来のdart:ioを使用
    else {
      // ?path= パラメータで相対パスを受け取りサブフォルダナビゲーションに対応 (#178, #179)
      final relPath = request.requestedUri.queryParameters['path'] ?? '';
      final rootDir = Directory(storagePath);
      if (!await rootDir.exists()) {
        return Response.internalServerError(body: 'Documents directory not found.');
      }
      // パストラバーサル防止: シンボリックリンク解決後のパスで検証
      final canonicalRoot = await rootDir.resolveSymbolicLinks();
      final targetPath = p.normalize(p.join(canonicalRoot, relPath));
      final directory = Directory(targetPath);
      if (!await directory.exists()) {
        return Response.notFound('Directory not found.');
      }
      final canonicalTarget = await directory.resolveSymbolicLinks();
      if (canonicalTarget != canonicalRoot &&
          !p.isWithin(canonicalRoot, canonicalTarget)) {
        return Response.forbidden('Access denied');
      }
      final items = await directory.list(followLinks: false).toList();
      final itemList = items.map((item) async {
        final isDir = item is Directory;
        final id = base64Url.encode(utf8.encode(item.path));
        if (isDir) {
          return {
            'name': p.basename(item.path),
            'type': 'directory',
            'id': id,
          };
        } else {
          final stat = await item.stat();
          return {
            'name': p.basename(item.path),
            'type': 'file',
            'size': stat.size,
            'modified': stat.modified.toIso8601String(),
            'id': id,
          };
        }
      }).toList();

      final results = await Future.wait(itemList);
      // フォルダ先頭、名前順でソート
      results.sort((a, b) {
        if (a['type'] != b['type']) return a['type'] == 'directory' ? -1 : 1;
        return (a['name'] as String? ?? '').compareTo(b['name'] as String? ?? '');
      });
      return Response.ok(jsonEncode(results), headers: {'Content-Type': 'application/json'});
    }
  }
  /// ダウンロード専用モード時に書き込み操作を拒否するガード
  Response? _checkDownloadOnlyMode() {
    if (_operationMode != OperationMode.downloadOnly) return null;
    return Response.forbidden(
      json.encode({'error': 'This server is in download-only mode.'}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<Response> _uploadHandler(Request request) async {
    final guard = _checkDownloadOnlyMode();
    if (guard != null) return guard;

    final storagePath = _safDirectoryUri ?? _fallbackStoragePath;
    if (storagePath == null) {
      return Response.internalServerError(body: 'Documents directory not initialized.');
    }

    final encodedFilename = request.headers['x-filename'];
    if (encodedFilename == null || encodedFilename.isEmpty) {
      return Response.badRequest(body: 'x-filename header is required.');
    }
    final rawName = p.basename(Uri.decodeComponent(encodedFilename));
    // #263: null バイト/制御文字を含む名前はサニタイズ前に拒否
    if (rawName.codeUnits.any((c) => c < 32 || c == 127)) {
      return Response.badRequest(body: 'Invalid filename.');
    }
    final sanitizedFilename = _sanitizeFilename(rawName);
    if (sanitizedFilename == null) {
      return Response.badRequest(body: 'Invalid filename.');
    }

    // #285: 直接アップロードのサイズ上限。content-length で早期に弾く
    // （ヘッダを詐称された場合はストリーム中でも打ち切る）。
    final maxBytes = _maxUploadBytes;
    if (maxBytes != null) {
      final clHeader = request.headers['content-length'];
      final cl = clHeader != null ? int.tryParse(clHeader) : null;
      if (cl != null && cl > maxBytes) {
        return _tooLargeResponse(maxBytes);
      }
    }

    final relPath = request.requestedUri.queryParameters['path'] ?? '';

    // AndroidでSAF URIが設定されている場合
    if (Platform.isAndroid && _safDirectoryUri != null) {
      // SAF はサブディレクトリ URI 解決が未実装なので、path 指定はサポートしない
      // (Copilot #207 review): silent root fallback を避け、明示的に 400 を返す
      if (relPath.isNotEmpty) {
        return Response.badRequest(
            body: 'Subfolder upload is not supported on Android SAF.');
      }
      try {
        final bytes = <int>[];
        await for (final chunk in request.read()) {
          bytes.addAll(chunk);
          if (maxBytes != null && bytes.length > maxBytes) {
            return _tooLargeResponse(maxBytes); // #285
          }
        }
        final mimeType = _getMimeType(sanitizedFilename);

        final String? newFileUri = await _safPlatform.invokeMethod('createFile', {
          'uri': _safDirectoryUri,
          'filename': sanitizedFilename,
          'mimeType': mimeType,
          'bytes': Uint8List.fromList(bytes),
        });

        if (newFileUri != null) {
          // #214: SAF はサブフォルダ非対応なので relPath は空。
          _maybePostUploadClipboard(request, sanitizedFilename, '');
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
      // #203: ?path=<relpath> でサブフォルダ宛のアップロードを許可
      // (Copilot #207 review): セグメント単位で .. のみ拒否 (`..backup` 等は許可)
      if (relPath.startsWith('/') || relPath.startsWith(r'\')) {
        return Response.badRequest(body: 'Invalid path.');
      }
      if (p.split(relPath).contains('..')) {
        return Response.badRequest(body: 'Invalid path.');
      }
      // (Copilot #207 review): root ディレクトリ消失を resolveSymbolicLinks より先に検出
      final rootDir = Directory(storagePath);
      if (!await rootDir.exists()) {
        _log('Upload error: storage directory missing -> $storagePath');
        return Response.internalServerError(body: 'Documents directory not found.');
      }
      final canonicalRoot = await rootDir.resolveSymbolicLinks();
      final targetDirPath = p.normalize(p.join(canonicalRoot, relPath));
      final directory = Directory(targetDirPath);
      if (!await directory.exists()) {
        _log('Upload error: target directory missing -> $targetDirPath');
        return Response.notFound('Target directory not found.');
      }
      final canonicalTarget = await directory.resolveSymbolicLinks();
      if (canonicalTarget != canonicalRoot &&
          !p.isWithin(canonicalRoot, canonicalTarget)) {
        return Response.forbidden('Access denied');
      }

      final file = await _getUniqueFilePath(directory, sanitizedFilename);
      final sink = file.openWrite();
      try {
        int totalBytes = 0;
        await for (final chunk in request.read()) {
          totalBytes += chunk.length;
          // #285: content-length を詐称されても書き込み途中で打ち切る
          if (maxBytes != null && totalBytes > maxBytes) {
            await sink.close();
            try {
              await file.delete();
            } catch (_) {}
            return _tooLargeResponse(maxBytes);
          }
          sink.add(chunk);
        }
        await sink.close();
        _log('Upload success: ${p.basename(file.path)} bytes=$totalBytes');
        // #214: x-clipboard-text / x-clipboard-link 指定時はクリップボードにも通知
        _maybePostUploadClipboard(request, p.basename(file.path), relPath);
        return Response.ok('File uploaded successfully: ${p.basename(file.path)}');
      } catch (e, st) {
        await sink.close();
        _log('Upload error: $e\n$st');
        return Response.internalServerError(body: 'Failed to save file: $e');
      }
    }
  }

  // #285: アップロード上限超過の 413 応答。Web UI は status===413 を見て
  // 専用メッセージを表示する（#262）。
  Response _tooLargeResponse(int maxBytes) {
    return Response(413,
        body: json.encode({
          'error': 'too-large',
          'message': 'Upload exceeds server limit of $maxBytes bytes.',
        }),
        headers: {'Content-Type': 'application/json'});
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
        // F1: SAF ツリー外のファイルへのアクセスを拒否
        if (!_isWithinSafTree(decoded)) {
          return Response.forbidden('Access denied');
        }
        final fileUri = decoded;
        final Uint8List? bytes = await _safPlatform.invokeMethod('readFile', {'uri': fileUri});

        if (bytes == null) {
          return Response.internalServerError(body: 'Failed to read file.');
        }

        final filename = Uri.parse(fileUri).pathSegments.last;
        final mimeType = _getMimeType(filename);
        // #200: SAF はメモリ上で範囲スライス（大ファイルは非効率だが互換のため）
        return _maybeRangeResponseFromBytes(request, bytes, mimeType);
      }
      // 他のプラットフォーム、またはSAFが設定されていないAndroidの場合
      else {
        final filePath = decoded;
        // パストラバーサル防止: シンボリックリンク解決後のパスで検証
        final canonicalRoot =
            await Directory(storagePath).resolveSymbolicLinks();
        final canonicalFile =
            await File(filePath).resolveSymbolicLinks().catchError((_) async {
          return Directory(filePath).resolveSymbolicLinks();
        });
        if (canonicalFile != canonicalRoot &&
            !p.isWithin(canonicalRoot, canonicalFile)) {
          return Response.forbidden('Access denied');
        }
        // #191: フォルダは個別ダウンロード対象外（download-all のみ使用）
        if (await FileSystemEntity.isDirectory(filePath)) {
          return Response.notFound('Directory download is not supported.');
        }
        final file = File(filePath);
        if (!await file.exists()) {
          return Response.notFound('File not found: $filePath');
        }
        final mimeType = _getMimeType(p.basename(filePath));
        return _maybeRangeResponseFromFile(request, file, mimeType);
      }
    } catch (e) {
      return Response.internalServerError(body: "Failed to process download request: $e");
    }
  }

  // #200: 単一 Range リクエストの解析。"bytes=start-end" の形式のみ対応。
  // 戻り値: 範囲 (start, end inclusive) または null（Range ヘッダなし）。
  // 無効な Range の場合は throw RangeError。
  ({int start, int end})? _parseRange(String? header, int fileLength) {
    if (header == null || header.isEmpty) return null;
    if (!header.startsWith('bytes=')) throw RangeError('Invalid range unit');
    final spec = header.substring('bytes='.length).trim();
    if (spec.contains(',')) {
      // multipart range は未対応 → 全体を返すよう null を返す
      return null;
    }
    final dash = spec.indexOf('-');
    if (dash < 0) throw RangeError('Invalid range spec');
    final startStr = spec.substring(0, dash);
    final endStr = spec.substring(dash + 1);
    int start, end;
    if (startStr.isEmpty) {
      // "bytes=-N" : 末尾 N バイト
      final suffix = int.tryParse(endStr);
      if (suffix == null || suffix <= 0) throw RangeError('Invalid suffix');
      start = (fileLength - suffix).clamp(0, fileLength);
      end = fileLength - 1;
    } else {
      final s = int.tryParse(startStr);
      if (s == null || s < 0) throw RangeError('Invalid start');
      start = s;
      end = endStr.isEmpty ? fileLength - 1 : (int.tryParse(endStr) ?? -1);
      if (end < 0) throw RangeError('Invalid end');
      if (end >= fileLength) end = fileLength - 1;
    }
    if (start > end || start >= fileLength) throw RangeError('Unsatisfiable');
    return (start: start, end: end);
  }

  Future<Response> _maybeRangeResponseFromFile(
      Request request, File file, String mimeType) async {
    final length = await file.length();
    final rangeHeader = request.headers['range'];
    ({int start, int end})? range;
    try {
      range = _parseRange(rangeHeader, length);
    } on RangeError {
      return Response(416, body: 'Requested Range Not Satisfiable',
          headers: {'Content-Range': 'bytes */$length'});
    }
    if (range == null) {
      return Response.ok(file.openRead(), headers: {
        'Content-Type': mimeType,
        'Accept-Ranges': 'bytes',
        'Content-Length': '$length',
      });
    }
    final contentLength = range.end - range.start + 1;
    return Response(206, body: file.openRead(range.start, range.end + 1),
        headers: {
          'Content-Type': mimeType,
          'Accept-Ranges': 'bytes',
          'Content-Length': '$contentLength',
          'Content-Range': 'bytes ${range.start}-${range.end}/$length',
        });
  }

  Response _maybeRangeResponseFromBytes(
      Request request, Uint8List bytes, String mimeType) {
    final rangeHeader = request.headers['range'];
    ({int start, int end})? range;
    try {
      range = _parseRange(rangeHeader, bytes.length);
    } on RangeError {
      return Response(416, body: 'Requested Range Not Satisfiable',
          headers: {'Content-Range': 'bytes */${bytes.length}'});
    }
    if (range == null) {
      return Response.ok(bytes, headers: {
        'Content-Type': mimeType,
        'Accept-Ranges': 'bytes',
        'Content-Length': '${bytes.length}',
      });
    }
    final slice = bytes.sublist(range.start, range.end + 1);
    return Response(206, body: slice, headers: {
      'Content-Type': mimeType,
      'Accept-Ranges': 'bytes',
      'Content-Length': '${slice.length}',
      'Content-Range': 'bytes ${range.start}-${range.end}/${bytes.length}',
    });
  }

  // Android SAF URI から表示用パスを生成するヘルパー
  String _getAndroidSafDisplayPath(String uri) {
    // content://com.android.externalstorage.documents/tree/primary%3ADownload%2Ffolder
    // → Download/folder
    final decoded = Uri.decodeComponent(uri);
    final treeIndex = decoded.indexOf('/tree/');
    if (treeIndex != -1) {
      var path = decoded.substring(treeIndex + '/tree/'.length);
      // "primary:" プレフィックスを除去
      if (path.startsWith('primary:')) {
        path = path.substring('primary:'.length);
      }
      return path;
    }
    return uri;
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

  static Uint8List _buildPlaceholderJpeg() {
    final placeholder = img.Image(width: 120, height: 120);
    img.fill(placeholder, color: img.ColorRgb8(180, 180, 180));
    return Uint8List.fromList(img.encodeJpg(placeholder, quality: 70));
  }

  Future<Response> _thumbnailHandler(Request request, String id,
      {String? filenameHint}) async {
    final storagePath = _safDirectoryUri ?? _fallbackStoragePath;
    if (storagePath == null || _thumbnailCacheDir == null) {
      return Response.internalServerError(body: 'Server directory not initialized.');
    }

    try {
      final decoded = utf8.decode(base64Url.decode(id));
      // #209: ネストした SAF パス由来の呼び出しでは URI 末尾に `/` が混じり得るので
      //       呼び出し側のヒントを優先する。無ければ従来のロジック。
      // SAF の pathSegments.last は percent-decode 後に '/' を含む場合がある
      // (例: "primary:LocalNode/file.png")。p.basename で末尾ファイル名だけにする。
      final filename = filenameHint ??
          (Platform.isAndroid && _safDirectoryUri != null
              ? p.basename(Uri.parse(decoded).pathSegments.last)
              : p.basename(decoded));

      if (!_isImageFile(filename)) {
        return Response.badRequest(body: 'File is not an image.');
      }

      final cacheFile = File(p.join(_thumbnailCacheDir!.path, '$filename.jpg'));

      if (await cacheFile.exists()) {
        return Response.ok(cacheFile.openRead(), headers: {'Content-Type': 'image/jpeg'});
      }
      
      Uint8List? imageBytes;

      if (Platform.isAndroid && _safDirectoryUri != null) {
        // F1: SAF ツリー外のファイルへのアクセスを拒否
        if (!_isWithinSafTree(decoded)) {
          return Response.forbidden('Access denied');
        }
        imageBytes = await _safPlatform.invokeMethod('readFile', {'uri': decoded});
      } else {
        final file = File(decoded);
        if (!await file.exists()) {
          return Response.notFound('File not found: $filename');
        }
        // path traversal 防止: 共有ルート配下のファイルだけ許可
        final canonicalRoot =
            await Directory(storagePath).resolveSymbolicLinks();
        final canonicalFile = await file.resolveSymbolicLinks();
        if (!p.isWithin(canonicalRoot, canonicalFile)) {
          return Response.forbidden('Access denied');
        }
        imageBytes = await file.readAsBytes();
      }

      if (imageBytes == null) {
        return Response.internalServerError(body: 'Failed to read image bytes.');
      }

      final thumbnailBytes = await Isolate.run(() {
        final image = img.decodeImage(imageBytes!);
        if (image == null) return null;
        final thumb = img.copyResize(image, width: 120);
        return Uint8List.fromList(img.encodeJpg(thumb, quality: 85));
      });

      if (thumbnailBytes == null) {
        return Response.ok(_placeholderThumbBytes,
            headers: {'Content-Type': 'image/jpeg'});
      }

      await cacheFile.writeAsBytes(thumbnailBytes);
      _chmodFile(cacheFile); // #269

      return Response.ok(thumbnailBytes, headers: {'Content-Type': 'image/jpeg'});

    } catch (e) {
      _log('Thumbnail generation error: $e');
      return Response.internalServerError(body: 'Failed to generate thumbnail.');
    }
  }
  
  // #198: @file:<relpath> 用のパスベースサムネイル取得
  Future<Response> _thumbnailByPathHandler(Request request) async {
    final storagePath = _safDirectoryUri ?? _fallbackStoragePath;
    if (storagePath == null) {
      return Response.internalServerError(body: 'Server directory not initialized.');
    }
    final relPath = request.requestedUri.queryParameters['path'] ?? '';
    if (relPath.isEmpty ||
        relPath.contains('..') ||
        relPath.startsWith('/') ||
        relPath.startsWith(r'\') ||
        relPath.contains(':')) {
      return Response.badRequest(body: 'Invalid path.');
    }
    if (Platform.isAndroid && _safDirectoryUri != null) {
      // #209: SAF ツリー配下の相対パスを Kotlin 側で walk して document URI を得る
      try {
        final resolvedUri = await _safPlatform.invokeMethod<String>(
          'resolvePath',
          {'uri': _safDirectoryUri, 'path': relPath},
        );
        if (resolvedUri == null) {
          return Response.notFound('File not found.');
        }
        final id = base64Url.encode(utf8.encode(resolvedUri));
        return _thumbnailHandler(request, id, filenameHint: p.basename(relPath));
      } on PlatformException catch (e) {
        if (e.code == 'NOT_FOUND' || e.code == 'NOT_FILE') {
          return Response.notFound('File not found.');
        }
        if (e.code == 'INVALID_PATH') {
          return Response.badRequest(body: 'Invalid path.');
        }
        return Response.internalServerError(body: 'SAF resolve failed: ${e.message}');
      }
    }
    final canonicalRoot =
        await Directory(storagePath).resolveSymbolicLinks();
    final targetPath = p.normalize(p.join(canonicalRoot, relPath));
    final file = File(targetPath);
    if (!await file.exists()) {
      return Response.notFound('File not found.');
    }
    final canonicalTarget = await file.resolveSymbolicLinks();
    if (!p.isWithin(canonicalRoot, canonicalTarget)) {
      return Response.forbidden('Access denied');
    }
    final id = base64Url.encode(utf8.encode(targetPath));
    return _thumbnailHandler(request, id);
  }

  // #193: テキストファイルのインラインプレビュー（head / tail / full）
  // #216: 拡張子に依らず、先頭 8KB を見て NUL バイト無し + UTF-8 として
  //       decode できるかでテキストらしさを判定。SAF / 実 path 両対応。
  //       (#244 review)
  //       - 末尾でマルチバイト境界をまたいだだけの偽陰性は最大 3 バイト
  //         までトリムして再試行することで吸収する。
  //       - #245: SAF 経路も範囲読み (readFileRange) で先頭 8KB だけ取得する。
  //         以前は readFile が「全ファイル読み」だったため 5MB のサイズ上限で
  //         ガードしていたが、範囲読みなら sniff はファイルサイズに依存しない。
  //         (実プレビュー側の maxFullBytes 上限は従来どおり有効)
  Future<bool> _sniffTextLike(String decoded) async {
    try {
      const sniffBytes = 8 * 1024;
      Uint8List buf;
      if (Platform.isAndroid && _safDirectoryUri != null) {
        final bytes = await _safPlatform.invokeMethod(
            'readFileRange', {'uri': decoded, 'offset': 0, 'length': sniffBytes});
        if (bytes == null) return false;
        buf = bytes as Uint8List;
      } else {
        final file = File(decoded);
        final raf = await file.open();
        try {
          final size = await raf.length();
          final n = size < sniffBytes ? size : sniffBytes;
          if (n == 0) return true;
          buf = await raf.read(n);
        } finally {
          await raf.close();
        }
      }
      if (buf.isEmpty) return true;
      if (buf.contains(0)) return false;
      return _utf8DecodesWithTrim(buf);
    } catch (_) {
      return false;
    }
  }

  bool _utf8DecodesWithTrim(List<int> buf) {
    for (var trim = 0; trim <= 3 && trim < buf.length; trim++) {
      try {
        utf8.decode(buf.sublist(0, buf.length - trim), allowMalformed: false);
        return true;
      } catch (_) {
        // try one more byte off the tail
      }
    }
    return false;
  }

  Future<Response> _textPreviewHandler(Request request, String id) async {
    const maxFullBytes = 5 * 1024 * 1024; // 5MB
    final modeRaw = request.requestedUri.queryParameters['mode'] ?? 'head';
    if (modeRaw != 'head' && modeRaw != 'tail' && modeRaw != 'full') {
      return Response.badRequest(body: 'mode must be head|tail|full');
    }
    final mode = modeRaw;
    final lines = int.tryParse(request.requestedUri.queryParameters['lines'] ?? '') ?? 200;
    if (lines < 1 || lines > 10000) {
      return Response.badRequest(body: 'lines out of range');
    }
    final storagePath = _safDirectoryUri ?? _fallbackStoragePath;
    if (storagePath == null) {
      return Response.internalServerError(body: 'Server directory not initialized.');
    }
    try {
      final decoded = utf8.decode(base64Url.decode(id));

      // パストラバーサル検証 (Copilot #199 review)
      if (Platform.isAndroid && _safDirectoryUri != null) {
        if (!_isWithinSafTree(decoded)) {
          return Response.forbidden('Access denied');
        }
      } else {
        if (await FileSystemEntity.isDirectory(decoded)) {
          return Response.badRequest(body: 'Target is a directory.');
        }
        final canonicalRoot =
            await Directory(storagePath).resolveSymbolicLinks();
        final target = File(decoded);
        if (!await target.exists()) {
          return Response.notFound('File not found.');
        }
        final canonicalFile = await target.resolveSymbolicLinks();
        if (!p.isWithin(canonicalRoot, canonicalFile)) {
          return Response.forbidden('Access denied');
        }
      }

      // #216: 拡張子ホワイトリスト外でも binary でなければ preview させる。
      //       先頭 8KB を sniff。SAF / 実 path のどちらでも動作。
      final sniffOk = await _sniffTextLike(decoded);
      if (!sniffOk) {
        return Response(415,
            body: jsonEncode({
              'error': 'not-text',
              'message': 'File does not look like text (binary content).',
            }),
            headers: {'Content-Type': 'application/json'});
      }

      // head/tail は全読みせず、行数だけ集める（バウンドメモリ）
      if (mode == 'head' || mode == 'tail') {
        return _streamTextLines(decoded, mode, lines);
      }

      // mode == 'full' は 5MB キャップ
      String content;
      int totalLines;
      if (Platform.isAndroid && _safDirectoryUri != null) {
        final bytes = await _safPlatform.invokeMethod('readFile', {'uri': decoded});
        if (bytes == null) return Response.notFound('File not found.');
        if (bytes.length > maxFullBytes) {
          return Response.badRequest(body: 'File too large for full preview (max 5MB).');
        }
        content = utf8.decode(bytes, allowMalformed: true);
      } else {
        final file = File(decoded);
        final size = await file.length();
        if (size > maxFullBytes) {
          return Response.badRequest(body: 'File too large for full preview (max 5MB).');
        }
        content = await file.readAsString(encoding: utf8);
      }
      totalLines = '\n'.allMatches(content).length + 1;
      return Response.ok(
        json.encode({
          'content': content,
          'totalLines': totalLines,
          'truncated': false,
          'mode': mode,
          'lines': lines,
        }),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(body: 'Text preview failed: $e');
    }
  }

  // head/tail のストリーミング読み込み（ファイル全体をメモリに乗せない）
  Future<Response> _streamTextLines(String filePath, String mode, int lines) async {
    // SAF はストリーミング読み込みが面倒なので、SAFの場合は読み切ってから head/tail
    if (Platform.isAndroid && _safDirectoryUri != null) {
      final bytes = await _safPlatform.invokeMethod('readFile', {'uri': filePath});
      if (bytes == null) return Response.notFound('File not found.');
      final content = utf8.decode(bytes, allowMalformed: true);
      final all = content.split('\n');
      final result = mode == 'head'
          ? all.take(lines).join('\n')
          : (all.length > lines
              ? all.sublist(all.length - lines).join('\n')
              : content);
      return Response.ok(
        json.encode({
          'content': result,
          'totalLines': all.length,
          'truncated': all.length > lines,
          'mode': mode,
          'lines': lines,
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }
    final file = File(filePath);
    final stream = file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    if (mode == 'head') {
      final collected = <String>[];
      var totalLines = 0;
      await for (final line in stream) {
        totalLines++;
        if (collected.length < lines) collected.add(line);
      }
      return Response.ok(
        json.encode({
          'content': collected.join('\n'),
          'totalLines': totalLines,
          'truncated': totalLines > lines,
          'mode': mode,
          'lines': lines,
        }),
        headers: {'Content-Type': 'application/json'},
      );
    } else {
      // tail: 末尾 N 行を循環バッファで保持
      final buf = <String>[];
      var totalLines = 0;
      await for (final line in stream) {
        totalLines++;
        buf.add(line);
        if (buf.length > lines) buf.removeAt(0);
      }
      return Response.ok(
        json.encode({
          'content': buf.join('\n'),
          'totalLines': totalLines,
          'truncated': totalLines > lines,
          'mode': mode,
          'lines': lines,
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  bool _isImageFile(String filename) {
    final extension = p.extension(filename).toLowerCase();
    const imageExtensions = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.heic', '.heif'};
    return imageExtensions.contains(extension);
  }

  Future<Response> _deleteFileHandler(Request request, String id) async {
    final guard = _checkDownloadOnlyMode();
    if (guard != null) return guard;

    final storagePath = _safDirectoryUri ?? _fallbackStoragePath;
    if (storagePath == null || _thumbnailCacheDir == null) {
      return Response.internalServerError(body: 'Documents directory not initialized.');
    }

    try {
      final decoded = utf8.decode(base64Url.decode(id));
      bool? deleted = false;

      // AndroidでSAF URIが設定されている場合
      if (Platform.isAndroid && _safDirectoryUri != null) {
        // F1: SAF ツリー外のファイルへのアクセスを拒否
        if (!_isWithinSafTree(decoded)) {
          return Response.forbidden('Access denied');
        }
        final fileUri = decoded;
        deleted = await _safPlatform.invokeMethod('deleteFile', {'uri': fileUri});
      } 
      // 他のプラットフォーム、またはSAFが設定されていないAndroidの場合
      else {
        final filePath = decoded;
        final file = File(filePath);
        if (await file.exists()) {
          // path traversal 防止: 共有ルート配下のファイルだけ削除を許可。
          // (id はクライアント制御なので、download ハンドラと同じ検証を行う)
          final canonicalRoot =
              await Directory(storagePath).resolveSymbolicLinks();
          final canonicalFile = await file.resolveSymbolicLinks();
          if (!p.isWithin(canonicalRoot, canonicalFile)) {
            return Response.forbidden('Access denied');
          }
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

  // #190: 表示されているファイル ID のリストを受け取って削除
  Future<Response> _deleteBatchHandler(Request request) async {
    final guard = _checkDownloadOnlyMode();
    if (guard != null) return guard;

    final storagePath = _safDirectoryUri ?? _fallbackStoragePath;
    if (storagePath == null || _thumbnailCacheDir == null) {
      return Response.internalServerError(body: 'Documents directory not initialized.');
    }

    final List<dynamic> ids;
    try {
      final body = json.decode(await request.readAsString()) as Map<String, dynamic>;
      ids = body['ids'] as List<dynamic>? ?? const [];
    } catch (_) {
      return Response.badRequest(body: 'Invalid request body.');
    }

    int deleted = 0;
    int failed = 0;
    final List<String> skipped = [];

    // Android SAF
    if (Platform.isAndroid && _safDirectoryUri != null) {
      for (final raw in ids) {
        try {
          final fileUri = utf8.decode(base64Url.decode(raw as String));
          if (!_isWithinSafTree(fileUri)) {
            skipped.add(raw);
            continue;
          }
          final filename = Uri.parse(fileUri).pathSegments.last;
          final success = await _safPlatform.invokeMethod('deleteFile', {'uri': fileUri});
          if (success == true) {
            deleted++;
            final cacheFile = File(p.join(_thumbnailCacheDir!.path, '$filename.jpg'));
            if (await cacheFile.exists()) await cacheFile.delete();
          } else {
            failed++;
          }
        } catch (_) {
          failed++;
        }
      }
    } else {
      final canonicalRoot = await Directory(storagePath).resolveSymbolicLinks();
      for (final raw in ids) {
        try {
          final filePath = utf8.decode(base64Url.decode(raw as String));
          final file = File(filePath);
          if (!await file.exists()) {
            failed++;
            continue;
          }
          final canonicalFile = await file.resolveSymbolicLinks();
          if (!p.isWithin(canonicalRoot, canonicalFile)) {
            skipped.add(raw as String);
            continue;
          }
          final filename = p.basename(filePath);
          await file.delete();
          deleted++;
          final cacheFile = File(p.join(_thumbnailCacheDir!.path, '$filename.jpg'));
          if (await cacheFile.exists()) await cacheFile.delete();
        } catch (_) {
          failed++;
        }
      }
    }

    return Response.ok(
      json.encode({'deleted': deleted, 'failed': failed, 'skipped': skipped}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<Response> _downloadAllHandler(Request request) async {
    final storagePath = _safDirectoryUri ?? _fallbackStoragePath;
    if (storagePath == null) {
      return Response.internalServerError(body: 'Documents directory not initialized.');
    }

    // #195: ZIP を一時ファイルへストリーミングして書き出し、レスポンスとして
    // 流す。これによりサーバ側でも巨大ファイル × 多数を扱える。
    // #287: CLI の --cache-dir 指定時はその配下に置く（GUI では null → systemTemp）。
    final tempDir = await _cliCacheBaseDir().createTemp('localnode_zip_');
    final zipPath = p.join(tempDir.path, 'archive.zip');
    // ステージング用サブディレクトリ (Copilot #199 review):
    // ユーザのファイル名と zip 出力名/パス・パス区切り文字の衝突を避ける
    final stagingDir =
        await Directory(p.join(tempDir.path, 'staging')).create();

    try {
      final zipEncoder = ZipFileEncoder()..create(zipPath);

      // AndroidでSAF URIが設定されている場合
      if (Platform.isAndroid && _safDirectoryUri != null) {
        try {
          final List<dynamic>? files = await _safPlatform
              .invokeMethod('listFiles', {'uri': _safDirectoryUri});
          if (files == null) {
            await zipEncoder.close();
            await tempDir.delete(recursive: true);
            return Response.internalServerError(
                body: 'Failed to list files for zipping.');
          }
          int stagingSeq = 0;
          for (final fileInfo in files) {
            final String fileUri = fileInfo['uri'];
            final String filename = fileInfo['name'];
            final Uint8List? bytes = await _safPlatform
                .invokeMethod('readFile', {'uri': fileUri});
            if (bytes != null) {
              // SAF はバイト列でしか取れないため、ステージングディレクトリへ
              // ユニーク名 (連番) で書いて ZipFileEncoder に渡す。
              // ZIP 内の entry 名はオリジナル filename を使用する。
              final tmpFile = File(p.join(stagingDir.path, '$stagingSeq.bin'));
              stagingSeq++;
              await tmpFile.writeAsBytes(bytes, flush: true);
              await zipEncoder.addFile(tmpFile, filename);
              await tmpFile.delete();
            }
          }
        } on PlatformException catch (e) {
          await zipEncoder.close();
          await tempDir.delete(recursive: true);
          return Response.internalServerError(
              body: 'Failed to read files for zipping: ${e.message}');
        }
      } else {
        // ?path= で現在フォルダを指定し、そのフォルダのファイルのみをZIP (#179)
        final relPath = request.requestedUri.queryParameters['path'] ?? '';
        final canonicalRoot =
            await Directory(storagePath).resolveSymbolicLinks();
        final targetPath = p.normalize(p.join(canonicalRoot, relPath));
        final directory = Directory(targetPath);
        if (!await directory.exists()) {
          await zipEncoder.close();
          await tempDir.delete(recursive: true);
          return Response.internalServerError(
              body: 'Documents directory not found.');
        }
        final canonicalTarget = await directory.resolveSymbolicLinks();
        if (canonicalTarget != canonicalRoot &&
            !p.isWithin(canonicalRoot, canonicalTarget)) {
          await zipEncoder.close();
          await tempDir.delete(recursive: true);
          return Response.forbidden('Access denied');
        }
        // 現在フォルダの直下ファイルのみ（再帰なし）
        final files = directory.listSync(followLinks: false).whereType<File>();
        for (final file in files) {
          await zipEncoder.addFile(file, p.basename(file.path));
        }
      }

      await zipEncoder.close();

      final zipFile = File(zipPath);
      final length = await zipFile.length();

      // ストリーム完了後（成功・中断問わず）に一時ディレクトリを削除
      Stream<List<int>> streamAndCleanup() async* {
        try {
          yield* zipFile.openRead();
        } finally {
          try {
            await tempDir.delete(recursive: true);
          } catch (_) {}
        }
      }

      return Response.ok(streamAndCleanup(), headers: {
        'Content-Type': 'application/zip',
        'Content-Length': '$length',
        'Content-Disposition': 'attachment; filename="localnode_files.zip"',
      });
    } catch (e) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
      return Response.internalServerError(body: 'Failed to create zip: $e');
    }
  }

  // === Clipboard Handlers ===

  /// GET /api/clipboard - クリップボード履歴取得 (#228 差分対応)
  Response _getClipboardHandler(Request request) {
    final q = request.requestedUri.queryParameters;
    final hasQuery = q.containsKey('since') ||
        q.containsKey('before') ||
        q.containsKey('limit');

    if (!hasQuery) {
      // 後方互換: 全件返す
      return Response.ok(
        json.encode({
          'items': _clipboardItems.map((item) => item.toJson()).toList(),
          'lastModified': _clipboardLastModified,
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final since = int.tryParse(q['since'] ?? '');
    final before = int.tryParse(q['before'] ?? '');
    final limit = int.tryParse(q['limit'] ?? '');
    if (limit != null && (limit < 1 || limit > 2000)) {
      return Response.badRequest(body: 'limit must be 1..2000');
    }

    bool refresh = false;
    List<String> deletedSince = const [];
    if (since != null) {
      if (_clipboardDeletes.length >= _maxDeletionLog &&
          _clipboardDeletes.first.deletedAtMs > since) {
        refresh = true;
      }
      deletedSince = _clipboardDeletes
          .where((d) => d.deletedAtMs > since)
          .map((d) => d.id)
          .toList();
    }

    Iterable<ClipboardItem> filtered = _clipboardItems;
    if (since != null) {
      filtered = filtered
          .where((i) => i.createdAt.millisecondsSinceEpoch > since);
    }
    if (before != null) {
      filtered = filtered
          .where((i) => i.createdAt.millisecondsSinceEpoch < before);
    }
    final list = filtered.toList();
    final cap = limit ?? list.length;
    final returned = list.length > cap ? list.sublist(0, cap) : list;
    final hasMore = list.length > cap;

    return Response.ok(
      json.encode({
        'items': returned.map((i) => i.toJson()).toList(),
        'deleted': deletedSince,
        'lastModified': _clipboardLastModified,
        'hasMore': hasMore,
        'refresh': refresh,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  /// POST /api/clipboard - テキスト追加
  Future<Response> _postClipboardHandler(Request request) async {
    try {
      final body = await request.readAsString();
      final params = json.decode(body) as Map<String, dynamic>;
      var text = (params['text'] as String?)?.trim();
      final rawTag = (params['tag'] as String?)?.trim();
      final tag = (rawTag != null && rawTag.isNotEmpty) ? rawTag : null;

      if (text == null || text.isEmpty) {
        return Response.badRequest(
          body: json.encode({'error': 'Text is required and cannot be empty.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      if (text.length > _maxTextLength) {
        return Response.badRequest(
          body: json.encode({'error': 'Text exceeds maximum length of $_maxTextLength characters.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      // #220: `@up ` プレフィックスで important マーク + プレフィックス剥がし
      bool important = false;
      if (text == '@up' || text.startsWith('@up ')) {
        if (text.length > 4) {
          important = true;
          text = text.substring(4).trimLeft();
        }
      }

      final item = ClipboardItem(
        id: _generateClipboardId(),
        text: text,
        tag: tag,
        createdAt: DateTime.now(),
        important: important,
      );

      _clipboardItems.insert(0, item);

      // 最大件数を超えたら古いものを削除 (#228 でリングバッファに記録)
      while (_clipboardItems.length > _maxClipboardItems) {
        final evicted = _evictClipboardItem();
        _recordDeletion(evicted.id);
      }

      _clipboardLastModified = DateTime.now().millisecondsSinceEpoch;

      return Response.ok(
        json.encode(item.toJson()),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.badRequest(
        body: json.encode({'error': 'Invalid request body.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  // クリップボードに1件追加して lastModified を更新する共通処理。
  void _appendClipboard(String text, {String? tag, bool important = false}) {
    final item = ClipboardItem(
      id: _generateClipboardId(),
      text: text,
      tag: tag,
      createdAt: DateTime.now(),
      important: important,
    );
    _clipboardItems.insert(0, item);
    while (_clipboardItems.length > _maxClipboardItems) {
      final evicted = _evictClipboardItem();
      _recordDeletion(evicted.id);
    }
    _clipboardLastModified = DateTime.now().millisecondsSinceEpoch;
  }

  // #214: アップロードと同時にクリップボード通知を1件投稿する。
  // x-clipboard-text（本文）/ x-clipboard-tag（タグ）は x-filename と同様に
  // percent-encoded で受け取り decode する。x-clipboard-link: 1 のときは本文が
  // 無くても保存済みファイルへの @file:<relpath> マーカーを自動生成する。
  void _maybePostUploadClipboard(
      Request request, String savedName, String relPath) {
    if (!_clipboardEnabled) return;
    final text = _decodeHeader(request.headers['x-clipboard-text'])?.trim();
    final rawTag = _decodeHeader(request.headers['x-clipboard-tag'])?.trim();
    final link = request.headers['x-clipboard-link']?.trim();
    final tag = (rawTag != null && rawTag.isNotEmpty) ? rawTag : null;

    String? msg;
    if (text != null && text.isNotEmpty) {
      msg = text;
    } else if (link == '1') {
      final rel = relPath.isEmpty ? savedName : '$relPath/$savedName';
      // #214: マーカーは空白で切れる (`@file:(\S+)`) ので percent-encode する。
      // 重複時のリネームが "name (1).ext" とスペースを含むため必須。
      // '/' は区切りとして残すためセグメント単位でエンコードする。
      final encoded = rel.split('/').map(Uri.encodeComponent).join('/');
      msg = '@file:$encoded';
    }
    if (msg == null || msg.isEmpty) return;
    if (msg.length > _maxTextLength) msg = msg.substring(0, _maxTextLength);
    _appendClipboard(msg, tag: tag);
  }

  // #214: HTTP ヘッダは仕様上 latin1 なので、値の受け取り方が2通りある。
  //   (a) percent-encoded (推奨・x-filename と同じ) -> decodeComponent で復元
  //   (b) 生の UTF-8 バイト列 -> latin1 として読まれ文字化けするので、
  //       latin1 に戻してから UTF-8 として解釈し直す
  // どちらでも正しく読めるように両方試す。
  // #291(L2): SAF ツリー URI の配下かを境界付きで判定する。
  // 単純な startsWith だと tree=".../Shared" のとき ".../SharedEvil" も通って
  // しまうため、完全一致か直後が '/' で続く場合のみ許可する。
  // （SAF の document URI は <treeUri>/document/... の形なので子は必ず '/' が続く。
  //   実際のアクセスは Android のパーミッションでも守られるが、多層防御として。）
  bool _isWithinSafTree(String uri) {
    final tree = _safDirectoryUri;
    if (tree == null) return false;
    return uri == tree || uri.startsWith('$tree/');
  }

  String? _decodeHeader(String? raw) {
    if (raw == null) return null;
    var s = raw;
    try {
      s = Uri.decodeComponent(s);
    } catch (_) {
      // percent-encode されていない値はそのまま
    }
    try {
      // s が既に正しい多バイト文字なら latin1.encode が投げるので何もしない。
      // latin1 で潰れた UTF-8 のときだけ復元される。
      s = utf8.decode(latin1.encode(s));
    } catch (_) {
      // UTF-8 として不正 or もともと正しい文字列 -> そのまま
    }
    return s;
  }

  /// DELETE /api/clipboard/<id> - 個別アイテム削除
  Response _deleteClipboardItemHandler(Request request, String id) {
    final index = _clipboardItems.indexWhere((item) => item.id == id);
    if (index == -1) {
      return Response.notFound(
        json.encode({'error': 'Clipboard item not found.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final removed = _clipboardItems.removeAt(index);
    _recordDeletion(removed.id);
    _clipboardLastModified = DateTime.now().millisecondsSinceEpoch;

    return Response.ok(
      json.encode({'status': 'deleted'}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  /// DELETE /api/clipboard - 全アイテム削除
  Response _clearClipboardHandler(Request request) {
    final count = _clipboardItems.length;
    for (final it in _clipboardItems) {
      _recordDeletion(it.id);
    }
    _clipboardItems.clear();
    _clipboardLastModified = DateTime.now().millisecondsSinceEpoch;

    return Response.ok(
      json.encode({'status': 'cleared', 'count': count}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  /// クリップボードID生成
  String _generateClipboardId() {
    final random = Random.secure();
    final values = List<int>.generate(8, (i) => random.nextInt(256));
    return base64Url.encode(values);
  }

  /// クリップボードにテキストを追加（Flutter UIから直接呼び出し用）
  ClipboardItem addClipboardText(String text) {
    final trimmedText = text.trim();
    if (trimmedText.isEmpty) {
      throw ArgumentError('Text cannot be empty.');
    }
    if (trimmedText.length > _maxTextLength) {
      throw ArgumentError('Text exceeds maximum length of $_maxTextLength characters.');
    }

    final item = ClipboardItem(
      id: _generateClipboardId(),
      text: trimmedText,
      createdAt: DateTime.now(),
    );

    _clipboardItems.insert(0, item);

    while (_clipboardItems.length > _maxClipboardItems) {
      final evicted = _evictClipboardItem();
      _recordDeletion(evicted.id);
    }

    _clipboardLastModified = DateTime.now().millisecondsSinceEpoch;
    return item;
  }

  /// クリップボードアイテムを削除（Flutter UIから直接呼び出し用）
  bool deleteClipboardItem(String id) {
    final index = _clipboardItems.indexWhere((item) => item.id == id);
    if (index == -1) return false;

    final removed = _clipboardItems.removeAt(index);
    _recordDeletion(removed.id);
    _clipboardLastModified = DateTime.now().millisecondsSinceEpoch;
    return true;
  }

  /// クリップボードをクリア（Flutter UIから直接呼び出し用）
  int clearClipboard() {
    final count = _clipboardItems.length;
    for (final it in _clipboardItems) {
      _recordDeletion(it.id);
    }
    _clipboardItems.clear();
    _clipboardLastModified = DateTime.now().millisecondsSinceEpoch;
    return count;
  }

  // === Middleware ===

  // #221: federation ループ防止
  static const String _kFedOrigin = 'x-fed-origin';
  static const String _kFedSeenBy = 'x-fed-seen-by';

  Middleware get _federationLoopGuard => (innerHandler) {
        return (request) {
          final seenByRaw = request.headers[_kFedSeenBy];
          if (seenByRaw != null && _deviceId.isNotEmpty) {
            final ids = seenByRaw
                .split(',')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toSet();
            if (ids.contains(_deviceId)) {
              final origin = request.headers[_kFedOrigin] ?? '?';
              _log('[fed] loop-drop origin=$origin seen_by_count=${ids.length}');
              return Response.ok(
                json.encode({'dropped': 'loop', 'device_id': _deviceId}),
                headers: {'Content-Type': 'application/json'},
              );
            }
          }
          return innerHandler(request);
        };
      };

  /// #219 から使うヘルパ: federation event 転送時の seen_by 構築
  // ignore: unused_element
  List<String> _appendSelfToSeenBy(String? incomingHeader) {
    final ids = (incomingHeader ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (_deviceId.isNotEmpty && !ids.contains(_deviceId)) ids.add(_deviceId);
    return ids;
  }

  Middleware get _authMiddleware => (innerHandler) {
    return (request) {
      final path = request.url.path;

      // /api/で始まらないパス、または認証が不要なAPIパスはそのまま通す
      if (!path.startsWith('api/') || path == 'api/info' || path == 'api/auth' || path == 'api/health') {
        return innerHandler(request);
      }

      // PINなしモードでは認証をスキップ
      if (_authMode == AuthMode.noPin) {
        return innerHandler(request);
      }

      final cookieHeader = request.headers['cookie'];
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

      // #282: verbose ログでもトークン全体は出さない（漏洩でセッション乗っ取り可能なため）
      _log('Auth middleware: session token ${token == null ? 'absent' : 'present'}');

      // #261: トークンを TTL 込みで検証
      if (token != null && _isValidSession(token)) {
        return innerHandler(request); // 認証成功
      }

      // 認証失敗
      return Response.unauthorized(json.encode({'error': 'Authentication required.'}),
          headers: {'Content-Type': 'application/json'});
    };
  };


  // === Server Control ===

  /// CLI用の初期化（Flutterプラグインを使用しない）
  Future<void> _initCli(String? storagePath) async {
    if (storagePath != null) {
      _fallbackStoragePath = storagePath;
      _displayPath = storagePath;
    } else {
      // デフォルトはカレントディレクトリ
      _fallbackStoragePath = Directory.current.path;
      _displayPath = Directory.current.path;
    }

    // ストレージディレクトリの存在確認
    final storageDir = Directory(_fallbackStoragePath!);
    if (!await storageDir.exists()) {
      await storageDir.create(recursive: true);
    }

    // サムネイルキャッシュディレクトリの初期化
    // #264/#269/#271: 共有 /tmp では固定名だと symlink poisoning / 情報漏洩の恐れ。
    // PID + OS ランダムサフィックスで分離し 700 に制限、死んだ PID の残骸は掃除する。
    // #287: --cache-dir 指定時はその配下に置く。
    final cacheBase = _cliCacheBaseDir();
    const thumbPrefix = 'localnode_thumbnails_';
    _reapStaleWebDirs(cacheBase, thumbPrefix);
    _thumbnailCacheDir =
        await cacheBase.createTemp('$thumbPrefix${pid}_');
    _chmodDir(_thumbnailCacheDir!);
  }

  /// CLI用のアセット展開（Flutterプラグインを使用しない）
  Future<void> _deployAssetsCli() async {
    final tempPath = _cliCacheBaseDir().path; // #287
    // #242: 同ホストで他 LocalNode と共存しても上書きしないよう PID 別
    const prefix = 'localnode_web_';
    _reapStaleWebDirs(Directory(tempPath), prefix);
    _webRootDir = Directory(p.join(tempPath, '$prefix$pid'));

    // 既存のディレクトリがあればクリーンアップ
    if (await _webRootDir!.exists()) {
      await _webRootDir!.delete(recursive: true);
    }
    await _webRootDir!.create(recursive: true);
    _chmodDir(_webRootDir!); // #269

    // CLIモードでは実行ファイルのバンドル/ディレクトリからassetsを探索
    final executablePath = Platform.resolvedExecutable;
    final executableDir = p.dirname(executablePath);

    // アセットの探索パス（プラットフォーム別）
    final possiblePaths = [
      // Linux: <dir>/data/flutter_assets/assets/web/index.html
      p.join(executableDir, 'data', 'flutter_assets', 'assets', 'web', 'index.html'),
      // macOS .app: Contents/MacOS/../Frameworks/App.framework/Versions/A/Resources/flutter_assets/...
      p.join(executableDir, '..', 'Frameworks', 'App.framework', 'Versions', 'A', 'Resources', 'flutter_assets', 'assets', 'web', 'index.html'),
      // macOS .app (alternative)
      p.join(executableDir, '..', 'Frameworks', 'App.framework', 'Resources', 'flutter_assets', 'assets', 'web', 'index.html'),
      // Windows/generic: <dir>/assets/web/index.html
      p.join(executableDir, 'assets', 'web', 'index.html'),
      // Development fallback
      p.join(Directory.current.path, 'assets', 'web', 'index.html'),
    ];

    File? sourceFile;
    for (final path in possiblePaths) {
      final file = File(path);
      if (await file.exists()) {
        sourceFile = file;
        break;
      }
    }

    if (sourceFile != null) {
      final destinationFile = File(p.join(_webRootDir!.path, 'index.html'));
      await sourceFile.copy(destinationFile.path);
    } else {
      // アセットが見つからない場合は最小限のHTMLを生成
      final destinationFile = File(p.join(_webRootDir!.path, 'index.html'));
      await destinationFile.writeAsString(_getMinimalHtml());
      print('Warning: Web assets not found. Using minimal HTML.');
    }
    await _deployThemeFiles(); // #304
  }

  String _getMinimalHtml() {
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>LocalNode</title>
  <style>
    body { font-family: sans-serif; padding: 20px; text-align: center; }
    h1 { color: #333; }
  </style>
</head>
<body>
  <h1>LocalNode Server</h1>
  <p>Server is running. Web UI assets not found.</p>
  <p>API is available at /api/*</p>
</body>
</html>
''';
  }

  /// CLIモード用のサーバー起動
  Future<void> startServerCli({
    required String ipAddress,
    required int port,
    String? fixedPin,
    String? storagePath,
    String? cacheDir, // #287
    OperationMode operationMode = OperationMode.normal,
    AuthMode authMode = AuthMode.randomPin,
    bool verboseLogging = false,
    bool clipboardEnabled = true,
    String serverName = 'LocalNode',
    String? httpsCertPath,
    String? httpsKeyPath,
    String? themeCssPath, // #304
  }) async {
    if (_server != null) return;

    await _validateHttpsPaths(httpsCertPath, httpsKeyPath);

    _themeCssPath = themeCssPath; // #304
    _verboseLogging = verboseLogging;
    _clipboardEnabled = clipboardEnabled;
    _serverName = serverName.isNotEmpty ? serverName : 'LocalNode';
    _operationMode = operationMode;
    _authMode = authMode;
    _cacheDir = cacheDir; // #287
    await _validateCacheDir(); // #287

    // 認証モードに応じたPIN設定
    switch (authMode) {
      case AuthMode.randomPin:
        _pin = _generatePin();
      case AuthMode.fixedPin:
        _pin = fixedPin ?? _generatePin();
      case AuthMode.noPin:
        _pin = null;
    }
    _sessions.clear();
    _failedAttempts.clear();
    _lockoutUntil.clear();
    _startedAt = DateTime.now().millisecondsSinceEpoch;

    try {
      await _initCli(storagePath);
      await _deployAssetsCli();

      _ipAddress = ipAddress;
      _port = port;
      _httpsCertPath = httpsCertPath;
      _httpsKeyPath = httpsKeyPath;
      _httpsHostname = null; // CLI経由ではホスト名指定なし
      _httpsEnabled = isHttpsMode; // #6
      // 注: cli_runner は現状 HTTPS 未対応 (httpsCert/Key は常に null, #98)。
      //     将来 #98 で HTTPS + 証明書ホスト名を配線する際は、cert の SAN を
      //     _allowedHosts に加えないと Host ガードで 421 になる点に注意。
      await _buildAllowedHosts(ipAddress); // #258

      final staticHandler =
          createStaticHandler(_webRootDir!.path, defaultDocument: 'index.html');

      final apiHandler = const Pipeline()
          .addMiddleware(_hostGuardMiddleware) // #258
          .addMiddleware(_federationLoopGuard)
          .addMiddleware(_authMiddleware)
          .addHandler(_router.call);

      final cascade = Cascade().add(apiHandler).add(staticHandler);

      // verbose時のみリクエストログ出力、通常は無し
      final pipeline = const Pipeline();
      final handler = verboseLogging
          ? pipeline.addMiddleware(logRequests()).addHandler(cascade.handler)
          : pipeline.addHandler(cascade.handler);

      if (isHttpsMode) {
        final secCtx = SecurityContext()
          ..useCertificateChain(httpsCertPath!)
          ..usePrivateKey(httpsKeyPath!);
        _server = await _serveDualStack(handler, port, securityContext: secCtx);
      } else {
        _server = await _serveDualStack(handler, port);
      }
    } catch (e) {
      print('Error starting server: $e');
      await stopServer();
      rethrow;
    }
  }

  Future<void> startServer({
    required String ipAddress,
    required int port,
    OperationMode operationMode = OperationMode.normal,
    AuthMode authMode = AuthMode.randomPin,
    String? fixedPin,
    String serverName = 'LocalNode',
    String? httpsCertPath,
    String? httpsKeyPath,
    String? httpsHostname,
    int? maxUploadBytes,
    String? themeCssPath, // #304
  }) async {
    if (_server != null) return;

    await _validateHttpsPaths(httpsCertPath, httpsKeyPath);

    _themeCssPath = themeCssPath; // #304
    _operationMode = operationMode;
    _authMode = authMode;
    _maxUploadBytes = maxUploadBytes; // #285
    _serverName = serverName.isNotEmpty ? serverName : 'LocalNode';

    // 認証モードに応じたPIN設定
    switch (authMode) {
      case AuthMode.randomPin:
        _pin = _generatePin();
      case AuthMode.fixedPin:
        _pin = fixedPin ?? _generatePin();
      case AuthMode.noPin:
        _pin = null;
    }
    _sessions.clear();
    _failedAttempts.clear();
    _lockoutUntil.clear();
    _startedAt = DateTime.now().millisecondsSinceEpoch;
    _log('Server starting (auth: ${_authMode.name}).');

    try {
      await _init();
      await _deployAssets();
      try {
        await WakelockPlus.enable();
      } catch (_) {
        // WSL 等の Linux 環境では DBus ScreenSaver サービスが存在しないため無視
      }

      _ipAddress = ipAddress;
      _port = port;
      _httpsCertPath = httpsCertPath;
      _httpsKeyPath = httpsKeyPath;
      _httpsHostname = httpsHostname;
      _httpsEnabled = isHttpsMode; // #6
      await _buildAllowedHosts(ipAddress); // #258

      final staticHandler =
          createStaticHandler(_webRootDir!.path, defaultDocument: 'index.html');

      final apiHandler = const Pipeline()
          .addMiddleware(_hostGuardMiddleware) // #258
          .addMiddleware(_federationLoopGuard)
          .addMiddleware(_authMiddleware)
          .addHandler(_router.call);

      final cascade = Cascade().add(apiHandler).add(staticHandler);

      final handler =
          const Pipeline().addMiddleware(logRequests()).addHandler(cascade.handler);

      if (isHttpsMode) {
        final secCtx = SecurityContext()
          ..useCertificateChain(httpsCertPath!)
          ..usePrivateKey(httpsKeyPath!);
        _server = await _serveDualStack(handler, port, securityContext: secCtx);
        _log('Serving at https://$_ipAddress:${_server!.port}');
      } else {
        _server = await _serveDualStack(handler, port);
        _log('Serving at http://$_ipAddress:${_server!.port}');
      }
    } catch (e) {
      _log('Error starting server: $e');
      await stopServer();
      rethrow;
    }
  }

  Future<void> stopServer() async {
    await _server?.close(force: true);
    _server = null;
    _httpsCertPath = null;
    _httpsKeyPath = null;
    _httpsHostname = null;
    _httpsEnabled = false;
    _allowedHosts = {};
    _maxUploadBytes = null;
    _cacheDir = null; // #287
    _ipAddress = null;
    _port = null;
    _pin = null;
    _sessions.clear();
    _failedAttempts.clear();
    _lockoutUntil.clear();
    _clipboardItems.clear();
    _clipboardLastModified = 0;
    // #242: 自分用 deploy dir を後片付け。残っても次回起動の reap で拾える。
    try {
      final d = _webRootDir;
      if (d != null && await d.exists()) {
        await d.delete(recursive: true);
      }
    } catch (_) {}
    // WakelockPlusはCLIモードでは使用されないため、try-catchで囲む
    try {
      await WakelockPlus.disable();
    } catch (_) {
      // CLIモードまたはWSL等DBus未対応環境では無視
    }
    _log('Server stopped.');
  }

  // #242: 同プレフィックスのきょうだいディレクトリのうち PID が
  //       生きていないものを削除。長寿の常駐サーバを巻き込まないよう
  //       PID 生存チェックのみで mtime は見ない。
  void _reapStaleWebDirs(Directory base, String prefix) {
    if (!base.existsSync()) return;
    final myPid = pid;
    for (final entry in base.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (!name.startsWith(prefix)) continue;
      // <prefix><pid> と <prefix><pid>_<random> (createTemp) の両形式に対応
      final pidStr = name.substring(prefix.length).split('_').first;
      final otherPid = int.tryParse(pidStr);
      if (otherPid == null || otherPid == myPid) continue;
      if (_isProcessAlive(otherPid)) continue;
      try {
        entry.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  bool _isProcessAlive(int otherPid) {
    if (otherPid <= 0) return false;
    if (Platform.isWindows) {
      try {
        final r = Process.runSync(
            'tasklist', ['/NH', '/FI', 'PID eq $otherPid'],
            runInShell: false);
        final out = r.stdout as String;
        return !out.contains('No tasks') && out.contains('$otherPid');
      } catch (_) {
        return true;
      }
    }
    if (Platform.isAndroid || Platform.isIOS) {
      // モバイル: ps が制限されることがある + 他プロセスとの共存は通常起きない。
      // 安全側で「生存」扱いにして消さない (アプリ再起動時の旧 PID dir は次回 reap か
      // OS の temp 掃除に任せる)。
      return true;
    }
    try {
      final r = Process.runSync('ps', ['-p', '$otherPid'], runInShell: false);
      return r.exitCode == 0;
    } catch (_) {
      return true;
    }
  }

  // #287: CLI の --cache-dir が指定されていればそこを、なければ OS の一時
  // ディレクトリを基点にする。GUI 経路 (startServer) は _cacheDir を設定しない
  // ので従来どおり systemTemp / getTemporaryDirectory のまま。
  Directory _cliCacheBaseDir() =>
      (_cacheDir != null && _cacheDir!.isNotEmpty)
          ? Directory(_cacheDir!)
          : Directory.systemTemp;

  // #287: --cache-dir を検証。作成できなければ警告して OS 一時ディレクトリに
  // フォールバックする（サーバは起動し続ける）。macOS はサンドボックスにより
  // コンテナ外パスが拒否され得るが、その場合もここでフォールバックする。
  Future<void> _validateCacheDir() async {
    if (_cacheDir == null || _cacheDir!.isEmpty) return;
    final dir = Directory(_cacheDir!);
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      final probe = await dir.createTemp('localnode_cli_probe_');
      await probe.delete();
    } catch (e) {
      _log('Warning: --cache-dir "$_cacheDir" is not usable ($e); '
          'falling back to the system temp directory.');
      // フォールバックは verbose 以外でも見えるよう stderr にも出す
      stderr.writeln('Warning: --cache-dir "$_cacheDir" is not usable ($e); '
          'falling back to the system temp directory.');
      _cacheDir = null;
    }
  }

  // #269: Unix のみ、ディレクトリ/ファイルのパーミッションを制限。
  // モバイル (Android/iOS) は temp が app サンドボックス内なので不要 & chmod 不可。
  void _chmodDir(Directory dir) {
    if (Platform.isWindows || Platform.isAndroid || Platform.isIOS) return;
    try {
      Process.runSync('chmod', ['700', dir.path], runInShell: false);
    } catch (_) {}
  }

  void _chmodFile(File file) {
    if (Platform.isWindows || Platform.isAndroid || Platform.isIOS) return;
    try {
      Process.runSync('chmod', ['600', file.path], runInShell: false);
    } catch (_) {}
  }

  // #261: セッションの有効性を TTL 込みで判定。失効していたら破棄して false。
  bool _isValidSession(String token) {
    final expiry = _sessions[token];
    if (expiry == null) return false;
    if (DateTime.now().millisecondsSinceEpoch > expiry) {
      _sessions.remove(token);
      return false;
    }
    return true;
  }

  void _pruneExpiredSessions() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _sessions.removeWhere((_, expiry) => expiry < now);
  }

  // #261: 新しいセッションを発行して失効時刻付きで登録。
  // no-pin モードは上限を設けて最古から追い出し、メモリ枯渇を防ぐ。
  String _issueSession() {
    final token = _generateSessionToken();
    if (_authMode == AuthMode.noPin) {
      _pruneExpiredSessions();
      if (_sessions.length >= _maxNoPinSessions) {
        final oldest =
            _sessions.entries.reduce((a, b) => a.value < b.value ? a : b);
        _sessions.remove(oldest.key);
      }
    }
    _sessions[token] =
        DateTime.now().add(_sessionTtl).millisecondsSinceEpoch;
    return token;
  }

  // #6: 認証モードと TLS 状態に応じた Set-Cookie 値を組み立てる。
  String _buildSessionCookie(String token) {
    return 'localnode_session=$token; Path=/; HttpOnly; SameSite=Strict'
        '${_httpsEnabled ? '; Secure' : ''}';
  }

  // #260: タイミング攻撃を防ぐ定数時間文字列比較。
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }

  // #263: アップロードファイル名のサニタイズ。空になった場合は null を返す。
  String? _sanitizeFilename(String name) {
    var s = name.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
    s = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    s = s.replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
    if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..+)?$',
            caseSensitive: false)
        .hasMatch(s)) {
      s = '_$s';
    }
    return s.isEmpty ? null : s;
  }

  // #265: 有効なセッション Cookie を持つリクエストか判定。
  // GUI サーバは CLI と違い Bearer/upload-token 認証を持たないため Cookie のみ見る。
  bool _isAuthenticatedRequest(Request request) {
    if (_authMode == AuthMode.noPin) return true;
    final cookie = request.headers['cookie'] ?? '';
    for (final c in cookie.split(';')) {
      final t = c.trim();
      if (t.startsWith('localnode_session=')) {
        final token = t.substring(t.indexOf('=') + 1);
        if (_isValidSession(token)) return true;
      }
    }
    return false;
  }

  // #258: DNS rebinding 対策 — Host ヘッダが既知の IP/localhost と一致しなければ拒否。
  Middleware get _hostGuardMiddleware => (inner) {
        return (req) {
          if (_allowedHosts.isEmpty) return inner(req);
          final host = req.headers['host'];
          // #275: Host 欠落は fail-closed（正規クライアントは必ず付与する）。
          if (host == null) {
            return Response(421,
                body: 'Missing Host header',
                headers: {'Content-Type': 'text/plain'});
          }
          // #277: IPv4/ホスト名は ":port" を除去、IPv6 リテラルは "[::1]:port" の
          // ブラケット/ゾーンID を除去してから照合。
          final hostKey = _hostHeaderKey(host);
          if (!_allowedHosts.contains(hostKey)) {
            return Response(421,
                body: 'Misdirected Request',
                headers: {'Content-Type': 'text/plain'});
          }
          return inner(req);
        };
      };

  // #258/#277: 起動時に許可 Host 集合を構築（localhost + 広告 IP + 全 NIC の
  // IPv4/IPv6）。値は小文字・ブラケット無し・ゾーンID無しで格納し、ガード側も
  // 同じ形に正規化して照合する。
  Future<void> _buildAllowedHosts(String ipAddress) async {
    _allowedHosts = {
      'localhost',
      '127.0.0.1',
      '::1',
      _normalizeHostValue(ipAddress),
    };
    // HTTPS 証明書のホスト名でアクセスする場合も許可（#275）。
    if (_httpsHostname != null && _httpsHostname!.isNotEmpty) {
      _allowedHosts.add(_normalizeHostValue(_httpsHostname!));
    }
    try {
      final ifaces = await NetworkInterface.list(includeLoopback: true);
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          // #277: IPv4 に加え IPv6 アドレスも許可
          _allowedHosts.add(_normalizeHostValue(addr.address));
        }
      }
    } catch (_) {}
  }

  // #277: 格納・比較用に Host 値を正規化（小文字化＋IPv6 ゾーンID除去）。
  static String _normalizeHostValue(String h) {
    final zi = h.indexOf('%');
    if (zi >= 0) h = h.substring(0, zi);
    return h.toLowerCase();
  }

  // #277: Host ヘッダを allowedHosts 照合用のキーに正規化する。
  //  - "host:port" / "1.2.3.4:port" → ポート除去
  //  - "[::1]:port" / "[fe80::1%eth0]" → ブラケット除去＋ゾーンID除去
  //  - 全体を小文字化
  static String _hostHeaderKey(String host) {
    var h = host;
    if (h.startsWith('[')) {
      final end = h.indexOf(']');
      h = end > 0 ? h.substring(1, end) : h.substring(1);
    } else {
      h = h.replaceFirst(RegExp(r':\d+$'), '');
    }
    return _normalizeHostValue(h);
  }

  // #277: IPv6 対応。anyIPv6 は Dart 既定の v6Only=false でデュアルスタック
  // （v4-mapped で IPv4 も受ける）。IPv6 が無効な環境では anyIPv4 にフォールバック。
  Future<HttpServer> _serveDualStack(Handler handler, int port,
      {SecurityContext? securityContext}) async {
    try {
      return await shelf_io.serve(handler, InternetAddress.anyIPv6, port,
          securityContext: securityContext);
    } on SocketException catch (e) {
      _log('IPv6 bind unavailable ($e); falling back to IPv4-only');
      return await shelf_io.serve(handler, InternetAddress.anyIPv4, port,
          securityContext: securityContext);
    }
  }

  // SAF ディレクトリを選択するメソッド
  Future<void> selectSafDirectory() async {
    try {
      if (Platform.isAndroid) {
        // Android: SAF (Storage Access Framework) を使用
        final String? uri = await _safPlatform.invokeMethod('requestSafDirectory');
        if (uri != null) {
          _safDirectoryUri = uri;
          _displayPath = _getAndroidSafDisplayPath(uri);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('saf_directory_uri', uri);
          _log('SAF Directory URI selected and persisted: $uri');
        } else {
          _log('SAF Directory selection cancelled.');
        }
      } else if (Platform.isIOS) {
        // iOSではアプリ内Documentsフォルダ固定のため、フォルダ選択は無効
        return;
        // Windows, macOS, Linux: file_picker を使用
      } else {
        final String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
        if (selectedDirectory != null && selectedDirectory.isNotEmpty) {
          await _ensureDirectoryExists(selectedDirectory);
          _fallbackStoragePath = selectedDirectory;
          _displayPath = selectedDirectory;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('selected_directory_path', selectedDirectory);
          _log('Directory selected and persisted: $selectedDirectory');
        } else {
          _log('Directory selection cancelled.');
        }
      }
    } on PlatformException catch (e) {
      _log("Failed to select directory: '${e.message}'.");
    } catch (e) {
      // WSL 等の環境では DBus (XDG Desktop Portal) が利用できず、
      // PlatformException 以外の例外が発生するため汎用的に捕捉する
      _log("Failed to select directory: $e");
    }
  }

  /// 選択フォルダの in-memory 状態をリセットし、デフォルトパスを再設定する
  Future<void> resetDirectoryState() async {
    _safDirectoryUri = null;
    _fallbackStoragePath = null;
    _displayPath = null;
    await initializePaths();
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
      _displayPath = _getAndroidSafDisplayPath(_safDirectoryUri!);
      _log('Loaded persisted SAF Directory URI: $_safDirectoryUri');
      // ここでネイティブ側にもURIを渡し、アクセス権を再確認させるなどの処理が必要になる可能性
    }

    // iOS/Desktop: 永続化されたディレクトリパスを読み込む
    if (!Platform.isAndroid) {
      final savedPath = prefs.getString('selected_directory_path');
      if (savedPath != null) {
        final dir = Directory(savedPath);
        if (await dir.exists()) {
          _fallbackStoragePath = savedPath;
          if (Platform.isIOS) {
            final packageInfo = await PackageInfo.fromPlatform();
            final docDir = await getApplicationDocumentsDirectory();
            _displayPath = _getIosDisplayPath(savedPath, packageInfo.appName, docDir.path);
          } else {
            _displayPath = savedPath;
          }
          _log('Loaded persisted directory path: $savedPath');
        } else {
          // 保存されたフォルダが存在しない場合は設定をクリア
          await prefs.remove('selected_directory_path');
          _log('Persisted directory no longer exists, reverted to default: $savedPath');
        }
      }
    }
  }

  /// フォルダを開く
  /// iOSでは制限があるため、パス表示ダイアログを返す（戻り値がfalseの場合）
  Future<bool> openDownloadsFolder() async {
    final storagePath = _safDirectoryUri ?? _fallbackStoragePath;
    if (storagePath == null) {
      return false;
    }

    try {
      if (Platform.isMacOS) {
        // macOS: MethodChannel経由でFinderでフォルダを開く
        await _folderPlatform.invokeMethod('openFolder', {'path': storagePath});
        return true;
      } else if (Platform.isWindows) {
        // Windows: explorerで開く
        await Process.run('explorer', [storagePath]);
        return true;
      } else if (Platform.isLinux) {
        // Linux: xdg-openで開く。WSL等xdg-openが動作しない環境では
        // 終了コードが非ゼロになるため、falseを返してパス表示ダイアログに委ねる (#88)
        final result = await Process.run('xdg-open', [storagePath]);
        return result.exitCode == 0;
      } else if (Platform.isAndroid || Platform.isIOS) {
        // Android/iOS: SAFやサンドボックスの制限により直接フォルダを開けないため、
        // falseを返してダイアログ表示を促す
        return false;
      }
    } on PlatformException catch (e) {
      _log('Failed to open folder: ${e.message}');
    } catch (e) {
      _log('Failed to open folder: $e');
    }
    return false;
  }
}
