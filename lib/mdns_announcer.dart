// mDNS / DNS-SD service announcer (#308).
//
// Pure Dart (dart:io only, no Flutter dependency) so that it can be shared by
// the Flutter GUI / `--cli` runner (lib/server_service.dart) and the
// standalone `bin/localnode_cli.dart` binary.
//
// Publishes a single DNS-SD service so that other devices on the LAN can find
// this LocalNode server without typing an IP address:
//
//   _localnode._tcp.local.                 PTR  <instance>._localnode._tcp.local.
//   <instance>._localnode._tcp.local.      SRV  0 0 <port> <host>.local.
//   <instance>._localnode._tcp.local.      TXT  txtvers=1 scheme=http path=/ ...
//   <host>.local.                          A    <ip>
//
// This is announcement only. Discovery is done by the launcher app.
// Limitations: IPv4 only, a single advertised address, no AAAA records and
// no known-answer suppression.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class MdnsAnnouncer {
  /// DNS-SD service type browsed by the launcher app.
  static const String defaultServiceType = '_localnode._tcp';

  static const int _mdnsPort = 5353;
  static const int _typeA = 1;
  static const int _typePtr = 12;
  static const int _typeTxt = 16;
  static const int _typeSrv = 33;
  static const int _typeAny = 255;
  static const int _ttlService = 4500;
  static const int _ttlHost = 120;
  static const int _maxLabelBytes = 63;

  static final InternetAddress _group = InternetAddress('224.0.0.251');

  MdnsAnnouncer({
    required String instanceName,
    required this.port,
    required this.address,
    String? hostLabel,
    this.serviceType = defaultServiceType,
    this.txt = const {},
    this.onLog,
  })  : _instanceName = _truncateLabel(
            instanceName.trim().isEmpty ? 'LocalNode' : instanceName.trim()),
        hostLabel = hostLabel ?? defaultHostLabel();

  /// TCP port of the HTTP(S) server.
  final int port;

  /// IPv4 address published in the A record.
  final String address;

  /// `<label>` of `<label>.local.`; deterministic so callers can allow it as a
  /// Host header value before the announcer is started.
  final String hostLabel;

  final String serviceType;
  final Map<String, String> txt;
  final void Function(String message)? onLog;

  String _instanceName;
  // Receives queries (bound to 0.0.0.0:5353).
  RawDatagramSocket? _socket;
  // Sends announcements/replies out of the interface that owns [address]
  // (bound to <address>:5353 with IP_MULTICAST_IF). Without it the OS picks
  // the egress interface by routing metric, which on multi-homed machines
  // (Windows with Wi-Fi + Ethernet + Hyper-V/WSL/VPN adapters) is often not
  // the LAN the server was started on.
  RawDatagramSocket? _sendSocket;
  String? _egressInterface;
  Timer? _announceTimer;
  final Map<String, int> _lastReplyMs = {};
  bool _stopped = false;

  /// Instance name actually published (may get a " (2)" suffix on conflict).
  String get instanceName => _instanceName;

  /// `<label>.local` (without trailing dot).
  String get hostName => '$hostLabel.local';

  bool get isRunning => _socket != null && !_stopped;

  /// Name of the network interface announcements are sent from, if it could
  /// be determined (diagnostics).
  String? get egressInterface => _egressInterface;

  // ---------------------------------------------------------------------------
  // Public helpers
  // ---------------------------------------------------------------------------

  /// Host label derived from the machine's host name, e.g. `macbook-localnode`.
  /// A dedicated name is used so we never clash with the host record that the
  /// OS responder (Bonjour / Avahi) publishes for the machine itself.
  static String defaultHostLabel() {
    var base = '';
    try {
      base = Platform.localHostname;
    } catch (_) {}
    final dot = base.indexOf('.');
    if (dot > 0) base = base.substring(0, dot);
    base = base
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    if (base.length > 40) base = base.substring(0, 40);
    return base.isEmpty ? 'localnode' : '$base-localnode';
  }

  /// TXT record contents shared by GUI and CLI so the launcher sees the same
  /// schema everywhere.
  static Map<String, String> buildTxt({
    required bool https,
    required String serverName,
    required bool authRequired,
    required String version,
    String? host,
  }) {
    return {
      'txtvers': '1',
      'scheme': https ? 'https' : 'http',
      'path': '/',
      'name': serverName,
      'auth': authRequired ? 'pin' : 'none',
      'ver': version,
      // HTTPS: certificate host name to use instead of the resolved address.
      if (host != null && host.isNotEmpty) 'host': host,
    };
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Binds the mDNS socket, resolves instance-name conflicts and announces the
  /// service. Throws [SocketException] if port 5353 cannot be used.
  Future<void> start() async {
    if (_socket != null) return;
    if (InternetAddress.tryParse(address)?.type != InternetAddressType.IPv4) {
      throw ArgumentError.value(address, 'address', 'must be an IPv4 address');
    }
    _stopped = false;

    final socket = await _bind();
    _socket = socket;
    socket.multicastLoopback = true;
    final iface = await _interfaceOwningAddress();
    _egressInterface = iface?.name;
    await _joinGroups(socket, iface);
    socket.listen(_onSocketEvent, onError: (_) {}, cancelOnError: false);
    _sendSocket = await _openSendSocket();

    await _resolveConflicts();
    _announce(ttlZero: false);
    // RFC 6762 §8.3: announce at least twice, one second apart.
    _announceTimer = Timer(const Duration(seconds: 1), () {
      if (!_stopped) _announce(ttlZero: false);
    });
    onLog?.call('mDNS: announcing "$_instanceName" as '
        '$serviceType.local on $address:$port ($hostName) '
        'via ${_egressInterface ?? 'default interface'}');
  }

  /// Sends goodbye packets (TTL 0) and releases the socket.
  Future<void> stop() async {
    if (_socket == null) return;
    _stopped = true;
    _announceTimer?.cancel();
    _announceTimer = null;
    try {
      _announce(ttlZero: true);
    } catch (_) {}
    // Give the goodbye packet a moment to leave the socket before closing.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _sendSocket?.close();
    _sendSocket = null;
    _socket?.close();
    _socket = null;
    _lastReplyMs.clear();
    onLog?.call('mDNS: stopped');
  }

  // ---------------------------------------------------------------------------
  // Socket handling
  // ---------------------------------------------------------------------------

  Future<RawDatagramSocket> _bind() async {
    try {
      return await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _mdnsPort,
        reuseAddress: true,
        // reusePort is not supported on Windows (reuseAddress is sufficient).
        reusePort: !Platform.isWindows,
      );
    } on SocketException {
      return await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _mdnsPort,
        reuseAddress: true,
        reusePort: false,
      );
    }
  }

  /// The interface that has [address], or null if it is not found.
  Future<NetworkInterface?> _interfaceOwningAddress() async {
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in ifaces) {
        if (iface.addresses.any((a) => a.address == address)) return iface;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _joinGroups(
      RawDatagramSocket socket, NetworkInterface? owner) async {
    // Prefer only the interface the server is bound to, so that queries from
    // other segments are not answered with an address they cannot reach.
    if (owner != null) {
      try {
        socket.joinMulticast(_group, owner);
        return;
      } catch (e) {
        onLog?.call('mDNS: could not join group on ${owner.name}: $e');
      }
    }
    var joined = false;
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in ifaces) {
        try {
          socket.joinMulticast(_group, iface);
          joined = true;
        } catch (_) {}
      }
    } catch (_) {}
    if (!joined) {
      socket.joinMulticast(_group);
    }
  }

  // IP_MULTICAST_IF: 32 on Linux/Android, 9 on macOS/iOS/Windows.
  int get _ipMulticastIf =>
      (Platform.isLinux || Platform.isAndroid) ? 32 : 9;

  /// Opens a socket bound to our own address so multicast leaves through the
  /// right interface. Returns null (the receive socket is used) on failure.
  Future<RawDatagramSocket?> _openSendSocket() async {
    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(
        InternetAddress(address),
        _mdnsPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      sock.multicastLoopback = true;
      sock.setRawOption(RawSocketOption(
        RawSocketOption.levelIPv4,
        _ipMulticastIf,
        Uint8List.fromList(InternetAddress(address).rawAddress),
      ));
      // Nothing is expected here, but drain it so the buffer cannot fill up.
      sock.listen((e) {
        if (e == RawSocketEvent.read) {
          while (sock!.receive() != null) {}
        }
      }, onError: (_) {});
      return sock;
    } catch (e) {
      onLog?.call('mDNS: could not select the outgoing interface '
          '($address): $e; using the default one');
      sock?.close();
      return null;
    }
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;
    Datagram? dg;
    while ((dg = socket.receive()) != null) {
      try {
        _handleDatagram(dg!);
      } catch (_) {
        // Malformed packet from the network: ignore.
      }
    }
  }

  void _send(Uint8List data) {
    final sock = _sendSocket ?? _socket;
    sock?.send(data, _group, _mdnsPort);
  }

  // ---------------------------------------------------------------------------
  // Names / records
  // ---------------------------------------------------------------------------

  List<String> get _typeName => [...serviceType.split('.'), 'local'];
  List<String> get _instanceFqdn => [_instanceName, ..._typeName];
  List<String> get _hostFqdn => [hostLabel, 'local'];
  static const List<String> _enumName = [
    '_services',
    '_dns-sd',
    '_udp',
    'local'
  ];

  _Rr get _ptr => _Rr(_typeName, _typePtr, false, _ttlService,
      _encodeName(_instanceFqdn));

  _Rr get _enumPtr => _Rr(_enumName, _typePtr, false, _ttlService,
      _encodeName(_typeName));

  _Rr get _srv {
    final b = BytesBuilder();
    b.add([0, 0, 0, 0, port >> 8 & 0xff, port & 0xff]);
    b.add(_encodeName(_hostFqdn));
    return _Rr(_instanceFqdn, _typeSrv, true, _ttlHost, b.toBytes());
  }

  _Rr get _txt {
    final b = BytesBuilder();
    for (final e in txt.entries) {
      final bytes = utf8.encode('${e.key}=${e.value}');
      final len = min(bytes.length, 255);
      b.addByte(len);
      b.add(bytes.sublist(0, len));
    }
    if (b.isEmpty) b.addByte(0);
    return _Rr(_instanceFqdn, _typeTxt, true, _ttlService, b.toBytes());
  }

  _Rr get _a {
    final raw = InternetAddress(address).rawAddress;
    return _Rr(_hostFqdn, _typeA, true, _ttlHost, Uint8List.fromList(raw));
  }

  void _announce({required bool ttlZero}) {
    final answers = [_ptr, _srv, _txt, _a, _enumPtr];
    _send(_encodeResponse(answers, const [], ttlZero: ttlZero));
  }

  // ---------------------------------------------------------------------------
  // Query handling / conflict detection
  // ---------------------------------------------------------------------------

  void _handleDatagram(Datagram dg) {
    final msg = _Message.parse(dg.data);
    if (msg == null) return;
    if (msg.isResponse) {
      _onResponse(msg); // only conflict probing cares about responses
      return;
    }
    if (_stopped) return;

    final answers = <_Rr>[];
    final extras = <_Rr>[];
    for (final q in msg.questions) {
      final name = q.name.map((s) => s.toLowerCase()).join('.');
      final type = q.type;
      if (name == _typeName.join('.').toLowerCase() &&
          (type == _typePtr || type == _typeAny)) {
        answers.add(_ptr);
        extras..add(_srv)..add(_txt)..add(_a);
      } else if (name == _enumName.join('.') &&
          (type == _typePtr || type == _typeAny)) {
        answers.add(_enumPtr);
      } else if (name == _instanceFqdn.join('.').toLowerCase()) {
        if (type == _typeSrv || type == _typeAny) answers.add(_srv);
        if (type == _typeTxt || type == _typeAny) answers.add(_txt);
        if (answers.isNotEmpty) extras.add(_a);
      } else if (name == _hostFqdn.join('.').toLowerCase() &&
          (type == _typeA || type == _typeAny)) {
        answers.add(_a);
      }
    }
    if (answers.isEmpty) return;

    // Cheap rate limit: do not repeat an identical reply more than once a
    // second (RFC 6762 §6).
    final key = answers.map((r) => '${r.type}:${r.name.join('.')}').join('|');
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastReplyMs[key];
    if (last != null && now - last < 1000) return;
    _lastReplyMs[key] = now;

    final answerKeys = answers.map((r) => '${r.type}:${r.name.join('.')}').toSet();
    final additional = extras
        .where((r) => !answerKeys.contains('${r.type}:${r.name.join('.')}'))
        .toList();
    _send(_encodeResponse(answers, additional, ttlZero: false));
  }

  /// Probes for another host using the same instance name (e.g. two machines
  /// both left on the default name "LocalNode") and appends " (2)", " (3)", ...
  Future<void> _resolveConflicts() async {
    for (var attempt = 0; attempt < 9; attempt++) {
      _conflictSeen = false;
      _probing = true;
      _send(_encodeQuery(_instanceFqdn, _typeAny));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      _probing = false;
      if (!_conflictSeen) return;
      _instanceName =
          _truncateLabel('${_baseInstanceName()} (${attempt + 2})');
    }
  }

  bool _probing = false;
  bool _conflictSeen = false;

  void _onResponse(_Message msg) {
    if (!_probing) return;
    for (final r in msg.records) {
      if (r.type != _typeSrv || !_sameName(r.name, _instanceFqdn)) continue;
      final other = _srvTarget(msg.raw, r);
      if (other == null) continue;
      // Our own looped-back announcements carry the same port + host.
      final mine = other.port == port && _sameName(other.target, _hostFqdn);
      if (!mine) _conflictSeen = true;
    }
  }

  String _baseInstanceName() =>
      _instanceName.replaceFirst(RegExp(r' \(\d+\)$'), '');

  ({int port, List<String> target})? _srvTarget(Uint8List raw, _RrRef r) {
    if (r.rdLength < 7) return null;
    final port = (raw[r.rdOffset + 4] << 8) | raw[r.rdOffset + 5];
    final nm = _readName(raw, r.rdOffset + 6);
    if (nm == null) return null;
    return (port: port, target: nm.labels);
  }

  bool _sameName(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].toLowerCase() != b[i].toLowerCase()) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // DNS wire format
  // ---------------------------------------------------------------------------

  static String _truncateLabel(String s) {
    if (utf8.encode(s).length <= _maxLabelBytes) return s;
    final out = StringBuffer();
    var bytes = 0;
    for (final rune in s.runes) {
      final ch = String.fromCharCode(rune);
      final n = utf8.encode(ch).length;
      if (bytes + n > _maxLabelBytes) break;
      out.write(ch);
      bytes += n;
    }
    return out.toString();
  }

  static Uint8List _encodeName(List<String> labels) {
    final b = BytesBuilder();
    for (final l in labels) {
      final bytes = utf8.encode(l);
      final len = min(bytes.length, _maxLabelBytes);
      b.addByte(len);
      b.add(bytes.sublist(0, len));
    }
    b.addByte(0);
    return b.toBytes();
  }

  static Uint8List _encodeQuery(List<String> name, int type) {
    final b = BytesBuilder();
    b.add([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    b.add(_encodeName(name));
    b.add([type >> 8, type & 0xff, 0, 1]);
    return b.toBytes();
  }

  static Uint8List _encodeResponse(List<_Rr> answers, List<_Rr> additional,
      {required bool ttlZero}) {
    final b = BytesBuilder();
    b.add([0, 0, 0x84, 0]); // id=0, QR=1 AA=1
    b.add([0, 0]); // qdcount
    b.add([answers.length >> 8, answers.length & 0xff]);
    b.add([0, 0]); // nscount
    b.add([additional.length >> 8, additional.length & 0xff]);
    for (final r in [...answers, ...additional]) {
      b.add(_encodeName(r.name));
      b.add([r.type >> 8, r.type & 0xff]);
      final cls = 1 | (r.cacheFlush ? 0x8000 : 0);
      b.add([cls >> 8, cls & 0xff]);
      final ttl = ttlZero ? 0 : r.ttl;
      b.add([
        ttl >> 24 & 0xff,
        ttl >> 16 & 0xff,
        ttl >> 8 & 0xff,
        ttl & 0xff,
      ]);
      b.add([r.rdata.length >> 8, r.rdata.length & 0xff]);
      b.add(r.rdata);
    }
    return b.toBytes();
  }

  /// Reads a (possibly compressed) domain name. Returns null if malformed.
  static ({List<String> labels, int next})? _readName(
      Uint8List data, int offset) {
    final labels = <String>[];
    var pos = offset;
    int? next;
    var jumps = 0;
    while (true) {
      if (pos >= data.length) return null;
      final len = data[pos];
      if (len == 0) {
        next ??= pos + 1;
        break;
      }
      if (len & 0xC0 == 0xC0) {
        if (pos + 1 >= data.length) return null;
        final ptr = ((len & 0x3F) << 8) | data[pos + 1];
        next ??= pos + 2;
        if (++jumps > 16 || ptr >= data.length) return null;
        pos = ptr;
        continue;
      }
      if (len > _maxLabelBytes || pos + 1 + len > data.length) return null;
      labels.add(utf8.decode(data.sublist(pos + 1, pos + 1 + len),
          allowMalformed: true));
      pos += 1 + len;
    }
    return (labels: labels, next: next);
  }
}

class _Rr {
  _Rr(this.name, this.type, this.cacheFlush, this.ttl, this.rdata);
  final List<String> name;
  final int type;
  final bool cacheFlush;
  final int ttl;
  final Uint8List rdata;
}

class _Question {
  _Question(this.name, this.type);
  final List<String> name;
  final int type;
}

class _RrRef {
  _RrRef(this.name, this.type, this.rdOffset, this.rdLength);
  final List<String> name;
  final int type;
  final int rdOffset;
  final int rdLength;
}

class _Message {
  _Message(this.raw, this.isResponse, this.questions, this.records);
  final Uint8List raw;
  final bool isResponse;
  final List<_Question> questions;
  final List<_RrRef> records;

  static _Message? parse(Uint8List data) {
    if (data.length < 12) return null;
    final flags = (data[2] << 8) | data[3];
    final qd = (data[4] << 8) | data[5];
    final rrCount = ((data[6] << 8) | data[7]) +
        ((data[8] << 8) | data[9]) +
        ((data[10] << 8) | data[11]);
    var pos = 12;
    final questions = <_Question>[];
    for (var i = 0; i < qd; i++) {
      final n = MdnsAnnouncer._readName(data, pos);
      if (n == null || n.next + 4 > data.length) return null;
      final type = (data[n.next] << 8) | data[n.next + 1];
      questions.add(_Question(n.labels, type));
      pos = n.next + 4;
    }
    final records = <_RrRef>[];
    for (var i = 0; i < rrCount; i++) {
      final n = MdnsAnnouncer._readName(data, pos);
      if (n == null || n.next + 10 > data.length) break;
      final type = (data[n.next] << 8) | data[n.next + 1];
      final rdLen = (data[n.next + 8] << 8) | data[n.next + 9];
      final rdOff = n.next + 10;
      if (rdOff + rdLen > data.length) break;
      records.add(_RrRef(n.labels, type, rdOff, rdLen));
      pos = rdOff + rdLen;
    }
    return _Message(data, flags & 0x8000 != 0, questions, records);
  }
}
