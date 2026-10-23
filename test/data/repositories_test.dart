import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/core/host_trust.dart';
import 'package:portlink/core/server_profile.dart';
import 'package:portlink/data/host_trust_store.dart';
import 'package:portlink/data/profile_repository.dart';

ServerProfile profile(String id) => ServerProfile(
  id: id,
  name: '服务器 $id',
  host: 'example.com',
  username: 'user',
);
String pin(String letter) => 'SHA256:${List.filled(43, letter).join()}';

void main() {
  late Directory directory;
  late String path;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'portlink-repository-test-',
    );
    path = '${directory.path}/profiles.json';
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'empty first run, immutable snapshot and validated round trip',
    () async {
      final repo = JsonProfileRepository(path);
      expect((await repo.load()).profiles, isEmpty);
      final input = [profile('one')];
      final snapshot = ProfileSnapshot(
        profiles: input,
        defaultProfileId: 'one',
      );
      input.clear();
      expect(snapshot.profiles.length, 1);
      expect(() => snapshot.profiles.clear(), throwsUnsupportedError);
      await repo.save(snapshot);
      final loaded = await repo.load();
      expect(loaded.profiles.single.toJson(), profile('one').toJson());
      expect(loaded.defaultProfileId, 'one');
      final json = await File(path).readAsString();
      expect(jsonDecode(json)['schemaVersion'], 1);
      expect(json, isNot(contains('password')));
    },
  );
  test(
    'atomic backup recovers corrupt primary and preserves last good backup',
    () async {
      final repo = JsonProfileRepository(path);
      await repo.save(
        ProfileSnapshot(profiles: [profile('one')], defaultProfileId: 'one'),
      );
      await repo.save(
        ProfileSnapshot(profiles: [profile('two')], defaultProfileId: 'two'),
      );
      await File(path).writeAsString('{broken');
      expect((await repo.load()).defaultProfileId, 'one');
      await repo.save(
        ProfileSnapshot(
          profiles: [profile('three')],
          defaultProfileId: 'three',
        ),
      );
      expect(
        jsonDecode(await File('$path.bak').readAsString())['defaultProfileId'],
        'one',
      );
      expect((await repo.load()).defaultProfileId, 'three');
      expect(
        directory.listSync().where((f) => f.path.contains('.tmp.')),
        isEmpty,
      );
    },
  );
  test(
    'concurrent repository instances never expose partial documents',
    () async {
      await Future.wait(
        List.generate(
          25,
          (i) => JsonProfileRepository(path).save(
            ProfileSnapshot(
              profiles: [profile('id-$i')],
              defaultProfileId: 'id-$i',
            ),
          ),
        ),
      );
      expect(
        (await JsonProfileRepository(path).load()).defaultProfileId,
        'id-24',
      );
      expect(
        jsonDecode(await File('$path.bak').readAsString())['defaultProfileId'],
        'id-23',
      );
    },
  );
  test('schema limits duplicate IDs missing default and plaintext fields are rejected', () async {
    final repo = JsonProfileRepository(path);
    await expectLater(
      repo.save(ProfileSnapshot(profiles: [profile('x'), profile('x')])),
      throwsFormatException,
    );
    await expectLater(
      repo.save(ProfileSnapshot(defaultProfileId: 'missing')),
      throwsFormatException,
    );
    await expectLater(
      repo.save(
        ProfileSnapshot(profiles: List.generate(101, (i) => profile('id-$i'))),
      ),
      throwsFormatException,
    );
    for (final data in [
      {'schemaVersion': 2, 'profiles': []},
      {
        'schemaVersion': 1,
        'profiles': [
          {...profile('x').toJson(), 'password': 'never-store'},
        ],
      },
      {
        'schemaVersion': 1,
        'profiles': [
          {...profile('x').toJson(), 'sshPort': 22.5},
        ],
      },
    ]) {
      await File(path).writeAsString(jsonEncode(data));
      await expectLater(repo.load(), throwsFormatException);
    }
    await File(path).writeAsString('x' * (1024 * 1024 + 1));
    await expectLater(repo.load(), throwsFormatException);
  });
  test(
    'host pins normalize host case, isolate ports and block algorithm changes',
    () async {
      final store = JsonHostTrustStore(path);
      expect(
        await store.readFingerprint('EXAMPLE.com', 22, 'ssh-ed25519'),
        isNull,
      );
      await store.trust('EXAMPLE.com', 22, 'ssh-ed25519', pin('A'));
      expect(
        await store.readFingerprint('example.com', 22, 'ssh-ed25519'),
        pin('A'),
      );
      expect(
        await store.readFingerprint('example.com', 2222, 'ssh-rsa'),
        isNull,
      );
      await expectLater(
        store.readFingerprint('example.com', 22, 'ssh-rsa'),
        throwsA(isA<HostKeyChangedException>()),
      );
      await expectLater(
        store.trust('example.com', 22, 'ssh-ed25519', pin('B')),
        throwsA(isA<HostKeyChangedException>()),
      );
      await expectLater(
        store.trust('example.com', 22, 'ssh-rsa', pin('A')),
        throwsA(isA<HostKeyChangedException>()),
      );
      expect(
        await store.readFingerprint('example.com', 22, 'ssh-ed25519'),
        pin('A'),
      );
    },
  );
  test(
    'trust read-modify-write serialized across instances without losing pins',
    () async {
      await Future.wait(
        List.generate(
          20,
          (i) =>
              JsonHostTrustStore(path)
                  .trust('host-$i.example', 22, 'ssh-ed25519', pin('A')),
        ),
      );
      for (var i = 0; i < 20; i++) {
        expect(
          await JsonHostTrustStore(path)
              .readFingerprint('host-$i.example', 22, 'ssh-ed25519'),
          pin('A'),
        );
      }
    },
  );
  test('pin formats and malformed trust documents fail closed', () async {
    final store = JsonHostTrustStore(path);
    await expectLater(
      store.trust('one', 22, 'ssh-ed25519', 'MD5:old'),
      throwsFormatException,
    );
    await expectLater(
      store.trust('one', 0, 'ssh-ed25519', pin('A')),
      throwsFormatException,
    );
    await File(path).writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'hosts': {
          'not-a-host-port-key': {
            'keyType': 'ssh-ed25519',
            'fingerprint': pin('A'),
          },
        },
      }),
    );
    await expectLater(
      store.readFingerprint('one', 22, 'ssh-ed25519'),
      throwsFormatException,
    );
  });
  test(
    'trust corruption fails closed even with a valid stale backup',
    () async {
      final store = JsonHostTrustStore(path);
      await store.trust('one', 22, 'ssh-ed25519', pin('A'));
      await store.trust('two', 22, 'ssh-ed25519', pin('B'));
      expect(await File('$path.bak').exists(), isTrue);
      await File(path).writeAsString('corrupt');
      await expectLater(
        store.readFingerprint('two', 22, 'ssh-ed25519'),
        throwsFormatException,
      );
      await expectLater(
        store.trust('two', 22, 'ssh-ed25519', pin('C')),
        throwsFormatException,
      );
    },
  );
}
