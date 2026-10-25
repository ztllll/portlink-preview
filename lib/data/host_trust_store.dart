import 'dart:convert';
import 'dart:io';

import '../core/host_trust.dart';
import 'atomic_json_file.dart';

abstract interface class HostTrustStore {
  Future<String?> readFingerprint(String host, int port, String keyType);
  Future<void> trust(String host, int port, String keyType, String fingerprint);
}

final class JsonHostTrustStore implements HostTrustStore {
  JsonHostTrustStore(String filePath) : _file = AtomicJsonFile(filePath);
  final AtomicJsonFile _file;

  String _key(String host, int port) {
    if (host.isEmpty || host.length > 253 || port < 1 || port > 65535) {
      throw const FormatException('主机信任地址无效');
    }
    final canonical =
        InternetAddress.tryParse(host)?.address ?? host.toLowerCase();
    return jsonEncode([canonical, port]);
  }

  Map<String, dynamic> _decode(Map<String, dynamic> data) {
    if (data['schemaVersion'] is! int ||
        data['schemaVersion'] != 1 ||
        data['hosts'] is! Map<String, dynamic> ||
        data.keys.any((k) => !{'schemaVersion', 'hosts'}.contains(k))) {
      throw const FormatException('主机信任配置格式无效');
    }
    final hosts = data['hosts'] as Map<String, dynamic>;
    if (hosts.length > 1000) throw const FormatException('主机信任条目过多');
    for (final entry in hosts.entries) {
      final key = jsonDecode(entry.key);
      if (key is! List ||
          key.length != 2 ||
          key[0] is! String ||
          key[1] is! int ||
          _key(key[0] as String, key[1] as int) != entry.key) {
        throw const FormatException('主机信任地址无效');
      }
      final value = entry.value;
      if (value is! Map<String, dynamic> ||
          value.length != 2 ||
          value['keyType'] is! String ||
          value['fingerprint'] is! String) {
        throw const FormatException('主机信任条目无效');
      }
      _validatePin(value['keyType'] as String, value['fingerprint'] as String);
    }
    return Map<String, dynamic>.from(hosts);
  }

  void _validatePin(String keyType, String fingerprint) {
    if (!RegExp(r'^[a-zA-Z0-9@._+-]{1,128}$').hasMatch(keyType) ||
        !RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$').hasMatch(fingerprint)) {
      throw const FormatException('主机指纹格式无效');
    }
  }

  Future<Map<String, dynamic>> _load() async =>
      await _file.read(_decode, allowBackupRecovery: false) ??
      <String, dynamic>{};

  @override
  Future<String?> readFingerprint(String host, int port, String keyType) =>
      _file.locked(() async {
        final hosts = await _load();
        final entry = hosts[_key(host, port)] as Map<String, dynamic>?;
        if (entry == null) return null;
        if (entry['keyType'] != keyType) throw const HostKeyChangedException();
        return entry['fingerprint'] as String;
      });

  @override
  Future<void> trust(
    String host,
    int port,
    String keyType,
    String fingerprint,
  ) => _file.locked(() async {
    _validatePin(keyType, fingerprint);
    final hosts = await _load();
    final key = _key(host, port);
    final existing = hosts[key] as Map<String, dynamic>?;
    if (existing != null &&
        (existing['keyType'] != keyType ||
            existing['fingerprint'] != fingerprint)) {
      throw const HostKeyChangedException();
    }
    hosts[key] = {'keyType': keyType, 'fingerprint': fingerprint};
    await _file.write({'schemaVersion': 1, 'hosts': hosts}, (data) {
      _decode(data);
    });
  });
}
