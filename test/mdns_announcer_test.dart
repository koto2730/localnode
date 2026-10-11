import 'package:flutter_test/flutter_test.dart';
import 'package:localnode/mdns_announcer.dart';

void main() {
  group('MdnsAnnouncer', () {
    test('defaultHostLabel is a valid DNS label', () {
      final label = MdnsAnnouncer.defaultHostLabel();
      expect(label, matches(RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$')));
      expect(label.length, lessThanOrEqualTo(63));
      expect(label, endsWith('localnode'));
    });

    test('buildTxt carries what a launcher needs to build the URL', () {
      final txt = MdnsAnnouncer.buildTxt(
        https: false,
        serverName: 'My Node',
        authRequired: true,
        version: '1.2.3',
      );
      expect(txt['scheme'], 'http');
      expect(txt['path'], '/');
      expect(txt['auth'], 'pin');
      expect(txt['name'], 'My Node');
      expect(txt['ver'], '1.2.3');
      expect(txt.containsKey('host'), isFalse);
    });

    test('buildTxt adds host for HTTPS certificate host names', () {
      final txt = MdnsAnnouncer.buildTxt(
        https: true,
        serverName: 'n',
        authRequired: false,
        version: '1',
        host: 'example.com',
      );
      expect(txt['scheme'], 'https');
      expect(txt['auth'], 'none');
      expect(txt['host'], 'example.com');
    });

    test('start rejects non-IPv4 addresses', () async {
      final a = MdnsAnnouncer(
        instanceName: 'x',
        port: 8080,
        address: '::1',
      );
      expect(a.start(), throwsArgumentError);
    });
  });
}
