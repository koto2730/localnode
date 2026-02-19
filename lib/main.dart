import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localnode/cli_runner.dart';
import 'package:localnode/server_service.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// サーバーの状態を表すenum
enum ServerStatus { stopped, running, error }

// サーバーの状態を保持するクラス
@immutable
class ServerState {
  const ServerState({
    required this.status,
    this.availableIpAddresses = const [],
    this.selectedIpAddress,
    this.pin,
    this.port,
    this.errorMessage,
    this.storagePath,
    this.operationMode = OperationMode.normal,
    this.authMode = AuthMode.randomPin,
    this.fixedPin,
  });

  final ServerStatus status;
  final List<String> availableIpAddresses;
  final String? selectedIpAddress;
  final String? pin;
  final int? port;
  final String? errorMessage;
  final String? storagePath;
  final OperationMode operationMode;
  final AuthMode authMode;
  final String? fixedPin;

  ServerState copyWith({
    ServerStatus? status,
    List<String>? availableIpAddresses,
    String? selectedIpAddress,
    String? pin,
    int? port,
    String? errorMessage,
    String? storagePath,
    OperationMode? operationMode,
    AuthMode? authMode,
    String? fixedPin,
    bool clearPin = false,
    bool clearErrorMessage = false,
    bool clearFixedPin = false,
  }) {
    return ServerState(
      status: status ?? this.status,
      availableIpAddresses: availableIpAddresses ?? this.availableIpAddresses,
      selectedIpAddress: selectedIpAddress ?? this.selectedIpAddress,
      pin: clearPin ? null : (pin ?? this.pin),
      port: port ?? this.port,
      errorMessage: clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
      storagePath: storagePath ?? this.storagePath,
      operationMode: operationMode ?? this.operationMode,
      authMode: authMode ?? this.authMode,
      fixedPin: clearFixedPin ? null : (fixedPin ?? this.fixedPin),
    );
  }
}

// クリップボード状態を保持するクラス
@immutable
class ClipboardState {
  const ClipboardState({
    this.items = const [],
    this.lastModified = 0,
  });

  final List<ClipboardItemData> items;
  final int lastModified;

  ClipboardState copyWith({
    List<ClipboardItemData>? items,
    int? lastModified,
  }) {
    return ClipboardState(
      items: items ?? this.items,
      lastModified: lastModified ?? this.lastModified,
    );
  }
}

// クリップボードアイテムデータ
@immutable
class ClipboardItemData {
  const ClipboardItemData({
    required this.id,
    required this.text,
    this.tag,
    required this.createdAt,
  });

  final String id;
  final String text;
  final String? tag;
  final DateTime createdAt;

  factory ClipboardItemData.fromClipboardItem(ClipboardItem item) {
    return ClipboardItemData(
      id: item.id,
      text: item.text,
      tag: item.tag,
      createdAt: item.createdAt,
    );
  }
}

// Notifierの定義
class ServerNotifier extends Notifier<ServerState> {
  @override
  ServerState build() {
    // 初期状態を返す
    return const ServerState(status: ServerStatus.stopped);
  }

  // _serverService を ref 経由で取得
  ServerService get _serverService => ref.read(serverServiceProvider);

  Future<void> loadIpAddresses() async {
    if (kIsWeb) return; // Webでは実行しない
    await _serverService.initializePaths();
    final ips = await _serverService.getAvailableIpAddresses();
    final current = state.selectedIpAddress;
    final selected = (current != null && ips.contains(current))
        ? current
        : (ips.isNotEmpty ? ips.first : null);
    state = state.copyWith(
      availableIpAddresses: ips,
      selectedIpAddress: selected,
      storagePath: _serverService.displayPath ?? _serverService.documentsPath,
    );
  }

  /// SharedPreferencesから設定を読み込む
  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final opModeStr = prefs.getString('operation_mode');
    final authModeStr = prefs.getString('auth_mode');
    final savedFixedPin = prefs.getString('fixed_pin');

    final opMode = opModeStr == 'downloadOnly'
        ? OperationMode.downloadOnly
        : OperationMode.normal;
    final authMode = authModeStr == 'fixedPin'
        ? AuthMode.fixedPin
        : authModeStr == 'noPin'
            ? AuthMode.noPin
            : AuthMode.randomPin;

    state = state.copyWith(
      operationMode: opMode,
      authMode: authMode,
      fixedPin: savedFixedPin,
    );
  }

  /// 動作モードを変更して永続化
  Future<void> setOperationMode(OperationMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('operation_mode',
        mode == OperationMode.downloadOnly ? 'downloadOnly' : 'normal');
    state = state.copyWith(operationMode: mode);
  }

  /// 認証モードを変更して永続化
  Future<void> setAuthMode(AuthMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_mode',
        mode == AuthMode.fixedPin ? 'fixedPin' : mode == AuthMode.noPin ? 'noPin' : 'randomPin');
    if (mode != AuthMode.fixedPin) {
      await prefs.remove('fixed_pin');
      state = state.copyWith(authMode: mode, clearFixedPin: true);
    } else {
      state = state.copyWith(authMode: mode);
    }
  }

  /// 固定PINを設定して永続化
  Future<void> setFixedPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('fixed_pin', pin);
    state = state.copyWith(fixedPin: pin);
  }

  void selectIpAddress(String ipAddress) {
    if (kIsWeb) return; // Webでは実行しない
    state = state.copyWith(selectedIpAddress: ipAddress);
  }

  Future<void> selectSafDirectory() async {
    if (kIsWeb) return;
    await _serverService.selectSafDirectory();
    state = state.copyWith(storagePath: _serverService.displayPath ?? _serverService.documentsPath);
  }

  Future<void> start(int port) async {
    if (kIsWeb) return; // Webでは実行しない

    if (state.selectedIpAddress == null) {
      state = state.copyWith(
        status: ServerStatus.error,
        errorMessage: '利用可能なIPアドレスがありません。',
      );
      return;
    }

    try {
      await _serverService.startServer(
        ipAddress: state.selectedIpAddress!,
        port: port,
        operationMode: state.operationMode,
        authMode: state.authMode,
        fixedPin: state.fixedPin,
      );

      state = state.copyWith(
        status: ServerStatus.running,
        selectedIpAddress: _serverService.ipAddress,
        pin: _serverService.pin,
        port: _serverService.port,
        clearPin: _serverService.pin == null,
      );

      // クリップボードポーリングを開始
      ref.read(clipboardNotifierProvider.notifier).startPolling();
    } catch (e, stackTrace) {
      state = state.copyWith(
        status: ServerStatus.error,
        errorMessage: 'エラー: $e\n$stackTrace',
      );
    }
  }

  Future<void> stop() async {
    // クリップボードポーリングを停止
    ref.read(clipboardNotifierProvider.notifier).stopPolling();
    await _serverService.stopServer();
    // モード設定は維持する
    state = state.copyWith(
      status: ServerStatus.stopped,
      clearPin: true,
      clearErrorMessage: true,
    );
    // 停止後もIPアドレスとパスは維持する
    loadIpAddresses();
  }

  Future<bool> openDownloadsFolder() async {
    if (kIsWeb) return false;
    return await _serverService.openDownloadsFolder();
  }
}

// クリップボードNotifierの定義
class ClipboardNotifier extends Notifier<ClipboardState> {
  Timer? _pollingTimer;

  @override
  ClipboardState build() {
    ref.onDispose(() {
      _pollingTimer?.cancel();
    });
    return const ClipboardState();
  }

  ServerService get _serverService => ref.read(serverServiceProvider);

  void startPolling() {
    _pollingTimer?.cancel();
    _refreshFromService();
    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _refreshFromService();
    });
  }

  void stopPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    state = const ClipboardState();
  }

  void _refreshFromService() {
    final currentLastModified = _serverService.clipboardLastModified;
    if (currentLastModified != state.lastModified) {
      final items = _serverService.clipboardItems
          .map((item) => ClipboardItemData.fromClipboardItem(item))
          .toList();
      state = ClipboardState(
        items: items,
        lastModified: currentLastModified,
      );
    }
  }

  void addText(String text) {
    try {
      _serverService.addClipboardText(text);
      _refreshFromService();
    } catch (e) {
      // エラーは呼び出し側で処理
      rethrow;
    }
  }

  void deleteItem(String id) {
    _serverService.deleteClipboardItem(id);
    _refreshFromService();
  }

  void clearAll() {
    _serverService.clearClipboard();
    _refreshFromService();
  }
}

// Providerの定義
final serverServiceProvider = Provider((ref) => ServerService());

final serverNotifierProvider =
    NotifierProvider<ServerNotifier, ServerState>(ServerNotifier.new);

final clipboardNotifierProvider =
    NotifierProvider<ClipboardNotifier, ClipboardState>(ClipboardNotifier.new);

void main(List<String> args) async {
  // --helpや-hが指定された場合はCLIヘルプを表示
  if (args.contains('--help') || args.contains('-h')) {
    final runner = CliRunner(args);
    await runner.run();
    return;
  }

  // CLIモードかチェック
  if (CliRunner.isCliMode(args)) {
    // CLIモードではFlutter UIを使わずにサーバーを起動
    final runner = CliRunner(args);
    await runner.run();
    return;
  }

  // 通常のFlutter UIモード
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LocalNode',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.grey[100],
      ),
      home: const HomePage(),
    );
  }
}

// 表示モードを定義するenum
enum DisplayMode {
  pinAndQrVisible, // PINとQRコードを表示 (デフォルト)
  allVisible,      // すべて表示
  qrOnlyVisible,   // QRコードのみ表示
}

// サーバー稼働時のタブを定義するenum
enum ServerTab {
  connection, // 接続情報
  clipboard,  // クリップボード共有
}

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  // 初期状態を pinAndQrVisible に設定
  DisplayMode _displayMode = DisplayMode.pinAndQrVisible;
  // サーバー稼働時のタブ
  ServerTab _currentTab = ServerTab.connection;
  late final TextEditingController _portController;
  late final TextEditingController _fixedPinController;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(text: '8080');
    _fixedPinController = TextEditingController();
    // Web以外のプラットフォームでのみIPアドレスリストと設定を読み込む
    if (!kIsWeb) {
      Future.microtask(() {
        final notifier = ref.read(serverNotifierProvider.notifier);
        notifier.loadIpAddresses();
        notifier.loadSettings().then((_) {
          // 固定PINが保存されていればコントローラに反映
          final fixedPin = ref.read(serverNotifierProvider).fixedPin;
          if (fixedPin != null) {
            _fixedPinController.text = fixedPin;
          }
        });
      });
    }
  }

  @override
  void dispose() {
    _portController.dispose();
    _fixedPinController.dispose();
    super.dispose();
  }

  // 表示モードを切り替えるメソッド
  void _toggleDisplayMode() {
    setState(() {
      if (_displayMode == DisplayMode.pinAndQrVisible) {
        _displayMode = DisplayMode.allVisible;
      } else if (_displayMode == DisplayMode.allVisible) {
        _displayMode = DisplayMode.qrOnlyVisible;
      } else {
        _displayMode = DisplayMode.pinAndQrVisible;
      }
    });
  }

  // 表示モードに応じたアイコンを返すメソッド
  IconData _getDisplayModeIcon() {
    switch (_displayMode) {
      case DisplayMode.pinAndQrVisible:
        return Icons.visibility; // 基本表示
      case DisplayMode.allVisible:
        return Icons.explore; // 詳細表示
      case DisplayMode.qrOnlyVisible:
        return Icons.security; // QRのみ
    }
  }
  
  String _getDisplayModeTooltip() {
    switch (_displayMode) {
      case DisplayMode.pinAndQrVisible:
        return 'すべての情報を表示';
      case DisplayMode.allVisible:
        return 'QRコードのみ表示';
      case DisplayMode.qrOnlyVisible:
        return 'PINとQRコードを表示';
    }
  }

  Widget _buildTabSelector() {
    return SegmentedButton<ServerTab>(
      segments: const [
        ButtonSegment<ServerTab>(
          value: ServerTab.connection,
          label: Text('接続情報'),
          icon: Icon(Icons.qr_code),
        ),
        ButtonSegment<ServerTab>(
          value: ServerTab.clipboard,
          label: Text('クリップボード'),
          icon: Icon(Icons.content_paste),
        ),
      ],
      selected: {_currentTab},
      onSelectionChanged: (Set<ServerTab> newSelection) {
        setState(() {
          _currentTab = newSelection.first;
        });
      },
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.teal[100];
          }
          return null;
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Webプラットフォーム用の専用UI
    if (kIsWeb) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('LocalNode'),
          backgroundColor: Colors.white,
          elevation: 1,
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.cloud_done_outlined, size: 80, color: Colors.blueAccent),
                SizedBox(height: 20),
                Text(
                  'Web Client Mode',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 10),
                Text(
                  'このページは、他のデバイスで起動しているLocalNodeサーバーにアクセスするためのクライアントです。\nサーバーのQRコードをスキャンするか、表示されたアドレスにアクセスしてください。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // ネイティブプラットフォーム用のUI
    final serverState = ref.watch(serverNotifierProvider);
    final url = serverState.selectedIpAddress != null && serverState.port != null
        ? 'http://${serverState.selectedIpAddress}:${serverState.port}'
        : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('LocalNode'),
        backgroundColor: Colors.white,
        elevation: 1,
        actions: [
          if (serverState.status == ServerStatus.running)
            IconButton(
              icon: Icon(_getDisplayModeIcon()),
              onPressed: _toggleDisplayMode,
              tooltip: _getDisplayModeTooltip(),
            ),
        ],
      ),
      body: SingleChildScrollView(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                // サーバー稼働時：タブ切り替え
                if (serverState.status == ServerStatus.running) ...[
                  _buildTabSelector(),
                  const SizedBox(height: 16),
                  if (_currentTab == ServerTab.connection && url != null)
                    _buildConnectionInfo(context, url, serverState.pin, serverState.storagePath),
                  if (_currentTab == ServerTab.clipboard)
                    _buildClipboardSection(context),
                ],

                if (serverState.status == ServerStatus.stopped)
                  _buildStoppedView(context),

                if (serverState.status == ServerStatus.error)
                  Text('エラー: ${serverState.errorMessage}',
                      style: const TextStyle(fontSize: 16, color: Colors.red)),

                const SizedBox(height: 40),

                // Start/Stopボタン
                _buildControlButton(context, ref, serverState),

                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStoppedView(BuildContext context) {
    final serverState = ref.watch(serverNotifierProvider);
    final notifier = ref.read(serverNotifierProvider.notifier);

    return Column(
      children: [
        const Text('サーバーは停止しています',
            style: TextStyle(fontSize: 18, color: Colors.grey)),
        const SizedBox(height: 20),
        
        // IPアドレス選択ドロップダウン
        if (serverState.availableIpAddresses.isNotEmpty && serverState.selectedIpAddress != null)
          DropdownButton<String>(
            value: serverState.selectedIpAddress,
            items: serverState.availableIpAddresses
                .map((ip) => DropdownMenuItem(value: ip, child: Text(ip)))
                .toList(),
            onChanged: (ip) {
              if (ip != null) {
                notifier.selectIpAddress(ip);
              }
            },
          ),
        const SizedBox(height: 10),

        SizedBox(
          width: 150,
          child: TextField(
            controller: _portController,
            decoration: const InputDecoration(
              labelText: 'ポート番号',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
          ),
        ),
        // 動作モード選択
        const SizedBox(height: 20),
        const Text('動作モード', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        SegmentedButton<OperationMode>(
          segments: const [
            ButtonSegment<OperationMode>(
              value: OperationMode.normal,
              label: Text('通常'),
              icon: Icon(Icons.swap_vert),
            ),
            ButtonSegment<OperationMode>(
              value: OperationMode.downloadOnly,
              label: Text('DL専用'),
              icon: Icon(Icons.download),
            ),
          ],
          selected: {serverState.operationMode},
          onSelectionChanged: (Set<OperationMode> newSelection) {
            notifier.setOperationMode(newSelection.first);
          },
        ),

        // 認証モード選択
        const SizedBox(height: 20),
        const Text('認証モード', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        SegmentedButton<AuthMode>(
          segments: const [
            ButtonSegment<AuthMode>(
              value: AuthMode.randomPin,
              label: Text('ランダムPIN'),
              icon: Icon(Icons.shuffle),
            ),
            ButtonSegment<AuthMode>(
              value: AuthMode.fixedPin,
              label: Text('固定PIN'),
              icon: Icon(Icons.pin),
            ),
            ButtonSegment<AuthMode>(
              value: AuthMode.noPin,
              label: Text('PIN無し'),
              icon: Icon(Icons.lock_open),
            ),
          ],
          selected: {serverState.authMode},
          onSelectionChanged: (Set<AuthMode> newSelection) {
            notifier.setAuthMode(newSelection.first);
            // 固定PINモードに戻ったとき、コントローラに残っているPINをstateに同期する
            if (newSelection.first == AuthMode.fixedPin &&
                _fixedPinController.text.length == 4) {
              notifier.setFixedPin(_fixedPinController.text);
            }
          },
        ),

        // 固定PIN入力フィールド
        if (serverState.authMode == AuthMode.fixedPin) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: 150,
            child: TextField(
              controller: _fixedPinController,
              decoration: const InputDecoration(
                labelText: '固定PIN (4桁)',
                border: OutlineInputBorder(),
                isDense: true,
                counterText: '',
              ),
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              textAlign: TextAlign.center,
              maxLength: 4,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (value) {
                if (value.length == 4) {
                  notifier.setFixedPin(value);
                  FocusScope.of(context).unfocus();
                }
              },
            ),
          ),
        ],

        // PINなし警告
        if (serverState.authMode == AuthMode.noPin) ...[
          const SizedBox(height: 10),
          Card(
            color: Colors.orange[50],
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.warning, color: Colors.orange[800]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '警告: PIN認証が無効です。同じネットワーク上の誰でもアクセスできます。',
                      style: TextStyle(color: Colors.orange[800], fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],

        if (!kIsWeb) ...[
          const SizedBox(height: 20),
          // iOSではフォルダはアプリ内固定のため選択UIを非表示
          if (!kIsWeb && !Platform.isIOS)
            ElevatedButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('共有フォルダを選択'),
              onPressed: () async {
                await notifier.selectSafDirectory();
              },
            ),
          if (!kIsWeb && !Platform.isIOS)
            const SizedBox(height: 10),
          if (serverState.storagePath != null)
            Text('選択中のフォルダ: ${serverState.storagePath}', textAlign: TextAlign.center),
          if (serverState.storagePath != null && !Platform.isIOS) ...[
            const SizedBox(height: 10),
            ElevatedButton.icon(
              icon: const Icon(Icons.launch),
              label: const Text('フォルダを開く'),
              onPressed: () async {
                final opened = await notifier.openDownloadsFolder();
                if (!opened && context.mounted) {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('フォルダの場所'),
                      content: Text(
                        'ファイルアプリで以下の場所を確認してください:\n\n${serverState.storagePath}',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  );
                }
              },
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildConnectionInfo(BuildContext context, String url, String? pin, String? storagePath) {
    final serverState = ref.watch(serverNotifierProvider);
    // モードに応じて表示/非表示を決定
    final bool showPin = serverState.authMode != AuthMode.noPin &&
        (_displayMode == DisplayMode.pinAndQrVisible || _displayMode == DisplayMode.allVisible);
    final bool showDetails = _displayMode == DisplayMode.allVisible;

    return Column(
      children: [
        // モードインジケータ
        if (serverState.operationMode == OperationMode.downloadOnly)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              color: Colors.blue[50],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.download, color: Colors.blue[700]),
                    const SizedBox(width: 8),
                    Text('ダウンロード専用モード',
                        style: TextStyle(color: Colors.blue[700], fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ),
        if (serverState.authMode == AuthMode.noPin)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              color: Colors.orange[50],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_open, color: Colors.orange[700]),
                    const SizedBox(width: 8),
                    Text('PIN認証無し',
                        style: TextStyle(color: Colors.orange[700], fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ),

        // PIN表示エリア
        SizedBox(
          height: 80, // Cardのおおよその高さ
          child: AnimatedOpacity(
            opacity: showPin && pin != null ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: pin != null
              ? Card(
                  color: Colors.amber[100],
                  elevation: 2,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.pin, color: Colors.grey[850]),
                          const SizedBox(width: 12),
                          Text(
                            'PIN: $pin',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 6,
                              color: Colors.grey[850],
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(), // pinがnullの場合は何も表示しない
          ),
        ),
        
        const SizedBox(height: 25),
        
        const Text(
          '以下のQRコードまたはアドレスにアクセスしてください',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 20),
        
        // QRコード
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.grey.withOpacity(0.2),
                spreadRadius: 2,
                blurRadius: 5,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: QrImageView(
            data: url,
            version: QrVersions.auto,
            size: 200.0,
          ),
        ),
        const SizedBox(height: 20),

        // URL表示エリア
        SizedBox(
          height: 30, // SelectableTextのおおよその高さ
          child: AnimatedOpacity(
            opacity: showDetails ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: SelectableText(
              url,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blue),
            ),
          ),
        ),
        const SizedBox(height: 30),


      ],
    );
  }

  Widget _buildControlButton(BuildContext context, WidgetRef ref, ServerState serverState) {
    final bool isRunning = serverState.status == ServerStatus.running;

    return ElevatedButton.icon(
      icon: Icon(isRunning ? Icons.stop : Icons.play_arrow),
      style: ElevatedButton.styleFrom(
        backgroundColor: isRunning ? Colors.redAccent : Colors.lightBlue,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(30),
        ),
        elevation: 5,
      ),
      onPressed: () async {
        final notifier = ref.read(serverNotifierProvider.notifier);
        if (isRunning) {
          await notifier.stop();
        } else {
          final port = int.tryParse(_portController.text);
          if (port == null || port < 1 || port > 65535) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('無効なポート番号です。1〜65535の範囲で入力してください。'),
                backgroundColor: Colors.red,
              ),
            );
            return;
          }
          // 固定PINモードのバリデーション
          if (serverState.authMode == AuthMode.fixedPin) {
            final fixedPin = serverState.fixedPin;
            if (fixedPin == null || fixedPin.length != 4) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('固定PINは4桁の数字を入力してください。'),
                  backgroundColor: Colors.red,
                ),
              );
              return;
            }
          }
          await notifier.start(port);
        }
      },
      label: Text(isRunning ? 'サーバーを停止' : 'サーバーを開始'),
    );
  }

  Widget _buildClipboardSection(BuildContext context) {
    final clipboardState = ref.watch(clipboardNotifierProvider);
    final clipboardNotifier = ref.read(clipboardNotifierProvider.notifier);

    return Card(
      color: Colors.teal[50],
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ヘッダー
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.content_paste, color: Colors.teal[700]),
                    const SizedBox(width: 8),
                    Text(
                      'クリップボード共有',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.teal[700],
                      ),
                    ),
                  ],
                ),
                if (clipboardState.items.isNotEmpty)
                  TextButton.icon(
                    icon: const Icon(Icons.delete_sweep, size: 18),
                    label: const Text('すべて削除'),
                    onPressed: () => clipboardNotifier.clearAll(),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // 入力フィールド
            _ClipboardInputField(
              onSubmit: (text) {
                try {
                  clipboardNotifier.addText(text);
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('エラー: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
            ),
            const SizedBox(height: 16),

            // アイテムリスト
            if (clipboardState.items.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'テキストを入力して共有しましょう',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: clipboardState.items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = clipboardState.items[index];
                    return _ClipboardItemTile(
                      item: item,
                      onCopy: () => _copyToClipboard(context, item.text),
                      onDelete: () => clipboardNotifier.deleteItem(item.id),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyToClipboard(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('クリップボードにコピーしました'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }
}

// クリップボード入力フィールドウィジェット
class _ClipboardInputField extends StatefulWidget {
  final Function(String) onSubmit;

  const _ClipboardInputField({required this.onSubmit});

  @override
  State<_ClipboardInputField> createState() => _ClipboardInputFieldState();
}

class _ClipboardInputFieldState extends State<_ClipboardInputField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) {
      widget.onSubmit(text);
      _controller.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            decoration: InputDecoration(
              hintText: '共有するテキストを入力...',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
            maxLines: 3,
            minLines: 1,
            onSubmitted: (_) => _submit(),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          icon: const Icon(Icons.send),
          onPressed: _submit,
          style: IconButton.styleFrom(
            backgroundColor: Colors.teal,
          ),
        ),
      ],
    );
  }
}

// クリップボードアイテムタイルウィジェット
class _ClipboardItemTile extends StatelessWidget {
  final ClipboardItemData item;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  const _ClipboardItemTile({
    required this.item,
    required this.onCopy,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      title: Text(
        item.text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Row(
        children: [
          if (item.tag != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.teal,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                item.tag!,
                style: const TextStyle(fontSize: 10, color: Colors.white),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            _formatTime(item.createdAt),
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.copy, color: Colors.teal),
            onPressed: onCopy,
            tooltip: 'コピー',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            onPressed: onDelete,
            tooltip: '削除',
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);
    if (diff.inMinutes < 1) return '今';
    if (diff.inHours < 1) return '${diff.inMinutes}分前';
    if (diff.inDays < 1) return '${diff.inHours}時間前';
    return '${diff.inDays}日前';
  }
}
