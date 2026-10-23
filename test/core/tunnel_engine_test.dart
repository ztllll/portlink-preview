import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/core/host_trust.dart';
import 'package:portlink/core/server_profile.dart';
import 'package:portlink/core/ssh_transport.dart';
import 'package:portlink/core/tunnel_engine.dart';
import 'package:portlink/core/tunnel_status.dart';
import 'package:portlink/data/host_trust_store.dart';

const profile = ServerProfile(
  id: 'one',
  name: '测试主机',
  host: 'example.com',
  username: 'alice',
);
final fingerprint = 'SHA256:${'A' * 43}';
const timing = TunnelTiming(
  connectTimeout: Duration(milliseconds: 150),
  handshakeTimeout: Duration(milliseconds: 150),
  authTimeout: Duration(milliseconds: 150),
  trustTimeout: Duration(milliseconds: 150),
  probeTimeout: Duration(milliseconds: 60),
  pingTimeout: Duration(milliseconds: 40),
  healthInterval: Duration(milliseconds: 80),
  operationTimeout: Duration(seconds: 2),
  closeTimeout: Duration(milliseconds: 100),
  retryBase: Duration(milliseconds: 30),
  retryMax: Duration(milliseconds: 100),
  maxRetries: 2,
);

Future<void> until(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 3)) {
      throw StateError('condition timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late MemoryTrust trust;
  late FakeConnector connector;
  late SshTunnelEngine engine;
  late int listenPort;
  setUp(() async {
    trust = MemoryTrust();
    connector = FakeConnector();
    final reservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    listenPort = reservation.port;
    await reservation.close();
    engine = SshTunnelEngine.forTesting(
      trustStore: trust,
      listenPort: listenPort,
      connector: connector,
      timing: timing,
      jitter: () => 0.5,
    );
  });
  tearDown(() async {
    await engine.dispose();
  });

  Future<void> connect({HostTrustPrompt? prompt}) => engine.connect(
    profile,
    'not-in-status',
    onTrustHost: prompt ?? (_) async => true,
  );

  test('ready requires auth, real exclusive loopback listener and SSH target probe', () async {
    await connect();
    expect(engine.status.phase, TunnelPhase.ready);
    expect(connector.sessions.single.targets.single, ['127.0.0.1', 3080]);
    await expectLater(
      ServerSocket.bind(InternetAddress.loopbackIPv4, listenPort),
      throwsA(isA<SocketException>()),
    );
    final socket = await Socket.connect('127.0.0.1', listenPort);
    expect(socket.remotePort, listenPort);
    socket.destroy();
    await engine.disconnect();
    final rebound = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      listenPort,
    );
    await rebound.close();
    expect(engine.status.phase, TunnelPhase.idle);
  });

  test('eight concurrent streams preserve payloads and response after upload half-close', () async {
    await connect();
    await Future.wait(
      List.generate(8, (i) async {
        final socket = await Socket.connect('127.0.0.1', listenPort);
        final expected = Uint8List.fromList(
          List.generate(256 * 1024, (j) => (j + i) % 256),
        );
        final received = socket.fold<BytesBuilder>(
          BytesBuilder(),
          (builder, data) => builder..add(data),
        );
        socket.add(expected);
        await socket.flush();
        await socket
            .close(); // FIN upload; the remote response still must arrive.
        final bytes = (await received.timeout(const Duration(seconds: 5)))
            .takeBytes();
        expect(bytes, expected);
        socket.destroy();
      }),
    );
    expect(connector.sessions.single.targets.length, greaterThanOrEqualTo(9));
    await until(
      () => connector.sessions.single.channels.every((c) => c.destroyed),
    );
  });

  test('binding conflict is fatal and never retried', () async {
    final occupied = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      listenPort,
    );
    try {
      await connect();
      expect(engine.status.phase, TunnelPhase.failed);
      expect(engine.status.message, contains('3080'));
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(connector.calls, 1);
      expect(connector.sessions.single.closed, isTrue);
    } finally {
      await occupied.close();
    }
  });

  test('production constructor keeps fixed 3080 and fails safely if already occupied', () async {
    await engine.dispose();
    ServerSocket? owned;
    try {
      owned = await ServerSocket.bind(InternetAddress.loopbackIPv4, 3080);
    } on SocketException {
      // A pre-existing user process owns 3080. Do not connect to it or close it.
    }
    engine = SshTunnelEngine(
      trustStore: trust,
      connector: connector,
      timing: timing,
    );
    try {
      await connect();
      expect(engine.status.phase, TunnelPhase.failed);
      expect(engine.status.message, contains('3080'));
      expect(connector.calls, 1);
    } finally {
      await owned?.close();
    }
  });

  test(
    'target failure keeps listener and periodically reprobes through SSH',
    () async {
      connector.configure = (session) {
        session.targetAvailable = false;
      };
      await connect();
      expect(engine.status.phase, TunnelPhase.targetUnavailable);
      expect(engine.status.isConnected, isTrue);
      final socket = await Socket.connect('127.0.0.1', listenPort);
      final closed = socket.drain<void>();
      await closed.timeout(const Duration(seconds: 2));
      socket.destroy();
      connector.sessions.single.targetAvailable = true;
      await until(() => engine.status.phase == TunnelPhase.ready);
      expect(connector.calls, 1);
      expect(connector.sessions.single.targets.length, greaterThan(1));
    },
  );

  test(
    'ping hang has timeout, closes old session and reconnects once',
    () async {
      connector.configure = (session) {
        if (connector.calls == 1) session.hangPing = true;
      };
      await connect();
      final seen = <TunnelPhase>[];
      final subscription = engine.statuses.listen((s) => seen.add(s.phase));
      await until(
        () => connector.calls == 2 && engine.status.phase == TunnelPhase.ready,
      );
      expect(connector.sessions.first.closed, isTrue);
      expect(seen, contains(TunnelPhase.reconnecting));
      await subscription.cancel();
    },
  );

  test(
    'transient initial failure returns before retries and backoff is bounded',
    () async {
      connector.failure = const SocketException('network');
      await connect();
      expect(connector.calls, 1);
      expect(engine.status.phase, TunnelPhase.reconnecting);
      await until(() => engine.status.phase == TunnelPhase.failed);
      expect(connector.calls, 3); // initial + two retries
      expect(engine.status.retryAttempt, 2);
    },
  );

  test(
    'auth failure never retries or reveals server text or password',
    () async {
      connector.configure = (session) {
        session.authFailure = SSHAuthFailError('not-in-status');
      };
      await connect();
      expect(engine.status.phase, TunnelPhase.failed);
      expect(engine.status.message, isNot(contains('not-in-status')));
      expect(engine.status.message, contains('认证失败'));
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(connector.calls, 1);
    },
  );

  test(
    'unknown prompts once, repeated key skips prompt, changed key hard-stops',
    () async {
      var prompts = 0;
      Future<bool> prompt(HostTrustRequest request) async {
        prompts++;
        expect(request.fingerprint, fingerprint);
        return true;
      }

      await connect(prompt: prompt);
      await engine.disconnect();
      await connect(prompt: prompt);
      expect(prompts, 1);
      await engine.disconnect();
      connector.presentedFingerprint = 'SHA256:${'B' * 43}';
      await connect(prompt: prompt);
      expect(engine.status.phase, TunnelPhase.failed);
      expect(engine.status.message, contains('已变化'));
      expect(prompts, 1);
    },
  );

  test(
    'transport cannot publish ready if it skipped host verification',
    () async {
      connector.skipVerification = true;
      await connect();
      expect(engine.status.phase, TunnelPhase.failed);
      expect(trust.writes, 0);
      final listener = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        listenPort,
      );
      await listener.close();
    },
  );

  test('algorithm changes are fatal before first-use prompt', () async {
    trust.type = 'ssh-ed25519';
    trust.pin = fingerprint;
    connector.keyType = 'ssh-rsa';
    var prompted = false;
    await connect(
      prompt: (_) async {
        prompted = true;
        return true;
      },
    );
    expect(engine.status.phase, TunnelPhase.failed);
    expect(prompted, isFalse);
    expect(engine.status.message, contains('已变化'));
  });

  test('rejecting trust does not save or retry', () async {
    await connect(prompt: (_) async => false);
    expect(engine.status.phase, TunnelPhase.failed);
    expect(trust.writes, 0);
    await Future<void>.delayed(const Duration(milliseconds: 160));
    expect(connector.calls, 1);
  });

  test('disconnect pending trust returns promptly and stale acceptance cannot persist', () async {
    final answer = Completer<bool>();
    final connecting = connect(prompt: (_) => answer.future);
    await until(() => engine.status.phase == TunnelPhase.verifyingHost);
    await engine.disconnect().timeout(const Duration(seconds: 1));
    await connecting.timeout(const Duration(seconds: 1));
    answer.complete(true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(engine.status.phase, TunnelPhase.idle);
    expect(trust.writes, 0);
    expect(connector.sessions.single.closed, isTrue);
  });

  test(
    'stale late connector is closed and cannot bind or overwrite newer status',
    () async {
      final late = Completer<SshSession>();
      connector.pending = late;
      final old = connect();
      await until(() => connector.calls == 1);
      await engine.disconnect();
      await old;
      connector.pending = null;
      await engine.connect(
        const ServerProfile(
          id: 'two',
          name: '新主机',
          host: 'two.example',
          username: 'bob',
        ),
        'new-password',
        onTrustHost: (_) async => true,
      );
      final orphan = FakeSession();
      late.complete(orphan);
      await until(() => orphan.closed);
      expect(engine.status.phase, TunnelPhase.ready);
      expect(engine.status.profileId, 'two');
    },
  );

  test('rapid double switch waits for the oldest teardown and only latest connects', () async {
    await connect();
    final gate = Completer<void>();
    connector.sessions.single.closeGate = gate;
    final firstSwitch = engine.connect(
      const ServerProfile(
        id: 'two',
        name: '二',
        host: 'two.example',
        username: 'bob',
      ),
      'two-password',
      onTrustHost: (_) async => true,
    );
    final latestSwitch = engine.connect(
      const ServerProfile(
        id: 'three',
        name: '三',
        host: 'three.example',
        username: 'bob',
      ),
      'three-password',
      onTrustHost: (_) async => true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(connector.calls, 1);
    gate.complete();
    await Future.wait([firstSwitch, latestSwitch]);
    expect(connector.calls, 2);
    expect(engine.status.profileId, 'three');
    expect(engine.status.phase, TunnelPhase.ready);
  });

  test('cancel retry timer prevents any later connection attempt', () async {
    connector.failure = const SocketException('network');
    await connect();
    await engine.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(connector.calls, 1);
    expect(engine.status.phase, TunnelPhase.idle);
  });

  test('late failed accepted channel is cleaned after disconnect', () async {
    await connect();
    final session = connector.sessions.single;
    final pending = Completer<ForwardConnection>();
    session.pendingChannel = pending;
    final socket = await Socket.connect('127.0.0.1', listenPort);
    final drain = socket.drain<void>();
    await until(() => session.targets.length == 2);
    await engine.disconnect();
    final late = EchoChannel();
    pending.complete(late);
    await until(() => late.destroyed);
    await drain.timeout(const Duration(seconds: 1));
    socket.destroy();
  });

  test(
    'connect timeout retires late host prompt and closes late session',
    () async {
      final pending = Completer<SshSession>();
      connector.pending = pending;
      await connect();
      expect(engine.status.phase, TunnelPhase.reconnecting);
      // A timed-out connector callback must not prompt/persist in the same generation.
      final accepted = await connector.lastVerify!('ssh-ed25519', fingerprint);
      expect(accepted, isFalse);
      expect(trust.writes, 0);
      final orphan = FakeSession();
      pending.complete(orphan);
      await until(() => orphan.closed);
      await engine.disconnect();
    },
  );

  test(
    'hung authentication expires and only transient timeout is retried',
    () async {
      connector.configure = (session) {
        session.hangAuth = true;
      };
      await connect();
      expect(engine.status.phase, TunnelPhase.reconnecting);
      expect(connector.sessions.first.closed, isTrue);
      await engine.disconnect();
    },
  );

  test(
    'hung authentication is bounded and disconnect clears its timer',
    () async {
      connector.configure = (session) {
        session.hangAuth = true;
      };
      final connecting = connect();
      await until(
        () =>
            connector.sessions.isNotEmpty &&
            connector.sessions.single.authObserved,
      );
      await engine.disconnect();
      await connecting.timeout(const Duration(seconds: 1));
      expect(connector.sessions.single.closed, isTrue);
      expect(engine.status.phase, TunnelPhase.idle);
    },
  );

  test('target probe timeout marks unavailable and destroys a late successful channel', () async {
    final pending = Completer<ForwardConnection>();
    connector.configure = (session) {
      session.pendingChannel = pending;
    };
    await connect();
    expect(engine.status.phase, TunnelPhase.targetUnavailable);
    final orphan = EchoChannel();
    pending.complete(orphan);
    await until(() => orphan.destroyed);
    connector.sessions.single.pendingChannel = null;
    await until(() => engine.status.phase == TunnelPhase.ready);
  });

  test(
    'trust-store failure fails closed without a prompt or automatic retry',
    () async {
      trust.readFailure = const FileSystemException(
        'private-path-must-not-leak',
      );
      var prompts = 0;
      await connect(
        prompt: (_) async {
          prompts++;
          return true;
        },
      );
      expect(engine.status.phase, TunnelPhase.failed);
      expect(engine.status.message, isNot(contains('private-path')));
      expect(prompts, 0);
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(connector.calls, 1);
    },
  );

  test('session closing during initial probe never emits ready', () async {
    final pending = Completer<ForwardConnection>();
    connector.configure = (session) {
      session.pendingChannel = pending;
    };
    final connecting = connect();
    await until(
      () =>
          connector.sessions.isNotEmpty &&
          connector.sessions.single.targets.isNotEmpty,
    );
    final session = connector.sessions.single;
    await session.close();
    pending.complete(EchoChannel());
    await connecting;
    expect(engine.status.phase, TunnelPhase.reconnecting);
    await engine.disconnect();
  });

  test(
    'stale open from retired attempt cannot leak after auto-reconnect',
    () async {
      await connect();
      final old = connector.sessions.single;
      final pending = Completer<ForwardConnection>();
      old.pendingChannel = pending;
      final socket = await Socket.connect('127.0.0.1', listenPort);
      final drain = socket.drain<void>();
      await until(() => old.targets.length == 2);
      await old.close();
      await until(
        () => connector.calls == 2 && engine.status.phase == TunnelPhase.ready,
      );
      final orphan = EchoChannel();
      pending.complete(orphan);
      await until(() => orphan.destroyed);
      await drain.timeout(const Duration(seconds: 1));
      socket.destroy();
    },
  );

  test('dispose is idempotent and prevents new connects', () async {
    await connect();
    await engine.dispose();
    await engine.dispose();
    await expectLater(connect(), throwsStateError);
  });
}

final class MemoryTrust implements HostTrustStore {
  String? type, pin;
  int writes = 0;
  Object? readFailure;
  @override
  Future<String?> readFingerprint(String host, int port, String keyType) async {
    if (readFailure != null) throw readFailure!;
    if (pin != null && type != keyType) throw const HostKeyChangedException();
    return pin;
  }

  @override
  Future<void> trust(
    String host,
    int port,
    String keyType,
    String fingerprint,
  ) async {
    if (pin != null && (type != keyType || pin != fingerprint)) {
      throw const HostKeyChangedException();
    }
    type = keyType;
    pin = fingerprint;
    writes++;
  }
}

final class FakeConnector implements SshConnector {
  int calls = 0;
  bool skipVerification = false;
  final sessions = <FakeSession>[];
  String keyType = 'ssh-ed25519';
  String? presentedFingerprint;
  Object? failure;
  Completer<SshSession>? pending;
  VerifySshHost? lastVerify;
  void Function(FakeSession)? configure;
  @override
  Future<SshSession> connect(
    ServerProfile profile,
    String password, {
    required VerifySshHost verifyHost,
    required Duration connectTimeout,
    required Duration handshakeTimeout,
    required Duration authTimeout,
  }) async {
    calls++;
    lastVerify = verifyHost;
    if (failure != null) throw failure!;
    if (pending != null) return pending!.future;
    final session = FakeSession();
    sessions.add(session);
    configure?.call(session);
    // Match dartssh2: return client before its asynchronous authentication.
    scheduleMicrotask(() async {
      try {
        if (!skipVerification &&
            !await verifyHost(keyType, presentedFingerprint ?? fingerprint)) {
          throw SSHHostkeyError('untrusted');
        }
        if (session.hangAuth) return;
        if (session.authFailure != null) throw session.authFailure!;
        session.auth.complete();
      } on Object catch (error, stack) {
        session.auth.completeError(error, stack);
      }
    });
    return session;
  }
}

final class FakeSession implements SshSession {
  final auth = Completer<void>();
  final ended = Completer<void>();
  bool targetAvailable = true,
      hangPing = false,
      hangAuth = false,
      closed = false;
  bool authObserved = false;
  Object? authFailure;
  final targets = <List<Object>>[];
  final channels = <EchoChannel>[];
  Completer<ForwardConnection>? pendingChannel;
  Completer<void>? closeGate;
  @override
  Future<void> get authenticated {
    authObserved = true;
    return auth.future;
  }

  @override
  Future<void> get done => ended.future;
  @override
  Future<ForwardConnection> open(String host, int port) async {
    targets.add([host, port]);
    if (pendingChannel != null) return pendingChannel!.future;
    if (!targetAvailable) throw SSHChannelOpenError(2, 'refused');
    final channel = EchoChannel();
    channels.add(channel);
    return channel;
  }

  @override
  Future<void> ping() =>
      hangPing ? Completer<void>().future : Future<void>.value();
  @override
  Future<void> close() async {
    closed = true;
    for (final channel in channels) {
      channel.destroy();
    }
    if (!ended.isCompleted) ended.complete();
    await closeGate?.future;
  }
}

final class EchoChannel implements ForwardConnection {
  EchoChannel() {
    input.stream.listen(
      (bytes) {
        received.add(bytes);
      },
      onDone: () {
        if (destroyed) return;
        output.add(received.takeBytes());
        unawaited(output.close());
      },
    );
  }
  final input = StreamController<List<int>>();
  final output = StreamController<Uint8List>();
  final ended = Completer<void>();
  final received = BytesBuilder();
  bool destroyed = false;
  @override
  Stream<Uint8List> get stream => output.stream;
  @override
  StreamSink<List<int>> get sink => input.sink;
  @override
  Future<void> get done => ended.future;
  @override
  Future<void> flush() async {}
  @override
  void destroy() {
    if (destroyed) return;
    destroyed = true;
    unawaited(input.close());
    unawaited(output.close());
    if (!ended.isCompleted) ended.complete();
  }
}
