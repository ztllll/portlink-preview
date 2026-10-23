import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/data/secret_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });
  test(
    'password roundtrip is namespaced per profile and delete is isolated',
    () async {
      final store = SecureSecretStore();
      expect(await store.readPassword('one'), isNull);
      await store.writePassword('one', 'sensitive-one');
      await store.writePassword('two', 'sensitive-two');
      expect(await store.readPassword('one'), 'sensitive-one');
      expect(await store.readPassword('two'), 'sensitive-two');
      await store.deletePassword('one');
      expect(await store.readPassword('one'), isNull);
      expect(await store.readPassword('two'), 'sensitive-two');
    },
  );
  test(
    'platform secure-storage failures propagate and never become silent fallback',
    () async {
      final store = SecureSecretStore(storage: UnavailableStorage());
      await expectLater(store.readPassword('one'), throwsA(isA<StateError>()));
      await expectLater(
        store.writePassword('one', 'sensitive'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        store.deletePassword('one'),
        throwsA(isA<StateError>()),
      );
    },
  );
  test('invalid IDs cannot escape credential namespace', () {
    final store = SecureSecretStore();
    expect(() => store.readPassword('../../other'), throwsArgumentError);
    expect(() => store.writePassword('', 'sensitive'), throwsArgumentError);
  });
}

final class UnavailableStorage implements FlutterSecureStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<Never>.error(StateError('keychain unavailable'));
}
