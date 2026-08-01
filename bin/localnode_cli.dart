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
const String _appVersion = '1.10.0';

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

// #267: passkey (WebAuthn) アカウント。credentials ファイルの 1 エントリ。
// SSH の authorized_keys 相当。label=アカウント名, credentialId=base64url(rawId),
// publicKeySpki=登録時に取得した公開鍵 (SPKI DER)。
class _PasskeyAccount {
  final String name;
  final String credentialId; // base64url (パディング無し) の rawId
  final Uint8List publicKeySpki; // SubjectPublicKeyInfo (DER)
  _PasskeyAccount(this.name, this.credentialId, this.publicKeySpki);
}

class _LoadedConfig {
  // server section
  int? port;
  String? ip;
  String? pin;
  String? dir;
  String? mode;
  String? name;
  // #287
  String? cacheDir;
  String? httpsCert;
  String? httpsKey;
  String? token;
  bool? noPin;
  bool? noClipboard;
  bool? verbose;
  bool? noToken;
  // #206
  int? pinLength;
  String? pinCharset;
  // #262
  String? maxUploadSize;
  // #290
  int? postActionTimeout;
  // #267
  String? accountsFile;
  // #237
  String? stateFile;
  // #208
  String? pinFile;
  String? tokenFile;
  // #275: DNS rebinding guard に追加で許可するホスト名（リバースプロキシ等）
  List<String>? allowedHosts;
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
    cfg.maxUploadSize = _yamlString(server, 'max-upload-size');
    cfg.postActionTimeout = _yamlInt(server, 'post-action-timeout'); // #290
    cfg.accountsFile = _yamlString(server, 'accounts-file');         // #267
    cfg.cacheDir = _yamlString(server, 'cache-dir');     // #287
    cfg.stateFile = _yamlString(server, 'state-file');   // #237
    cfg.pinFile = _yamlString(server, 'pin-file');       // #208
    cfg.tokenFile = _yamlString(server, 'token-file');   // #208
    // #275: allowed-hosts はホスト名文字列のリスト
    final ah = server['allowed-hosts'];
    if (ah is YamlList) {
      cfg.allowedHosts = ah.map((e) => e.toString()).toList();
    } else if (ah != null) {
      stderr.writeln('Error: server.allowed-hosts must be a list of host names.');
      exit(1);
    }
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

  // #287: キャッシュ/一時データの基点（CLI arg > YAML）。存在検証は起動時に行う。
  final cacheDir = results['cache-dir'] as String? ?? cfg?.cacheDir;

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
    if (raw == null) return 8;
    final n = int.tryParse(raw);
    if (n == null || n < 8 || n > 16) {
      stderr.writeln('Error: --pin-length must be an integer 8..16 (got "$raw").');
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
  // #262: 直接アップロードのサイズ上限
  final maxUploadSizeStr = results.wasParsed('max-upload-size')
      ? results['max-upload-size'] as String?
      : (cfg?.maxUploadSize ?? results['max-upload-size'] as String?);
  final int? maxDirectUploadBytes = _parseSizeBytes(maxUploadSizeStr);
  // #290: post-action タイムアウト秒（CLI > YAML > デフォルト300）。0 で無制限。
  final postActionTimeoutSeconds = int.tryParse(
          results['post-action-timeout'] as String? ?? '') ??
      cfg?.postActionTimeout ??
      300;
  // #267: passkey アカウントファイル（CLI > YAML）
  final accountsFile = results['accounts-file'] as String? ?? cfg?.accountsFile;

  // #208: CLI > YAML config
  final String? pinFile = results.wasParsed('pin-file')
      ? results['pin-file'] as String?
      : cfg?.pinFile;
  final String? tokenFile = results.wasParsed('token-file')
      ? results['token-file'] as String?
      : cfg?.tokenFile;

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
  // #237: CLI > YAML config > デフォルト
  final statePath = results['state-file'] as String? ?? cfg?.stateFile ?? _defaultStateFilePath();
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

  // #275: DNS-rebinding guard が許可する追加ホスト名。HTTPS の場合は cert SAN から
  // 選ばれた advertisedHost（peer / ブラウザが実際に到達する名前）を必ず含める。
  // これが無いと federation や Tailscale の DNS 名アクセスが 421 で拒否される。
  final extraAllowedHosts = <String>{
    advertisedHost,
    ...?(cfg?.allowedHosts),
    ...(results['allowed-host'] as List<String>? ?? const []),
  }.where((h) => h.isNotEmpty).toList();

  stdout.writeln('');
  stdout.writeln('LocalNode CLI Server v$_appVersion');
  stdout.writeln('=' * 40);

  // #173: アップロードトークンの決定（download-only / no-pin モードでは不要）
  // no-pin では認証がないためトークンを発行しても意味がなく、逆に誤った安心感を与える
  final String? uploadToken = (!noToken && !downloadOnly && !noPin)
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
      cacheDir: cacheDir,           // #287
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
      maxDirectUploadBytes: maxDirectUploadBytes, // #262
      postActionTimeoutSeconds: postActionTimeoutSeconds, // #290
      accountsFile: accountsFile, // #267
      extraAllowedHosts: extraAllowedHosts,       // #275
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

  // #208: PIN / token をファイルに書き出す（daemon / systemd 連携用）
  // #274: 秘密情報なので 0600 で書き出す（_writeSecretFile）
  if (pinFile != null && server.pin != null) {
    try {
      _writeSecretFile(pinFile, '${server.pin}\n');
    } catch (e) {
      stderr.writeln('Warning: could not write PIN to $pinFile: $e');
    }
  }
  if (tokenFile != null && uploadToken != null) {
    try {
      _writeSecretFile(tokenFile, '$uploadToken\n');
    } catch (e) {
      stderr.writeln('Warning: could not write upload token to $tokenFile: $e');
    }
  }

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
    ..addOption('cache-dir',
        help: 'Base directory for cache/temp data (thumbnails, web assets, '
            'zip staging). Default: the system temp directory')
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
    ..addOption('post-action-timeout',
        help: 'Timeout in seconds for each post-action script; the process is '
            'killed if it exceeds this. 0 disables the timeout. (default: 300)',
        valueHelp: 'SECONDS')
    ..addOption('accounts-file',
        help: 'Path to a YAML passkey accounts file for WebAuthn login (#267). '
            'Enables per-user passkey login alongside the PIN. Requires HTTPS + '
            'a hostname (or localhost); does not work over a bare LAN IP.',
        valueHelp: 'PATH')
    ..addMultiOption('mention-action',
        help:
            'Register a clipboard mention command: <alias>=<script>. '
            'Send "@run <alias>" via clipboard to trigger the script (repeatable). '
            'Runs as the server process user.',
        valueHelp: 'alias=script')
    ..addOption('token', help: 'Fixed upload token (random if not specified)')
    ..addFlag('no-token',
        help: 'Disable token-based upload authentication', negatable: false)
    ..addOption('max-upload-size',
        help: 'Maximum size for direct file uploads, e.g. 100M, 2G (default: unlimited)',
        valueHelp: 'SIZE')
    // #208: daemon / systemd 連携用 — 生成値をファイルに書き出す
    ..addOption('pin-file',
        help: 'Write the generated PIN to this file on startup',
        valueHelp: 'PATH')
    ..addOption('token-file',
        help: 'Write the generated upload token to this file on startup',
        valueHelp: 'PATH')
    // #275: DNS-rebinding guard が拒否しない追加ホスト名（リバースプロキシ等、repeatable）
    ..addMultiOption('allowed-host',
        help: 'Extra Host header value to accept (e.g. a reverse-proxy or DNS '
            'name). HTTPS cert hostnames are accepted automatically (repeatable).',
        valueHelp: 'HOST')
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

/// #274: 秘密情報（PIN / token）をファイルに書き出す。Unix では先に空ファイルを
/// 0600 に絞ってから中身を書くことで、ワールドリーダブルな窓を作らない。
void _writeSecretFile(String path, String content) {
  final file = File(path);
  if (!Platform.isWindows) {
    // 空で作成 → chmod 600 → 中身を書く。秘密はパーミッション制限後にのみ書かれる。
    file.writeAsStringSync('');
    Process.runSync('chmod', ['600', path], runInShell: false);
  }
  file.writeAsStringSync(content);
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
  // #287: キャッシュ/一時データの基点。null なら OS の一時ディレクトリ。
  String? _cacheDir;
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

  // #261: token → expiry epoch (ms)
  final Map<String, int> _sessions = {};
  static const Duration _sessionTtl = Duration(hours: 24);
  static const int _maxNoPinSessions = 1000;
  // #267: セッション → アカウント名（passkey ログイン時のみ。PIN/no-pin は未設定=guest）
  final Map<String, String> _sessionAccounts = {};
  // #267: passkey アカウント（credentials ファイルから読み込む）
  List<_PasskeyAccount> _accounts = [];
  String? _accountsFile;
  // #267: 発行済み WebAuthn チャレンジ（base64url） → 失効エポック ms。リプレイ防止に消費する。
  final Map<String, int> _webauthnChallenges = {};
  static const Duration _webauthnChallengeTtl = Duration(minutes: 2);
  static const int _maxWebauthnChallenges = 4096;
  // #258: DNS rebinding 対策 — 許可する Host 値のセット
  Set<String> _allowedHosts = {};
  // #6: HTTPS 起動時は Secure 属性を付与
  bool _httpsEnabled = false;
  final Map<String, int> _failedAttempts = {};
  final Map<String, DateTime> _lockoutUntil = {};
  String? _uploadToken;
  List<({String pattern, String script})> _postActions = [];
  Map<String, ({String script, String? description})> _mentionActions = {};
  // #206
  int _pinLength = 4;
  String _pinCharset = 'digits';
  int? _maxDirectUploadBytes; // #262: 直接アップロードのサイズ上限 (null = 無制限)

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
      ..post('/api/webauthn/challenge', _webauthnChallengeHandler)  // #267
      ..post('/api/webauthn/verify', _webauthnVerifyHandler)        // #267
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
      ..get('/api/run/<alias>', _runActionHandler)  // #220 @run_to result
      ..post('/api/clipboard', _postClipboardHandler)
      ..delete('/api/clipboard/<id>', _deleteClipboardItemHandler)
      ..delete('/api/clipboard', _clearClipboardHandler)
      // #222: federation 状態（peer 一覧と接続状態）
      ..get('/api/federation/status', _federationStatusHandler)
      ..post('/api/federation/peers/<name>/pause', _federationPausePeerHandler)  // #223
      ..delete('/api/federation/peers/<name>/pause', _federationResumePeerHandler)  // #223
      ..delete('/api/cache/thumbnails', _clearThumbnailCacheHandler);  // #272
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

  /// #220 @run_to: child 側でエイリアスを実行して結果を返す
  Future<Response> _runActionHandler(Request req, String alias) async {
    final entry = _mentionActions[alias];
    if (entry == null) {
      return Response.notFound(
        json.encode({'error': 'alias not found: $alias'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
    try {
      // コマンドテキストを先に積む（旧: POST /api/clipboard 受信時と同じ挙動）
      _replyToClipboard('@run $alias');
      final cmd = _buildCommand(entry.script, []);
      final result = await Process.run(
        cmd.$1, cmd.$2,
        runInShell: !Platform.isWindows,
      ).timeout(const Duration(seconds: 30));
      final ok = result.exitCode == 0;
      final resultText =
          ok ? '@run $alias: OK' : '@run $alias: FAILED (exit ${result.exitCode})';
      if (!ok && (result.stderr as String).isNotEmpty) {
        stderr.writeln('[mention-action] "$alias" stderr: ${result.stderr}');
      }
      _replyToClipboard(resultText);
      _log('[mention-action] "$alias" via federation -> $resultText');
      return Response.ok(
        json.encode({'ok': ok, 'result': resultText}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response(500,
        body: json.encode({'error': '$e'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
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
    String? cacheDir,             // #287
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
    int? maxDirectUploadBytes,    // #262
    List<String> extraAllowedHosts = const [],   // #275
    int postActionTimeoutSeconds = 300,          // #290 (0 = 無制限)
    String? accountsFile,                         // #267
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
    _maxDirectUploadBytes = maxDirectUploadBytes; // #262
    _cacheDir = cacheDir;         // #287
    // #290: post-action のタイムアウト。0 以下は無制限（従来動作）。
    _postActionTimeout = postActionTimeoutSeconds > 0
        ? Duration(seconds: postActionTimeoutSeconds)
        : null;
    // #267: passkey アカウント読み込み（指定時のみ）
    _accountsFile = accountsFile;
    if (accountsFile != null) _loadAccounts(accountsFile);
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

    // #258: DNS rebinding — 許可する Host 値を事前収集（IPv4 のみ。IPv6 バインド未対応）
    _allowedHosts = {'localhost', '127.0.0.1', ipAddress};
    try {
      final ifaces = await NetworkInterface.list(includeLoopback: true);
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4) {
            _allowedHosts.add(addr.address);
          }
        }
      }
    } catch (_) {}
    // #275: cert SAN から選ばれた広告ホスト名や設定で明示された名前を許可。
    // federation（両端 HTTPS）や Tailscale の DNS 名アクセスが 421 にならないようにする。
    _allowedHosts.addAll(extraAllowedHosts);

    final staticHandler =
        createStaticHandler(_webRootDir!.path, defaultDocument: 'index.html');
    final apiHandler = const Pipeline()
        .addMiddleware(_hostGuardMiddleware)   // #258
        .addMiddleware(_federationLoopGuard)   // #221
        .addMiddleware(_authMiddleware)
        .addHandler(_router.call);
    final cascade = Cascade().add(apiHandler).add(staticHandler);

    final handler = verbose
        ? const Pipeline()
            .addMiddleware(logRequests())
            .addHandler(cascade.handler)
        : const Pipeline().addHandler(cascade.handler);

    if (httpsCertPath != null && httpsKeyPath != null) {
      _httpsEnabled = true; // #6: Secure Cookie 付与のために記憶
      final secCtx = SecurityContext()
        ..useCertificateChain(httpsCertPath)
        ..usePrivateKey(httpsKeyPath);
      _server = await shelf_io.serve(
        handler, InternetAddress.anyIPv4, port,
        securityContext: secCtx,
      );
      _log('Serving at https://$ipAddress:$port');
    } else {
      _httpsEnabled = false;
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
    // #271: PID ベースのサムネイルキャッシュも同様に削除
    try {
      final t = _thumbnailCacheDir;
      if (t != null && await t.exists()) {
        await t.delete(recursive: true);
      }
    } catch (e) {
      stderr.writeln(
          'Warning: could not remove thumbnail cache ${_thumbnailCacheDir?.path}: $e');
      stderr.writeln('  You can remove it manually.');
    }
  }

  // #242: 同プレフィックスのきょうだいディレクトリのうち、対応する PID が
  //       生きていないものを削除する。長寿の常駐サーバを巻き込まないよう
  //       mtime ベースの judge は使わず、PID 生存チェック一本でいく。
  // #269: Unix のみ、ディレクトリのパーミッションを 700 に制限
  void _chmodDir(Directory dir) {
    if (Platform.isWindows) return;
    try {
      Process.runSync('chmod', ['700', dir.path], runInShell: false);
    } catch (_) {}
  }

  // #269: Unix のみ、ファイルのパーミッションを 600 に制限
  void _chmodFile(File file) {
    if (Platform.isWindows) return;
    try {
      Process.runSync('chmod', ['600', file.path], runInShell: false);
    } catch (_) {}
  }

  // #259: サムネイルキャッシュキーをファイルの相対パス (base64url) で生成。
  //       basename のみだとサブフォルダの同名ファイルが衝突する。
  String _thumbCacheKey(String filePath) {
    final rel = p.relative(filePath, from: _storagePath!);
    return base64Url.encode(utf8.encode(rel)).replaceAll('=', '');
  }

  void _reapStaleDeployDirs(Directory base, String prefix) {
    if (!base.existsSync()) return;
    final myPid = pid;
    for (final entry in base.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (!name.startsWith(prefix)) continue;
      // #264: 新形式 <prefix><pid>_<random> と旧形式 <prefix><pid> の両方に対応
      final pidStr = name.substring(prefix.length).split('_').first;
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

  // #287: キャッシュ/一時データの基点ディレクトリ。
  // --cache-dir 指定時はそこを、なければ OS の一時ディレクトリを使う。
  Directory _cacheBaseDir() =>
      (_cacheDir != null && _cacheDir!.isNotEmpty)
          ? Directory(_cacheDir!)
          : Directory.systemTemp;

  // #287: --cache-dir を検証。作成できなければ警告して OS 一時ディレクトリに
  // フォールバックする（サーバは起動し続ける）。
  Future<void> _validateCacheDir() async {
    if (_cacheDir == null || _cacheDir!.isEmpty) return;
    final dir = Directory(_cacheDir!);
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      // 書き込み可否を実際に createTemp して確認（失敗すれば catch へ）
      final probe = await dir.createTemp('localnode_cli_probe_');
      await probe.delete();
    } catch (e) {
      stderr.writeln(
          'Warning: --cache-dir "$_cacheDir" is not usable ($e); '
          'falling back to the system temp directory.');
      _cacheDir = null;
    }
  }

  Future<void> _init(String? storagePath) async {
    if (storagePath != null) {
      _storagePath = storagePath;
    } else {
      _storagePath = Directory.current.path;
    }

    final dir = Directory(_storagePath!);
    if (!await dir.exists()) await dir.create(recursive: true);

    await _validateCacheDir(); // #287
    final cacheBase = _cacheBaseDir();

    // #271/#264: PID + OS ランダムサフィックスでインスタンス分離かつ symlink poisoning を防ぐ
    const thumbPrefix = 'localnode_cli_thumbnails_';
    _reapStaleDeployDirs(cacheBase, thumbPrefix);
    // #264: createTemp で OS がアトミックにディレクトリを生成 → パスが推測不能
    _thumbnailCacheDir =
        await cacheBase.createTemp('${thumbPrefix}${pid}_');
    // #269: 他ユーザーから読めないようにパーミッションを制限
    _chmodDir(_thumbnailCacheDir!);
  }

  Future<void> _deployAssets() async {
    final tmpBase = _cacheBaseDir().path; // #287
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
    _chmodDir(_webRootDir!); // #269

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

  // #261: 期限切れチェック付きセッション検証
  bool _isValidSession(String token) {
    final expiry = _sessions[token];
    if (expiry == null) return false;
    if (DateTime.now().millisecondsSinceEpoch > expiry) {
      _sessions.remove(token);
      _sessionAccounts.remove(token); // #267
      return false;
    }
    return true;
  }

  void _pruneExpiredSessions() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _sessions.removeWhere((token, expiry) {
      final expired = expiry < now;
      if (expired) _sessionAccounts.remove(token); // #267
      return expired;
    });
  }

  // #267: セッションを1件発行する。account を渡すと passkey ログイン扱い。
  String _createSession({String? account}) {
    final token = _generateToken();
    _pruneExpiredSessions();
    if (_authMode == _AuthMode.noPin && _sessions.length >= _maxNoPinSessions) {
      final oldest =
          _sessions.entries.reduce((a, b) => a.value < b.value ? a : b);
      _sessions.remove(oldest.key);
      _sessionAccounts.remove(oldest.key);
    }
    _sessions[token] = DateTime.now().add(_sessionTtl).millisecondsSinceEpoch;
    if (account != null) _sessionAccounts[token] = account;
    return token;
  }

  String _sessionCookie(String token) =>
      'localnode_session=$token; Path=/; HttpOnly; SameSite=Strict'
      '${_httpsEnabled ? '; Secure' : ''}';

  // #267: リクエストのセッション Cookie からアカウント名を取り出す（無ければ null=guest）。
  String? _sessionAccountOf(Request req) {
    final cookie = req.headers['cookie'] ?? '';
    for (final c in cookie.split(';')) {
      final t = c.trim();
      if (t.startsWith('localnode_session=')) {
        final token = t.substring(t.indexOf('=') + 1);
        if (_isValidSession(token)) return _sessionAccounts[token];
      }
    }
    return null;
  }

  // #267: passkey アカウントを YAML ファイルから読み込む（authorized_keys 相当）。
  // 形式:  accounts:
  //          - name: shiba
  //            credential_id: <base64url>
  //            public_key: <base64 SPKI DER>
  // 読めなくても passkey が無効になるだけでサーバは起動を続ける。
  void _loadAccounts(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln(
          'Warning: accounts file not found: $path (passkey login disabled)');
      return;
    }
    try {
      final doc = loadYaml(file.readAsStringSync());
      final list = (doc is YamlMap) ? doc['accounts'] : null;
      if (list is! YamlList) {
        stderr.writeln('Error: accounts file must contain an "accounts:" list.');
        return;
      }
      final acc = <_PasskeyAccount>[];
      final seen = <String>{};
      for (final e in list) {
        if (e is! YamlMap) continue;
        final name = e['name']?.toString();
        final cid = e['credential_id']?.toString();
        final pk = e['public_key']?.toString();
        if (name == null || cid == null || pk == null) {
          stderr.writeln('Warning: skipping incomplete account entry.');
          continue;
        }
        if (!seen.add(cid)) {
          stderr.writeln('Warning: duplicate credential_id for "$name", skipping.');
          continue;
        }
        try {
          acc.add(_PasskeyAccount(name, cid, base64.decode(pk)));
        } catch (_) {
          stderr.writeln('Warning: account "$name" has an invalid public_key.');
        }
      }
      _accounts = acc;
      if (_accounts.isNotEmpty) {
        _log('[passkey] loaded ${_accounts.length} account(s) from $path');
      }
    } catch (e) {
      stderr.writeln('Error reading accounts file: $e');
    }
  }

  // #265: セッション Cookie または Bearer トークンが有効なリクエストか判定
  bool _isAuthenticatedRequest(Request req) {
    if (_authMode == _AuthMode.noPin) return true;
    final cookie = req.headers['cookie'] ?? '';
    for (final c in cookie.split(';')) {
      final t = c.trim();
      if (t.startsWith('localnode_session=')) {
        final token = t.substring(t.indexOf('=') + 1);
        if (_isValidSession(token)) return true;
      }
    }
    if (_uploadToken != null) {
      final auth = req.headers['authorization'] ?? '';
      if (auth == 'Bearer $_uploadToken') return true;
    }
    return false;
  }

  // #260: タイミング攻撃を防ぐ定数時間文字列比較
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }

  // #263: アップロードファイル名のサニタイズ。空になった場合は null を返す
  String? _sanitizeFilename(String name) {
    // 制御文字 (0x00–0x1F, 0x7F) を除去
    var s = name.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
    // パス区切り・Windows 禁止文字を除去
    s = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    // 先頭・末尾のドット/スペース（Windows で非表示になる）を除去
    s = s.replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
    // Windows 予約デバイス名 (CON, PRN, AUX, NUL, COM1-9, LPT1-9) に接頭辞を付加
    if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..+)?$', caseSensitive: false).hasMatch(s)) {
      s = '_$s';
    }
    return s.isEmpty ? null : s;
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

  // #258: DNS rebinding 対策 — Host ヘッダが既知の IP/ホスト名と一致しない場合は拒否
  Middleware get _hostGuardMiddleware => (inner) {
        return (req) {
          if (_allowedHosts.isEmpty) return inner(req);
          final host = req.headers['host'];
          // #275: Host 欠落は fail-closed で拒否（正規のブラウザ/peer/curl は必ず付与する）
          if (host == null) {
            return Response(
              421,
              body: 'Missing Host header',
              headers: {'Content-Type': 'text/plain'},
            );
          }
          // Host ヘッダはポート付き ("192.168.1.1:8080") の場合があるのでポートを除去
          final hostWithoutPort = host.replaceFirst(RegExp(r':\d+$'), '');
          if (!_allowedHosts.contains(hostWithoutPort)) {
            return Response(
              421,
              body: 'Misdirected Request',
              headers: {'Content-Type': 'text/plain'},
            );
          }
          return inner(req);
        };
      };

  Middleware get _authMiddleware => (inner) {
        return (req) {
          final path = req.url.path;
          if (!path.startsWith('api/') ||
              path == 'api/info' ||
              path == 'api/auth' ||
              path == 'api/webauthn/challenge' || // #267
              path == 'api/webauthn/verify' ||    // #267
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
          if (token != null && _isValidSession(token)) return inner(req);

          // #173/#188: Bearer トークンによる API 認証（スコープ限定）
          //   - POST /api/upload      … ファイルアップロード（#173）
          //   - POST /api/clipboard   … クリップボードへの送信（#188）
          //   - GET  /api/mentions    … federation @list <child> 用（#220）
          // x-fed-origin の有無でスコープを広げない。ヘッダは任意クライアントが
          // 付加できるため、列挙したエンドポイント以外への昇格には使えない。
          if (_uploadToken != null) {
            final authHeader = req.headers['authorization'] ?? '';
            // #284: トークン比較も定数時間で（PIN と一貫性を取る）
            if (_constantTimeEquals(authHeader, 'Bearer $_uploadToken')) {
              if ((req.method == 'POST' &&
                      (path == 'api/upload' || path == 'api/clipboard')) ||
                  (req.method == 'GET' &&
                      (path == 'api/mentions' ||
                          path.startsWith('api/run/'))) ||
                  (req.method == 'DELETE' &&
                      path == 'api/cache/thumbnails')) {
                // F10: x-fed-origin が存在する場合、既知の peer の deviceId と一致するか検証。
                // 存在しない場合は通常の Bearer 利用（curl 等）として許可。
                // 一致しない deviceId を使った peer 偽装を防ぐ。
                final origin = req.headers[_kFedOrigin];
                if (origin != null &&
                    !_federationPeers
                        .any((p) => p.learnedDeviceId == origin)) {
                  return Response.forbidden(
                    json.encode({'error': 'Unknown federation origin.'}),
                    headers: {'Content-Type': 'application/json'},
                  );
                }
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
      final token = _createSession();
      return Response.ok(json.encode({'status': 'success'}), headers: {
        'Content-Type': 'application/json',
        'Set-Cookie': _sessionCookie(token),
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
      if (_pin != null && _constantTimeEquals(params['pin'] as String? ?? '', _pin!)) {
        _failedAttempts.remove(clientIp);
        _lockoutUntil.remove(clientIp);
        final token = _createSession();
        return Response.ok(json.encode({'status': 'success'}), headers: {
          'Content-Type': 'application/json',
          'Set-Cookie': _sessionCookie(token),
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

  // === #267: passkey (WebAuthn) 認証 =========================================

  // base64url（パディング有無どちらでも）→ bytes
  Uint8List _b64urlDecode(String s) {
    var t = s.replaceAll('-', '+').replaceAll('_', '/');
    while (t.length % 4 != 0) {
      t += '=';
    }
    return base64.decode(t);
  }

  String _b64urlNoPad(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  void _pruneWebauthnChallenges() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _webauthnChallenges.removeWhere((_, exp) => exp < now);
  }

  // リクエストの Host からポートを除いたホスト名（= WebAuthn の rpId 候補）。
  String? _rpIdForRequest(Request req) {
    final host = req.headers['host'];
    if (host == null) return null;
    return host.replaceFirst(RegExp(r':\d+$'), '');
  }

  // clientData.origin が自サーバのものか（ホストが許可集合にある）を確認。
  bool _isAllowedWebauthnOrigin(String origin) {
    try {
      final u = Uri.parse(origin);
      if (u.host.isEmpty) return false;
      return _allowedHosts.contains(u.host);
    } catch (_) {
      return false;
    }
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var r = 0;
    for (var i = 0; i < a.length; i++) {
      r |= a[i] ^ b[i];
    }
    return r == 0;
  }

  // POST /api/webauthn/challenge : ログイン用のチャレンジ(nonce)を発行する。
  Response _webauthnChallengeHandler(Request req) {
    if (_accounts.isEmpty) {
      return Response.notFound(
        json.encode({'error': 'Passkey login is not configured.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
    _pruneWebauthnChallenges();
    // 未認証エンドポイントなので、TTL 内スパムでのメモリ肥大を上限で抑える
    // （超過時は最古を1件退避）。
    if (_webauthnChallenges.length >= _maxWebauthnChallenges) {
      final oldest =
          _webauthnChallenges.entries.reduce((a, b) => a.value < b.value ? a : b);
      _webauthnChallenges.remove(oldest.key);
    }
    final r = Random.secure();
    final challenge =
        _b64urlNoPad(List<int>.generate(32, (_) => r.nextInt(256)));
    _webauthnChallenges[challenge] =
        DateTime.now().add(_webauthnChallengeTtl).millisecondsSinceEpoch;
    return Response.ok(
      json.encode({
        'challenge': challenge,
        'rpId': _rpIdForRequest(req),
        'timeout': 60000,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  // POST /api/webauthn/verify : WebAuthn assertion を検証してセッションを発行する。
  Future<Response> _webauthnVerifyHandler(Request req) async {
    if (_accounts.isEmpty) {
      return Response.forbidden(
        json.encode({'error': 'Passkey login is not configured.'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
    Response fail(int status, String msg) => Response(status,
        body: json.encode({'error': msg}),
        headers: {'Content-Type': 'application/json'});

    final clientIp = _getClientIp(req);
    final lockout = _lockoutUntil[clientIp];
    if (lockout != null && DateTime.now().isBefore(lockout)) {
      final rem = lockout.difference(DateTime.now()).inSeconds;
      return fail(403, 'Locked out. Try again in $rem seconds.');
    }

    Map<String, dynamic> body;
    try {
      body = json.decode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return fail(400, 'Invalid request body.');
    }
    final credentialId = body['credentialId'] as String?;
    final authDataB64 = body['authenticatorData'] as String?;
    final clientDataB64 = body['clientDataJSON'] as String?;
    final signatureB64 = body['signature'] as String?;
    if (credentialId == null ||
        authDataB64 == null ||
        clientDataB64 == null ||
        signatureB64 == null) {
      return fail(400, 'Missing assertion fields.');
    }

    final account =
        _accounts.firstWhereOrNullExt((a) => a.credentialId == credentialId);
    if (account == null) return fail(401, 'Unknown credential.');

    void recordFailure() {
      final attempts = (_failedAttempts[clientIp] ?? 0) + 1;
      _failedAttempts[clientIp] = attempts;
      if (attempts >= _maxFailedAttempts) {
        _lockoutUntil[clientIp] = DateTime.now().add(_lockoutDuration);
        _failedAttempts.remove(clientIp);
      }
    }

    try {
      final authData = _b64urlDecode(authDataB64);
      final clientData = _b64urlDecode(clientDataB64);
      final signature = _b64urlDecode(signatureB64);

      // 1) clientDataJSON の検証
      final cd = json.decode(utf8.decode(clientData)) as Map<String, dynamic>;
      if (cd['type'] != 'webauthn.get') {
        recordFailure();
        return fail(401, 'Bad clientData type.');
      }
      final challenge = cd['challenge'] as String?;
      _pruneWebauthnChallenges();
      // チャレンジは1回限り（消費してリプレイを防ぐ）
      if (challenge == null || _webauthnChallenges.remove(challenge) == null) {
        recordFailure();
        return fail(401, 'Invalid or expired challenge.');
      }
      final origin = cd['origin'] as String?;
      if (origin == null || !_isAllowedWebauthnOrigin(origin)) {
        recordFailure();
        return fail(401, 'Bad origin.');
      }

      // 2) authenticatorData の検証（rpIdHash / user-present フラグ）
      if (authData.length < 37) {
        recordFailure();
        return fail(401, 'Bad authenticator data.');
      }
      final rpId = Uri.parse(origin).host;
      final expectedRpHash =
          CryptoUtils.getHashPlain(Uint8List.fromList(utf8.encode(rpId)));
      if (!_bytesEqual(authData.sublist(0, 32), expectedRpHash)) {
        recordFailure();
        return fail(401, 'rpId mismatch.');
      }
      final flags = authData[32];
      if ((flags & 0x01) == 0) {
        recordFailure();
        return fail(401, 'User presence flag not set.');
      }

      // 3) 署名検証: sig は (authData || SHA256(clientDataJSON)) に対する ES256
      final clientDataHash =
          CryptoUtils.getHashPlain(Uint8List.fromList(clientData));
      final signedData =
          Uint8List.fromList([...authData, ...clientDataHash]);
      final pubKey = CryptoUtils.ecPublicKeyFromDerBytes(account.publicKeySpki);
      final sig =
          CryptoUtils.ecSignatureFromDerBytes(Uint8List.fromList(signature));
      final ok = CryptoUtils.ecVerify(pubKey, signedData, sig,
          algorithm: 'SHA-256/ECDSA');
      if (!ok) {
        recordFailure();
        return fail(401, 'Signature verification failed.');
      }

      // 成功: アカウント付きセッションを発行
      _failedAttempts.remove(clientIp);
      _lockoutUntil.remove(clientIp);
      final token = _createSession(account: account.name);
      _log('[passkey] login ok: ${account.name} from $clientIp');
      return Response.ok(
        json.encode({'status': 'success', 'account': account.name}),
        headers: {
          'Content-Type': 'application/json',
          'Set-Cookie': _sessionCookie(token),
        },
      );
    } catch (e) {
      recordFailure();
      return fail(401, 'Assertion verification error.');
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

  Response _infoHandler(Request req) {
    final authed = _isAuthenticatedRequest(req);
    return Response.ok(
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
        // #267: passkey ログインが使えるか（accounts が1件以上）。Web UI がボタン表示に使う。
        'passkeyEnabled': _accounts.isNotEmpty,
        // #267: ログイン中のアカウント名（passkey セッションのみ。未ログイン/guest は null）
        if (authed) 'account': _sessionAccountOf(req),
        // #265: deviceId は認証済みリクエストにのみ返す
        // federation heartbeat は Bearer トークン付きで /api/info を叩くため引き続き取得可能
        if (authed) 'deviceId': _deviceId,
        // #206: Web UI が PIN 入力モードを切り替えるためのヒント
        'pinCharset': _pinCharset,
        'pinLength': _pinLength,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

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
    final rawName = p.basename(Uri.decodeComponent(encodedName));
    if (rawName.codeUnits.any((c) => c < 32 || c == 127)) {
      return Response.badRequest(body: 'Invalid filename.');
    }
    final filename = _sanitizeFilename(rawName);
    if (filename == null) {
      return Response.badRequest(body: 'Invalid filename.');
    }

    // サイズ検査: federation quota → 直接アップロード上限
    final clHeader = req.headers['content-length'];
    final cl = clHeader != null ? int.tryParse(clHeader) : null;
    if (cl != null) {
      // #219: federation 由来のアップロードなら送信元 child の max_upload_size を検査
      final quotaResp = _checkFederationUploadQuota(req, cl);
      if (quotaResp != null) return quotaResp;
      // #262: 直接アップロード（非 federation）にグローバル上限を適用
      final isFed = req.headers[_kFedOrigin]?.isNotEmpty == true;
      if (!isFed && _maxDirectUploadBytes != null && cl > _maxDirectUploadBytes!) {
        return Response(413,
            body: json.encode({
              'error': 'too-large',
              'message': 'Upload exceeds server limit of $_maxDirectUploadBytes bytes.',
            }),
            headers: {'Content-Type': 'application/json'});
      }
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
      // #214: x-clipboard-text / x-clipboard-link 指定時はクリップボードにも通知
      _maybePostUploadClipboard(req, file, relPath);
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
      // cmd.exe メタ文字（& | ^ < > ( ) % ! ;）をアンダースコアに置換して
      // ファイル名経由のコマンドインジェクションを防ぐ
      final safeArgs = extraArgs
          .map((a) => a.replaceAll(RegExp(r'[&|^<>()\%;!]'), '_'))
          .toList();
      if (script.toLowerCase().endsWith('.ps1')) {
        return (
          'cmd',
          ['/c', 'powershell.exe', '-ExecutionPolicy', 'Bypass', '-File', script, ...safeArgs]
        );
      }
      return ('cmd', ['/c', script, ...safeArgs]);
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

  // #181: post-action は「サーバ全体で1本のキュー」に直列化する。
  // 元は各アクションを await せず並列起動していたため、同一ファイルに複数
  // マッチすると実行順が不定になり、先行アクションがファイルを移動/削除
  // すると後続が不定に失敗していた。ファイル内を逐次化しただけでは複数
  // ファイルを同時アップロードしたときにファイル間で混ざる
  // (move(A),move(B),move(C) -> notify(A),notify(C),notify(B)) ため、
  // キュー全体を直列にして「A:move -> A:notify -> B:move -> ...」と
  // 完全に予測可能な順序にする。post-action スクリプトは同時実行を想定して
  // いないことが多いので、その点でも安全。
  // アップロード応答はブロックしない（fire-and-forget のまま）。
  Future<void> _postActionQueue = Future.value();
  // #290: 1本ハングするとキュー全体が止まるので、各アクションにタイムアウトを
  // 設ける。null なら無制限（従来動作）。
  Duration? _postActionTimeout = const Duration(seconds: 300);

  // #290: スクリプトをタイムアウト付きで実行。時間超過時はプロセスを kill する。
  // 注意: 出力ストリームは await せず listen で消費する。runInShell 経由だと
  // タイムアウトで殺したシェルの子プロセスが stdout パイプを握ったまま残ることが
  // あり、drain/join を await するとそこで固まってキュー全体が止まるため。
  // プロセス終了とタイムアウトを Completer で競わせ、どちらか早い方で返す。
  // （スクリプトがさらに子プロセスを detach した場合、その孫までは確実には
  //   刈り取れない。ここで保証するのは「キューを二度と詰まらせない」こと。）
  Future<({int exitCode, bool timedOut, String stderr})> _runScript(
      String exe, List<String> args, Duration? timeout) async {
    final proc = await Process.start(exe, args, runInShell: !Platform.isWindows);
    final errBuf = StringBuffer();
    proc.stdout.listen((_) {}, onError: (_) {});
    proc.stderr.transform(utf8.decoder).listen(errBuf.write, onError: (_) {});

    if (timeout == null) {
      final code = await proc.exitCode;
      return (exitCode: code, timedOut: false, stderr: errBuf.toString());
    }
    final completer =
        Completer<({int exitCode, bool timedOut, String stderr})>();
    final timer = Timer(timeout, () {
      if (completer.isCompleted) return;
      proc.kill(ProcessSignal.sigkill);
      completer
          .complete((exitCode: -1, timedOut: true, stderr: errBuf.toString()));
    });
    unawaited(proc.exitCode.then((code) {
      if (completer.isCompleted) return;
      timer.cancel();
      completer.complete(
          (exitCode: code, timedOut: false, stderr: errBuf.toString()));
    }));
    return completer.future;
  }

  void _runPostActions(String filePath) {
    final filename = p.basename(filePath);
    final matched = _postActions
        .where((a) => _globMatch(a.pattern, filename))
        .toList();
    if (matched.isEmpty) return;
    _postActionQueue = _postActionQueue.then((_) async {
      for (final action in matched) {
        try {
          final cmd = _buildCommand(action.script, [filePath]);
          final r = await _runScript(cmd.$1, cmd.$2, _postActionTimeout);
          if (r.timedOut) {
            stderr.writeln('[post-action] "${action.script}" timed out after '
                '${_postActionTimeout!.inSeconds}s (killed) for $filename');
          } else if (r.exitCode != 0) {
            stderr.writeln(
                '[post-action] "${action.script}" exited ${r.exitCode}');
            if (r.stderr.isNotEmpty) stderr.writeln(r.stderr);
          } else {
            _log('[post-action] "${action.script}" completed for $filename');
          }
        } catch (e) {
          stderr.writeln('[post-action] Failed to run "${action.script}": $e');
        }
      }
    });
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

  void _replyToClipboard(String text) =>
      _appendClipboard(text, tag: 'mention-result');

  // クリップボードに1件追加して lastModified を更新する共通処理。
  void _appendClipboard(String text, {String? tag, bool important = false}) {
    final item = _ClipboardItem(
      id: _generateId(),
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
  void _maybePostUploadClipboard(Request req, File file, String relPath) {
    if (!_clipboardEnabled) return;
    final text = _decodeHeader(req.headers['x-clipboard-text'])?.trim();
    final rawTag = _decodeHeader(req.headers['x-clipboard-tag'])?.trim();
    final link = req.headers['x-clipboard-link']?.trim();
    final tag = (rawTag != null && rawTag.isNotEmpty) ? rawTag : null;

    String? msg;
    if (text != null && text.isNotEmpty) {
      msg = text;
    } else if (link == '1') {
      final saved = p.basename(file.path);
      final rel = relPath.isEmpty ? saved : '$relPath/$saved';
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
      // #259: キャッシュキーに相対パスを使い、サブフォルダの同名ファイルの衝突を防ぐ
      final cache = File(p.join(_thumbnailCacheDir!.path, '${_thumbCacheKey(filePath)}.jpg'));
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
      await cache.writeAsBytes(thumbBytes);
      _chmodFile(cache); // #269
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
    // #287: --cache-dir 指定時はそこに置く（zip も大きくなり得るため）
    final tempDir = await _cacheBaseDir().createTemp('localnode_zip_');
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
          p.join(_thumbnailCacheDir!.path, '${_thumbCacheKey(filePath)}.jpg'));
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
        await file.delete();
        deleted++;
        final cache = File(p.join(_thumbnailCacheDir!.path, '${_thumbCacheKey(filePath)}.jpg'));
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
      // #267: タグ未指定なら passkey ログイン中のアカウント名を既定タグにする
      //       （誰が投稿したか分かる＝クリップボードが軽量な複数人チャットになる）。
      final tag = (rawTag != null && rawTag.isNotEmpty)
          ? rawTag
          : _sessionAccountOf(req);

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
      // F11: Bearer トークン経由（federation / curl）からは mention を実行しない。
      //      ブラウザのセッション Cookie 経由のローカル操作のみ許可。
      final isBearerRequest =
          (req.headers['authorization'] ?? '').startsWith('Bearer ');
      if (!important && !isBearerRequest) {
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
          if (peer.relation == 'equally') {
            _replyToClipboard(
                '[$childName] Note: @run_to results will not be forwarded from equally-relation child');
          }
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

  /// `@run_to <name> <alias>` を解決して子の /api/run/<alias> を直接 GET し結果を自分の clipboard に投稿する
  void _dispatchRunToChild(String childName, String alias) {
    final peer = _federationPeers.firstWhereOrNullExt(
        (p) => p.kind == 'child' && p.name == childName);
    if (peer == null) {
      _replyToClipboard('@run_to $childName: child not found');
      return;
    }
    () async {
      try {
        _heartbeatClient ??=
            HttpClient()..connectionTimeout = const Duration(seconds: 10);
        final uri = Uri.parse(
            '${peer.url}/api/run/${Uri.encodeComponent(alias)}');
        final req = await _heartbeatClient!.getUrl(uri);
        req.headers.set('Authorization', 'Bearer ${peer.token}');
        req.headers.set(_kFedRelation, peer.relation);
        final res =
            await req.close().timeout(const Duration(seconds: 35));
        if (res.statusCode == 200) {
          final body = await res.transform(utf8.decoder).join();
          final data = json.decode(body) as Map<String, dynamic>;
          final resultText =
              data['result'] as String? ?? '@run_to $childName $alias: ok';
          _replyToClipboard('[$childName] $resultText');
          _log('[fed] @run_to ${peer.name} $alias ok');
        } else {
          await res.drain();
          _replyToClipboard(
              '@run_to $childName $alias: failed (HTTP ${res.statusCode})');
        }
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

  // #272: 起動中にサムネイルキャッシュをクリアする（認証はミドルウェア済み）
  Future<Response> _clearThumbnailCacheHandler(Request req) async {
    final dir = _thumbnailCacheDir;
    if (dir == null || !await dir.exists()) {
      return Response.ok(json.encode({'status': 'cleared', 'count': 0}),
          headers: {'Content-Type': 'application/json'});
    }
    int count = 0;
    await for (final entry in dir.list()) {
      try {
        await entry.delete();
        count++;
      } catch (_) {}
    }
    return Response.ok(json.encode({'status': 'cleared', 'count': count}),
        headers: {'Content-Type': 'application/json'});
  }
}
