import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/app_controller.dart';
import 'package:portlink/core/host_trust.dart';
import 'package:portlink/core/server_profile.dart';
import 'package:portlink/core/tunnel_engine.dart';
import 'package:portlink/core/tunnel_status.dart';
import 'package:portlink/data/profile_repository.dart';
import 'package:portlink/data/secret_store.dart';

const one = ServerProfile(
  id: 'one',
  name: '主机一',
  host: 'one.example',
  username: 'alice',
);
const two = ServerProfile(
  id: 'two',
  name: '主机二',
  host: 'two.example',
  username: 'bob',
);
const hostRequest = HostTrustRequest(
  host: 'one.example',
  port: 22,
  keyType: 'ssh-ed25519',
  fingerprint: 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);

Future<void> eventually(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 2)) {
      throw StateError('condition timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  late MemoryProfiles repository;
  late MemorySecrets secrets;
  late MemoryTunnel engine;
  late MemorySession session;
  late AppController controller;
  setUp(() {
    repository = MemoryProfiles();
    secrets = MemorySecrets();
    engine = MemoryTunnel();
    session = MemorySession(engine.events);
    controller = AppController(
      repository: repository,
      secrets: secrets,
      engine: engine,
      startSession: session.start,
      stopSession: session.stop,
      newId: () => 'new-id',
    );
  });
  tearDown(() async {
    await controller.shutdown();
    controller.dispose();
  });

  Future<void> seed({String? defaultId, bool password = true}) async {
    repository.snapshot = ProfileSnapshot(
      profiles: [one, two],
      defaultProfileId: defaultId,
    );
    if (password) {
      secrets.values.addAll({'one': 'old-one-secret', 'two': 'old-two-secret'});
    }
    await controller.initialize();
  }

  Future<void> save({
    String? id,
    String name = '新主机',
    String? password = 'new-secret',
    bool makeDefault = false,
    String host = 'new.example',
  }) => controller.saveProfile(
    id: id,
    name: name,
    host: host,
    sshPort: 22,
    username: 'user',
    password: password,
    makeDefault: makeDefault,
  );

  test(
    'initialize loads immutable profiles and auto-connects only default once',
    () async {
      await seed(defaultId: 'two');
      await controller.initialize();
      expect(repository.loads, 1);
      expect(controller.initialized, isTrue);
      expect(controller.busy, isFalse);
      expect(controller.defaultProfileId, 'two');
      expect(engine.connections.map((p) => p.id), ['two']);
      expect(controller.activeProfile?.id, 'two');
      expect(controller.tunnelStatus.phase, TunnelPhase.ready);
      expect(session.starts, 1);
      expect(() => controller.profiles.clear(), throwsUnsupportedError);
      expect(
        engine.events.indexOf('session.start'),
        lessThan(engine.events.indexOf('engine.connect:two')),
      );
    },
  );

  test(
    'concurrent initialize calls share a single load and autoconnect',
    () async {
      repository.snapshot = ProfileSnapshot(
        profiles: [one],
        defaultProfileId: 'one',
      );
      secrets.values['one'] = 'old-one-secret';
      final gate = Completer<void>();
      repository.loadGate = gate;
      final first = controller.initialize();
      final second = controller.initialize();
      expect(controller.busy, isTrue);
      expect(repository.loads, 1);
      gate.complete();
      await Future.wait([first, second]);
      expect(engine.connections.length, 1);
    },
  );

  test(
    'initialization error forbids every mutation and connection without leaking errors',
    () async {
      repository.loadFailure = StateError(
        'SECRET-IN-EXCEPTION /private/config',
      );
      await controller.initialize();
      expect(controller.initialized, isFalse);
      expect(controller.busy, isFalse);
      expect(controller.errorMessage, contains('禁止修改'));
      expect(controller.errorMessage, isNot(contains('SECRET-IN-EXCEPTION')));
      await save();
      await controller.deleteProfile('one');
      await controller.setDefault('one');
      await controller.connectProfile('one');
      expect(repository.saves, isEmpty);
      expect(secrets.writes, isEmpty);
      expect(engine.connections, isEmpty);
      controller.clearError();
      await save();
      expect(controller.errorMessage, contains('不能修改'));
    },
  );

  test(
    'new profile requires password before metadata or secret writes',
    () async {
      await controller.initialize();
      await save(password: '');
      expect(controller.errorMessage, contains('需要 SSH 密码'));
      expect(repository.saves, isEmpty);
      expect(secrets.writes, isEmpty);
      expect(controller.profiles, isEmpty);
    },
  );

  test('invalid profile is rejected before touching secure storage', () async {
    await controller.initialize();
    await save(host: 'https://invalid.example/path');
    expect(controller.errorMessage, isNotNull);
    expect(secrets.reads, isEmpty);
    expect(secrets.writes, isEmpty);
    expect(repository.saves, isEmpty);
  });

  test(
    'first saved profile becomes default without automatically connecting',
    () async {
      await controller.initialize();
      await save(name: '  主机  ', host: ' new.example ');
      expect(controller.profiles.single.id, 'new-id');
      expect(controller.profiles.single.name, '主机');
      expect(controller.profiles.single.host, 'new.example');
      expect(controller.defaultProfileId, 'new-id');
      expect(secrets.values['new-id'], 'new-secret');
      expect(
        repository.snapshot.toJson().toString(),
        isNot(contains('new-secret')),
      );
      expect(engine.connections, isEmpty);
    },
  );

  test(
    'failed metadata save rolls existing password back and leaves configuration unchanged',
    () async {
      await seed(defaultId: 'one');
      final old = controller.profiles;
      final connects = engine.connections.length;
      repository.saveFailure = StateError('SECRET-IN-EXCEPTION');
      await save(id: 'one', makeDefault: true);
      expect(controller.profiles, same(old));
      expect(controller.defaultProfileId, 'one');
      expect(secrets.values['one'], 'old-one-secret');
      expect(secrets.writes.map((w) => w.id), ['one', 'one']);
      expect(engine.connections.length, connects);
      expect(controller.tunnelStatus.phase, TunnelPhase.ready);
      expect(controller.errorMessage, isNotNull);
      expect(controller.errorMessage, isNot(contains('SECRET-IN-EXCEPTION')));
      expect(controller.errorMessage, isNot(contains('new-secret')));
    },
  );

  test('failed new-profile save removes newly written credential', () async {
    await controller.initialize();
    repository.saveFailure = StateError('disk failed');
    await save();
    expect(controller.profiles, isEmpty);
    expect(secrets.values['new-id'], isNull);
    expect(secrets.deletes, ['new-id']);
    expect(controller.defaultProfileId, isNull);
  });

  test(
    'failed credential rollback surfaces explicit repair warning without exposing secrets',
    () async {
      await seed();
      repository.saveFailure = StateError('disk failed');
      secrets.failWriteAt = 2;
      await save(id: 'one');
      expect(controller.profiles.first.name, one.name);
      expect(controller.errorMessage, contains('旧凭据也未能恢复'));
      expect(controller.errorMessage, isNot(contains('old-one-secret')));
      expect(controller.errorMessage, isNot(contains('new-secret')));
    },
  );

  test(
    'secure-store write failure never commits metadata or updates UI state',
    () async {
      await seed();
      secrets.failWriteAt = 1;
      await save(id: 'one');
      expect(repository.saves, isEmpty);
      expect(controller.profiles.first.name, one.name);
      expect(secrets.values['one'], 'old-one-secret');
      expect(controller.errorMessage, contains('不会回退为明文'));
    },
  );

  test(
    'editing blank password keeps credential and only restarts active profile after save succeeds',
    () async {
      await seed(defaultId: 'one');
      final passwordWrites = secrets.writes.length;
      final gate = Completer<void>();
      repository.saveGate = gate;
      final operation = save(
        id: 'one',
        password: '',
        name: '编辑名称',
        makeDefault: true,
      );
      await eventually(() => repository.saves.isNotEmpty);
      expect(controller.busy, isTrue);
      expect(engine.connections.length, 1);
      expect(controller.profiles.first.name, one.name);
      gate.complete();
      await operation;
      expect(secrets.writes.length, passwordWrites);
      expect(secrets.values['one'], 'old-one-secret');
      expect(engine.connections.length, 2);
      expect(engine.passwords.last, 'old-one-secret');
      expect(controller.activeProfile?.name, '编辑名称');
    },
  );

  test(
    'setting default persists choice but never switches a live connection',
    () async {
      await seed(defaultId: 'one');
      final calls = engine.connections.length;
      await controller.setDefault('two');
      expect(controller.defaultProfileId, 'two');
      expect(repository.snapshot.defaultProfileId, 'two');
      expect(controller.activeProfile?.id, 'one');
      expect(engine.connections.length, calls);
    },
  );

  test('failed default save leaves the previous selection intact', () async {
    await seed(defaultId: 'one');
    repository.saveFailure = StateError('disk');
    await controller.setDefault('two');
    expect(controller.defaultProfileId, 'one');
    expect(repository.snapshot.defaultProfileId, 'one');
  });

  test(
    'delete active default disconnects before stopping Android session and chooses first remaining',
    () async {
      await seed(defaultId: 'one');
      engine.events.clear();
      await controller.deleteProfile('one');
      expect(controller.profiles.map((p) => p.id), ['two']);
      expect(controller.defaultProfileId, 'two');
      expect(controller.activeProfile, isNull);
      expect(controller.tunnelStatus.phase, TunnelPhase.idle);
      expect(secrets.values.containsKey('one'), isFalse);
      expect(engine.events.take(2), ['engine.disconnect', 'session.stop']);
      expect(
        engine.connections.length,
        1,
      ); // changing fallback default does not connect it
    },
  );

  test(
    'delete inactive profile does not disconnect the current server',
    () async {
      await seed(defaultId: 'one');
      final disconnects = engine.disconnects;
      await controller.deleteProfile('two');
      expect(controller.activeProfile?.id, 'one');
      expect(engine.disconnects, disconnects);
      expect(controller.defaultProfileId, 'one');
    },
  );

  test(
    'delete secret failure leaves metadata deleted with honest cleanup warning',
    () async {
      await seed();
      secrets.deleteFailure = StateError('SECRET-IN-EXCEPTION');
      await controller.deleteProfile('two');
      expect(controller.profiles.map((p) => p.id), ['one']);
      expect(repository.snapshot.profiles.map((p) => p.id), ['one']);
      expect(controller.errorMessage, contains('凭据清理失败'));
      expect(controller.errorMessage, isNot(contains('SECRET-IN-EXCEPTION')));
    },
  );

  test(
    'delete metadata failure preserves credential and configuration',
    () async {
      await seed();
      repository.saveFailure = StateError('disk');
      await controller.deleteProfile('two');
      expect(controller.profiles.map((p) => p.id), ['one', 'two']);
      expect(secrets.deletes, isEmpty);
      expect(secrets.values['two'], 'old-two-secret');
    },
  );

  test(
    'busy metadata transaction gates all other mutations and connect switches',
    () async {
      await seed();
      final gate = Completer<void>();
      repository.saveGate = gate;
      final operation = save(id: 'one', password: '', makeDefault: true);
      await eventually(() => repository.saves.length == 1);
      await controller.deleteProfile('two');
      await controller.setDefault('two');
      await save();
      await controller.connectProfile('two');
      expect(repository.saves.length, 1);
      expect(engine.connections, isEmpty);
      gate.complete();
      await operation;
      expect(controller.busy, isFalse);
    },
  );

  test(
    'host-key prompt can be explicitly accepted and is cleared exactly once',
    () async {
      await seed();
      engine.requireTrust = true;
      final connecting = controller.connectProfile('one');
      await eventually(() => controller.pendingTrust != null);
      expect(controller.busy, isTrue);
      expect(controller.pendingTrust?.fingerprint, hostRequest.fingerprint);
      controller.answerHostTrust(true);
      controller.answerHostTrust(true);
      await connecting;
      expect(engine.trustResults, [true]);
      expect(controller.pendingTrust, isNull);
      expect(controller.tunnelStatus.phase, TunnelPhase.ready);
      expect(controller.busy, isFalse);
    },
  );

  test(
    'disconnect bypasses busy and rejects a hanging host-key prompt',
    () async {
      await seed();
      engine.requireTrust = true;
      final connecting = controller.connectProfile('one');
      await eventually(() => controller.pendingTrust != null);
      await controller.disconnect().timeout(const Duration(seconds: 1));
      await connecting.timeout(const Duration(seconds: 1));
      controller.answerHostTrust(true); // stale UI response must have no effect
      expect(engine.trustResults, [false]);
      expect(controller.pendingTrust, isNull);
      expect(controller.tunnelStatus.phase, TunnelPhase.idle);
      expect(session.active, isFalse);
      expect(controller.busy, isFalse);
    },
  );

  test(
    'fatal engine status dismisses outstanding trust and stops platform session',
    () async {
      await seed();
      engine.requireTrust = true;
      final connecting = controller.connectProfile('one');
      await eventually(() => controller.pendingTrust != null);
      engine.publish(
        const TunnelStatus(
          phase: TunnelPhase.failed,
          profileId: 'one',
          message: '安全失败',
        ),
      );
      await connecting;
      await eventually(() => !session.active);
      expect(engine.trustResults, [false]);
      expect(controller.pendingTrust, isNull);
    },
  );

  test(
    'Android start failure prevents SSH connect and cleans session without leaking platform text',
    () async {
      await seed();
      session.startFailure = StateError('SECRET-IN-EXCEPTION');
      await controller.connectProfile('one');
      expect(engine.connections, isEmpty);
      expect(session.starts, 1);
      expect(session.active, isFalse);
      expect(controller.busy, isFalse);
      expect(controller.errorMessage, isNotNull);
      expect(controller.errorMessage, isNot(contains('SECRET-IN-EXCEPTION')));
    },
  );

  test('cancel during pending Android start cannot later open SSH', () async {
    await seed();
    final gate = Completer<void>();
    session.startGate = gate;
    final connecting = controller.connectProfile('one');
    await eventually(() => session.starts == 1);
    await controller.disconnect();
    gate.complete();
    await connecting;
    expect(engine.connections, isEmpty);
    expect(session.active, isFalse);
    expect(controller.tunnelStatus.phase, TunnelPhase.idle);
  });

  test('missing password never starts Android or opens SSH', () async {
    await seed(password: false);
    await controller.connectProfile('one');
    expect(session.starts, 0);
    expect(engine.connections, isEmpty);
    expect(controller.tunnelStatus.phase, TunnelPhase.failed);
    expect(controller.errorMessage, contains('无法读取 SSH 密码'));
  });

  test(
    'transient reconnect keeps Android session while fatal status stops it',
    () async {
      await seed(defaultId: 'one');
      final stops = session.stops;
      engine.publish(
        const TunnelStatus(phase: TunnelPhase.reconnecting, profileId: 'one'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(session.active, isTrue);
      expect(session.stops, stops);
      engine.publish(
        const TunnelStatus(phase: TunnelPhase.failed, profileId: 'one'),
      );
      await eventually(() => !session.active);
      expect(session.stops, stops + 1);
    },
  );

  test('stale queued failure cannot stop a newer healthy connection', () async {
    await seed(defaultId: 'one');
    engine.publish(
      const TunnelStatus(phase: TunnelPhase.failed, profileId: 'one'),
    );
    await controller.connectProfile('two');
    await Future<void>.delayed(Duration.zero);
    expect(controller.activeProfile?.id, 'two');
    expect(session.active, isTrue);
  });

  test(
    'secure-store read failure never opens SSH or leaks backend exception',
    () async {
      await seed();
      secrets.readFailure = StateError('SECRET-IN-EXCEPTION');
      await controller.connectProfile('one');
      expect(engine.connections, isEmpty);
      expect(session.starts, 0);
      expect(controller.tunnelStatus.phase, TunnelPhase.failed);
      expect(controller.errorMessage, isNotNull);
      expect(controller.errorMessage, isNot(contains('SECRET-IN-EXCEPTION')));
    },
  );

  test(
    'failed native stop is not acknowledged and delete does not commit metadata',
    () async {
      await seed(defaultId: 'one');
      session.stopFailure = StateError('SECRET-IN-EXCEPTION');
      try {
        await expectLater(controller.disconnect(), throwsA(isA<StateError>()));
        expect(controller.errorMessage, contains('停止连接失败'));
        expect(controller.errorMessage, isNot(contains('SECRET-IN-EXCEPTION')));
        // An engine reporting the profile active makes delete exercise stop again.
        engine.publish(
          const TunnelStatus(phase: TunnelPhase.ready, profileId: 'one'),
        );
        await controller.deleteProfile('one');
        expect(repository.saves, isEmpty);
        expect(controller.profiles.map((p) => p.id), ['one', 'two']);
        expect(secrets.deletes, isEmpty);
      } finally {
        session.stopFailure = null;
      }
    },
  );

  test(
    'target unavailable remains an active Android forwarding session',
    () async {
      await seed(defaultId: 'one');
      final stops = session.stops;
      engine.publish(
        const TunnelStatus(
          phase: TunnelPhase.targetUnavailable,
          profileId: 'one',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.tunnelStatus.isConnected, isTrue);
      expect(session.active, isTrue);
      expect(session.stops, stops);
    },
  );

  test(
    'shutdown while loading cannot resurrect profiles or auto-connect default',
    () async {
      repository.snapshot = ProfileSnapshot(
        profiles: [one],
        defaultProfileId: 'one',
      );
      secrets.values['one'] = 'old-one-secret';
      final gate = Completer<void>();
      repository.loadGate = gate;
      final initialize = controller.initialize();
      await controller.shutdown();
      gate.complete();
      await initialize;
      expect(controller.initialized, isFalse);
      expect(controller.profiles, isEmpty);
      expect(engine.connections, isEmpty);
      expect(session.starts, 0);
    },
  );

  test(
    'shutdown during default save never updates closed controller state',
    () async {
      await seed(defaultId: 'one');
      final gate = Completer<void>();
      repository.saveGate = gate;
      final operation = controller.setDefault('two');
      await eventually(() => repository.saves.isNotEmpty);
      await controller.shutdown();
      gate.complete();
      await operation;
      expect(
        repository.snapshot.defaultProfileId,
        'two',
      ); // already accepted disk transaction finishes
      expect(controller.defaultProfileId, 'one');
    },
  );

  test(
    'shutdown during delete lets committed credential cleanup finish without UI resurrection',
    () async {
      await seed();
      final gate = Completer<void>();
      repository.saveGate = gate;
      final operation = controller.deleteProfile('two');
      await eventually(() => repository.saves.isNotEmpty);
      await controller.shutdown();
      gate.complete();
      await operation;
      expect(repository.snapshot.profiles.map((p) => p.id), ['one']);
      expect(controller.profiles.map((p) => p.id), ['one', 'two']);
      expect(secrets.deletes, ['two']);
      expect(session.active, isFalse);
    },
  );

  test(
    'disconnect during secure-store read cancels before Android session starts',
    () async {
      await seed();
      final gate = Completer<void>();
      secrets.readGate = gate;
      final operation = controller.connectProfile('one');
      await eventually(() => secrets.reads.contains('one'));
      expect(controller.tunnelStatus.phase, TunnelPhase.connecting);
      expect(controller.busy, isTrue);
      await controller.disconnect();
      gate.complete();
      await operation;
      expect(engine.connections, isEmpty);
      expect(session.starts, 0);
      expect(controller.tunnelStatus.phase, TunnelPhase.idle);
    },
  );

  test(
    'shutdown during delayed engine completion cannot republish ready',
    () async {
      await seed();
      final gate = Completer<void>();
      engine.connectGate = gate;
      final operation = controller.connectProfile('one');
      await eventually(() => engine.connections.isNotEmpty);
      await controller.shutdown();
      gate.complete();
      await operation;
      expect(engine.disposals, 1);
      expect(controller.tunnelStatus.phase, isNot(TunnelPhase.ready));
      expect(session.active, isFalse);
    },
  );

  test(
    'password whitespace is preserved rather than silently trimmed',
    () async {
      await controller.initialize();
      await save(password: '  meaningful whitespace  ');
      expect(secrets.values['new-id'], '  meaningful whitespace  ');
    },
  );

  test(
    'saving an unknown edit ID never creates or overwrites credentials',
    () async {
      await seed();
      await save(id: 'missing');
      expect(controller.errorMessage, contains('不存在'));
      expect(repository.saves, isEmpty);
      expect(secrets.reads, isEmpty);
      expect(secrets.writes, isEmpty);
    },
  );

  test(
    'deleting the final profile clears the default and stored password',
    () async {
      repository.snapshot = ProfileSnapshot(
        profiles: [one],
        defaultProfileId: 'one',
      );
      secrets.values['one'] = 'old-one-secret';
      await controller.initialize();
      await controller.deleteProfile('one');
      expect(controller.profiles, isEmpty);
      expect(controller.defaultProfileId, isNull);
      expect(repository.snapshot.defaultProfileId, isNull);
      expect(secrets.values, isEmpty);
      expect(controller.tunnelStatus.phase, TunnelPhase.idle);
    },
  );

  test(
    'explicit host trust rejection stops platform session without an uncaught error',
    () async {
      await seed();
      engine.requireTrust = true;
      final connecting = controller.connectProfile('one');
      await eventually(() => controller.pendingTrust != null);
      controller.answerHostTrust(false);
      await connecting;
      expect(engine.trustResults, [false]);
      expect(controller.pendingTrust, isNull);
      expect(controller.tunnelStatus.phase, TunnelPhase.failed);
      expect(session.active, isFalse);
    },
  );

  test(
    'failed new-profile rollback warns about remaining orphaned credential',
    () async {
      await controller.initialize();
      repository.saveFailure = StateError('disk');
      secrets.deleteFailure = StateError('SECRET-IN-EXCEPTION');
      await save();
      expect(controller.profiles, isEmpty);
      expect(controller.errorMessage, contains('旧凭据也未能恢复'));
      expect(controller.errorMessage, isNot(contains('new-secret')));
      expect(controller.errorMessage, isNot(contains('SECRET-IN-EXCEPTION')));
    },
  );

  test(
    'shutdown is idempotent, rejects pending trust and blocks later mutation/connect',
    () async {
      await seed();
      engine.requireTrust = true;
      final connecting = controller.connectProfile('one');
      await eventually(() => controller.pendingTrust != null);
      await controller.shutdown();
      await controller.shutdown();
      await connecting;
      expect(engine.disposals, 1);
      expect(engine.trustResults, [false]);
      expect(controller.pendingTrust, isNull);
      expect(session.active, isFalse);
      final saves = repository.saves.length;
      await save();
      await controller.setDefault('two');
      await controller.connectProfile('two');
      expect(repository.saves.length, saves);
      expect(engine.connections.length, 1);
    },
  );
}

final class MemoryProfiles implements ProfileRepository {
  ProfileSnapshot snapshot = ProfileSnapshot();
  int loads = 0;
  final saves = <ProfileSnapshot>[];
  Object? loadFailure, saveFailure;
  Completer<void>? loadGate, saveGate;
  @override
  Future<ProfileSnapshot> load() async {
    loads++;
    await loadGate?.future;
    if (loadFailure != null) throw loadFailure!;
    return snapshot;
  }

  @override
  Future<void> save(ProfileSnapshot value) async {
    value.toJson();
    saves.add(value);
    await saveGate?.future;
    if (saveFailure != null) throw saveFailure!;
    snapshot = value;
  }
}

final class SecretWrite {
  SecretWrite(this.id);
  final String id; // Do not include passwords in test diagnostics.
}

final class MemorySecrets implements SecretStore {
  final values = <String, String>{};
  final reads = <String>[], deletes = <String>[];
  final writes = <SecretWrite>[];
  int? failWriteAt;
  Object? readFailure, deleteFailure;
  Completer<void>? readGate;
  @override
  Future<String?> readPassword(String id) async {
    reads.add(id);
    await readGate?.future;
    if (readFailure != null) throw readFailure!;
    return values[id];
  }

  @override
  Future<void> writePassword(String id, String password) async {
    writes.add(SecretWrite(id));
    if (writes.length == failWriteAt) throw StateError('SECRET-IN-EXCEPTION');
    values[id] = password;
  }

  @override
  Future<void> deletePassword(String id) async {
    deletes.add(id);
    if (deleteFailure != null) throw deleteFailure!;
    values.remove(id);
  }
}

final class MemorySession {
  MemorySession(this.events);
  final List<String> events;
  int starts = 0, stops = 0;
  bool active = false;
  Object? startFailure, stopFailure;
  Completer<void>? startGate;
  Future<void> start() async {
    starts++;
    events.add('session.start');
    await startGate?.future;
    if (startFailure != null) throw startFailure!;
    active = true;
  }

  Future<void> stop() async {
    stops++;
    events.add('session.stop');
    if (stopFailure != null) throw stopFailure!;
    active = false;
  }
}

final class MemoryTunnel implements TunnelEngine {
  final changes = StreamController<TunnelStatus>.broadcast(sync: true);
  TunnelStatus current = const TunnelStatus(phase: TunnelPhase.idle);
  final connections = <ServerProfile>[];
  final passwords = <String>[];
  final trustResults = <bool>[];
  final events = <String>[];
  bool requireTrust = false, disposed = false;
  Completer<void>? connectGate;
  int disconnects = 0, disposals = 0, generation = 0;
  @override
  Stream<TunnelStatus> get statuses => changes.stream;
  @override
  TunnelStatus get status => current;
  void publish(TunnelStatus value) {
    current = value;
    if (!disposed) changes.add(value);
  }

  @override
  Future<void> connect(
    ServerProfile profile,
    String password, {
    required HostTrustPrompt onTrustHost,
  }) async {
    final token = ++generation;
    connections.add(profile);
    passwords.add(password);
    events.add('engine.connect:${profile.id}');
    publish(TunnelStatus(phase: TunnelPhase.connecting, profileId: profile.id));
    if (requireTrust) {
      publish(
        TunnelStatus(phase: TunnelPhase.verifyingHost, profileId: profile.id),
      );
      final accepted = await onTrustHost(hostRequest);
      trustResults.add(accepted);
      if (token != generation || disposed) return;
      if (!accepted) {
        publish(TunnelStatus(phase: TunnelPhase.failed, profileId: profile.id));
        return;
      }
    }
    await connectGate?.future;
    if (token == generation && !disposed) {
      publish(TunnelStatus(phase: TunnelPhase.ready, profileId: profile.id));
    }
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    generation++;
    events.add('engine.disconnect');
    publish(const TunnelStatus(phase: TunnelPhase.idle));
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposals++;
    generation++;
    events.add('engine.dispose');
    disposed = true;
    current = const TunnelStatus(phase: TunnelPhase.idle);
    await changes.close();
  }
}
