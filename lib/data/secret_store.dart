import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SecretStore {
  Future<String?> readPassword(String profileId);
  Future<void> writePassword(String profileId, String password);
  Future<void> deletePassword(String profileId);
}

/// OS keychain / credential storage only. Failures propagate: never write secrets
/// to preferences, JSON, logs, error messages, or a plaintext fallback.
final class SecureSecretStore implements SecretStore {
  SecureSecretStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;

  String _key(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
      throw ArgumentError('服务器标识无效');
    }
    return 'portlink.password.v1.$id';
  }

  @override
  Future<String?> readPassword(String profileId) =>
      _storage.read(key: _key(profileId));
  @override
  Future<void> writePassword(String profileId, String password) =>
      _storage.write(key: _key(profileId), value: password);
  @override
  Future<void> deletePassword(String profileId) =>
      _storage.delete(key: _key(profileId));
}
