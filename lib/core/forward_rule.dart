import 'dart:io';

/// Validates a DNS name or IP literal (no scheme, path, port, or whitespace).
String? validateHostText(String host) {
  if (host.isEmpty ||
      host.length > 253 ||
      host != host.trim() ||
      RegExp(r'[\s/@\\?#\[\]]').hasMatch(host)) {
    return '请输入主机名或 IP 地址，不含协议和路径';
  }
  if (InternetAddress.tryParse(host) == null &&
      (!RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$').hasMatch(host) ||
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

/// One local->remote TCP forward over a server's single SSH session.
///
/// [bindHost] is where PortLink listens on this computer (default loopback).
/// [targetHost]:[remotePort] is where the *server* connects to; the default
/// 127.0.0.1 means the server itself, any other value is resolved by the server.
final class ForwardRule {
  const ForwardRule({
    required this.id,
    required this.label,
    required this.localPort,
    required this.remotePort,
    this.bindHost = loopback,
    this.targetHost = loopback,
    this.enabled = true,
  });

  /// The rule every profile had before multi-port support: 3080 -> 3080.
  const ForwardRule.legacy()
    : id = 'default',
      label = '默认',
      localPort = 3080,
      remotePort = 3080,
      bindHost = loopback,
      targetHost = loopback,
      enabled = true;

  static const loopback = '127.0.0.1';
  static const minLocalPort = 1024;
  static const maxRules = 32;

  final String id;
  final String label;
  final int localPort;
  final int remotePort;
  final String bindHost;
  final String targetHost;
  final bool enabled;

  /// True when other devices on the network could reach the local listener.
  bool get exposesToNetwork => !isLoopbackBind(bindHost);

  static bool isLoopbackBind(String host) {
    final address = InternetAddress.tryParse(host);
    return address != null && address.isLoopback;
  }

  String get localAddress => '$bindHost:$localPort';
  String get remoteAddress => '$targetHost:$remotePort';

  ForwardRule copyWith({
    String? label,
    int? localPort,
    int? remotePort,
    String? bindHost,
    String? targetHost,
    bool? enabled,
  }) => ForwardRule(
    id: id,
    label: label ?? this.label,
    localPort: localPort ?? this.localPort,
    remotePort: remotePort ?? this.remotePort,
    bindHost: bindHost ?? this.bindHost,
    targetHost: targetHost ?? this.targetHost,
    enabled: enabled ?? this.enabled,
  );

  String? validate() {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id)) return '转发规则标识无效';
    if (label.isEmpty ||
        label.length > 40 ||
        label != label.trim() ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(label)) {
      return '规则名称应为 1–40 个字符，不能包含控制字符';
    }
    if (localPort < minLocalPort || localPort > 65535) {
      return '本地端口须为 $minLocalPort–65535（低于 $minLocalPort 的端口需要管理员权限）';
    }
    if (remotePort < 1 || remotePort > 65535) return '远端端口须为 1–65535';
    // Listen address must be a literal IPv4 address; hostnames would make the
    // exposure of the listener depend on DNS.
    final bind = InternetAddress.tryParse(bindHost);
    if (bind == null || bind.type != InternetAddressType.IPv4) {
      return '本地监听地址须为 IPv4 地址，例如 127.0.0.1 或 0.0.0.0';
    }
    final target = validateHostText(targetHost);
    if (target != null) return '远端目标地址：$target';
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'localPort': localPort,
    'remotePort': remotePort,
    'bindHost': bindHost,
    'targetHost': targetHost,
    'enabled': enabled,
  };

  factory ForwardRule.fromJson(Map<String, dynamic> json) {
    const keys = {
      'id',
      'label',
      'localPort',
      'remotePort',
      'bindHost',
      'targetHost',
      'enabled',
    };
    if (json.keys.any((key) => !keys.contains(key)) ||
        json['id'] is! String ||
        json['label'] is! String ||
        json['localPort'] is! int ||
        json['remotePort'] is! int ||
        json['bindHost'] is! String ||
        json['targetHost'] is! String ||
        json['enabled'] is! bool) {
      throw const FormatException('转发规则格式无效');
    }
    final rule = ForwardRule(
      id: json['id'] as String,
      label: json['label'] as String,
      localPort: json['localPort'] as int,
      remotePort: json['remotePort'] as int,
      bindHost: json['bindHost'] as String,
      targetHost: json['targetHost'] as String,
      enabled: json['enabled'] as bool,
    );
    final error = rule.validate();
    if (error != null) throw FormatException(error);
    return rule;
  }

  /// 0.0.0.0 overlaps every address on the same port.
  static bool _overlaps(String a, String b) =>
      a == b || a == '0.0.0.0' || b == '0.0.0.0';

  /// Validates a rule set: bounded size, unique ids, no two *enabled* rules
  /// that would bind overlapping addresses on the same port, and at least one
  /// enabled rule.
  static String? validateAll(List<ForwardRule> rules) {
    if (rules.isEmpty) return '至少需要一条转发规则';
    if (rules.length > maxRules) return '每台服务器最多 $maxRules 条转发规则';
    final ids = <String>{};
    final enabled = <ForwardRule>[];
    for (final rule in rules) {
      final error = rule.validate();
      if (error != null) return error;
      if (!ids.add(rule.id)) return '转发规则标识重复';
      if (rule.enabled) {
        for (final other in enabled) {
          if (other.localPort == rule.localPort &&
              _overlaps(other.bindHost, rule.bindHost)) {
            return '本地端口 ${rule.localPort} 被“${other.label}”和“${rule.label}”重复使用';
          }
        }
        enabled.add(rule);
      }
    }
    if (enabled.isEmpty) return '至少需要启用一条转发规则';
    return null;
  }
}

/// Per-rule outcome of the most recent listener bind / target probe.
enum RuleState { starting, ready, targetUnavailable, bindFailed }

final class RuleStatus {
  const RuleStatus({required this.rule, required this.state, this.message});
  final ForwardRule rule;
  final RuleState state;
  final String? message;
  bool get listening =>
      state == RuleState.ready || state == RuleState.targetUnavailable;
}
