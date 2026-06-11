// localnode-cli — Flutter/GTK 非依存の CLI サーバーバイナリ
//
// dart compile exe bin/localnode_cli.dart -o localnode-cli
//
// Linux ヘッドレス環境（Raspberry Pi 等）向けに localnode GUI バイナリとは
// 独立してビルド・実行できる。GTK/display への依存を一切持たない。

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:args/args.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:qr/qr.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:yaml/yaml.dart';

// pubspec.yaml の version と一致させる
const String _appVersion = '1.6.0';

// #174 + #220: 予約メンション名。ユーザーが `--mention-action <name>=...` で
// 登録できない。
//   list      自分のメンション一覧 (既存)
//   list <child>  (federation #220) 子のメンション一覧。引数なしと曖昧解消
//   run       script 実行 (既存; --mention-action で登録するのが alias)
//   to        親→子へ clipboard post を送る (federation #220)
//   run_to    親→子へ mention 実行を依頼する (federation #220)
//   up        子→親への重要マーカー (federation #220)
const Set<String> _kReservedMentionNames = {
  'list', 'run', 'to', 'run_to', 'up',
};

extension _FirstWhereOrNullExt<E> on Iterable<E> {
  E? firstWhereOrNullExt(bool Function(E) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}

// =============================================================================
// 設定ファイル (#185)
// =============================================================================
//
// YAML 構造 (1.6.0 spec §2.1):
//
//   server:
//     port: 8080
//     ip: 192.168.1.100
//     name: home-pi
//     dir: /srv/share
//     pin: "1234"
//     mode: normal              # or download-only
//     no-pin: false
//     no-clipboard: false
//     verbose: false
//     https-cert: /path/cert.pem
//     https-key: /path/key.pem
//     token: mytoken
//     no-token: false
//     pin-length: 4             # 1.6.0 #206 (parsed; consumed by #206)
//     pin-charset: digits       # 1.6.0 #206
//
//   mention_actions:
//     - alias: backup
//       script: ./backup.sh
//       description: ...        # 1.6.0 #224
//
//   post_actions:
//     - pattern: "*.png"
//       script: ./move-pic.sh
//
//   clipboard:                  # 1.6.0 #227 (parsed; consumed by #227)
//     max_items: 1000
//     max_text_length: 10000
//
//   children: [...]             # 1.6.0 #218 federation (parsed; consumed there)
//   parent: {...}               # 1.6.0 #218 federation
//
// 解決優先順位: CLI 引数 > config ファイル > 既定値

class _LoadedMentionAction {
  final String alias;
  final String script;
  final String? description;
  _LoadedMentionAction(this.alias, this.script, this.description);
}

class _LoadedPostAction {
  final String pattern;
  final String script;
  _LoadedPostAction(this.pattern, this.script);
}

class _LoadedConfig {
  // server section
  int? port;
  String? ip;
  String? pin;
  String? dir;
  String? mode;
  String? name;
  String? httpsCert;
  String? httpsKey;
  String? token;
  bool? noPin;
  bool? noClipboard;
  bool? verbose;
  bool? noToken;
  // #206 hooks (consumed by #206)
  int? pinLength;
  String? pinCharset;
  // lists
  List<_LoadedMentionAction>? mentionActions;
  List<_LoadedPostAction>? postActions;
  // future sections, parsed-but-not-consumed-yet
  Map<dynamic, dynamic>? clipboardRaw;       // #227
  List<dynamic>? childrenRaw;                // #218 federation
  Map<dynamic, dynamic>? parentRaw;          // #218 federation
}

/// Read and validate a YAML config file. Throws on fatal errors (unreadable,
/// syntax, type mismatch). Unknown top-level keys produce a warning to stderr.
_LoadedConfig _loadConfig(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('Error: Config file not found: $path');
    exit(1);
  }
  final dynamic doc;
  try {
    doc = loadYaml(file.readAsStringSync());
  } catch (e) {
    stderr.writeln('Error: Failed to parse config file: $e');
    exit(1);
  }
  if (doc == null) return _LoadedConfig();
  if (doc is! YamlMap) {
    stderr.writeln('Error: Config file root must be a YAML mapping.');
    exit(1);
  }

  final cfg = _LoadedConfig();
  const knownTop = {
    'server', 'mention_actions', 'post_actions', 'clipboard',
    'children', 'parent',
  };
  for (final key in doc.keys) {
    if (!knownTop.contains(key)) {
      stderr.writeln('Warning: Unknown top-level key in config: $key');
    }
  }

  // server section
  final server = doc['server'];
  if (server is YamlMap) {
    cfg.port = _yamlInt(server, 'port');
    cfg.ip = _yamlString(server, 'ip');
    cfg.pin = _yamlString(server, 'pin');
    cfg.dir = _yamlString(server, 'dir');
    cfg.mode = _yamlString(server, 'mode');
    cfg.name = _yamlString(server, 'name');
    cfg.httpsCert = _yamlString(server, 'https-cert');
    cfg.httpsKey = _yamlString(server, 'https-key');
    cfg.token = _yamlString(server, 'token');
    cfg.noPin = _yamlBool(server, 'no-pin');
    cfg.noClipboard = _yamlBool(server, 'no-clipboard');
    cfg.verbose = _yamlBool(server, 'verbose');
    cfg.noToken = _yamlBool(server, 'no-token');
    cfg.pinLength = _yamlInt(server, 'pin-length');
    cfg.pinCharset = _yamlString(server, 'pin-charset');
  } else if (server != null) {
    stderr.writeln('Error: server section must be a mapping.');
    exit(1);
  }

  // mention_actions
  final ma = doc['mention_actions'];
  if (ma is YamlList) {
    final list = <_LoadedMentionAction>[];
    for (final entry in ma) {
      if (entry is! YamlMap) {
        stderr.writeln('Error: mention_actions entry must be a mapping.');
        exit(1);
      }
      final alias = _yamlString(entry, 'alias');
      final script = _yamlString(entry, 'script');
      if (alias == null || alias.isEmpty || script == null || script.isEmpty) {
        stderr.writeln('Error: mention_actions entry requires alias and script.');
        exit(1);
      }
      list.add(_LoadedMentionAction(alias, script, _yamlString(entry, 'description')));
    }
    cfg.mentionActions = list;
  } else if (ma != null) {
    stderr.writeln('Error: mention_actions must be a list.');
    exit(1);
  }

  // post_actions
  final pa = doc['post_actions'];
  if (pa is YamlList) {
    final list = <_LoadedPostAction>[];
    for (final entry in pa) {
      if (entry is! YamlMap) {
        stderr.writeln('Error: post_actions entry must be a mapping.');
        exit(1);
      }
      final pattern = _yamlString(entry, 'pattern');
      final script = _yamlString(entry, 'script');
      if (pattern == null || pattern.isEmpty || script == null || script.isEmpty) {
        stderr.writeln('Error: post_actions entry requires pattern and script.');
        exit(1);
      }
      list.add(_LoadedPostAction(pattern, script));
    }
    cfg.postActions = list;
  } else if (pa != null) {
    stderr.writeln('Error: post_actions must be a list.');
    exit(1);
  }

  // forward-compat: clipboard はまだ consume されていないので silent skip OK
  final clip = doc['clipboard'];
  if (clip is YamlMap) cfg.clipboardRaw = Map.from(clip);

  // children / parent は 1.6.0 で federation の入口として consume される。
  // キー自体が書かれていれば、たとえ値が空 / 文字列 / 型違いでも黙って捨てずに
  // 即エラーで知らせる (silently skip すると検証も起動時表示もスキップされ、
  // 「parent 設定が反映されない」状態がデバッグ不能になるため)。
  if (doc.containsKey('children')) {
    final ch = doc['children'];
    if (ch is YamlList) {
      cfg.childrenRaw = List.from(ch);
    } else {
      stderr.writeln('Error: children must be a list of mappings '
          '(got: ${ch == null ? "null/empty" : ch.runtimeType}).');
      exit(1);
    }
  }
  if (doc.containsKey('parent')) {
    final pa2 = doc['parent'];
    if (pa2 is YamlMap) {
      cfg.parentRaw = Map.from(pa2);
    } else {
      stderr.writeln('Error: parent must be a mapping with url / token / relation '
          '(got: ${pa2 == null ? "null/empty" : pa2.runtimeType}).');
      exit(1);
    }
  }

  return cfg;
}

String? _yamlString(YamlMap m, String key) {
  final v = m[key];
  if (v == null) return null;
  return v.toString();
}

int? _yamlInt(YamlMap m, String key) {
  final v = m[key];
  if (v == null) return null;
  if (v is int) return v;
  final s = v.toString();
  return int.tryParse(s);
}

bool? _yamlBool(YamlMap m, String key) {
  final v = m[key];
  if (v == null) return null;
  if (v is bool) return v;
  final s = v.toString().toLowerCase();
  if (s == 'true' || s == 'yes' || s == '1') return true;
  if (s == 'false' || s == 'no' || s == '0') return false;
  return null;
}

// =============================================================================
// エントリポイント
// =============================================================================

Future<void> main(List<String> args) async {
  final parser = _buildParser();

  if (args.contains('--help') || args.contains('-h')) {
    _printUsage(parser);
    _flushWindowsInput();
    exit(0);
  }

  final ArgResults results;
  try {
    results = parser.parse(args);
  } catch (e) {
    stderr.writeln('Error: $e');
    stderr.writeln('');
    _printUsage(parser);
    exit(1);
  }

  // #185: --config が指定されていれば YAML を読み込む。
  // 解決優先順位: CLI 引数 > config > 既定値
  _LoadedConfig? cfg;
  if (results.wasParsed('config')) {
    cfg = _loadConfig(results['config'] as String);
  }

  // port: CLI > config > '8080'
  final portStr = results.wasParsed('port')
      ? results['port'] as String
      : (cfg?.port?.toString() ?? results['port'] as String);
  final port = int.tryParse(portStr);
  if (port == null || port < 1 || port > 65535) {
    stderr.writeln('Error: Invalid port number. Must be between 1 and 65535.');
    exit(1);
  }

  final dir = results.wasParsed('dir')
      ? results['dir'] as String?
      : (cfg?.dir ?? results['dir'] as String?);
  if (dir != null && !Directory(dir).existsSync()) {
    stderr.writeln('Error: Directory does not exist: $dir');
    exit(1);
  }

  final specifiedIp = results.wasParsed('ip')
      ? results['ip'] as String?
      : (cfg?.ip ?? results['ip'] as String?);
  final noClipboard = results.wasParsed('no-clipboard')
      ? results['no-clipboard'] as bool
      : (cfg?.noClipboard ?? results['no-clipboard'] as bool);
  final verbose = results.wasParsed('verbose')
      ? results['verbose'] as bool
      : (cfg?.verbose ?? results['verbose'] as bool);
  final modeStr = results.wasParsed('mode')
      ? results['mode'] as String
      : (cfg?.mode ?? results['mode'] as String);
  if (modeStr != 'normal' && modeStr != 'download-only') {
    stderr.writeln('Error: Invalid mode: $modeStr. Must be normal or download-only.');
    exit(1);
  }
  final downloadOnly = modeStr == 'download-only';
  final noPin = results.wasParsed('no-pin')
      ? results['no-pin'] as bool
      : (cfg?.noPin ?? results['no-pin'] as bool);
  final fixedPin = results.wasParsed('pin')
      ? results['pin'] as String?
      : (cfg?.pin ?? results['pin'] as String?);
  // #206
  final pinLength = () {
    final raw = results.wasParsed('pin-length')
        ? results['pin-length'] as String?
        : (cfg?.pinLength?.toString());
    if (raw == null) return 4;
    final n = int.tryParse(raw);
    if (n == null || n < 4 || n > 8) {
      stderr.writeln('Error: --pin-length must be an integer 4..8 (got "$raw").');
      exit(1);
    }
    return n;
  }();
  final pinCharset = () {
    const allowed = {'digits', 'alnum', 'alnum_symbols'};
    final raw = results.wasParsed('pin-charset')
        ? results['pin-charset'] as String?
        : (cfg?.pinCharset ?? results['pin-charset'] as String?);
    final v = raw ?? 'digits';
    if (!allowed.contains(v)) {
      stderr.writeln('Error: --pin-charset must be one of ${allowed.join("/")} (got "$v").');
      exit(1);
    }
    return v;
  }();
  final serverName = results.wasParsed('name')
      ? results['name'] as String
      : (cfg?.name ?? results['name'] as String);
  final noToken = results.wasParsed('no-token')
      ? results['no-token'] as bool
      : (cfg?.noToken ?? results['no-token'] as bool);
  final fixedToken = results.wasParsed('token')
      ? results['token'] as String?
      : (cfg?.token ?? results['token'] as String?);

  // post_actions: CLI > config (どちらかが存在すればその全体を使う)
  final List<String> postActionRaw;
  if (results.wasParsed('post-action')) {
    postActionRaw = results['post-action'] as List<String>;
  } else if (cfg?.postActions != null) {
    postActionRaw = cfg!.postActions!.map((a) => '${a.pattern}=${a.script}').toList();
  } else {
    postActionRaw = results['post-action'] as List<String>;
  }
  final postActions = <({String pattern, String script})>[];
  for (final entry in postActionRaw) {
    final eq = entry.indexOf('=');
    if (eq <= 0) {
      stderr.writeln('Error: --post-action must be in <pattern>=<script> format: $entry');
      exit(1);
    }
    final pattern = entry.substring(0, eq).trim();
    final script = entry.substring(eq + 1).trim();
    if (pattern.isEmpty || script.isEmpty) {
      stderr.writeln('Error: --post-action pattern and script must not be empty: $entry');
      exit(1);
    }
    postActions.add((pattern: pattern, script: script));
  }
  // mention_actions: CLI > config
  final mentionActions = <String, ({String script, String? description})>{};
  if (results.wasParsed('mention-action')) {
    final raw = results['mention-action'] as List<String>;
    for (final entry in raw) {
      final eq = entry.indexOf('=');
      if (eq <= 0) {
        stderr.writeln('Error: --mention-action must be in <alias>=<script> format: $entry');
        exit(1);
      }
      final alias = entry.substring(0, eq).trim();
      final script = entry.substring(eq + 1).trim();
      if (alias.isEmpty || script.isEmpty) {
        stderr.writeln('Error: --mention-action alias and script must not be empty: $entry');
        exit(1);
      }
      // #174 + #220: 予約名 list / run / to / run_to / up
      if (_kReservedMentionNames.contains(alias)) {
        stderr.writeln('Error: "$alias" is a reserved mention name and cannot be used as an alias.');
        exit(1);
      }
      // CLI には description フィールドが無い (YAML config 専用、#224)
      mentionActions[alias] = (script: script, description: null);
    }
  } else if (cfg?.mentionActions != null) {
    for (final m in cfg!.mentionActions!) {
      if (_kReservedMentionNames.contains(m.alias)) {
        stderr.writeln('Error: "${m.alias}" is a reserved mention name and cannot be used as an alias.');
        exit(1);
      }
      mentionActions[m.alias] = (script: m.script, description: m.description);
    }
  }
  final httpsCertPath = results.wasParsed('https-cert')
      ? results['https-cert'] as String?
      : (cfg?.httpsCert ?? results['https-cert'] as String?);
  final httpsKeyPath = results.wasParsed('https-key')
      ? results['https-key'] as String?
      : (cfg?.httpsKey ?? results['https-key'] as String?);
  if ((httpsCertPath == null) != (httpsKeyPath == null)) {
    stderr.writeln('Error: --https-cert and --https-key must be specified together.');
    exit(1);
  }
  if (httpsCertPath != null && !File(httpsCertPath).existsSync()) {
    stderr.writeln('Error: Certificate file does not exist: $httpsCertPath');
    exit(1);
  }
  if (httpsKeyPath != null && !File(httpsKeyPath).existsSync()) {
    stderr.writeln('Error: Key file does not exist: $httpsKeyPath');
    exit(1);
  }
  final bool httpsMode = httpsCertPath != null && httpsKeyPath != null;

  final authMode = noPin
      ? _AuthMode.noPin
      : fixedPin != null
          ? _AuthMode.fixedPin
          : _AuthMode.randomPin;

  // #218 / §1.11: 端末識別 UUID。federation 参加時の固定 ID として使う。
  final statePath = results['state-file'] as String? ?? _defaultStateFilePath();
  final deviceId = _loadOrCreateDeviceId(statePath);

  // #218: federation 設定 (parent / children) があるなら、構成の整合性を検証
  final hasFederation =
      (cfg?.childrenRaw?.isNotEmpty ?? false) || (cfg?.parentRaw != null);
  if (hasFederation) {
    final problems = <String>[];
    // (a) HTTPS が必須
    if (!httpsMode) {
      problems.add('federation requires HTTPS — set https-cert and https-key '
          'in config or pass --https-cert / --https-key');
    }
    // (b) --token は固定であること（ランダムだと再起動で切れる）
    if (noToken) {
      problems.add('federation requires a fixed Bearer token — remove no-token');
    } else if (fixedToken == null || fixedToken.isEmpty) {
      problems.add('federation requires a fixed Bearer token — set server.token '
          'in config or pass --token <value>');
    }
    // (c) children の各エントリを軽く検証
    final children = cfg?.childrenRaw ?? const [];
    for (final entry in children) {
      if (entry is! Map) {
        problems.add('children[]: each entry must be a mapping');
        continue;
      }
      final name = entry['name'];
      final url = entry['url'];
      final token = entry['token'];
      final relation = entry['relation'];
      if (name is! String || name.isEmpty) problems.add('children[]: name is required');
      if (url is! String || !url.startsWith('https://')) {
        problems.add('children[]: url must start with https:// (was: $url)');
      }
      if (token is! String || token.isEmpty) {
        problems.add('children[$name]: token is required (issued by the child)');
      }
      if (relation != 'friendly' && relation != 'equally') {
        problems.add('children[$name]: relation must be friendly or equally');
      }
    }
    // (d) parent エントリを検証
    final parent = cfg?.parentRaw;
    if (parent != null) {
      final url = parent['url'];
      final token = parent['token'];
      final relation = parent['relation'];
      if (url is! String || !url.startsWith('https://')) {
        problems.add('parent.url must start with https:// (was: $url)');
      }
      if (token is! String || token.isEmpty) {
        problems.add('parent.token is required (issued by the parent)');
      }
      if (relation != 'friendly' && relation != 'equally') {
        problems.add('parent.relation must be friendly or equally');
      }
    }
    if (problems.isNotEmpty) {
      stderr.writeln('Error: federation config is incomplete:');
      for (final p in problems) {
        stderr.writeln('  - $p');
      }
      exit(1);
    }
  }

  // #177/#169: HTTPS モードで SAN→ホスト名→IP 解決フロー
  String ipAddress;
  String advertisedHost; // QR/URL に使うホスト名またはIP
  if (httpsMode) {
    final sanResult = await _resolveHttpsHost(
        certPath: httpsCertPath!, specifiedIp: specifiedIp);
    ipAddress = sanResult.bindIp;
    advertisedHost = sanResult.advertisedHost;
  } else {
    ipAddress = specifiedIp ?? await _selectIpAddress();
    advertisedHost = ipAddress;
  }

  stdout.writeln('');
  stdout.writeln('LocalNode CLI Server');
  stdout.writeln('=' * 40);

  // #173: アップロードトークンの決定（download-only モードでは不要）
  final String? uploadToken = (!noToken && !downloadOnly)
      ? (fixedToken ?? _generateUploadToken())
      : null;

  // #227: clipboard 設定を config から読む (config.clipboard.max_items / max_text_length)
  final clipboardCfg = cfg?.clipboardRaw;
  int maxClipboardItems = 1000;
  int maxTextLength = 10000;
  if (clipboardCfg != null) {
    final mi = clipboardCfg['max_items'];
    if (mi is int && mi > 0 && mi <= 100000) {
      maxClipboardItems = mi;
    } else if (mi != null) {
      stderr.writeln('Error: clipboard.max_items must be a positive integer (1-100000).');
      exit(1);
    }
    final ml = clipboardCfg['max_text_length'];
    if (ml is int && ml > 0 && ml <= 1000000) {
      maxTextLength = ml;
    } else if (ml != null) {
      stderr.writeln('Error: clipboard.max_text_length must be a positive integer (1-1000000).');
      exit(1);
    }
  }

  final server = _CliServer(
    verbose: verbose,
    maxClipboardItems: maxClipboardItems,
    maxTextLength: maxTextLength,
    deviceId: deviceId,
  );

  try {
    await server.start(
      ipAddress: ipAddress,
      port: port,
      storagePath: dir,
      downloadOnly: downloadOnly,
      authMode: authMode,
      fixedPin: fixedPin,
      pinLength: pinLength,         // #206
      pinCharset: pinCharset,       // #206
      serverName: serverName,
      clipboardEnabled: !noClipboard,
      httpsCertPath: httpsCertPath,
      httpsKeyPath: httpsKeyPath,
      uploadToken: uploadToken,
      postActions: postActions,
      mentionActions: mentionActions,
    );
  } catch (e) {
    stderr.writeln('Error: Failed to start server: $e');
    exit(1);
  }

  final scheme = httpsMode ? 'https' : 'http';
  final serverUrl = '$scheme://$advertisedHost:$port';

  stdout.writeln('Server started.');
  stdout.writeln('');
  stdout.writeln('  URL:  $serverUrl');
  if (authMode != _AuthMode.noPin) {
    stdout.writeln('  PIN:  ${server.pin}');
  } else {
    stdout.writeln('  PIN:  disabled (no auth)');
  }
  stdout.writeln('  Name: $serverName');
  stdout.writeln('  Mode: ${downloadOnly ? "download-only" : "normal"}');
  if (hasFederation) {
    stdout.writeln('  DeviceID: $deviceId');
    stdout.writeln('  Federation:');
    if (cfg?.childrenRaw != null && cfg!.childrenRaw!.isNotEmpty) {
      stdout.writeln('    children:');
      for (final ch in cfg.childrenRaw!) {
        if (ch is Map) {
          stdout.writeln('      ${ch['name']} <${ch['url']}> [${ch['relation']}]');
        }
      }
    }
    if (cfg?.parentRaw != null) {
      final pr = cfg!.parentRaw!;
      stdout.writeln('    parent: ${pr['name']} <${pr['url']}> [${pr['relation']}${pr['trust'] == true ? ', trust' : ''}]');
    }
  }
  if (postActions.isNotEmpty) {
    stdout.writeln('  Post-action(s):');
    for (final a in postActions) {
      stdout.writeln('    ${a.pattern} -> ${a.script}');
    }
  }
  if (mentionActions.isNotEmpty) {
    stdout.writeln('  Mention action(s):');
    for (final entry in mentionActions.entries) {
      final desc = entry.value.description;
      final suffix = (desc == null || desc.isEmpty) ? '' : '  # $desc';
      stdout.writeln('    @run ${entry.key} -> ${entry.value.script}$suffix');
    }
  }
  if (uploadToken != null) {
    stdout.writeln('  Upload Token: $uploadToken');
    stdout.writeln('');
    stdout.writeln('  curl example:');
    stdout.writeln('    curl -H "Authorization: Bearer $uploadToken" \\');
    stdout.writeln('         -H "x-filename: myfile.txt" \\');
    stdout.writeln('         --data-binary @/path/to/myfile.txt \\');
    stdout.writeln('         $serverUrl/api/upload');
    stdout.writeln('    # subfolder upload: append ?path=<relpath>');
    stdout.writeln('    #   $serverUrl/api/upload?path=photos%2F2026');
    stdout.writeln('');
    stdout.writeln('  curl example (clipboard):');
    stdout.writeln('    curl -H "Authorization: Bearer $uploadToken" \\');
    stdout.writeln('         -H "Content-Type: application/json" \\');
    stdout.writeln('         -d \'{"text":"hello from curl"}\' \\');
    stdout.writeln('         $serverUrl/api/clipboard');
  }
  stdout.writeln('');
  stdout.writeln('QR Code:');
  _printQrCode(serverUrl);
  stdout.writeln('');
  stdout.writeln('Press Ctrl+C to stop.');
  stdout.writeln('');

  // #222: federation peer を登録してハートビート開始
  if (hasFederation) {
    if (cfg?.childrenRaw != null) {
      for (final ch in cfg!.childrenRaw!) {
        if (ch is Map) {
          server.registerFederationPeer(_FederationPeer(
            kind: 'child',
            name: ch['name'] as String,
            url: ch['url'] as String,
            token: ch['token'] as String,
            relation: ch['relation'] as String,
            // #219: 親側設定。子から来るアップロードの上限
            maxUploadSizeBytes: _parseSizeBytes(ch['max_upload_size']),
          ));
        }
      }
    }
    if (cfg?.parentRaw != null) {
      final pr = cfg!.parentRaw!;
      server.registerFederationPeer(_FederationPeer(
        kind: 'parent',
        name: pr['name'] as String,
        url: pr['url'] as String,
        token: pr['token'] as String,
        relation: pr['relation'] as String,
        // #219: 子側設定。trust:true で「親に転送したらローカル削除」
        trust: pr['trust'] == true,
      ));
    }
    server._startHeartbeat();
  }

  _setupSignalHandlers(server);
  if (!noClipboard) _startClipboardPolling(server);
  // Windows: disable echo/line-input to prevent typed chars from appearing (#139)
  // and flush residual keystrokes to prevent prompt mid-screen (#129).
  if (Platform.isWindows) {
    _setWindowsConsoleRawMode();
    _flushWindowsInput();
  }
  await _waitForQuit(server);
}

// =============================================================================
// 引数パーサー
// =============================================================================

ArgParser _buildParser() {
  return ArgParser()
    ..addOption('config',
        abbr: 'c',
        help: 'Path to YAML config file (overridden by CLI args)')
    ..addOption('state-file',
        help: 'Path to state file for persistent device_id '
            '(default: platform-specific user state dir, see docs)')
    ..addOption('port',
        abbr: 'p', help: 'Server port number', defaultsTo: '8080')
    ..addOption('ip', help: 'IP address to bind (skip auto-detection)')
    ..addOption('pin', help: 'Fixed PIN (random if not specified)')
    // #206
    ..addOption('pin-length',
        help: 'PIN length when generating a random PIN (4..8, default 4)')
    ..addOption('pin-charset',
        help: 'Character set for the generated PIN',
        allowed: ['digits', 'alnum', 'alnum_symbols'],
        defaultsTo: 'digits')
    ..addOption('dir', abbr: 'd', help: 'Shared directory path')
    ..addOption('mode',
        abbr: 'm',
        help: 'Operation mode',
        defaultsTo: 'normal',
        allowed: ['normal', 'download-only'])
    ..addFlag('no-pin', help: 'Disable PIN authentication', negatable: false)
    ..addFlag('no-clipboard',
        help: 'Suppress clipboard output in console', negatable: false)
    ..addFlag('verbose',
        abbr: 'v', help: 'Enable verbose request logging', negatable: false)
    ..addOption('name',
        abbr: 'n', help: 'Server name shown in browser tab title', defaultsTo: 'LocalNode')
    ..addOption('https-cert', help: 'Path to TLS certificate file (cert.pem)')
    ..addOption('https-key', help: 'Path to TLS private key file (key.pem)')
    ..addMultiOption('post-action',
        help:
            'Script to run after matching uploads: <pattern>=<script> (repeatable). '
            'Pattern is a glob matched against the filename (e.g. *.zip, *.png, *). '
            'Runs as the server process user. '
            'Use only on trusted networks. If running as a systemd service, set User= to a '
            'low-privilege account.',
        valueHelp: 'pattern=script')
    ..addMultiOption('mention-action',
        help:
            'Register a clipboard mention command: <alias>=<script>. '
            'Send "@run <alias>" via clipboard to trigger the script (repeatable). '
            'Runs as the server process user.',
        valueHelp: 'alias=script')
    ..addOption('token', help: 'Fixed upload token (random if not specified)')
    ..addFlag('no-token',
        help: 'Disable token-based upload authentication', negatable: false)
    ..addFlag('help', abbr: 'h', help: 'Show this help', negatable: false);
}

void _printUsage(ArgParser parser) {
  stdout.writeln('LocalNode CLI - Local file & clipboard sharing server');
  stdout.writeln('');
  stdout.writeln('Usage: localnode-cli [options]');
  stdout.writeln('');
  stdout.writeln('Options:');
  stdout.writeln(parser.usage);
  stdout.writeln('');
  stdout.writeln('Examples:');
  stdout.writeln('  localnode-cli');
  stdout.writeln('  localnode-cli -p 3000 --pin 1234');
  stdout.writeln('  localnode-cli -d /path/to/share --ip 192.168.1.100');
  stdout.writeln('  localnode-cli --mode download-only --no-pin');
  stdout.writeln('  localnode-cli --no-clipboard --verbose');
  stdout.writeln('  localnode-cli --name "MyServer"');
  stdout.writeln('  localnode-cli --https-cert /path/to/cert.pem --https-key /path/to/key.pem');
  stdout.writeln('  localnode-cli --post-action "*.png=./resize.sh" --post-action "*.zip=./unzip.sh"');
  stdout.writeln('  localnode-cli --mention-action backup=./backup.sh --mention-action notify=./notify.sh');
  stdout.writeln('  localnode-cli --config /etc/localnode/config.yaml');
  stdout.writeln('');
  stdout.writeln('Config file (YAML, see docs):');
  stdout.writeln('  Supports server.*, mention_actions[], post_actions[]; CLI args override config.');
  stdout.writeln('');
  stdout.writeln('Security note (--post-action / --mention-action):');
  stdout.writeln('  Scripts run with the same user privileges as the LocalNode process.');
  stdout.writeln('  If running as a systemd service, set User= to a low-privilege account.');
  stdout.writeln('  Use only on trusted networks.');
  stdout.writeln('');
  stdout.writeln('To stop: Ctrl+C');
}

// =============================================================================
// IPアドレス選択
// =============================================================================

Future<String> _selectIpAddress() async {
  final addresses = <String>[];
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        addresses.add(addr.address);
      }
    }
  } catch (_) {}

  if (addresses.isEmpty) return '0.0.0.0';
  if (addresses.length == 1) return addresses.first;

  if (stdin.hasTerminal && _isInteractiveForeground()) {
    stdout.writeln('Multiple network interfaces detected:');
    for (int i = 0; i < addresses.length; i++) {
      stdout.writeln('  [${i + 1}] ${addresses[i]}');
    }
    stdout.write('Select IP address [1-${addresses.length}] (default: 1): ');
    try {
      final input = stdin.readLineSync()?.trim();
      if (input != null && input.isNotEmpty) {
        final idx = int.tryParse(input);
        if (idx != null && idx >= 1 && idx <= addresses.length) {
          return addresses[idx - 1];
        }
      }
    } catch (_) {}
  } else {
    // Non-interactive mode (background launch with &, piped stdin, etc.).
    // Automatically select the first IP and inform the user via stdout.
    // Use --ip <address> to specify a different interface (#97).
    stdout.writeln('Multiple network interfaces detected. '
        'Running in non-interactive mode; auto-selecting ${addresses.first}.');
    stdout.writeln('Use --ip <address> to specify a different interface.');
  }

  return addresses.first;
}

// =============================================================================
// QRコード表示
// =============================================================================

void _printQrCode(String data) {
  final qrCode = QrCode.fromData(
    data: data,
    errorCorrectLevel: QrErrorCorrectLevel.L,
  );
  final qrImage = QrImage(qrCode);
  stdout.writeln('');
  for (int y = 0; y < qrImage.moduleCount; y++) {
    final buf = StringBuffer('  ');
    for (int x = 0; x < qrImage.moduleCount; x++) {
      buf.write(qrImage.isDark(y, x) ? '\u2588\u2588' : '  ');
    }
    stdout.writeln(buf.toString());
  }
}

// =============================================================================
// シグナルハンドラ・終了処理
// =============================================================================

bool _shuttingDown = false;


void _setupSignalHandlers(_CliServer server) {
  try {
    ProcessSignal.sigint.watch().listen((_) async {
      await _shutdown(server);
    });
  } catch (_) {}

  if (!Platform.isWindows) {
    for (final sig in [ProcessSignal.sigterm, ProcessSignal.sighup]) {
      try {
        sig.watch().listen((_) async {
          await _shutdown(server);
        });
      } catch (_) {}
    }
  }
}

Future<void> _waitForQuit(_CliServer server) async {
  // On Windows, avoid calling stdin.listen() as it causes PowerShell to treat
  // the process as background and show the prompt immediately (#140).
  // On other platforms, drain stdin silently to prevent buffered input from
  // leaking to the parent shell after exit.
  if (!Platform.isWindows) {
    if (stdin.hasTerminal) stdin.listen((_) {}, onError: (_) {});
  }
  await Completer<void>().future;
}

Future<void> _shutdown(_CliServer server) async {
  if (_shuttingDown) return;
  _shuttingDown = true;
  _restoreWindowsConsoleMode();
  _flushWindowsInput();
  stdout.writeln('');
  stdout.writeln('Shutting down...');
  await server.stop();
  stdout.writeln('Server stopped.');
  exit(0);
}

// =============================================================================
// クリップボードポーリング（コンソール出力）
// =============================================================================

Timer? _clipboardTimer;
int _lastClipboardModified = 0;

void _startClipboardPolling(_CliServer server) {
  _lastClipboardModified = server.clipboardLastModified;
  _clipboardTimer = Timer.periodic(const Duration(seconds: 2), (_) {
    final current = server.clipboardLastModified;
    if (current != _lastClipboardModified) {
      _lastClipboardModified = current;
      final items = server.clipboardItems;
      if (items.isNotEmpty) {
        final latest = items.first;
        stdout.writeln('');
        final tagLabel = latest.tag != null ? '[${latest.tag}] ' : '';
        stdout.writeln(
            '[Clipboard] $tagLabel${latest.createdAt.toLocal().toString().substring(11, 19)}');
        final text = latest.text;
        stdout.writeln('  ${text.length > 200 ? '${text.substring(0, 200)}...' : text}');
      }
    }
  });
}

// =============================================================================
// Windows コンソール制御（FFI）
// =============================================================================

/// Returns true if the process is in the foreground process group of its
/// controlling terminal. On Linux/macOS this detects background launch with &,
/// which causes stdin.hasTerminal to still return true but makes readLineSync
/// trigger SIGTTIN, stopping the process (#130).
/// Always returns true on Windows (not applicable).
bool _isInteractiveForeground() {
  if (Platform.isWindows) return true;
  try {
    final libc = DynamicLibrary.open(
        Platform.isMacOS ? 'libSystem.dylib' : 'libc.so.6');
    final tcgetpgrp = libc.lookupFunction<Int32 Function(Int32),
        int Function(int)>('tcgetpgrp');
    final getpgrp = libc.lookupFunction<Int32 Function(),
        int Function()>('getpgrp');
    return tcgetpgrp(0) == getpgrp();
  } catch (_) {
    return true;
  }
}

// =============================================================================
// HTTPS: SAN → ホスト名 → IP 解決 (#177, #169)
// =============================================================================

class _HttpsHostResult {
  final String bindIp;
  final String advertisedHost;
  _HttpsHostResult({required this.bindIp, required this.advertisedHost});
}

/// cert の SAN を解析し、バインド IP と広告ホストを決定する。
/// - SANのホスト名をデバイスIPに解決して候補を絞り込む
/// - 候補が1つなら自動決定、複数なら対話選択
/// - 一致しない場合はエラー終了 (#169)
Future<_HttpsHostResult> _resolveHttpsHost({
  required String certPath,
  String? specifiedIp,
}) async {
  // SAN を解析
  List<String> sans = [];
  try {
    final raw = await File(certPath).readAsString();
    final begin = '-----BEGIN CERTIFICATE-----';
    final end = '-----END CERTIFICATE-----';
    final startIdx = raw.indexOf(begin);
    final endIdx = startIdx >= 0 ? raw.indexOf(end, startIdx) : -1;
    if (startIdx >= 0 && endIdx >= 0) {
      final pem = raw.substring(startIdx, endIdx + end.length);
      final cert = X509Utils.x509CertificateFromPem(pem);
      sans = cert.subjectAlternativNames ?? [];
    }
  } catch (e) {
    stderr.writeln('Warning: Failed to parse certificate SANs: $e');
  }

  if (sans.isEmpty) {
    stderr.writeln('Error: No SANs found in certificate. Cannot determine HTTPS hostname.');
    exit(1);
  }

  // デバイスの IP 一覧を取得
  final deviceIps = <String>{};
  try {
    for (final iface in await NetworkInterface.list()) {
      for (final addr in iface.addresses) {
        deviceIps.add(addr.address);
      }
    }
  } catch (_) {}

  // --ip 指定時はその IP が SAN に含まれるか検証 (#169)
  if (specifiedIp != null) {
    bool covered = sans.contains(specifiedIp);
    if (!covered) {
      // ホスト名 SAN を DNS 解決して照合
      for (final san in sans) {
        if (InternetAddress.tryParse(san) == null) {
          try {
            final addrs = await InternetAddress.lookup(san);
            if (addrs.any((a) => a.address == specifiedIp)) {
              covered = true;
              break;
            }
          } catch (_) {}
        }
      }
    }
    if (!covered) {
      stderr.writeln(
          'Error: The certificate does not cover the specified IP "$specifiedIp".');
      stderr.writeln('  Certificate SANs: ${sans.join(', ')}');
      exit(1);
    }
    return _HttpsHostResult(bindIp: specifiedIp, advertisedHost: specifiedIp);
  }

  // SAN のホスト名をデバイス IP に解決して候補を抽出
  final candidates = <({String host, String ip})>[];
  for (final san in sans) {
    if (InternetAddress.tryParse(san) != null) {
      // IP SAN: デバイス IP と一致するか確認
      if (deviceIps.contains(san)) {
        candidates.add((host: san, ip: san));
      }
    } else {
      // ホスト名 SAN: DNS 解決してデバイス IP と照合
      try {
        final addrs = await InternetAddress.lookup(san);
        for (final addr in addrs) {
          if (deviceIps.contains(addr.address)) {
            candidates.add((host: san, ip: addr.address));
            break;
          }
        }
      } catch (_) {}
    }
  }

  if (candidates.isEmpty) {
    stderr.writeln(
        'Error: Certificate SANs do not match any device IP address. Cannot start HTTPS server.');
    stderr.writeln('  Certificate SANs: ${sans.join(', ')}');
    stderr.writeln('  Device IPs: ${deviceIps.join(', ')}');
    stderr.writeln('  Use --ip <address> to override, or fix the certificate.');
    exit(1);
  }

  // #234: SAN に hostname と IP の両方あるときは hostname を優先 (ブラウザ警告回避)
  final hostnameCandidates =
      candidates.where((c) => InternetAddress.tryParse(c.host) == null).toList();
  if (hostnameCandidates.length == 1) {
    final c = hostnameCandidates.first;
    stdout.writeln('HTTPS: Using "${c.host}" (resolved to ${c.ip})');
    return _HttpsHostResult(bindIp: c.ip, advertisedHost: c.host);
  }
  if (hostnameCandidates.isEmpty && candidates.length == 1) {
    // SAN が IP のみ → IP をそのまま使う (互換動作)
    final c = candidates.first;
    stdout.writeln('HTTPS: Using "${c.host}" (resolved to ${c.ip})');
    return _HttpsHostResult(bindIp: c.ip, advertisedHost: c.host);
  }

  // 複数候補 → 対話選択 (hostname を先頭に並べ替えて優先度を視認しやすく)
  candidates.sort((a, b) {
    final aIsHost = InternetAddress.tryParse(a.host) == null;
    final bIsHost = InternetAddress.tryParse(b.host) == null;
    if (aIsHost == bIsHost) return 0;
    return aIsHost ? -1 : 1;
  });
  if (stdin.hasTerminal && _isInteractiveForeground()) {
    stdout.writeln('Multiple HTTPS hostname candidates detected:');
    for (int i = 0; i < candidates.length; i++) {
      final c = candidates[i];
      stdout.writeln('  [${i + 1}] ${c.host} (${c.ip})');
    }
    stdout.write('Select [1-${candidates.length}] (default: 1): ');
    try {
      final input = stdin.readLineSync()?.trim();
      if (input != null && input.isNotEmpty) {
        final idx = int.tryParse(input);
        if (idx != null && idx >= 1 && idx <= candidates.length) {
          final c = candidates[idx - 1];
          return _HttpsHostResult(bindIp: c.ip, advertisedHost: c.host);
        }
      }
    } catch (_) {}
  }
  final c = candidates.first;
  stdout.writeln('HTTPS: Auto-selecting "${c.host}" (${c.ip})');
  return _HttpsHostResult(bindIp: c.ip, advertisedHost: c.host);
}

// =============================================================================
// 端末識別 UUID (#218 / §1.11)
// =============================================================================
//
// federation 参加時の固定識別子。初回起動で生成し、再起動越しに保持する。
// 表示名（`server.name`）は mutable だが、UUID は immutable。federation
// イベントの `origin_device_id` / `seen_by` (#221) や、peer 認証時の
// 内部キーとして使う。
//
// 保存先:
//   POSIX: $XDG_STATE_HOME/localnode-cli/state.json （無ければ ~/.local/state/...）
//   Win:   %LOCALAPPDATA%\localnode-cli\state.json
//   または --state-file <path> で明示指定

String _defaultStateFilePath() {
  if (Platform.isWindows) {
    final base = Platform.environment['LOCALAPPDATA'] ??
        p.join(Platform.environment['USERPROFILE'] ?? '.', 'AppData', 'Local');
    return p.join(base, 'localnode-cli', 'state.json');
  }
  final xdg = Platform.environment['XDG_STATE_HOME'];
  if (xdg != null && xdg.isNotEmpty) {
    return p.join(xdg, 'localnode-cli', 'state.json');
  }
  final home = Platform.environment['HOME'] ?? '.';
  return p.join(home, '.local', 'state', 'localnode-cli', 'state.json');
}

/// UUID v4 (random) を生成して `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` 形式で返す。
String _generateUuidV4() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  // version (4) と variant (10xx)
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// state.json から `device_id` を読む。無ければ生成して書き、書いた値を返す。
String _loadOrCreateDeviceId(String statePath) {
  final file = File(statePath);
  if (file.existsSync()) {
    try {
      final raw = file.readAsStringSync();
      final dec = json.decode(raw);
      if (dec is Map && dec['device_id'] is String) {
        final id = dec['device_id'] as String;
        if (id.isNotEmpty) return id;
      }
    } catch (_) {
      // 破損していたら作り直す
    }
  }
  final id = _generateUuidV4();
  try {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(json.encode({'device_id': id}), flush: true);
  } catch (e) {
    stderr.writeln('Warning: Could not persist device_id to $statePath: $e');
    stderr.writeln('Federation pairing may not survive a restart with this server.');
  }
  return id;
}

/// ランダムなアップロードトークンを生成する（32文字の16進数）
String _generateUploadToken() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

void _flushWindowsInput() {
  if (!Platform.isWindows) return;
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getHandle = kernel32.lookupFunction<IntPtr Function(Uint32),
        int Function(int)>('GetStdHandle');
    final flush = kernel32.lookupFunction<Int32 Function(IntPtr),
        int Function(int)>('FlushConsoleInputBuffer');
    flush(getHandle(0xFFFFFFF6));
  } catch (_) {}
}

void _restoreWindowsConsoleMode() {
  if (!Platform.isWindows) return;
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getHandle = kernel32.lookupFunction<IntPtr Function(Uint32),
        int Function(int)>('GetStdHandle');
    final setMode = kernel32.lookupFunction<Int32 Function(IntPtr, Uint32),
        int Function(int, int)>('SetConsoleMode');
    setMode(getHandle(0xFFFFFFF6), 0x0007);
  } catch (_) {}
}

/// Disable echo and line-input so typed characters don't appear on screen
/// while the server is running (#139). ENABLE_PROCESSED_INPUT (0x1) is kept
/// so that Ctrl+C continues to work.
void _setWindowsConsoleRawMode() {
  if (!Platform.isWindows) return;
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getHandle = kernel32.lookupFunction<IntPtr Function(Uint32),
        int Function(int)>('GetStdHandle');
    final setMode = kernel32.lookupFunction<Int32 Function(IntPtr, Uint32),
        int Function(int, int)>('SetConsoleMode');
    // ENABLE_PROCESSED_INPUT (0x1) only: disables ENABLE_LINE_INPUT and ENABLE_ECHO_INPUT
    setMode(getHandle(0xFFFFFFF6), 0x0001);
  } catch (_) {}
}

// =============================================================================
// 認証モード
// =============================================================================

enum _AuthMode { randomPin, fixedPin, noPin }

// =============================================================================
// クリップボードアイテム
// =============================================================================

class _ClipboardItem {
  final String id;
  final String text;
  final String? tag;
  final DateTime createdAt;
  // #220 / #230: @up でマーク済みの重要アイテム
  final bool important;

  _ClipboardItem({
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

// =============================================================================
// CLI サーバー（GTK/Flutter 非依存）
// =============================================================================

/// #222: federation peer の動的状態
class _FederationPeer {
  final String kind; // 'child' or 'parent'
  final String name;
  final String url;
  final String token;
  final String relation;
  // #219: friendly + trust:true で「親に渡したら子側削除」 (parent peer 設定のみ意味あり)
  final bool trust;
  // #219: 子→親アップロードの 1 回の最大バイト数 (child peer 設定のみ意味あり)
  final int? maxUploadSizeBytes;
  String? learnedDeviceId; // /api/info から学習
  String? learnedRelation; // heartbeat で相手から学習した relation
  String status = 'unknown'; // 'connected' / 'offline' / 'paused' / 'relation-mismatch'
  int lastOkMs = 0;
  int lastTryMs = 0;
  String? lastError;
  // #223: pause まで有効な時刻 (epoch ms)。0 なら pause していない。
  int pauseUntilMs = 0;

  bool isPaused() {
    if (pauseUntilMs == 0) return false;
    return DateTime.now().millisecondsSinceEpoch < pauseUntilMs;
  }

  _FederationPeer({
    required this.kind,
    required this.name,
    required this.url,
    required this.token,
    required this.relation,
    this.trust = false,
    this.maxUploadSizeBytes,
  });

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'name': name,
        'url': url,
        'relation': relation,
        'trust': trust,
        if (maxUploadSizeBytes != null) 'maxUploadSizeBytes': maxUploadSizeBytes,
        'status': status,
        'lastOkMs': lastOkMs,
        'lastTryMs': lastTryMs,
        'learnedDeviceId': learnedDeviceId,
        'learnedRelation': learnedRelation,
        'lastError': lastError,
        'pauseUntilMs': pauseUntilMs,
      };
}

/// #219: "100MB" / "5GB" / "1024" 等を bytes に変換 (大文字小文字無視)
int? _parseSizeBytes(dynamic raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  final s = raw.toString().trim();
  final m = RegExp(r'^(\d+(?:\.\d+)?)\s*([kmgtKMGT]?)[bB]?$').firstMatch(s);
  if (m == null) return null;
  final num = double.parse(m.group(1)!);
  final unit = m.group(2)!.toUpperCase();
  const mult = {'': 1, 'K': 1024, 'M': 1024 * 1024, 'G': 1024 * 1024 * 1024, 'T': 1024 * 1024 * 1024 * 1024};
  return (num * mult[unit]!).toInt();
}

class _CliServer {
  // #227: clipboard 件数 / 文字長は config から指定可能 (デフォルト 1000 / 10000)
  final int _maxClipboardItems;
  final int _maxTextLength;
  static const int _maxFailedAttempts = 5;
  static const Duration _lockoutDuration = Duration(minutes: 5);

  // #218 / §1.11: 端末識別 UUID
  final String _deviceId;

  // #222: federation peer の動的状態とハートビートタイマ
  final List<_FederationPeer> _federationPeers = [];
  Timer? _heartbeatTimer;
  HttpClient? _heartbeatClient;
  static const Duration _heartbeatInterval = Duration(seconds: 45);

  final bool verbose;
  HttpServer? _server;
  String? _pin;
  _AuthMode _authMode = _AuthMode.randomPin;
  bool _downloadOnly = false;
  bool _clipboardEnabled = true;
  String _serverName = 'LocalNode';
  int _startedAt = 0;

  String? _storagePath;
  Directory? _webRootDir;
  Directory? _thumbnailCacheDir;
  late final Uint8List _placeholderThumbBytes = _buildPlaceholderJpeg();

  final List<_ClipboardItem> _clipboardItems = [];
  int _clipboardLastModified = 0;
  // #228: 削除リングバッファ。?since= で「自分が見た時刻以降」の削除を返す。
  // bound あり (200)。これより古い削除があるとクライアントは full refresh。
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

  // #230: クリップボード件数超過時の退避。非 important から先に削る。
  // 全部 important なら最古の important を退避（ハードピンしない）。
  // 退避した item を返す。
  _ClipboardItem _evictClipboardItem() {
    // list は新しい順 (insert(0, ...)) なので末尾が最古
    // 末尾から最初に見つかった非 important を取り除く
    for (var i = _clipboardItems.length - 1; i >= 0; i--) {
      if (!_clipboardItems[i].important) {
        return _clipboardItems.removeAt(i);
      }
    }
    // 全て important: 最古を退避
    return _clipboardItems.removeLast();
  }

  final Set<String> _sessions = {};
  final Map<String, int> _failedAttempts = {};
  final Map<String, DateTime> _lockoutUntil = {};
  String? _uploadToken;
  List<({String pattern, String script})> _postActions = [];
  Map<String, ({String script, String? description})> _mentionActions = {};
  // #206
  int _pinLength = 4;
  String _pinCharset = 'digits';

  late final Router _router;

  String? get pin => _pin;
  List<_ClipboardItem> get clipboardItems => List.unmodifiable(_clipboardItems);
  int get clipboardLastModified => _clipboardLastModified;

  _CliServer({
    required this.verbose,
    int maxClipboardItems = 1000,
    int maxTextLength = 10000,
    String? deviceId,
  })  : _maxClipboardItems = maxClipboardItems,
        _maxTextLength = maxTextLength,
        _deviceId = deviceId ?? '' {
    _router = Router()
      ..post('/api/auth', _authHandler)
      ..get('/api/health', _healthHandler)
      ..get('/api/info', _infoHandler)
      ..get('/api/check-auth', _checkAuthHandler)
      ..get('/api/files', _getFilesHandler)
      ..post('/api/upload', _uploadHandler)
      ..get('/api/download/<id>', _downloadHandler)
      ..get('/api/thumbnail/<id>', _thumbnailHandler)
      ..get('/api/thumbnail-by-path', _thumbnailByPathHandler)
      ..get('/api/text-preview/<id>', _textPreviewHandler)
      ..get('/api/download-all', _downloadAllHandler)
      ..delete('/api/files/<id>', _deleteFileHandler)
      ..post('/api/files/delete-batch', _deleteBatchHandler)
      ..get('/api/clipboard', _getClipboardHandler)
      ..get('/api/mentions', _mentionsHandler)  // #225
      ..post('/api/clipboard', _postClipboardHandler)
      ..delete('/api/clipboard/<id>', _deleteClipboardItemHandler)
      ..delete('/api/clipboard', _clearClipboardHandler)
      // #222: federation 状態（peer 一覧と接続状態）
      ..get('/api/federation/status', _federationStatusHandler)
      ..post('/api/federation/peers/<name>/pause', _federationPausePeerHandler)  // #223
      ..delete('/api/federation/peers/<name>/pause', _federationResumePeerHandler);  // #223
  }

  /// #222: federation peer を起動前に登録する
  void registerFederationPeer(_FederationPeer peer) {
    _federationPeers.add(peer);
  }

  // #225: mobile mention picker — structured form of `@list` content
  Response _mentionsHandler(Request _) {
    final items = <Map<String, dynamic>>[
      {
        'label': '@list',
        'insert': '@list',
        'description': 'show this list',
      },
    ];
    // #240: federation 設定があるときは予約 mention も含める
    final hasChildren = _federationPeers.any((p) => p.kind == 'child');
    final hasParent = _federationPeers.any((p) => p.kind == 'parent');
    if (hasChildren) {
      items.add({
        'label': '@list <child>',
        'insert': '@list ',
        'description': "fetch a child's mention list",
      });
      items.add({
        'label': '@to <child|all> <message>',
        'insert': '@to ',
        'description': "post to a child's clipboard",
      });
      items.add({
        'label': '@run_to <child> <alias>',
        'insert': '@run_to ',
        'description': 'run @run on a child',
      });
    }
    if (hasParent) {
      items.add({
        'label': '@up <message>',
        'insert': '@up ',
        'description': 'mark as important (forwarded under equally relation)',
      });
    }
    for (final e in _mentionActions.entries) {
      items.add({
        'label': '@run ${e.key}',
        'insert': '@run ${e.key}',
        'description': e.value.description,
      });
    }
    return Response.ok(
      json.encode({'items': items}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Response _federationStatusHandler(Request _) => Response.ok(
        json.encode({
          'deviceId': _deviceId,
          'peers': _federationPeers.map((p) => p.toJson()).toList(),
          'heartbeatIntervalSec': _heartbeatInterval.inSeconds,
        }),
        headers: {'Content-Type': 'application/json'},
      );

  // #223: peer pause / resume
  Response _federationPausePeerHandler(Request req, String name) {
    final peer = _federationPeers.firstWhereOrNullExt((p) => p.name == name);
    if (peer == null) return Response.notFound('Peer not found.');
    final durStr = req.requestedUri.queryParameters['duration'];
    final dur = int.tryParse(durStr ?? '');
    // 許容プリセット (秒): 30min / 1h / 3h / 12h / 24h
    const allowed = {1800, 3600, 10800, 43200, 86400};
    if (dur == null || !allowed.contains(dur)) {
      return Response.badRequest(
          body: 'duration must be one of 1800/3600/10800/43200/86400 (seconds)');
    }
    peer.pauseUntilMs =
        DateTime.now().millisecondsSinceEpoch + dur * 1000;
    peer.status = 'paused';
    _log('[fed] pause ${peer.name} until=${peer.pauseUntilMs}');
    return Response.ok(
      json.encode({'paused': true, 'pauseUntilMs': peer.pauseUntilMs}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Response _federationResumePeerHandler(Request _, String name) {
    final peer = _federationPeers.firstWhereOrNullExt((p) => p.name == name);
    if (peer == null) return Response.notFound('Peer not found.');
    peer.pauseUntilMs = 0;
    // 次の heartbeat で正しい status に更新される
    peer.status = 'unknown';
    _log('[fed] resume ${peer.name}');
    return Response.ok(
      json.encode({'paused': false}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  /// #222: 全 peer に GET /api/health を投げて状態を更新
  Future<void> _heartbeatTick() async {
    if (_federationPeers.isEmpty) return;
    _heartbeatClient ??= HttpClient()..connectionTimeout = const Duration(seconds: 10);
    for (final peer in _federationPeers) {
      // pause 中は heartbeat だけ続ける（生死表示用）
      try {
        peer.lastTryMs = DateTime.now().millisecondsSinceEpoch;
        final uri = Uri.parse('${peer.url}/api/health');
        final req = await _heartbeatClient!.getUrl(uri);
        req.headers.set('Authorization', 'Bearer ${peer.token}');
        // #221: ループ防止のため自分の id を seen_by に乗せる
        req.headers.set(_kFedOrigin, _deviceId);
        req.headers.set(_kFedSeenBy, _deviceId);
        // spec §1.3: 相手に自分の relation を通知し、相手側の healthHandler が
        // こちらの設定値を返すことで双方一致を検証できるようにする。
        req.headers.set(_kFedRelation, peer.relation);
        final res = await req.close().timeout(const Duration(seconds: 10));
        if (res.statusCode >= 200 && res.statusCode < 300) {
          peer.lastOkMs = DateTime.now().millisecondsSinceEpoch;
          // レスポンスボディから相手の relation 設定を学習する
          try {
            final body = await res.transform(utf8.decoder).join();
            final dec = json.decode(body);
            if (dec is Map && dec['relation'] is String) {
              peer.learnedRelation = dec['relation'] as String;
            }
          } catch (_) {
            await res.drain();
          }
          // relation 不一致なら専用ステータスに設定
          if (peer.learnedRelation != null &&
              peer.learnedRelation != peer.relation) {
            peer.status = 'relation-mismatch';
          } else if (peer.isPaused()) {
            peer.status = 'paused';
          } else {
            peer.status = 'connected';
          }
          peer.lastError = null;
        } else {
          await res.drain();
          peer.status = peer.isPaused() ? 'paused' : 'offline';
          peer.lastError = 'HTTP ${res.statusCode}';
        }
        // peer の deviceId を学習（/api/info を別途叩く）。負荷軽減のためおおむね 10 回に1回
        if (peer.learnedDeviceId == null) {
          try {
            final iReq = await _heartbeatClient!.getUrl(Uri.parse('${peer.url}/api/info'));
            iReq.headers.set('Authorization', 'Bearer ${peer.token}');
            final iRes = await iReq.close().timeout(const Duration(seconds: 5));
            if (iRes.statusCode == 200) {
              final body = await iRes.transform(utf8.decoder).join();
              final dec = json.decode(body);
              if (dec is Map && dec['deviceId'] is String) {
                peer.learnedDeviceId = dec['deviceId'] as String;
              }
            } else {
              await iRes.drain();
            }
          } catch (_) {}
        }
        _log('[fed] heartbeat ${peer.name} ${peer.status}');
      } catch (e) {
        // pause 中でも heartbeat 自体は流す。失敗時は status を offline にするが、
        // pause が有効ならその表示を優先
        peer.status = peer.isPaused() ? 'paused' : 'offline';
        peer.lastError = e.toString();
        _log('[fed] heartbeat ${peer.name} offline: $e');
      }
    }
  }

  // #243: 起動直後だけバックオフを詰めて、Tailscale 等で初回 dial が
  //       冷えていてもユーザを 45 秒待たせない。一巡したら通常の 45 秒周期へ。
  static const List<int> _warmupDelaysSec = [5, 10, 20, 30, 45];
  int _warmupTick = 0;

  void _startHeartbeat() {
    if (_federationPeers.isEmpty) return;
    _warmupTick = 0;
    Future.microtask(() async {
      await _heartbeatTick();
      _scheduleNextHeartbeat();
    });
  }

  void _scheduleNextHeartbeat() {
    if (_heartbeatStopped) return;
    final delay = _warmupTick < _warmupDelaysSec.length
        ? Duration(seconds: _warmupDelaysSec[_warmupTick])
        : _heartbeatInterval;
    _warmupTick++;
    _heartbeatTimer = Timer(delay, () async {
      if (_heartbeatStopped) return;
      await _heartbeatTick();
      _scheduleNextHeartbeat();
    });
  }

  bool _heartbeatStopped = false;

  void _stopHeartbeat() {
    _heartbeatStopped = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatClient?.close(force: true);
    _heartbeatClient = null;
  }

  // ---------------------------------------------------------------------------
  // #219: federation event 転送 (子 → 親)
  // ---------------------------------------------------------------------------

  static const String _kFedEvent = 'x-fed-event';

  bool _isUpItem(String text) => text.trimLeft().startsWith('@up ');

  bool _comesFromFederation(Request req) =>
      req.headers[_kFedSeenBy] != null;

  /// 子→親の clipboard 転送 (fire-and-forget)
  /// - 受信時に federation 由来 (seen_by あり) なら再転送しない
  /// - peer.kind=='parent' のみ
  /// - relation=='equally' は `@up` 付きだけ転送
  void _forwardClipboardToParents(_ClipboardItem item, Request originReq) {
    if (_comesFromFederation(originReq)) return;
    if (_deviceId.isEmpty) return;
    if (_federationPeers.isEmpty) return;

    final isUp = _isUpItem(item.text);
    for (final peer in _federationPeers) {
      if (peer.kind != 'parent') continue;
      if (peer.relation == 'equally' && !isUp) continue;
      // fire-and-forget
      () async {
        try {
          await _sendClipboardToPeer(peer, item, isUp);
        } catch (e) {
          _log('[fed] forward-clip ${peer.name} unexpected: $e');
        }
      }();
    }
  }

  /// 子→親の file upload 転送 (fire-and-forget)
  /// - friendly: 実ファイルを送信。成功 + trust なら local 削除
  /// - equally: 「@up file uploaded: <name>」を clipboard 通知のみ
  void _forwardFileToParents(File file, Request originReq) {
    if (_comesFromFederation(originReq)) return;
    if (_deviceId.isEmpty) return;
    if (_federationPeers.isEmpty) return;

    for (final peer in _federationPeers) {
      if (peer.kind != 'parent') continue;
      () async {
        try {
          if (peer.relation == 'equally') {
            // 通知のみ
            final basename = p.basename(file.path);
            final notice = _ClipboardItem(
              id: _generateId(),
              text: '@up file uploaded: $basename',
              tag: _serverName,
              createdAt: DateTime.now(),
            );
            await _sendClipboardToPeer(peer, notice, true);
            return;
          }
          // friendly: 実ファイル送信
          final ok = await _sendFileToPeer(peer, file);
          if (ok && peer.trust) {
            try {
              await file.delete();
              _log('[fed] forward-file ${peer.name} ok, local deleted (trust)');
            } catch (e) {
              _log('[fed] forward-file ${peer.name} local-delete fail: $e');
            }
          }
        } catch (e) {
          _log('[fed] forward-file ${peer.name} unexpected: $e');
        }
      }();
    }
  }

  Future<void> _sendClipboardToPeer(
      _FederationPeer peer, _ClipboardItem item, bool isUp) async {
    // #223: pause 中はサイレントに skip
    if (peer.isPaused()) {
      _log('[fed] paused-skip clip ${peer.name}');
      return;
    }
    _heartbeatClient ??=
        HttpClient()..connectionTimeout = const Duration(seconds: 10);
    final uri = Uri.parse('${peer.url}/api/clipboard');

    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final req = await _heartbeatClient!.postUrl(uri);
        req.headers.set('Content-Type', 'application/json');
        req.headers.set('Authorization', 'Bearer ${peer.token}');
        req.headers.set(_kFedOrigin, _deviceId);
        req.headers.set(_kFedSeenBy, _deviceId);
        req.headers.set(_kFedEvent, 'clipboard');
        req.headers.set(_kFedRelation, peer.relation);
        req.add(utf8.encode(json.encode({
          'text': item.text,
          // tag: 親側で「どの子から」かが分かるよう自サーバ名を入れる
          'tag': _serverName,
        })));
        final res = await req.close().timeout(const Duration(seconds: 15));
        await res.drain();

        if (res.statusCode >= 200 && res.statusCode < 300) {
          _log('[fed] forward-clip ${peer.name} ok attempt=$attempt up=$isUp');
          return;
        }
        _log('[fed] forward-clip ${peer.name} HTTP ${res.statusCode} attempt=$attempt');
        // 4xx (408 除く) は retry しない
        if (res.statusCode >= 400 &&
            res.statusCode < 500 &&
            res.statusCode != 408) {
          break;
        }
      } catch (e) {
        _log('[fed] forward-clip ${peer.name} error attempt=$attempt: $e');
      }
      if (attempt < 3) {
        await Future.delayed(Duration(seconds: 2 * attempt));
      }
    }
    _log('[fed] forward-clip ${peer.name} gave-up');
  }

  Future<bool> _sendFileToPeer(_FederationPeer peer, File file) async {
    // #223: pause 中は skip
    if (peer.isPaused()) {
      _log('[fed] paused-skip file ${peer.name}');
      return false;
    }
    _heartbeatClient ??=
        HttpClient()..connectionTimeout = const Duration(seconds: 10);
    final filename = p.basename(file.path);
    final pathParam = Uri.encodeComponent('children/$_serverName');
    final uri = Uri.parse('${peer.url}/api/upload?path=$pathParam');

    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final length = await file.length();
        final req = await _heartbeatClient!.postUrl(uri);
        req.headers.set('Content-Type', 'application/octet-stream');
        req.headers.set('Authorization', 'Bearer ${peer.token}');
        req.headers.set('x-filename', Uri.encodeComponent(filename));
        req.headers.set(_kFedOrigin, _deviceId);
        req.headers.set(_kFedSeenBy, _deviceId);
        req.headers.set(_kFedEvent, 'upload');
        req.headers.set(_kFedRelation, peer.relation);
        req.contentLength = length;
        await req.addStream(file.openRead());
        final res = await req.close().timeout(const Duration(minutes: 5));
        await res.drain();

        if (res.statusCode >= 200 && res.statusCode < 300) {
          _log('[fed] forward-file ${peer.name} ok attempt=$attempt bytes=$length');
          return true;
        }
        _log('[fed] forward-file ${peer.name} HTTP ${res.statusCode} attempt=$attempt');
        if (res.statusCode == 413) {
          _log('[fed] over-quota ${peer.name} (skip)');
          return false;
        }
        if (res.statusCode >= 400 &&
            res.statusCode < 500 &&
            res.statusCode != 408) {
          return false;
        }
      } catch (e) {
        _log('[fed] forward-file ${peer.name} error attempt=$attempt: $e');
      }
      if (attempt < 3) {
        await Future.delayed(Duration(seconds: 2 * attempt));
      }
    }
    _log('[fed] forward-file ${peer.name} gave-up');
    return false;
  }

  /// 親側: 受信したアップロードが federation 由来 + サイズ超過なら 413
  /// child の deviceId と peer 学習結果を突き合わせて配下の max_upload_size を引く。
  /// 学習未了なら制限なしとして通す。
  Response? _checkFederationUploadQuota(Request req, int contentLength) {
    final origin = req.headers[_kFedOrigin];
    if (origin == null || origin.isEmpty) return null;
    for (final peer in _federationPeers) {
      if (peer.kind != 'child') continue;
      if (peer.learnedDeviceId != origin) continue;
      final cap = peer.maxUploadSizeBytes;
      if (cap != null && contentLength > cap) {
        _log('[fed] over-quota ${peer.name} bytes=$contentLength cap=$cap');
        // 通知: 自分の clipboard に 1 件残す (受信者側で気付けるように)
        _clipboardItems.insert(
          0,
          _ClipboardItem(
            id: _generateId(),
            text:
                '@up over-quota from ${peer.name}: bytes=$contentLength cap=$cap',
            tag: 'federation',
            createdAt: DateTime.now(),
          ),
        );
        while (_clipboardItems.length > _maxClipboardItems) {
          final ev = _evictClipboardItem();
          _recordDeletion(ev.id);
        }
        _clipboardLastModified = DateTime.now().millisecondsSinceEpoch;
        return Response(413, body: 'Federation upload over quota.');
      }
    }
    return null;
  }

  void _log(String message) {
    if (verbose) print(message);
  }

  // --- 起動 ---

  Future<void> start({
    required String ipAddress,
    required int port,
    String? storagePath,
    bool downloadOnly = false,
    _AuthMode authMode = _AuthMode.randomPin,
    String? fixedPin,
    int pinLength = 4,             // #206
    String pinCharset = 'digits',  // #206
    String serverName = 'LocalNode',
    bool clipboardEnabled = true,
    String? httpsCertPath,
    String? httpsKeyPath,
    String? uploadToken,
    List<({String pattern, String script})> postActions = const [],
    Map<String, ({String script, String? description})> mentionActions = const {},
  }) async {
    _authMode = authMode;
    _downloadOnly = downloadOnly;
    _uploadToken = uploadToken;
    _postActions = postActions;
    _mentionActions = mentionActions;
    _clipboardEnabled = clipboardEnabled;
    _serverName = serverName;
    _pinLength = pinLength;       // #206
    _pinCharset = pinCharset;     // #206
    _startedAt = DateTime.now().millisecondsSinceEpoch;

    switch (authMode) {
      case _AuthMode.randomPin:
        _pin = _generatePin();
      case _AuthMode.fixedPin:
        _pin = fixedPin ?? _generatePin();
      case _AuthMode.noPin:
        _pin = null;
    }

    await _init(storagePath);
    await _deployAssets();

    final staticHandler =
        createStaticHandler(_webRootDir!.path, defaultDocument: 'index.html');
    final apiHandler = const Pipeline()
        .addMiddleware(_federationLoopGuard)  // #221
        .addMiddleware(_authMiddleware)
        .addHandler(_router.call);
    final cascade = Cascade().add(apiHandler).add(staticHandler);

    final handler = verbose
        ? const Pipeline()
            .addMiddleware(logRequests())
            .addHandler(cascade.handler)
        : const Pipeline().addHandler(cascade.handler);

    if (httpsCertPath != null && httpsKeyPath != null) {
      final secCtx = SecurityContext()
        ..useCertificateChain(httpsCertPath)
        ..usePrivateKey(httpsKeyPath);
      _server = await shelf_io.serve(
        handler, InternetAddress.anyIPv4, port,
        securityContext: secCtx,
      );
      _log('Serving at https://$ipAddress:$port');
    } else {
      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
      _log('Serving at http://$ipAddress:$port');
    }
  }

  Future<void> stop() async {
    _stopHeartbeat();
    await _server?.close(force: true);
    _server = null;
    // #242: 自分用 deploy dir を後片付け。異常終了で残った場合は
    //       次回起動の _reapStaleDeployDirs が拾うので best-effort で OK。
    try {
      final d = _webRootDir;
      if (d != null && await d.exists()) {
        await d.delete(recursive: true);
      }
    } catch (_) {}
  }

  // #242: 同プレフィックスのきょうだいディレクトリのうち、対応する PID が
  //       生きていないものを削除する。長寿の常駐サーバを巻き込まないよう
  //       mtime ベースの judge は使わず、PID 生存チェック一本でいく。
  void _reapStaleDeployDirs(Directory base, String prefix) {
    if (!base.existsSync()) return;
    final myPid = pid;
    for (final entry in base.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (!name.startsWith(prefix)) continue;
      final pidStr = name.substring(prefix.length);
      final otherPid = int.tryParse(pidStr);
      if (otherPid == null || otherPid == myPid) continue;
      if (_isProcessAlive(otherPid)) continue;
      try {
        entry.deleteSync(recursive: true);
      } catch (_) {
        // best-effort; permission / race losers are ignored
      }
    }
  }

  bool _isProcessAlive(int otherPid) {
    if (otherPid <= 0) return false;
    if (Platform.isWindows) {
      try {
        final r = Process.runSync(
            'tasklist', ['/NH', '/FI', 'PID eq $otherPid'],
            runInShell: false);
        // `INFO: No tasks ...` が返ったら死んでる扱い
        final out = r.stdout as String;
        return !out.contains('No tasks') && out.contains('$otherPid');
      } catch (_) {
        return true; // 判定不能なら安全側 (消さない)
      }
    }
    // POSIX: ps -p で exit 0 なら生存
    try {
      final r = Process.runSync('ps', ['-p', '$otherPid'], runInShell: false);
      return r.exitCode == 0;
    } catch (_) {
      return true;
    }
  }

  // --- 初期化 ---

  Future<void> _init(String? storagePath) async {
    if (storagePath != null) {
      _storagePath = storagePath;
    } else {
      _storagePath = Directory.current.path;
    }

    final dir = Directory(_storagePath!);
    if (!await dir.exists()) await dir.create(recursive: true);

    final tmpBase = Platform.environment['TMPDIR'] ??
        Platform.environment['TEMP'] ??
        '/tmp';
    _thumbnailCacheDir =
        Directory(p.join(tmpBase, 'localnode_cli_thumbnails'));
    if (!await _thumbnailCacheDir!.exists()) {
      await _thumbnailCacheDir!.create(recursive: true);
    }
  }

  Future<void> _deployAssets() async {
    final tmpBase = Platform.environment['TMPDIR'] ??
        Platform.environment['TEMP'] ??
        '/tmp';
    // #242: 同一ホストでの複数 LocalNode 共存を許す。
    // 固定パスだと後発の起動が先発の serving content を上書きするため
    // PID を混ぜたユニーク dir に展開する。
    const prefix = 'localnode_cli_web_';
    _reapStaleDeployDirs(Directory(tmpBase), prefix);
    _webRootDir = Directory(p.join(tmpBase, '$prefix$pid'));
    if (await _webRootDir!.exists()) {
      await _webRootDir!.delete(recursive: true);
    }
    await _webRootDir!.create(recursive: true);

    final exeDir = p.dirname(Platform.resolvedExecutable);
    final candidates = [
      // Linux bundle: data/flutter_assets/assets/web/index.html
      p.join(exeDir, 'data', 'flutter_assets', 'assets', 'web', 'index.html'),
      // Windows bundle
      p.join(exeDir, 'data', 'flutter_assets', 'assets', 'web', 'index.html'),
      // macOS .app
      p.join(exeDir, '..', 'Frameworks', 'App.framework', 'Versions', 'A',
          'Resources', 'flutter_assets', 'assets', 'web', 'index.html'),
      // generic fallback
      p.join(exeDir, 'assets', 'web', 'index.html'),
      p.join(Directory.current.path, 'assets', 'web', 'index.html'),
    ];

    File? src;
    for (final candidate in candidates) {
      final f = File(candidate);
      if (f.existsSync()) {
        src = f;
        break;
      }
    }

    final dest = File(p.join(_webRootDir!.path, 'index.html'));
    if (src != null) {
      await src.copy(dest.path);
    } else {
      await dest.writeAsString(_minimalHtml());
      stderr.writeln('Warning: Web assets not found. Using minimal HTML.');
    }
  }

  String _minimalHtml() => '''<!DOCTYPE html>
<html><head><meta charset="UTF-8">
<title>LocalNode</title></head>
<body><h1>LocalNode Server</h1><p>Web UI assets not found.</p></body>
</html>''';

  // --- ユーティリティ ---

  // #206: configurable length (4..8) and charset (digits / alnum / alnum_symbols)
  String _generatePin() {
    const digits = '0123456789';
    const alnum = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    // 紛らわしい記号を避け、URL/CLI/Cookie で安全な印字可能 ASCII 部分集合
    const symbols = '!@#\$%&*-_+=?';
    final pool = switch (_pinCharset) {
      'alnum' => alnum,
      'alnum_symbols' => alnum + symbols,
      _ => digits,
    };
    final rnd = Random.secure();
    final buf = StringBuffer();
    for (var i = 0; i < _pinLength; i++) {
      buf.write(pool[rnd.nextInt(pool.length)]);
    }
    return buf.toString();
  }

  String _generateToken() {
    final r = Random.secure();
    return base64Url.encode(List.generate(16, (_) => r.nextInt(256)));
  }

  String _generateId() {
    final r = Random.secure();
    return base64Url.encode(List.generate(8, (_) => r.nextInt(256)));
  }

  // ブルートフォースのロックアウト等で使うクライアント識別子。
  // X-Forwarded-For / X-Real-IP はクライアントが自由に詐称でき、LocalNode は
  // 信頼できるリバースプロキシ配下にいる前提ではないため **使わない**。
  // shelf が握っている実 TCP リモートアドレスを使う (詐称不能)。
  String _getClientIp(Request req) {
    final conn = req.context['shelf.io.connection_info'];
    if (conn is HttpConnectionInfo) {
      return conn.remoteAddress.address;
    }
    return 'unknown';
  }

  String _getMimeType(String filename) {
    const types = {
      '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
      '.gif': 'image/gif', '.webp': 'image/webp', '.bmp': 'image/bmp',
      '.svg': 'image/svg+xml', '.mp4': 'video/mp4', '.mov': 'video/quicktime',
      '.avi': 'video/x-msvideo', '.mkv': 'video/x-matroska',
      '.webm': 'video/webm', '.mp3': 'audio/mpeg', '.wav': 'audio/wav',
      '.ogg': 'audio/ogg', '.m4a': 'audio/mp4', '.pdf': 'application/pdf',
      '.zip': 'application/zip', '.txt': 'text/plain',
    };
    return types[p.extension(filename).toLowerCase()] ??
        'application/octet-stream';
  }

  bool _isImage(String filename) {
    const exts = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.heic', '.heif'};
    return exts.contains(p.extension(filename).toLowerCase());
  }

  Future<File> _uniqueFile(Directory dir, String filename) async {
    var file = File(p.join(dir.path, filename));
    if (!await file.exists()) return file;
    final name = p.basenameWithoutExtension(filename);
    final ext = p.extension(filename);
    for (int i = 1;; i++) {
      file = File(p.join(dir.path, '$name ($i)$ext'));
      if (!await file.exists()) return file;
    }
  }

  Response? _guardDownloadOnly() {
    if (!_downloadOnly) return null;
    return Response.forbidden(
      json.encode({'error': 'This server is in download-only mode.'}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  /// id (base64url(絶対パス)) をデコードし、共有ルート配下に収まっていることを
  /// 検証する。id はクライアント制御なので、全ての id デコード系ハンドラは
  /// ファイルを開く/消す前にこれを通すこと (path traversal 防止)。
  /// 正常時は解決済みの File を返し、範囲外/不正なら null + 適切な Response を返す。
  Future<({File? file, Response? error})> _resolveSharedFile(String id) async {
    String filePath;
    try {
      filePath = utf8.decode(base64Url.decode(id));
    } catch (_) {
      return (file: null, error: Response.badRequest(body: 'Invalid id.'));
    }
    final file = File(filePath);
    if (!await file.exists()) {
      return (file: null, error: Response.notFound('File not found.'));
    }
    try {
      final canonicalRoot =
          await Directory(_storagePath!).resolveSymbolicLinks();
      final canonicalFile = await file.resolveSymbolicLinks();
      if (!p.isWithin(canonicalRoot, canonicalFile)) {
        return (file: null, error: Response.forbidden('Access denied'));
      }
    } catch (_) {
      return (file: null, error: Response.forbidden('Access denied'));
    }
    return (file: file, error: null);
  }

  // --- 認証ミドルウェア ---

  // #221: federation ループ防止
  // 受信 request に `x-fed-seen-by` ヘッダがあり、自分の device_id が含まれて
  // いれば破棄。送信側がループに気付けるよう 200 OK + JSON ペイロードを返す
  // （HTTP エラー扱いにすると意味のないリトライを誘発しかねないため）。
  static const String _kFedOrigin = 'x-fed-origin';
  static const String _kFedSeenBy = 'x-fed-seen-by';
  static const String _kFedRelation = 'x-fed-relation';

  Middleware get _federationLoopGuard => (inner) {
        return (req) {
          final seenByRaw = req.headers[_kFedSeenBy];
          if (seenByRaw != null && _deviceId.isNotEmpty) {
            final ids = seenByRaw
                .split(',')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toSet();
            if (ids.contains(_deviceId)) {
              final origin = req.headers[_kFedOrigin] ?? '?';
              _log('[fed] loop-drop origin=$origin seen_by_count=${ids.length}');
              return Response.ok(
                json.encode({'dropped': 'loop', 'device_id': _deviceId}),
                headers: {'Content-Type': 'application/json'},
              );
            }
          }
          // #223: federation 由来 (x-fed-origin あり) かつ送信元 peer が pause 中なら遮断。
          //       heartbeat (/api/health) は pause 中でも通す (生死表示用)。
          final origin = req.headers[_kFedOrigin];
          if (origin != null && origin.isNotEmpty) {
            final path = req.url.path;
            if (path != 'api/health' && path != 'api/info') {
              final peer = _federationPeers
                  .firstWhereOrNullExt((p) => p.learnedDeviceId == origin);
              if (peer != null) {
                if (peer.isPaused()) {
                  _log('[fed] paused-block ${peer.name} path=$path');
                  return Response(503,
                      body: json.encode({
                        'paused': true,
                        'pauseUntilMs': peer.pauseUntilMs,
                      }),
                      headers: {'Content-Type': 'application/json'});
                }
                // spec §1.3: relation は双方一致が前提。送信元の relation が
                // 自分の設定と異なれば連携不可。
                final senderRelation = req.headers[_kFedRelation];
                if (senderRelation != null &&
                    senderRelation.isNotEmpty &&
                    senderRelation != peer.relation) {
                  _log('[fed] relation-mismatch ${peer.name}'
                      ' local=${peer.relation} remote=$senderRelation');
                  return Response(409,
                      body: json.encode({
                        'error': 'relation mismatch',
                        'local': peer.relation,
                        'remote': senderRelation,
                      }),
                      headers: {'Content-Type': 'application/json'});
                }
              }
            }
          }
          return inner(req);
        };
      };

  /// #219 から使うヘルパ: federation event を転送するときの seen_by 構築。
  /// 受信時の seen_by に自分の device_id を追加して返す（既に入っていたら追加しない）。
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

  Middleware get _authMiddleware => (inner) {
        return (req) {
          final path = req.url.path;
          if (!path.startsWith('api/') ||
              path == 'api/info' ||
              path == 'api/auth' ||
              path == 'api/health') {
            return inner(req);
          }
          if (_authMode == _AuthMode.noPin) return inner(req);

          final cookieHeader = req.headers['cookie'];
          String? token;
          if (cookieHeader != null) {
            for (final c in cookieHeader.split(';')) {
              final t = c.trim();
              if (t.startsWith('localnode_session=')) {
                token = t.substring(t.indexOf('=') + 1);
                break;
              }
            }
          }
          if (token != null && _sessions.contains(token)) return inner(req);

          // #173/#188: Bearer トークンによる API 認証（スコープ限定）
          //   - POST /api/upload      … ファイルアップロード（#173）
          //   - POST /api/clipboard   … クリップボードへの送信（#188）
          //   - GET  /api/mentions    … federation @list <child> 用（#220）
          // x-fed-origin の有無でスコープを広げない。ヘッダは任意クライアントが
          // 付加できるため、列挙したエンドポイント以外への昇格には使えない。
          if (_uploadToken != null) {
            final authHeader = req.headers['authorization'] ?? '';
            if (authHeader == 'Bearer $_uploadToken') {
              if ((req.method == 'POST' &&
                      (path == 'api/upload' || path == 'api/clipboard')) ||
                  (req.method == 'GET' && path == 'api/mentions')) {
                return inner(req);
              }
            }
          }

          return Response.unauthorized(
            json.encode({'error': 'Authentication required.'}),
            headers: {'Content-Type': 'application/json'},
          );
        };
      };

  // --- ハンドラ ---

  Future<Response> _authHandler(Request req) async {
    if (_authMode == _AuthMode.noPin) {
      final token = _generateToken();
      _sessions.add(token);
      return Response.ok(json.encode({'status': 'success'}), headers: {
        'Content-Type': 'application/json',
        'Set-Cookie': 'localnode_session=$token; Path=/; HttpOnly',
      });
    }

    final clientIp = _getClientIp(req);
    final lockout = _lockoutUntil[clientIp];
    if (lockout != null && DateTime.now().isBefore(lockout)) {
      final rem = lockout.difference(DateTime.now()).inSeconds;
      return Response.forbidden(
        json.encode({'error': 'Locked out. Try again in $rem seconds.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final body = await req.readAsString();
    try {
      final params = json.decode(body) as Map<String, dynamic>;
      if (params['pin'] == _pin) {
        _failedAttempts.remove(clientIp);
        _lockoutUntil.remove(clientIp);
        final token = _generateToken();
        _sessions.add(token);
        return Response.ok(json.encode({'status': 'success'}), headers: {
          'Content-Type': 'application/json',
          'Set-Cookie': 'localnode_session=$token; Path=/; HttpOnly',
        });
      } else {
        final attempts = (_failedAttempts[clientIp] ?? 0) + 1;
        _failedAttempts[clientIp] = attempts;
        if (attempts >= _maxFailedAttempts) {
          _lockoutUntil[clientIp] =
              DateTime.now().add(_lockoutDuration);
          _failedAttempts.remove(clientIp);
          return Response.forbidden(
            json.encode({'error': 'Locked out for ${_lockoutDuration.inMinutes} minutes.'}),
            headers: {'Content-Type': 'application/json'},
          );
        }
        return Response.forbidden(json.encode({'error': 'Invalid PIN'}),
            headers: {'Content-Type': 'application/json'});
      }
    } catch (_) {
      return Response.badRequest(
        body: json.encode({'error': 'Invalid request body.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  Response _healthHandler(Request req) {
    // 送信元が federation peer なら、こちらが設定している relation を返す。
    // 相手はこれを自分の設定と比較して不一致を検出できる。
    final origin = req.headers[_kFedOrigin];
    String? myRelationForSender;
    if (origin != null && origin.isNotEmpty) {
      final peer = _federationPeers
          .firstWhereOrNullExt((p) => p.learnedDeviceId == origin);
      myRelationForSender = peer?.relation;
    }
    return Response.ok(
      json.encode({
        'startedAt': _startedAt,
        if (myRelationForSender != null) 'relation': myRelationForSender,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  // #201: 認証チェック専用エンドポイント。認証ミドルウェアを通るので、
  // 200 が返れば有効、401 が返ればセッション切れ。
  Response _checkAuthHandler(Request _) =>
      Response.ok(json.encode({'ok': true}),
          headers: {'Content-Type': 'application/json'});

  Response _infoHandler(Request _) => Response.ok(
        json.encode({
          'version': _appVersion,
          'name': _serverName,
          'serverName': _serverName,
          'operationMode': _downloadOnly ? 'downloadOnly' : 'normal',
          'authMode': _authMode == _AuthMode.fixedPin
              ? 'fixedPin'
              : _authMode == _AuthMode.noPin
                  ? 'noPin'
                  : 'randomPin',
          'requiresAuth': _authMode != _AuthMode.noPin,
          'clipboardEnabled': _clipboardEnabled,
          // #218: federation 識別子。public エンドポイントなので未認証で見える。
          // peer 同士の identity 確認に使うが、機密ではない。
          'deviceId': _deviceId,
          // #206: Web UI が PIN 入力モードを切り替えるためのヒント
          'pinCharset': _pinCharset,
          'pinLength': _pinLength,
        }),
        headers: {'Content-Type': 'application/json'},
      );

  Future<Response> _getFilesHandler(Request req) async {
    final root = Directory(_storagePath!);
    if (!await root.exists()) {
      return Response.internalServerError(body: 'Storage directory not found.');
    }
    final relPath = req.requestedUri.queryParameters['path'] ?? '';
    final canonicalRoot = await root.resolveSymbolicLinks();
    final targetPath = p.normalize(p.join(canonicalRoot, relPath));
    final dir = Directory(targetPath);
    if (!await dir.exists()) {
      return Response.notFound('Directory not found.');
    }
    final canonicalTarget = await dir.resolveSymbolicLinks();
    if (canonicalTarget != canonicalRoot &&
        !p.isWithin(canonicalRoot, canonicalTarget)) {
      return Response.forbidden('Access denied');
    }
    final entries = await dir.list(followLinks: false).toList();
    final list = await Future.wait(entries.map((e) async {
      final isDir = e is Directory;
      final id = base64Url.encode(utf8.encode(e.path));
      if (isDir) {
        return {'name': p.basename(e.path), 'type': 'directory', 'id': id};
      }
      final stat = await e.stat();
      return {
        'name': p.basename(e.path),
        'type': 'file',
        'size': stat.size,
        'modified': stat.modified.toIso8601String(),
        'id': id,
      };
    }));
    list.sort((a, b) {
      if (a['type'] != b['type']) return a['type'] == 'directory' ? -1 : 1;
      return (a['name'] as String).compareTo(b['name'] as String);
    });
    return Response.ok(jsonEncode(list),
        headers: {'Content-Type': 'application/json'});
  }

  Future<Response> _uploadHandler(Request req) async {
    final guard = _guardDownloadOnly();
    if (guard != null) return guard;

    final encodedName = req.headers['x-filename'];
    if (encodedName == null || encodedName.isEmpty) {
      return Response.badRequest(body: 'x-filename header is required.');
    }
    final filename = p.basename(Uri.decodeComponent(encodedName));

    // #219: federation 由来のアップロードなら、送信元 child の
    // max_upload_size を Content-Length で先に検査
    final clHeader = req.headers['content-length'];
    final cl = clHeader != null ? int.tryParse(clHeader) : null;
    if (cl != null) {
      final quotaResp = _checkFederationUploadQuota(req, cl);
      if (quotaResp != null) return quotaResp;
    }

    // #203: ?path=<relpath> でサブフォルダ宛のアップロードを許可
    // (Copilot #207 review): セグメント単位で .. のみ拒否
    // spec §1.5: federation 由来のアップロードは子が指定した path を無視し、
    // 親の config に登録されている children[i].name から保存先を決定する。
    // 子がフォルダ名を自由に決められないようにする。
    String relPath;
    final fedOrigin = req.headers[_kFedOrigin];
    if (fedOrigin != null && fedOrigin.isNotEmpty) {
      final senderPeer = _federationPeers.firstWhereOrNullExt(
          (p) => p.kind == 'child' && p.learnedDeviceId == fedOrigin);
      if (senderPeer == null) {
        return Response.forbidden('Unknown federation sender.');
      }
      relPath = 'children/${senderPeer.name}';
    } else {
      relPath = req.requestedUri.queryParameters['path'] ?? '';
      if (relPath.startsWith('/') || relPath.startsWith(r'\')) {
        return Response.badRequest(body: 'Invalid path.');
      }
      if (p.split(relPath).contains('..')) {
        return Response.badRequest(body: 'Invalid path.');
      }
    }
    // (Copilot #207 review): root 不在を resolveSymbolicLinks より先に検出
    final rootDir = Directory(_storagePath!);
    if (!await rootDir.exists()) {
      return Response.internalServerError(body: 'Storage directory not found.');
    }
    final canonicalRoot = await rootDir.resolveSymbolicLinks();
    final targetDirPath = p.normalize(p.join(canonicalRoot, relPath));
    final dir = Directory(targetDirPath);
    if (!await dir.exists()) {
      // federation の children/<childname>/ は初回アップロード時に自動作成する。
      // パストラバーサルチェック済みなので作成は安全。
      await dir.create(recursive: true);
    }
    final canonicalTarget = await dir.resolveSymbolicLinks();
    if (canonicalTarget != canonicalRoot &&
        !p.isWithin(canonicalRoot, canonicalTarget)) {
      return Response.forbidden('Access denied');
    }

    final file = await _uniqueFile(dir, filename);
    final sink = file.openWrite();
    try {
      await for (final chunk in req.read()) {
        sink.add(chunk);
      }
      await sink.close();
      if (_postActions.isNotEmpty) {
        _runPostActions(file.path);
      }
      // #219: 親への転送 (自分が子のとき、かつ受信が federation 由来でない場合)
      _forwardFileToParents(file, req);
      return Response.ok('File uploaded: ${p.basename(file.path)}');
    } catch (e) {
      await sink.close();
      return Response.internalServerError(body: 'Upload failed: $e');
    }
  }

  // Windows で .ps1 は powershell.exe 経由で実行
  (String executable, List<String> args) _buildCommand(
      String script, List<String> extraArgs) {
    if (Platform.isWindows) {
      if (script.toLowerCase().endsWith('.ps1')) {
        return (
          'cmd',
          ['/c', 'powershell.exe', '-ExecutionPolicy', 'Bypass', '-File', script, ...extraArgs]
        );
      }
      return ('cmd', ['/c', script, ...extraArgs]);
    }
    return (script, extraArgs);
  }

  bool _globMatch(String pattern, String filename) {
    final regexStr = RegExp.escape(pattern)
        .replaceAll(r'\*', '.*')
        .replaceAll(r'\?', '.');
    return RegExp('^$regexStr\$', caseSensitive: !Platform.isWindows)
        .hasMatch(filename);
  }

  void _runPostActions(String filePath) {
    final filename = p.basename(filePath);
    for (final action in _postActions) {
      if (!_globMatch(action.pattern, filename)) continue;
      () async {
        try {
          final cmd = _buildCommand(action.script, [filePath]);
          final result = await Process.run(
            cmd.$1, cmd.$2,
            runInShell: !Platform.isWindows,
          );
          if (result.exitCode != 0) {
            stderr.writeln(
                '[post-action] "${action.script}" exited ${result.exitCode}');
            if ((result.stderr as String).isNotEmpty) {
              stderr.writeln(result.stderr);
            }
          } else {
            _log('[post-action] "${action.script}" completed for $filename');
          }
        } catch (e) {
          stderr.writeln('[post-action] Failed to run "${action.script}": $e');
        }
      }();
    }
  }

  String _buildMentionList() {
    final lines = <String>[];

    lines.add('Mention commands:');
    lines.add('  @list — show this list');

    // #240: federation 設定があるときだけ予約 mention を案内する
    //       (children/parent 未設定のサーバでノイズにならないように)
    final hasChildren = _federationPeers.any((p) => p.kind == 'child');
    final hasParent = _federationPeers.any((p) => p.kind == 'parent');
    if (hasChildren) {
      lines.add('  @list <childname> — fetch a child\'s mention list');
      lines.add('  @to <childname|all> <message> — post to a child\'s clipboard');
      lines.add('  @run_to <childname> <alias> — run @run on a child');
    }
    if (hasParent) {
      lines.add('  @up <message> — mark as important (forwarded under equally relation)');
    }

    if (_mentionActions.isEmpty) {
      lines.add('  (no @run actions registered)');
    } else {
      // #224: YAML config の mention_actions[].description があれば付与
      for (final e in _mentionActions.entries) {
        final desc = e.value.description;
        if (desc != null && desc.isNotEmpty) {
          lines.add('  @run ${e.key} — $desc');
        } else {
          lines.add('  @run ${e.key}');
        }
      }
    }

    if (_postActions.isNotEmpty) {
      lines.add('');
      lines.add('Post-upload actions:');
      for (final a in _postActions) {
        lines.add('  ${a.pattern} -> ${a.script}');
      }
    }

    return lines.join('\n');
  }

  void _replyToClipboard(String text) {
    final item = _ClipboardItem(
      id: _generateId(),
      text: text,
      tag: 'mention-result',
      createdAt: DateTime.now(),
    );
    _clipboardItems.insert(0, item);
    while (_clipboardItems.length > _maxClipboardItems) {
      final evicted = _evictClipboardItem();
      _recordDeletion(evicted.id);
    }
    _clipboardLastModified = DateTime.now().millisecondsSinceEpoch;
  }

  void _runMentionAction(String alias, String script) {
    () async {
      try {
        final cmd = _buildCommand(script, []);
        final result = await Process.run(
          cmd.$1, cmd.$2,
          runInShell: !Platform.isWindows,
        );
        final resultText = result.exitCode == 0
            ? '@run $alias: OK'
            : '@run $alias: FAILED (exit ${result.exitCode})';
        if (result.exitCode != 0 && (result.stderr as String).isNotEmpty) {
          stderr.writeln('[mention-action] "$alias" stderr: ${result.stderr}');
        }
        _replyToClipboard(resultText);
        _log('[mention-action] "$alias" -> $resultText');
      } catch (e) {
        stderr.writeln('[mention-action] Failed to run "$alias": $e');
      }
    }();
  }

  Future<Response> _downloadHandler(Request req, String id) async {
    try {
      // path traversal 防止: 共有ルート配下のファイルだけ許可
      final resolved = await _resolveSharedFile(id);
      if (resolved.error != null) return resolved.error!;
      final file = resolved.file!;
      final filePath = file.path;
      final mimeType = _getMimeType(p.basename(filePath));
      final length = await file.length();
      // #200: Range リクエスト対応 (動画サムネ生成等で部分取得を可能に)
      final rangeHeader = req.headers['range'];
      ({int start, int end})? range;
      try {
        range = _parseHttpRange(rangeHeader, length);
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
    } catch (e) {
      return Response.internalServerError(body: 'Download failed: $e');
    }
  }

  // #200: Range ヘッダ解析（単一範囲のみ）
  ({int start, int end})? _parseHttpRange(String? header, int fileLength) {
    if (header == null || header.isEmpty) return null;
    if (!header.startsWith('bytes=')) throw RangeError('Invalid range unit');
    final spec = header.substring('bytes='.length).trim();
    if (spec.contains(',')) return null;
    final dash = spec.indexOf('-');
    if (dash < 0) throw RangeError('Invalid range spec');
    final startStr = spec.substring(0, dash);
    final endStr = spec.substring(dash + 1);
    int start, end;
    if (startStr.isEmpty) {
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

  // #193: テキストファイルのインラインプレビュー
  // #216: 先頭 8KB を読んでテキストらしさを判定。NUL バイトを含む or
  //       UTF-8 として decode できないなら binary 扱い。
  //       (#244 review) 末尾でマルチバイト境界をまたいだだけの偽陰性を
  //       避けるため、末尾を最大 3 バイト削って再 decode を試す。
  Future<bool> _sniffTextLike(File file) async {
    try {
      const sniffBytes = 8 * 1024;
      final raf = await file.open();
      try {
        final size = await raf.length();
        final n = size < sniffBytes ? size : sniffBytes;
        if (n == 0) return true; // 空ファイルはテキスト扱い
        final buf = await raf.read(n);
        if (buf.contains(0)) return false; // NUL バイト → binary
        return _utf8DecodesWithTrim(buf);
      } finally {
        await raf.close();
      }
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

  Future<Response> _textPreviewHandler(Request req, String id) async {
    const maxFullBytes = 5 * 1024 * 1024;
    final mode = req.requestedUri.queryParameters['mode'] ?? 'head';
    if (mode != 'head' && mode != 'tail' && mode != 'full') {
      return Response.badRequest(body: 'mode must be head|tail|full');
    }
    final lines = int.tryParse(req.requestedUri.queryParameters['lines'] ?? '') ?? 200;
    if (lines < 1 || lines > 10000) {
      return Response.badRequest(body: 'lines out of range');
    }
    try {
      final filePath = utf8.decode(base64Url.decode(id));

      // パストラバーサル検証 (Copilot #199 review)
      if (await FileSystemEntity.isDirectory(filePath)) {
        return Response.badRequest(body: 'Target is a directory.');
      }
      final canonicalRoot = await Directory(_storagePath!).resolveSymbolicLinks();
      final file = File(filePath);
      if (!await file.exists()) return Response.notFound('File not found.');
      final canonicalFile = await file.resolveSymbolicLinks();
      if (!p.isWithin(canonicalRoot, canonicalFile)) {
        return Response.forbidden('Access denied');
      }

      // #216: 拡張子ホワイトリスト外 (例: LICENSE, Dockerfile, *.cfg) も
      //       バイナリでなければプレビューさせる。先頭 8KB を見て NUL バイトや
      //       UTF-8 不正がないかで判定する。
      final sniff = await _sniffTextLike(file);
      if (!sniff) {
        return Response(415,
            body: json.encode({
              'error': 'not-text',
              'message': 'File does not look like text (binary content).',
            }),
            headers: {'Content-Type': 'application/json'});
      }

      if (mode == 'head' || mode == 'tail') {
        // ファイル全体をメモリに乗せず、行をストリームで処理
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

      // mode == 'full'
      final size = await file.length();
      if (size > maxFullBytes) {
        return Response.badRequest(body: 'File too large for full preview (max 5MB).');
      }
      final content = await file.readAsString(encoding: utf8);
      final totalLines = '\n'.allMatches(content).length + 1;
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

  // #198: @file:<relpath> 用のパスベースサムネイル
  Future<Response> _thumbnailByPathHandler(Request req) async {
    final relPath = req.requestedUri.queryParameters['path'] ?? '';
    if (relPath.isEmpty ||
        relPath.contains('..') ||
        relPath.startsWith('/') ||
        relPath.startsWith(r'\') ||
        relPath.contains(':')) {
      return Response.badRequest(body: 'Invalid path.');
    }
    final canonicalRoot = await Directory(_storagePath!).resolveSymbolicLinks();
    final targetPath = p.normalize(p.join(canonicalRoot, relPath));
    final file = File(targetPath);
    if (!await file.exists()) return Response.notFound('File not found.');
    final canonicalTarget = await file.resolveSymbolicLinks();
    if (!p.isWithin(canonicalRoot, canonicalTarget)) {
      return Response.forbidden('Access denied');
    }
    final id = base64Url.encode(utf8.encode(targetPath));
    return _thumbnailHandler(req, id);
  }

  static Uint8List _buildPlaceholderJpeg() {
    final placeholder = img.Image(width: 120, height: 120);
    img.fill(placeholder, color: img.ColorRgb8(180, 180, 180));
    return Uint8List.fromList(img.encodeJpg(placeholder, quality: 70));
  }

  Future<Response> _thumbnailHandler(Request req, String id) async {
    if (_thumbnailCacheDir == null) {
      return Response.internalServerError(body: 'Server not initialized.');
    }
    try {
      // path traversal 防止: 共有ルート配下のファイルだけ許可。
      // (キャッシュ参照より先に検証する — 範囲外パスのキャッシュ汚染も防ぐ)
      final resolved = await _resolveSharedFile(id);
      if (resolved.error != null) return resolved.error!;
      final src = resolved.file!;
      final filePath = src.path;
      final filename = p.basename(filePath);
      if (!_isImage(filename)) {
        return Response.badRequest(body: 'Not an image.');
      }
      final cache = File(p.join(_thumbnailCacheDir!.path, '$filename.jpg'));
      if (await cache.exists()) {
        return Response.ok(cache.openRead(),
            headers: {'Content-Type': 'image/jpeg'});
      }
      final bytes = await src.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) {
        return Response.ok(_placeholderThumbBytes,
            headers: {'Content-Type': 'image/jpeg'});
      }
      final thumb = img.copyResize(image, width: 120);
      final thumbBytes = img.encodeJpg(thumb, quality: 85);
      cache.writeAsBytes(thumbBytes);
      return Response.ok(thumbBytes, headers: {'Content-Type': 'image/jpeg'});
    } catch (e) {
      return Response.internalServerError(body: 'Thumbnail failed: $e');
    }
  }

  Future<Response> _downloadAllHandler(Request req) async {
    final root = Directory(_storagePath!);
    if (!await root.exists()) {
      return Response.internalServerError(body: 'Storage directory not found.');
    }
    final relPath = req.requestedUri.queryParameters['path'] ?? '';
    final canonicalRoot = await root.resolveSymbolicLinks();
    final targetPath = p.normalize(p.join(canonicalRoot, relPath));
    final dir = Directory(targetPath);
    if (!await dir.exists()) {
      return Response.internalServerError(body: 'Directory not found.');
    }
    final canonicalTarget = await dir.resolveSymbolicLinks();
    if (canonicalTarget != canonicalRoot &&
        !p.isWithin(canonicalRoot, canonicalTarget)) {
      return Response.forbidden('Access denied');
    }

    // #195: ZIP を一時ファイルへストリーミング書き出ししてレスポンスとして流す
    final tempDir = await Directory.systemTemp.createTemp('localnode_zip_');
    final zipPath = p.join(tempDir.path, 'localnode_files.zip');
    try {
      final zipEncoder = ZipFileEncoder()..create(zipPath);
      final files = dir.listSync(followLinks: false).whereType<File>();
      for (final f in files) {
        await zipEncoder.addFile(f, p.basename(f.path));
      }
      await zipEncoder.close();

      final zipFile = File(zipPath);
      final length = await zipFile.length();

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

  Future<Response> _deleteFileHandler(Request req, String id) async {
    final guard = _guardDownloadOnly();
    if (guard != null) return guard;
    try {
      // path traversal 防止: 共有ルート配下のファイルだけ削除を許可
      final resolved = await _resolveSharedFile(id);
      if (resolved.error != null) return resolved.error!;
      final file = resolved.file!;
      final filePath = file.path;
      await file.delete();
      final cache = File(
          p.join(_thumbnailCacheDir!.path, '${p.basename(filePath)}.jpg'));
      if (await cache.exists()) await cache.delete();
      return Response.ok('File deleted.');
    } catch (e) {
      return Response.internalServerError(body: 'Delete failed: $e');
    }
  }

  // #190: クライアントが指定したファイル ID のみ削除
  Future<Response> _deleteBatchHandler(Request req) async {
    final guard = _guardDownloadOnly();
    if (guard != null) return guard;

    final List<dynamic> ids;
    try {
      final body = json.decode(await req.readAsString()) as Map<String, dynamic>;
      ids = body['ids'] as List<dynamic>? ?? const [];
    } catch (_) {
      return Response.badRequest(body: 'Invalid request body.');
    }

    int deleted = 0;
    int failed = 0;
    final List<String> skipped = [];

    final canonicalRoot = await Directory(_storagePath!).resolveSymbolicLinks();
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
          skipped.add(raw);
          continue;
        }
        final filename = p.basename(filePath);
        await file.delete();
        deleted++;
        final cache = File(p.join(_thumbnailCacheDir!.path, '$filename.jpg'));
        if (await cache.exists()) await cache.delete();
      } catch (_) {
        failed++;
      }
    }

    return Response.ok(
      json.encode({'deleted': deleted, 'failed': failed, 'skipped': skipped}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  // --- クリップボードハンドラ ---

  // #228: 差分 / paginated GET
  // クエリ:
  //   ?since=<ms>      これより新しい item と、これ以降の削除 id を返す
  //   ?before=<ms>     これより古い item を返す（古い方ページング）
  //   ?limit=N         返す item 数の上限 (1..2000)
  // 全て省略時は従来通り全件返す。
  // since が削除リングバッファより古い → refresh:true で full re-fetch を促す。
  Response _getClipboardHandler(Request req) {
    final q = req.requestedUri.queryParameters;
    final hasQuery = q.containsKey('since') || q.containsKey('before') || q.containsKey('limit');

    if (!hasQuery) {
      // 後方互換: 全件返す
      return Response.ok(
        json.encode({
          'items': _clipboardItems.map((i) => i.toJson()).toList(),
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
      // ring buffer が満杯で、その最古より since が古ければ full refresh
      if (_clipboardDeletes.length >= _maxDeletionLog &&
          _clipboardDeletes.first.deletedAtMs > since) {
        refresh = true;
      }
      deletedSince = _clipboardDeletes
          .where((d) => d.deletedAtMs > since)
          .map((d) => d.id)
          .toList();
    }

    // items は createdAt の新しい順に並んでいる（insert(0, ...) なので）
    Iterable<_ClipboardItem> filtered = _clipboardItems;
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

  Future<Response> _postClipboardHandler(Request req) async {
    try {
      final params =
          json.decode(await req.readAsString()) as Map<String, dynamic>;
      var text = (params['text'] as String?)?.trim();
      final rawTag = (params['tag'] as String?)?.trim();
      final tag = (rawTag != null && rawTag.isNotEmpty) ? rawTag : null;

      if (text == null || text.isEmpty) {
        return Response.badRequest(
          body: json.encode({'error': 'Text is required.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      if (text.length > _maxTextLength) {
        return Response.badRequest(
          body: json.encode({'error': 'Text too long.'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      // #220: 受信時 (federation 由来) に `@up ` で始まっていれば
      //   - important フラグを立てる
      //   - 表示テキストから `@up ` を剥がす
      //   ローカル直接投稿でも同様に重要フラグだけ立てる (剥がしは行わない方が
      //   送信側の意図が見えるが、spec §1.4 で「受信側で剥がす」とあるので剥がす)
      bool important = false;
      if (_isUpText(text)) {
        important = true;
        text = text.substring(4).trimLeft();
        if (text.isEmpty) {
          // @up だけのメッセージは空になる -> 体裁悪いのでマーク前に戻す
          text = '@up';
          important = false;
        }
      }

      final item = _ClipboardItem(
        id: _generateId(),
        text: text,
        tag: tag,
        createdAt: DateTime.now(),
        important: important,
      );
      _clipboardItems.insert(0, item);
      while (_clipboardItems.length > _maxClipboardItems) {
        final ev = _evictClipboardItem();
        _recordDeletion(ev.id);
      }
      _clipboardLastModified = DateTime.now().millisecondsSinceEpoch;

      // #219: 親への転送 (自分が子のとき、かつ受信が federation 由来でない場合)
      // 注: important フラグの判定は転送時にもう一度 _isUpItem で行う。
      //     しかし剥がした後 (`text` から `@up ` が消えている) なので、
      //     重要度を保つために item.text ではなく元の判定情報を渡す必要がある。
      //     ここでは「重要フラグ」を考慮した転送ヘルパを呼び分ける。
      _forwardClipboardItemWithImportance(item, req, important);

      // #174 / #220: メンションコマンド検出
      // 重要フラグで剥がした text はもうコマンドではないので、元の text で判定する
      // ためここで再度組み立てる必要はなく、剥がし前の text を扱うべき。
      // → 改修簡素化のため: important なら mention 検出はスキップ
      if (!important) {
        await _handleMentionInClipboard(text);
      }

      return Response.ok(json.encode(item.toJson()),
          headers: {'Content-Type': 'application/json'});
    } catch (_) {
      return Response.badRequest(
        body: json.encode({'error': 'Invalid request body.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  bool _isUpText(String s) => s == '@up' || s.startsWith('@up ');

  /// 親への転送ヘルパ。重要フラグも含めて転送先で `@up ` を付け直すかは
  /// 送信側で決める。
  void _forwardClipboardItemWithImportance(
      _ClipboardItem item, Request originReq, bool important) {
    if (important) {
      // 元のテキストを `@up ` 付きで送信し直すための一時 item
      final wireItem = _ClipboardItem(
        id: item.id,
        text: '@up ${item.text}',
        tag: item.tag,
        createdAt: item.createdAt,
        important: true,
      );
      _forwardClipboardToParents(wireItem, originReq);
    } else {
      _forwardClipboardToParents(item, originReq);
    }
  }

  /// #220: clipboard 投稿に含まれるメンションコマンドを処理
  Future<void> _handleMentionInClipboard(String text) async {
    // @list (自分)
    if (text == '@list') {
      _replyToClipboard(_buildMentionList());
      return;
    }
    // @list <child>
    final listChild = RegExp(r'^@list\s+(\S+)$').firstMatch(text);
    if (listChild != null) {
      final childName = listChild.group(1)!;
      _dispatchListToChild(childName);
      return;
    }
    // @to <child|all> <message>
    final toMatch = RegExp(r'^@to\s+(\S+)\s+(.+)$', dotAll: true).firstMatch(text);
    if (toMatch != null) {
      final target = toMatch.group(1)!;
      final message = toMatch.group(2)!;
      _dispatchToChild(target, message);
      return;
    }
    // @run_to <child> <alias>
    final runToMatch = RegExp(r'^@run_to\s+(\S+)\s+(\S+)$').firstMatch(text);
    if (runToMatch != null) {
      final childName = runToMatch.group(1)!;
      final alias = runToMatch.group(2)!;
      _dispatchRunToChild(childName, alias);
      return;
    }
    // @run <alias> (既存)
    final runMatch = RegExp(r'^@run\s+(\S+)$').firstMatch(text);
    if (runMatch != null) {
      final alias = runMatch.group(1)!;
      final entry = _mentionActions[alias];
      if (entry != null) {
        _runMentionAction(alias, entry.script);
      }
    }
  }

  /// 子に `@list` を投げる。子側で `@list` の結果が自分の clipboard に
  /// 子の /api/mentions を直接 GET して結果を自分の clipboard に投稿する。
  /// friendly/equally 問わず動作する（転送に依存しない）。
  void _dispatchListToChild(String childName) {
    final peer = _federationPeers.firstWhereOrNullExt(
        (p) => p.kind == 'child' && p.name == childName);
    if (peer == null) {
      _replyToClipboard('@list $childName: child not found');
      return;
    }
    () async {
      try {
        _heartbeatClient ??=
            HttpClient()..connectionTimeout = const Duration(seconds: 10);
        final uri = Uri.parse('${peer.url}/api/mentions');
        final req = await _heartbeatClient!.getUrl(uri);
        req.headers.set('Authorization', 'Bearer ${peer.token}');
        final res = await req.close().timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          final body = await res.transform(utf8.decoder).join();
          final data = json.decode(body) as Map<String, dynamic>;
          final items =
              (data['items'] as List? ?? []).cast<Map<String, dynamic>>();
          final lines = <String>['[$childName] Mention commands:'];
          for (final item in items) {
            final label = item['label'] as String? ?? '';
            final desc = item['description'] as String? ?? '';
            lines.add(desc.isNotEmpty ? '  $label — $desc' : '  $label');
          }
          _replyToClipboard(lines.join('\n'));
          _log('[fed] @list $childName ok (${items.length} items)');
        } else {
          await res.drain();
          _replyToClipboard('@list $childName: failed (HTTP ${res.statusCode})');
        }
      } catch (e) {
        _log('[fed] @list $childName fail: $e');
        _replyToClipboard('@list $childName: dispatch failed');
      }
    }();
  }

  /// `@to <name|all> <message>` を解決して送信
  void _dispatchToChild(String target, String message) {
    final List<_FederationPeer> targets;
    if (target == 'all') {
      targets = _federationPeers.where((p) => p.kind == 'child').toList();
    } else {
      final t = _federationPeers.firstWhereOrNullExt(
          (p) => p.kind == 'child' && p.name == target);
      if (t == null) {
        _replyToClipboard('@to $target: child not found');
        return;
      }
      targets = [t];
    }
    for (final peer in targets) {
      () async {
        try {
          await _sendBareTextToPeer(peer, message);
          _log('[fed] @to ${peer.name} ok');
        } catch (e) {
          _log('[fed] @to ${peer.name} fail: $e');
        }
      }();
    }
  }

  /// `@run_to <name> <alias>` を解決して `@run <alias>` を送信
  void _dispatchRunToChild(String childName, String alias) {
    final peer = _federationPeers.firstWhereOrNullExt(
        (p) => p.kind == 'child' && p.name == childName);
    if (peer == null) {
      _replyToClipboard('@run_to $childName: child not found');
      return;
    }
    () async {
      try {
        await _sendBareTextToPeer(peer, '@run $alias');
        _log('[fed] @run_to ${peer.name} $alias dispatched');
      } catch (e) {
        _log('[fed] @run_to ${peer.name} fail: $e');
        _replyToClipboard('@run_to $childName: dispatch failed');
      }
    }();
  }

  /// 任意のテキストを peer の /api/clipboard に送る (リトライ込み)
  Future<void> _sendBareTextToPeer(_FederationPeer peer, String text) async {
    if (peer.isPaused()) {
      _log('[fed] paused-skip text ${peer.name}');
      throw StateError('peer paused');
    }
    _heartbeatClient ??=
        HttpClient()..connectionTimeout = const Duration(seconds: 10);
    final uri = Uri.parse('${peer.url}/api/clipboard');
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final r = await _heartbeatClient!.postUrl(uri);
        r.headers.set('Content-Type', 'application/json');
        r.headers.set('Authorization', 'Bearer ${peer.token}');
        r.headers.set(_kFedOrigin, _deviceId);
        r.headers.set(_kFedSeenBy, _deviceId);
        r.headers.set(_kFedEvent, 'clipboard');
        r.headers.set(_kFedRelation, peer.relation);
        r.add(utf8.encode(json.encode({'text': text, 'tag': _serverName})));
        final res = await r.close().timeout(const Duration(seconds: 15));
        await res.drain();
        if (res.statusCode >= 200 && res.statusCode < 300) return;
        if (res.statusCode >= 400 &&
            res.statusCode < 500 &&
            res.statusCode != 408) {
          throw HttpException('HTTP ${res.statusCode}');
        }
      } catch (e) {
        if (attempt == 3) rethrow;
      }
      await Future.delayed(Duration(seconds: 2 * attempt));
    }
  }

  Response _deleteClipboardItemHandler(Request req, String id) {
    final idx = _clipboardItems.indexWhere((i) => i.id == id);
    if (idx == -1) {
      return Response.notFound(json.encode({'error': 'Item not found.'}),
          headers: {'Content-Type': 'application/json'});
    }
    final removed = _clipboardItems.removeAt(idx);
    _recordDeletion(removed.id);
    _clipboardLastModified = DateTime.now().millisecondsSinceEpoch;
    return Response.ok(json.encode({'status': 'deleted'}),
        headers: {'Content-Type': 'application/json'});
  }

  Response _clearClipboardHandler(Request req) {
    final count = _clipboardItems.length;
    for (final it in _clipboardItems) {
      _recordDeletion(it.id);
    }
    _clipboardItems.clear();
    _clipboardLastModified = DateTime.now().millisecondsSinceEpoch;
    return Response.ok(json.encode({'status': 'cleared', 'count': count}),
        headers: {'Content-Type': 'application/json'});
  }
}
