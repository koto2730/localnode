import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:localnode/server_service.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:state_notifier/state_notifier.dart';
// 3.0以降で StateNotifierProvider を使うための専用インポート
import 'package:flutter_riverpod/legacy.dart'; 
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    this.uploadPath,
  });

  final ServerStatus status;
  final List<String> availableIpAddresses;
  final String? selectedIpAddress;
  final String? pin;
  final int? port;
  final String? errorMessage;
  final String? uploadPath;
}

// StateNotifierの定義
class ServerStateNotifier extends StateNotifier<ServerState> {
  ServerStateNotifier(this._serverService)
      : super(const ServerState(status: ServerStatus.stopped));

  final ServerService _serverService;

  Future<void> loadIpAddresses() async {
    if (kIsWeb) return; // Webでは実行しない
    final ips = await _serverService.getAvailableIpAddresses();
    state = ServerState(
      status: state.status,
      availableIpAddresses: ips,
      // リストの最初のIPをデフォルトで選択
      selectedIpAddress: ips.isNotEmpty ? ips.first : null,
      pin: state.pin,
      port: state.port,
      errorMessage: state.errorMessage,
      uploadPath: state.uploadPath,
    );
  }

  void selectIpAddress(String ipAddress) {
    if (kIsWeb) return; // Webでは実行しない
    state = ServerState(
      status: state.status,
      availableIpAddresses: state.availableIpAddresses,
      selectedIpAddress: ipAddress,
      pin: state.pin,
      port: state.port,
      errorMessage: state.errorMessage,
      uploadPath: state.uploadPath,
    );
  }

  Future<bool> _requestPermissions() async {
    // Android以外では権限要求は不要
    if (kIsWeb || !Platform.isAndroid) {
      return true;
    }

    // Androidの場合のみ権限を要求
    final deviceInfo = await DeviceInfoPlugin().androidInfo;
    Permission permission;

    // Android 11 (API 30) 以上かどうかを判定
    if (deviceInfo.version.sdkInt >= 30) {
      // 全ファイルへのアクセス権限をリクエスト
      permission = Permission.manageExternalStorage;
    } else {
      // Android 10以下は従来のストレージ権限
      permission = Permission.storage;
    }

    final status = await permission.request();
    return status.isGranted;
  }

  Future<void> start(int port) async {
    if (kIsWeb) return; // Webでは実行しない

    if (state.selectedIpAddress == null) {
      state = ServerState(
          status: ServerStatus.error, errorMessage: '利用可能なIPアドレスがありません。');
      return;
    }

    try {
      final hasPermission = await _requestPermissions();
      if (!hasPermission) {
        throw Exception('外部ストレージへのアクセス許可が必要です。設定アプリから権限を許可してください。');
      }

      await _serverService.startServer(
        ipAddress: state.selectedIpAddress!,
        port: port,
      );

      state = ServerState(
        status: ServerStatus.running,
        availableIpAddresses: state.availableIpAddresses,
        selectedIpAddress: _serverService.ipAddress,
        pin: _serverService.pin,
        port: _serverService.port,
        uploadPath: _serverService.displayPath,
      );
    } catch (e, stackTrace) {
      state = ServerState(
        status: ServerStatus.error,
        errorMessage: 'エラー: $e\n$stackTrace',
        availableIpAddresses: state.availableIpAddresses,
        selectedIpAddress: state.selectedIpAddress,
      );
    }
  }

  Future<void> stop() async {
    await _serverService.stopServer();
    state = const ServerState(status: ServerStatus.stopped);
  }
}

// Providerの定義
final serverServiceProvider = Provider((ref) => ServerService());

final serverStateProvider =
    StateNotifierProvider<ServerStateNotifier, ServerState>((ref) {
  return ServerStateNotifier(ref.watch(serverServiceProvider));
});

void main() {
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

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  // 初期状態を pinAndQrVisible に設定
  DisplayMode _displayMode = DisplayMode.pinAndQrVisible;
  late final TextEditingController _portController;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(text: '8080');
    // Web以外のプラットフォームでのみIPアドレスリストを読み込む
    if (!kIsWeb) {
      Future.microtask(() => ref.read(serverStateProvider.notifier).loadIpAddresses());
    }
  }

  @override
  void dispose() {
    _portController.dispose();
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
    final serverState = ref.watch(serverStateProvider);
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
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                // サーバーの状態に応じて表示を切り替え
                if (serverState.status == ServerStatus.running && url != null)
                  _buildConnectionInfo(context, url, serverState.pin, serverState.uploadPath),

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
    final serverState = ref.watch(serverStateProvider);
    final notifier = ref.read(serverStateProvider.notifier);

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
      ],
    );
  }

  Widget _buildConnectionInfo(BuildContext context, String url, String? pin, String? uploadPath) {
    // モードに応じて表示/非表示を決定
    final bool showPin = _displayMode == DisplayMode.pinAndQrVisible || _displayMode == DisplayMode.allVisible;
    final bool showDetails = _displayMode == DisplayMode.allVisible;

    return Column(
      children: [
        // PIN表示エリア
        // 高さを固定して、表示/非表示でレイアウトがガタつかないようにする
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

        // アップロード先フォルダ表示エリア
        if (uploadPath != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey[300]!),
                borderRadius: BorderRadius.circular(8),
              ),
              child: showDetails
                ? ExpansionTile(
                    title: const Text(
                      'アップロード先フォルダ',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
                    ),
                    subtitle: Text(
                      uploadPath,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      softWrap: false,
                      style: const TextStyle(color: Colors.black54),
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16.0, 0, 16.0, 16.0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: SelectableText(uploadPath, style: const TextStyle(color: Colors.black87)),
                        ),
                      ),
                    ],
                  )
                : const ListTile( // 非表示の場合
                    title: Text(
                      'アップロード先フォルダ',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
                    ),
                    subtitle: Text('非表示（詳細表示モードで確認）', style: TextStyle(color: Colors.black54)),
                  ),
            ),
          ),
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

        final notifier = ref.read(serverStateProvider.notifier);

        if (isRunning) {

          await notifier.stop();
          // サーバー停止後にIPリストを再読み込み
          await notifier.loadIpAddresses();

        } else {
          final port = int.tryParse(_portController.text);
          if (port != null && port > 0 && port <= 65535) {
            await notifier.start(port);
          } else {
            // ポート番号が無効な場合の簡単なエラー表示
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('無効なポート番号です。1〜65535の範囲で入力してください。'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      },

      label: Text(isRunning ? 'サーバーを停止' : 'サーバーを開始'),

    );

  }

}
