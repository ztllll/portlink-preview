import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/core/forward_rule.dart';
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
      final info = jsonDecode(
        await lines.first.timeout(const Duration(seconds: 15)),
      ) as Map<String, dynamic>;
      final stderr = process.stderr.drain<void>();
      final directory = await Directory.systemTemp.createTemp(
        'portlink-ssh-integration-',
      );
      final trust = JsonHostTrustStore('${directory.path}/hosts.json');
      final reservation = await ServerSocket.bind('127.0.0.1', 0);
      final listenPort = reservation.port;
      await reservation.close();
      final engine = SshTunnelEngine(
        trustStore: trust,
        timing: const TunnelTiming(
          connectTimeout: Duration(seconds: 5),
          healthInterval: Duration(milliseconds: 40),
          pingTimeout: Duration(seconds: 5),
          probeTimeout: Duration(seconds: 5),
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
        rules: [
          ForwardRule(
            id: 'r1',
            label: 'fixture',
            localPort: listenPort,
            remotePort: 3080,
          ),
        ],
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

      // Keep four channels open while packets, health pings and target probes
      // interleave. Waiting for each echo BEFORE FIN reproduces the Android
      // path that a single bulk write immediately followed by close missed.
      Future<void> interactive(int seed) async {
        final socket = await Socket.connect('127.0.0.1', listenPort);
        final input = StreamIterator<Uint8List>(socket);
        var pending = <int>[];
        Future<List<int>> readExactly(int length) async {
          while (pending.length < length) {
            if (!await input.moveNext()) {
              fail('Unexpected EOF before request echo');
            }
            pending.addAll(input.current);
          }
          final result = pending.sublist(0, length);
          pending = pending.sublist(length);
          return result;
        }

        try {
          for (var round = 0; round < 24; round++) {
            final request = List<int>.generate(
              1024 + round * 13,
              (index) => (index + seed + round) % 251,
            );
            socket.add(request);
            await socket.flush();
            expect(
              await readExactly(request.length)
                  .timeout(const Duration(seconds: 10)),
              request,
            );
            await Future<void>.delayed(
              Duration(milliseconds: 10 + (seed + round) % 7),
            );
          }
          await socket.close();
          expect(
            await input.moveNext().timeout(const Duration(seconds: 5)),
            isFalse,
          );
        } finally {
          socket.destroy();
          await input.cancel();
        }
      }

      await Future.wait(List.generate(4, interactive));
      expect(engine.status.phase, TunnelPhase.ready);
      await Future.wait(
        List.generate(4, transfer),
      ); // retain bulk / FIN half-close coverage
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
