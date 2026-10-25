import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/core/forward_rule.dart';
import 'package:portlink/core/host_trust.dart';
import 'package:portlink/core/server_profile.dart';
import 'package:portlink/core/ssh_transport.dart';
import 'package:portlink/core/tunnel_engine.dart';
import 'package:portlink/core/tunnel_status.dart';
import 'package:portlink/data/host_trust_store.dart';

ServerProfile profileFor(
  int localPort, {
  int remotePort = 3080,
  String id = 'one',
  String name = '测试主机',
  String host = 'example.com',
  String username = 'alice',
}) => ServerProfile(
  id: id,
  name: name,
  host: host,
  username: username,
  rules: [
    ForwardRule(
      id: 'r1',
      label: '测试',
      localPort: localPort,
      remotePort: remotePort,
    ),
  ],
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
    engine = SshTunnelEngine(
      trustStore: trust,
      connector: connector,
      timing: timing,
      jitter: () => 0.5,
    );
  });
  tearDown(() async {
    await engine.dispose();
  });

  Future<void> connect({HostTrustPrompt? prompt}) => engine.connect(
    profileFor(listenPort),
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

  test(
    'channel pause propagates through both pipe controllers and resumes intact',
    () async {
      final gate = Completer<void>();
      connector.configure = (session) {
        session.channelReadGate = gate;
      };
      await connect();
      final socket = await Socket.connect('127.0.0.1', listenPort);
      final result = socket.fold<BytesBuilder>(
        BytesBuilder(),
        (all, chunk) => all..add(chunk),
      );
      final expected = List<int>.generate(256 * 1024, (index) => index % 251);
      socket.add(expected);
      await socket.flush();
      await socket.close();
      await until(() => connector.sessions.single.channels.length == 2);
      final channel = connector.sessions.single.channels.last;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        channel.acceptedChunks,
        0,
      ); // remote window has not admitted a read
      gate.complete();
      expect(
        (await result.timeout(const Duration(seconds: 3))).takeBytes(),
        expected,
      );
      socket.destroy();
    },
  );

  test('binding conflict is fatal and never retried', () async {
    final occupied = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      listenPort,
    );
    try {
      await connect();
      expect(engine.status.phase, TunnelPhase.failed);
      expect(engine.status.message, contains('本机转发端口'));
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(connector.calls, 1);
      expect(connector.sessions.single.closed, isTrue);
    } finally {
      await occupied.close();
    }
  });

  test('legacy default rule still maps local 3080 to remote 3080', () {
    const legacy = ServerProfile(
      id: 'one',
      name: '旧配置',
      host: 'example.com',
      username: 'alice',
    );
    expect(legacy.rules.single.localPort, 3080);
    expect(legacy.rules.single.remotePort, 3080);
    expect(legacy.rules.single.bindHost, '127.0.0.1');
    expect(legacy.rules.single.targetHost, '127.0.0.1');
    expect(legacy.validate(), isNull);
  });

  Future<int> freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  test('one SSH session forwards several rules to different remote ports', () async {
    final a = await freePort();
    final b = await freePort();
    final multi = ServerProfile(
      id: 'one',
      name: '多端口',
      host: 'example.com',
      username: 'alice',
      rules: [
        ForwardRule(id: 'a', label: 'Web', localPort: a, remotePort: 80),
        ForwardRule(id: 'b', label: 'DB', localPort: b, remotePort: 5432),
      ],
    );
    await engine.connect(multi, 'x', onTrustHost: (_) async => true);
    expect(engine.status.phase, TunnelPhase.ready);
    expect(connector.calls, 1, reason: 'a single SSH session serves all rules');
    expect(engine.status.rules.map((r) => r.state), [
      RuleState.ready,
      RuleState.ready,
    ]);
    // Probes target each rule's own remote port.
    final probed = connector.sessions.single.targets
        .map((t) => '${t[0]}:${t[1]}')
        .toSet();
    expect(probed, containsAll(['127.0.0.1:80', '127.0.0.1:5432']));
    // Each local port really listens and opens the matching remote port.
    final sa = await Socket.connect('127.0.0.1', a);
    final sb = await Socket.connect('127.0.0.1', b);
    await until(
      () => connector.sessions.single.targets.length >= 4,
    );
    sa.destroy();
    sb.destroy();
    await engine.disconnect();
    for (final port in [a, b]) {
      final rebound = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await rebound.close();
    }
  });

  test('an occupied local port fails only its rule; the others keep forwarding', () async {
    final good = await freePort();
    final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final partial = ServerProfile(
        id: 'one',
        name: '部分占用',
        host: 'example.com',
        username: 'alice',
        rules: [
          ForwardRule(id: 'ok', label: '可用', localPort: good, remotePort: 80),
          ForwardRule(
            id: 'bad',
            label: '被占用',
            localPort: taken.port,
            remotePort: 81,
          ),
        ],
      );
      await engine.connect(partial, 'x', onTrustHost: (_) async => true);
      expect(engine.status.phase, TunnelPhase.ready);
      expect(engine.status.isPartial, isTrue);
      final byId = {for (final r in engine.status.rules) r.rule.id: r.state};
      expect(byId['ok'], RuleState.ready);
      expect(byId['bad'], RuleState.bindFailed);
      expect(engine.status.message, contains('1/2'));
      // The unrelated listener owner is untouched and the good rule works.
      final socket = await Socket.connect('127.0.0.1', good);
      socket.destroy();
      expect(connector.calls, 1, reason: 'a bind conflict is not retried');
    } finally {
      await taken.close();
    }
  });

  test('every rule occupied is a fatal bind failure and never retried', () async {
    final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    try {
      await engine.connect(
        profileFor(taken.port),
        'x',
        onTrustHost: (_) async => true,
      );
      expect(engine.status.phase, TunnelPhase.failed);
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(connector.calls, 1);
    } finally {
      await taken.close();
    }
  });

  test('a custom target host is passed to the server, not hard-coded', () async {
    final port = await freePort();
    final custom = ServerProfile(
      id: 'one',
      name: '内网目标',
      host: 'example.com',
      username: 'alice',
      rules: [
        ForwardRule(
          id: 'c',
          label: '内网库',
          localPort: port,
          remotePort: 3306,
          targetHost: '10.0.0.5',
        ),
      ],
    );
    await engine.connect(custom, 'x', onTrustHost: (_) async => true);
    expect(engine.status.phase, TunnelPhase.ready);
    expect(connector.sessions.single.targets.first, ['10.0.0.5', 3306]);
  });

  test('a rule with an unreachable remote is reported without hiding the others', () async {
    final a = await freePort();
    final b = await freePort();
    connector.configure = (session) {
      session.failTargets = {5432};
    };
    final mixed = ServerProfile(
      id: 'one',
      name: '混合',
      host: 'example.com',
      username: 'alice',
      rules: [
        ForwardRule(id: 'a', label: 'Web', localPort: a, remotePort: 80),
        ForwardRule(id: 'b', label: 'DB', localPort: b, remotePort: 5432),
      ],
    );
    await engine.connect(mixed, 'x', onTrustHost: (_) async => true);
    expect(engine.status.phase, TunnelPhase.ready);
    expect(engine.status.isPartial, isTrue);
    final byId = {for (final r in engine.status.rules) r.rule.id: r.state};
    expect(byId['a'], RuleState.ready);
    expect(byId['b'], RuleState.targetUnavailable);
  });

  test('disabled rules never open a listener', () async {
    final on = await freePort();
    final off = await freePort();
    final profile2 = ServerProfile(
      id: 'one',
      name: '含停用',
      host: 'example.com',
      username: 'alice',
      rules: [
        ForwardRule(id: 'on', label: '启用', localPort: on, remotePort: 80),
        ForwardRule(
          id: 'off',
          label: '停用',
          localPort: off,
          remotePort: 81,
          enabled: false,
        ),
      ],
    );
    await engine.connect(profile2, 'x', onTrustHost: (_) async => true);
    expect(engine.status.rules.map((r) => r.rule.id), ['on']);
    final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, off);
    await free.close();
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
        profileFor(
          listenPort,
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
      profileFor(
        listenPort,
        id: 'two',
        name: '二',
        host: 'two.example',
        username: 'bob',
      ),
      'two-password',
      onTrustHost: (_) async => true,
    );
    final latestSwitch = engine.connect(
      profileFor(
        listenPort,
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

  /// Remote ports that refuse a direct-tcpip channel (others stay reachable).
  Set<int> failTargets = {};
  final targets = <List<Object>>[];
  final channels = <EchoChannel>[];
  Completer<ForwardConnection>? pendingChannel;
  Completer<void>? closeGate, channelReadGate;
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
    if (!targetAvailable || failTargets.contains(port)) {
      throw SSHChannelOpenError(2, 'refused');
    }
    final channel = EchoChannel(readGate: channelReadGate);
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
  EchoChannel({Completer<void>? readGate}) {
    if (readGate != null) {
      final bridge = StreamController<List<int>>();
      // Match SSHForwardChannel: map/pipe into a second controller consumed by
      // a StreamIterator, which reads only when remote-window credit exists.
      unawaited(
        input.stream
            .map((bytes) => bytes)
            .pipe(bridge.sink)
            .catchError((Object _) {}),
      );
      final iterator = StreamIterator<List<int>>(bridge.stream);
      unawaited(() async {
        await Future.any([readGate.future, ended.future]);
        if (destroyed) {
          await iterator.cancel();
          return;
        }
        while (await iterator.moveNext()) {
          acceptedChunks++;
          received.add(iterator.current);
        }
        if (!destroyed) {
          output.add(received.takeBytes());
          await output.close();
        }
      }());
      return;
    }
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
  int acceptedChunks = 0;
  @override
  Stream<Uint8List> get stream => output.stream;
  @override
  StreamSink<List<int>> get sink => input.sink;
  @override
  Future<void> get done => ended.future;
  @override
  void destroy() {
    if (destroyed) return;
    destroyed = true;
    unawaited(input.close());
    unawaited(output.close());
    if (!ended.isCompleted) ended.complete();
  }
}
