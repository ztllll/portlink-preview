import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/core/server_profile.dart';
import 'package:portlink/core/tunnel_engine.dart';
import 'package:portlink/core/tunnel_status.dart';
import 'package:portlink/data/host_trust_store.dart';

void main() {
  final python = Platform.environment['PORTLINK_SSH_TEST_PYTHON'];
  test(
    'real SSH password, pinned host, forwarding, concurrent data and cleanup',
    () async {
      final process = await Process.start(python!, ['tool/ssh_fixture.py']);
      final lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      final info =
          jsonDecode(await lines.first.timeout(const Duration(seconds: 15)))
              as Map<String, dynamic>;
      final stderr = process.stderr.drain<void>();
      final directory = await Directory.systemTemp.createTemp(
        'portlink-ssh-integration-',
      );
      final trust = JsonHostTrustStore('${directory.path}/hosts.json');
      final reservation = await ServerSocket.bind('127.0.0.1', 0);
      final listenPort = reservation.port;
      await reservation.close();
      final engine = SshTunnelEngine.forTesting(
        listenPort: listenPort,
        trustStore: trust,
        timing: const TunnelTiming(
          connectTimeout: Duration(seconds: 5),
          healthInterval: Duration(seconds: 60),
          maxRetries: 0,
        ),
      );
      addTearDown(() async {
        await engine.dispose();
        process.kill();
        await process.exitCode;
        await stderr;
        await directory.delete(recursive: true);
      });
      final profile = ServerProfile(
        id: 'integration',
        name: 'fixture',
        host: '127.0.0.1',
        sshPort: info['port'] as int,
        username: 'portlink-test',
      );
      var prompts = 0;
      await engine.connect(
        profile,
        'fixture-only-password',
        onTrustHost: (request) async {
          prompts++;
          expect(request.fingerprint, info['fingerprint']);
          return true;
        },
      );
      expect(engine.status.phase, TunnelPhase.ready);
      expect(prompts, 1);
      Future<void> transfer(int seed) async {
        final socket = await Socket.connect('127.0.0.1', listenPort);
        final expected = List<int>.generate(
          128 * 1024,
          (i) => (i + seed) % 251,
        );
        final received = socket.fold<List<int>>(
          [],
          (all, bytes) => all..addAll(bytes),
        );
        socket.add(expected);
        await socket.flush();
        await socket.close();
        expect(await received.timeout(const Duration(seconds: 15)), expected);
        socket.destroy();
      }

      await Future.wait(List.generate(4, transfer));
      await engine.disconnect();
      final listener = await ServerSocket.bind('127.0.0.1', listenPort);
      await listener.close();
      await engine.connect(
        profile,
        'fixture-only-password',
        onTrustHost: (_) async {
          fail('Saved host pin must not prompt again');
        },
      );
      expect(engine.status.phase, TunnelPhase.ready);
      await engine.disconnect();
      await engine.connect(
        profile,
        'wrong-password',
        onTrustHost: (_) async => false,
      );
      expect(engine.status.phase, TunnelPhase.failed);
      expect(engine.status.message, isNot(contains('wrong-password')));
    },
    skip: python == null
        ? 'Set PORTLINK_SSH_TEST_PYTHON to isolated asyncssh Python.'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
