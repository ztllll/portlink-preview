import 'dart:io';

/// Connection metadata only. Passwords must never enter this model or JSON.
final class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.name,
    required this.host,
    this.sshPort = 22,
    required this.username,
  });

  final String id;
  final String name;
  final String host;
  final int sshPort;
  final String username;

  String? validate() {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) return '服务器标识无效';
    if (!_validText(name, 100)) return '名称应为 1–100 个字符，不能包含控制字符';
    if (!_validText(username, 128) || RegExp(r'\s').hasMatch(username)) {
      return 'SSH 用户名无效';
    }
    if (sshPort < 1 || sshPort > 65535) return 'SSH 端口须为 1–65535';
    if (host.isEmpty ||
        host.length > 253 ||
        host != host.trim() ||
        RegExp(r'[\s/@\\?#\[\]]').hasMatch(host)) {
      return '请输入主机名或 IP 地址，不含协议和路径';
    }
    if (InternetAddress.tryParse(host) == null &&
        (!RegExp(
              r'^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$',
            ).hasMatch(host) ||
            host
                .split('.')
                .any(
                  (part) =>
                      part.isEmpty ||
                      part.length > 63 ||
                      part.startsWith('-') ||
                      part.endsWith('-'),
                ))) {
      return '主机名或 IP 地址无效';
    }
    return null;
  }

  static bool _validText(String value, int max) =>
      value.isNotEmpty &&
      value.length <= max &&
      value == value.trim() &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'sshPort': sshPort,
    'username': username,
  };

  factory ServerProfile.fromJson(Map<String, dynamic> json) {
    const keys = {'id', 'name', 'host', 'sshPort', 'username'};
    if (json.keys.any((key) => !keys.contains(key)) ||
        json['id'] is! String ||
        json['name'] is! String ||
        json['host'] is! String ||
        json['username'] is! String ||
        json['sshPort'] is! int) {
      throw const FormatException('服务器配置格式无效');
    }
    final profile = ServerProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      sshPort: json['sshPort'] as int,
      username: json['username'] as String,
    );
    final error = profile.validate();
    if (error != null) throw FormatException(error);
    return profile;
  }
}
