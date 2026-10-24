import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/core/server_profile.dart';
import 'package:portlink/core/tunnel_engine.dart';
import 'package:portlink/core/tunnel_status.dart';
import 'package:portlink/data/host_trust_store.dart';

final class _HttpResponseReader {
  _HttpResponseReader(Socket socket)
    : iterator = StreamIterator<Uint8List>(socket);
  final StreamIterator<Uint8List> iterator;
  List<int> pending = [];
  Future<(Map<String, String>, String)> read() async {
    var split = -1;
    while (split < 0) {
      for (var index = 0; index + 4 <= pending.length; index++) {
        if (pending[index] == 13 &&
            pending[index + 1] == 10 &&
            pending[index + 2] == 13 &&
            pending[index + 3] == 10) {
          split = index;
          break;
        }
      }
      if (split < 0) {
        if (!await iterator.moveNext()) {
          throw StateError('EOF before HTTP response');
        }
        pending.addAll(iterator.current);
        if (pending.length > 65536) {
          throw StateError('Oversized HTTP response header');
        }
      }
    }
    final lines = ascii.decode(pending.sublist(0, split)).split('\r\n');
    expect(lines.first, 'HTTP/1.1 200 OK');
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      headers[line.substring(0, colon).toLowerCase()] = line
          .substring(colon + 1)
          .trim();
    }
    pending = pending.sublist(split + 4);
    final length = int.parse(headers['content-length']!);
    while (pending.length < length) {
      if (!await iterator.moveNext()) {
        throw StateError('EOF before HTTP response body');
      }
      pending.addAll(iterator.current);
    }
    final body = utf8.decode(pending.sublist(0, length));
    pending = pending.sublist(length);
    return (headers, body);
  }
}

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
      final engine = SshTunnelEngine.forTesting(
        listenPort: listenPort,
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

  test(
    'real SSH streams 32MiB HTTP multipart plus concurrent uploads without request FIN',
    () async {
      final process = await Process.start(python!, [
        'tool/http_upload_fixture.py',
      ]);
      final stderr = process.stderr.drain<void>();
      final info = jsonDecode(
        await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 15)),
      ) as Map<String, dynamic>;
      final directory = await Directory.systemTemp.createTemp(
        'portlink-http-upload-',
      );
      final reservation = await ServerSocket.bind('127.0.0.1', 0);
      final listenPort = reservation.port;
      await reservation.close();
      final engine = SshTunnelEngine.forTesting(
        listenPort: listenPort,
        trustStore: JsonHostTrustStore('${directory.path}/hosts.json'),
        timing: const TunnelTiming(
          healthInterval: Duration(milliseconds: 100),
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
      await engine.connect(
        ServerProfile(
          id: 'multipart',
          name: 'HTTP fixture',
          host: '127.0.0.1',
          sshPort: info['port'] as int,
          username: 'portlink-test',
        ),
        'fixture-only-password',
        onTrustHost: (request) async {
          expect(request.fingerprint, info['fingerprint']);
          return true;
        },
      );
      expect(engine.status.phase, TunnelPhase.ready);
      final prefix = utf8.encode(info['prefix'] as String),
          suffix = utf8.encode(info['suffix'] as String);
      Future<void> upload(Map<String, dynamic> fixture) async {
        final socket = await Socket.connect('127.0.0.1', listenPort);
        final reader = _HttpResponseReader(socket);
        try {
          final size = fixture['size'] as int, seed = fixture['seed'] as int;
          final headers =
              'POST /upload HTTP/1.1\r\nHost: fixture\r\nContent-Type: multipart/form-data; boundary=${info['boundary']}\r\nContent-Length: ${prefix.length + size + suffix.length}\r\nConnection: keep-alive\r\n\r\n';
          socket.add(ascii.encode(headers));
          socket.add(prefix);
          await socket.flush();
          final block = Uint8List.fromList(
            List.generate(16384, (index) => (index + seed) % 251),
          );
          var remaining = size;
          while (remaining > 0) {
            final length = remaining < block.length ? remaining : block.length;
            socket.add(Uint8List.sublistView(block, 0, length));
            await socket.flush();
            remaining -= length;
            if (remaining % (256 * 1024) == 0) {
              await Future<void>.delayed(const Duration(milliseconds: 1));
            }
          }
          socket.add(suffix);
          await socket.flush();
          // No socket.close / FIN: HTTP response must arrive on the live connection.
          final (responseHeaders, body) = await reader.read().timeout(
            const Duration(seconds: 30),
          );
          expect(body, fixture['response']);
          expect(responseHeaders['x-body-sha256'], fixture['responseSha256']);
          final received = jsonDecode(body) as Map<String, dynamic>;
          expect(received['fileBytes'], size);
          expect(received['fileSha256'], fixture['fileSha256']);
          socket.add(
            ascii.encode(
              'GET /alive HTTP/1.1\r\nHost: fixture\r\nConnection: keep-alive\r\n\r\n',
            ),
          );
          await socket.flush();
          final (_, alive) = await reader.read().timeout(
            const Duration(seconds: 5),
          );
          expect(alive, '{"alive":true}');
          await socket.close();
        } finally {
          socket.destroy();
          await reader.iterator.cancel();
        }
      }

      final cases = (info['cases'] as List).cast<Map<String, dynamic>>();
      await upload(
        cases.first,
      ); // 32MiB file body, larger including multipart envelope
      await Future.wait(
        cases.skip(1).map(upload),
      ); // four simultaneous 4MiB uploads
      expect(engine.status.phase, TunnelPhase.ready);
      await engine.disconnect();
      final released = await ServerSocket.bind('127.0.0.1', listenPort);
      await released.close();
    },
    skip: python == null
        ? 'Set PORTLINK_SSH_TEST_PYTHON to isolated asyncssh Python.'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
