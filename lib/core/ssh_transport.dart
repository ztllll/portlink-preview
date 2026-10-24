import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'server_profile.dart';

typedef VerifySshHost = Future<bool> Function(
  String keyType,
  String fingerprint,
);

/// Injectable transport seam. Production always uses DartSshConnector; tests can
/// exercise real loopback listeners without weakening host verification.
abstract interface class SshConnector {
  Future<SshSession> connect(
    ServerProfile profile,
    String password, {
    required VerifySshHost verifyHost,
    required Duration connectTimeout,
    required Duration handshakeTimeout,
    required Duration authTimeout,
  });
}

abstract interface class SshSession {
  Future<void> get authenticated;
  Future<void> get done;
  Future<ForwardConnection> open(String host, int port);
  Future<void> ping();
  Future<void> close();
}

abstract interface class ForwardConnection {
  Stream<Uint8List> get stream;
  StreamSink<List<int>> get sink;
  Future<void> get done;
  void destroy();
}

final class DartSshConnector implements SshConnector {
  const DartSshConnector();
  @override
  Future<SshSession> connect(
    ServerProfile profile,
    String password, {
    required VerifySshHost verifyHost,
    required Duration connectTimeout,
    required Duration handshakeTimeout,
    required Duration authTimeout,
  }) async {
    final socket = await SSHSocket.connect(
      profile.host,
      profile.sshPort,
      timeout: connectTimeout,
    );
    try {
      final client = SSHClient(
        socket,
        username: profile.username,
        onPasswordRequest: () => password,
        onVerifyHostKey: (type, bytes) => verifyHost(type, utf8.decode(bytes)),
        handshakeTimeout: handshakeTimeout,
        authTimeout: authTimeout,
        // One application-owned health task, with an explicit ping timeout.
        keepAliveInterval: null,
        // Never enable printDebug or printTrace: traffic can contain credentials.
      );
      return _DartSshSession(client, socket);
    } on Object {
      socket.destroy();
      rethrow;
    }
  }
}

final class _DartSshSession implements SshSession {
  _DartSshSession(this.client, this.socket);
  final SSHClient client;
  final SSHSocket socket;
  @override
  Future<void> get authenticated => client.authenticated;
  @override
  Future<void> get done => client.done;
  @override
  Future<ForwardConnection> open(String host, int port) async => _DartForward(
    await client.forwardLocal(host, port, localHost: '127.0.0.1'),
  );
  @override
  Future<void> ping() => client.ping();
  @override
  Future<void> close() async {
    // Force the underlying TCP socket closed even if a library close is pending.
    final close = client.close();
    socket.destroy();
    await close;
  }
}

final class _DartForward implements ForwardConnection {
  _DartForward(this.channel);
  final SSHForwardChannel channel;
  @override
  Stream<Uint8List> get stream => channel.stream;
  @override
  StreamSink<List<int>> get sink => channel.sink;
  @override
  Future<void> get done => channel.done;
  @override
  void destroy() => channel.destroy();
}
