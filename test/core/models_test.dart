import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/core/server_profile.dart';
import 'package:portlink/core/tunnel_status.dart';

void main() {
  ServerProfile model({
    String host = 'server.example',
    int port = 22,
    String username = 'alice',
    String name = '服务器',
    String id = 'abc',
  }) => ServerProfile(
    id: id,
    name: name,
    host: host,
    sshPort: port,
    username: username,
  );
  test(
    'profile validates IPv4 IPv6 and DNS without URL or control characters',
    () {
      for (final host in [
        'server.example',
        'localhost',
        '127.0.0.1',
        '::1',
        '2001:db8::1',
      ]) {
        expect(model(host: host).validate(), isNull, reason: host);
      }
      for (final host in [
        'https://host',
        'host/path',
        'host:22',
        'host name',
        'a..b',
        '-bad',
        'x\n',
        '[::1]',
      ]) {
        expect(model(host: host).validate(), isNotNull, reason: host);
      }
      expect(model(port: 0).validate(), isNotNull);
      expect(model(port: 65536).validate(), isNotNull);
      expect(model(username: 'two users').validate(), isNotNull);
      expect(model(name: 'x\nname').validate(), isNotNull);
      expect(model(id: '../../password').validate(), isNotNull);
    },
  );
  test('profile JSON strictly roundtrips without credentials', () {
    final json = model().toJson();
    expect(ServerProfile.fromJson(json).toJson(), json);
    expect(
      () => ServerProfile.fromJson({...json, 'password': 'secret'}),
      throwsFormatException,
    );
    expect(
      () => ServerProfile.fromJson({...json, 'sshPort': '22'}),
      throwsFormatException,
    );
  });
  test('phase activity and transport connectivity follow contract', () {
    for (final phase in TunnelPhase.values) {
      final state = TunnelStatus(phase: phase);
      expect(
        state.isActive,
        ![TunnelPhase.idle, TunnelPhase.failed].contains(phase),
      );
      expect(
        state.isConnected,
        [TunnelPhase.ready, TunnelPhase.targetUnavailable].contains(phase),
      );
    }
  });
}
