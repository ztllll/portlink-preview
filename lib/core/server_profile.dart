import 'forward_rule.dart';

/// Connection metadata only. Passwords must never enter this model or JSON.
final class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.name,
    required this.host,
    this.sshPort = 22,
    required this.username,
    this.rules = const [ForwardRule.legacy()],
  });

  final String id;
  final String name;
  final String host;
  final int sshPort;
  final String username;
  final List<ForwardRule> rules;

  List<ForwardRule> get enabledRules =>
      rules.where((rule) => rule.enabled).toList(growable: false);

  ServerProfile copyWith({List<ForwardRule>? rules}) => ServerProfile(
    id: id,
    name: name,
    host: host,
    sshPort: sshPort,
    username: username,
    rules: rules ?? this.rules,
  );

  String? validate() {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) return '服务器标识无效';
    if (!_validText(name, 100)) return '名称应为 1–100 个字符，不能包含控制字符';
    if (!_validText(username, 128) || RegExp(r'\s').hasMatch(username)) {
      return 'SSH 用户名无效';
    }
    if (sshPort < 1 || sshPort > 65535) return 'SSH 端口须为 1–65535';
    final hostError = validateHostText(host);
    if (hostError != null) return hostError;
    return ForwardRule.validateAll(rules);
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
    'rules': rules.map((rule) => rule.toJson()).toList(),
  };

  /// Accepts the v1 shape (no `rules`) and upgrades it to the single legacy
  /// 127.0.0.1:3080 -> 3080 rule, so existing configurations keep working.
  factory ServerProfile.fromJson(Map<String, dynamic> json) {
    const keys = {'id', 'name', 'host', 'sshPort', 'username', 'rules'};
    if (json.keys.any((key) => !keys.contains(key)) ||
        json['id'] is! String ||
        json['name'] is! String ||
        json['host'] is! String ||
        json['username'] is! String ||
        json['sshPort'] is! int ||
        (json.containsKey('rules') && json['rules'] is! List)) {
      throw const FormatException('服务器配置格式无效');
    }
    final List<ForwardRule> rules;
    if (json.containsKey('rules')) {
      rules = (json['rules'] as List).map((value) {
        if (value is! Map<String, dynamic>) {
          throw const FormatException('转发规则格式无效');
        }
        return ForwardRule.fromJson(value);
      }).toList();
    } else {
      rules = const [ForwardRule.legacy()];
    }
    final profile = ServerProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      sshPort: json['sshPort'] as int,
      username: json['username'] as String,
      rules: rules,
    );
    final error = profile.validate();
    if (error != null) throw FormatException(error);
    return profile;
  }
}
