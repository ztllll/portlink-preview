import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/data/secret_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('standalone Mac password operations use login Keychain without sharing entitlement', () async {
    final previous = FlutterSecureStoragePlatform.instance;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    final received = <MethodCall>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    FlutterSecureStoragePlatform.instance = MethodChannelFlutterSecureStorage();
    messenger.setMockMethodCallHandler(channel, (call) async {
      received.add(call);
      return call.method == 'read' ? 'fixture-password' : null;
    });
    try {
      final store = SecureSecretStore();
      await store.writePassword('one', 'fixture-password');
      expect(await store.readPassword('one'), 'fixture-password');
      await store.deletePassword('one');
      expect(received.map((call) => call.method), ['write', 'read', 'delete']);
      for (final call in received) {
        final options = (call.arguments as Map)['options'] as Map;
        expect(options['usesDataProtectionKeychain'], 'false');
        expect(options['groupId'], anyOf(isNull, isEmpty));
      }
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
      FlutterSecureStoragePlatform.instance = previous;
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
