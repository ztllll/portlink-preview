import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/core/server_profile.dart';
import 'package:portlink/core/ssh_transport.dart';

void main() {
  test(
    'production adapter bounds silent TCP peer handshake and closes socket',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final received = <int>[];
      final subscription = server.listen((socket) {
        sockets.add(socket);
        socket.listen(received.addAll, onError: (Object _) {});
        // Intentionally no SSH banner or key: must not wait forever.
      });
      SshSession? session;
      try {
        final watch = Stopwatch()..start();
        session = await const DartSshConnector().connect(
          ServerProfile(
            id: 'fixture',
            name: '静默TCP',
            host: '127.0.0.1',
            sshPort: server.port,
            username: 'test',
          ),
          'not-to-be-sent-before-trust',
          verifyHost: (_, _) async => false,
          connectTimeout: const Duration(seconds: 1),
          handshakeTimeout: const Duration(milliseconds: 80),
          authTimeout: const Duration(milliseconds: 80),
        );
        unawaited(
          session.done.then((_) {}, onError: (Object _, StackTrace _) {}),
        );
        await expectLater(
          session.authenticated.timeout(const Duration(seconds: 2)),
          throwsA(isA<SSHHandshakeError>()),
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
        expect(
          String.fromCharCodes(received),
          isNot(contains('not-to-be-sent-before-trust')),
        );
      } finally {
        await session?.close();
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
        await subscription.cancel();
      }
    },
  );

  test(
    'production adapter rejects refused TCP connection within connect deadline',
    () async {
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = reservation.port;
      await reservation.close();
      await expectLater(
        const DartSshConnector().connect(
          ServerProfile(
            id: 'fixture',
            name: '拒绝TCP',
            host: '127.0.0.1',
            sshPort: port,
            username: 'test',
          ),
          'never-log',
          verifyHost: (_, _) async => false,
          connectTimeout: const Duration(milliseconds: 100),
          handshakeTimeout: const Duration(milliseconds: 100),
          authTimeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<SocketException>()),
      );
    },
  );
}
