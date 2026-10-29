import 'dart:io';

import 'package:elecon/core/scripts/network_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ScriptNetworkPolicy policy(List<String> origins, {List<String>? ips}) =>
      ScriptNetworkPolicy.fromJson({'origins': origins, 'ipAllow': ?ips});

  test('origins match exact scheme, host and effective port', () {
    final p = policy([
      'https://API.School.example:443/',
      'http://10.0.0.1:8080',
    ]);
    expect(
      p.allowsUrl(Uri.parse('https://api.school.example/grades?token=x')),
      isTrue,
    );
    expect(p.allowsUrl(Uri.parse('https://api.school.example/#/home')), isTrue);
    for (final url in [
      'http://api.school.example/grades',
      'https://api.school.example:8443/grades',
      'https://sub.api.school.example/grades',
      'https://api.school.example.evil.invalid/grades',
      'https://user:password@api.school.example/grades',
      'file:///tmp/grades',
    ]) {
      expect(p.allowsUrl(Uri.parse(url)), isFalse, reason: url);
    }
    expect(p.allowsUrl(Uri.parse('http://10.0.0.1:8080/')), isTrue);
    expect(p.toJson()['origins'], [
      'https://api.school.example',
      'http://10.0.0.1:8080',
    ]);
  });

  test('empty origins supports data-only scripts without network', () {
    final p = policy([]);
    expect(p.allowsUrl(Uri.parse('https://school.example')), isFalse);
  });

  test('malformed origins and ambiguous numeric hosts are rejected', () {
    for (final origin in [
      '*',
      'https://*.school.example',
      'https://school.example/path',
      'https://school.example?x=1',
      'https://school.example#fragment',
      'https://user@school.example',
      'ftp://school.example',
      'https://school.example:0',
      'https://school.example:65536',
      'https://school.example.',
      'http://127.1',
      'http://2130706433',
      'http://0177.0.0.1',
      'http://0x7f000001',
      'http://[fe80::1%25eth0]',
    ]) {
      expect(() => policy([origin]), throwsFormatException, reason: origin);
    }
    expect(
      () => policy(['https://school.example', 'https://school.example:443']),
      throwsFormatException,
    );
    expect(
      () => ScriptNetworkPolicy.fromJson({'origins': [], 'unknown': true}),
      throwsFormatException,
    );
    expect(
      () => ScriptNetworkPolicy.fromJson({'origins': [], 'ipAllow': null}),
      throwsFormatException,
    );
  });

  test('IPv6 origins normalize equivalent spellings', () {
    final p = policy(['http://[0:0:0:0:0:0:0:1]:8080']);
    expect(p.allowsUrl(Uri.parse('http://[::1]:8080/a')), isTrue);
    expect(p.allowsUrl(Uri.parse('http://[::2]:8080/a')), isFalse);
  });

  test('absent IP bounds permits admitted DNS results; empty denies all', () {
    final unrestricted = policy(['https://school.example']);
    final denied = policy(['https://school.example'], ips: []);
    for (final ip in ['127.0.0.1', '10.2.3.4', '192.0.2.1', '::1', 'fd00::1']) {
      expect(unrestricted.allowsAddress(InternetAddress(ip)), isTrue);
      expect(denied.allowsAddress(InternetAddress(ip)), isFalse);
    }
  });

  test('IPv4 non-byte CIDR and exact IP respect boundaries', () {
    final p = policy(
      ['https://school.example'],
      ips: ['10.0.0.0/9', '192.0.2.42'],
    );
    for (final ip in ['10.0.0.0', '10.127.255.255', '192.0.2.42']) {
      expect(p.allowsAddress(InternetAddress(ip)), isTrue, reason: ip);
    }
    for (final ip in [
      '9.255.255.255',
      '10.128.0.0',
      '192.0.2.41',
      '::ffff:10.0.0.1',
    ]) {
      expect(p.allowsAddress(InternetAddress(ip)), isFalse, reason: ip);
    }
  });

  test('IPv6 partial prefixes, exact addresses and /0', () {
    final p = policy(['https://school.example'], ips: ['2001:db8::/33', '::1']);
    for (final ip in ['2001:db8::', '2001:db8:7fff:ffff::1', '::1']) {
      expect(p.allowsAddress(InternetAddress(ip)), isTrue, reason: ip);
    }
    expect(p.allowsAddress(InternetAddress('2001:db8:8000::')), isFalse);
    expect(p.allowsAddress(InternetAddress('2001:db9::')), isFalse);
    expect(
      policy([], ips: ['::/0']).allowsAddress(InternetAddress('fd00::1')),
      isTrue,
    );
    expect(
      policy([], ips: ['0.0.0.0/0']).allowsAddress(InternetAddress('10.2.3.4')),
      isTrue,
    );
  });

  test('invalid IP and CIDR entries are rejected', () {
    for (final value in [
      'school.example',
      '*',
      '10.0.0.1/33',
      '::/129',
      '::/-1',
      '::/01',
      '127.1',
      ' 127.0.0.1',
      '[::1]',
      '10.0.0.1/8/2',
      '10.0.0.1/',
    ]) {
      expect(
        () => policy([], ips: [value]),
        throwsFormatException,
        reason: value,
      );
    }
  });
}
