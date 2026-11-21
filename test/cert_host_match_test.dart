import 'package:flutter_test/flutter_test.dart';
import 'package:localnode/cert_host_match.dart';

void main() {
  group('sanMatchesHost', () {
    test('exact hostname match (case-insensitive, trailing dot)', () {
      expect(sanMatchesHost('example.com', 'example.com'), isTrue);
      expect(sanMatchesHost('Example.COM', 'example.com.'), isTrue);
      expect(sanMatchesHost('example.com', 'host.example.com'), isFalse);
    });

    test('wildcard matches exactly one leftmost label', () {
      expect(sanMatchesHost('*.example.com', 'host.example.com'), isTrue);
      expect(sanMatchesHost('*.example.com', 'HOST.Example.com'), isTrue);
      expect(sanMatchesHost('*.example.com', 'a.b.example.com'), isFalse);
      expect(sanMatchesHost('*.example.com', 'example.com'), isFalse);
      expect(sanMatchesHost('*.example.com', '.example.com'), isFalse);
      expect(sanMatchesHost('*.example.com', 'hostexample.com'), isFalse);
      expect(sanMatchesHost('*.example.com', '*.example.com'), isFalse);
    });

    test('rejects overly broad or partial wildcards', () {
      expect(sanMatchesHost('*.com', 'example.com'), isFalse);
      expect(sanMatchesHost('f*.example.com', 'foo.example.com'), isFalse);
      expect(sanMatchesHost('*.*.example.com', 'a.b.example.com'), isFalse);
    });

    test('IP SANs match exactly, never via wildcard', () {
      expect(sanMatchesHost('192.168.1.10', '192.168.1.10'), isTrue);
      expect(sanMatchesHost('192.168.1.10', '192.168.1.11'), isFalse);
      expect(sanMatchesHost('*.168.1.10', '192.168.1.10'), isFalse);
      expect(sanMatchesHost('example.com', '192.168.1.10'), isFalse);
      expect(sanMatchesHost('::1', '0:0:0:0:0:0:0:1'), isTrue);
    });
  });

  test('sansCoverHost with typical Let\'s Encrypt SAN set', () {
    const sans = ['example.com', '*.example.com'];
    expect(sansCoverHost(sans, 'example.com'), isTrue);
    expect(sansCoverHost(sans, 'host.example.com'), isTrue);
    expect(sansCoverHost(sans, 'a.b.example.com'), isFalse);
    expect(sansCoverHost(sans, 'other.org'), isFalse);
  });
}
