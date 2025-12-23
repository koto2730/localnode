import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:localnode/server_service.dart';
import 'package:qr_flutter/qr_flutter.dart';

// サーバーの状態を表すenum
enum ServerStatus { stopped, running, error }

// サーバーの状態を保持するクラス
@immutable
class ServerState {
  const ServerState({
    required this.status,
    this.ipAddress,
    this.pin,
    this.port,
    this.errorMessage,
  });

  final ServerStatus status;
  final String? ipAddress;
  final String? pin;
  final int? port;
  final String? errorMessage;
}

// StateNotifierの定義
class ServerStateNotifier extends StateNotifier<ServerState> {
  ServerStateNotifier(this._serverService)
      : super(const ServerState(status: ServerStatus.stopped));

  final ServerService _serverService;

  Future<bool> _requestPermissions() async {
    if (!Platform.isAndroid) return true; // Android以外は常にtrue

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
    try {
      final hasPermission = await _requestPermissions();
      if (!hasPermission) {
        throw Exception('外部ストレージへのアクセス許可が必要です。設定アプリから権限を許可してください。');
      }

      await _serverService.startServer(port);
      state = ServerState(
        status: ServerStatus.running,
        ipAddress: _serverService.ipAddress,
        pin: _serverService.pin,
        port: _serverService.port,
      );
    } catch (e, stackTrace) {
      state = ServerState(
        status: ServerStatus.error,
        errorMessage: 'エラー: $e\n$stackTrace',
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

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool _isPinVisible = true;
  late final TextEditingController _portController;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(text: '8080');
  }

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final serverState = ref.watch(serverStateProvider);
    final url = serverState.ipAddress != null && serverState.port != null
        ? 'http://${serverState.ipAddress}:${serverState.port}'
        : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('LocalNode'),
        backgroundColor: Colors.white,
        elevation: 1,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              // サーバーの状態に応じて表示を切り替え
              if (serverState.status == ServerStatus.running && url != null)
                _buildConnectionInfo(context, url, serverState.pin),

              if (serverState.status == ServerStatus.stopped)
                _buildStoppedView(context),

              if (serverState.status == ServerStatus.error)
                Text('エラー: ${serverState.errorMessage}',
                    style: const TextStyle(fontSize: 16, color: Colors.red)),

              const Spacer(),

              // Start/Stopボタン
              _buildControlButton(context, ref, serverState),

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStoppedView(BuildContext context) {
    return Column(
      children: [
        const Text('サーバーは停止しています',
            style: TextStyle(fontSize: 18, color: Colors.grey)),
        const SizedBox(height: 20),
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

  Widget _buildConnectionInfo(BuildContext context, String url, String? pin) {
    return Column(
      children: [
        if (pin != null)
          Card(
            color: Colors.amber[100],
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.pin, color: Colors.grey[850]),
                  const SizedBox(width: 12),
                  Text(
                    _isPinVisible ? 'PIN: $pin' : 'PIN: ****',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      letterSpacing: _isPinVisible ? 6 : 2,
                      color: Colors.grey[850],
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: Icon(
                      _isPinVisible ? Icons.visibility_off : Icons.visibility,
                      color: Colors.grey[600],
                    ),
                    onPressed: () {
                      setState(() {
                        _isPinVisible = !_isPinVisible;
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 25),
        const Text(
          '以下のQRコードまたはアドレスにアクセスしてください',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16),
        ),

        const SizedBox(height: 20),

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

        SelectableText(

          url,

          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blue),

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

      onPressed: () {

        final notifier = ref.read(serverStateProvider.notifier);

        if (isRunning) {

          notifier.stop();

        } else {
          final port = int.tryParse(_portController.text);
          if (port != null && port > 0 && port <= 65535) {
            notifier.start(port);
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
