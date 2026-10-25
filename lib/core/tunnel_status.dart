import 'forward_rule.dart';

enum TunnelPhase {
  idle,
  connecting,
  verifyingHost,
  ready,
  reconnecting,
  targetUnavailable,
  failed,
}

final class TunnelStatus {
  const TunnelStatus({
    required this.phase,
    this.profileId,
    this.message,
    this.retryAttempt = 0,
    this.rules = const [],
  });
  final TunnelPhase phase;
  final String? profileId;
  final String? message;
  final int retryAttempt;

  /// Per-rule listener/probe outcome; empty until the SSH session is up.
  final List<RuleStatus> rules;

  bool get isActive => switch (phase) {
    TunnelPhase.connecting ||
    TunnelPhase.verifyingHost ||
    TunnelPhase.ready ||
    TunnelPhase.reconnecting ||
    TunnelPhase.targetUnavailable => true,
    _ => false,
  };
  bool get isConnected =>
      phase == TunnelPhase.ready || phase == TunnelPhase.targetUnavailable;

  int get readyRuleCount =>
      rules.where((r) => r.state == RuleState.ready).length;
  int get problemRuleCount => rules
      .where(
        (r) =>
            r.state == RuleState.bindFailed ||
            r.state == RuleState.targetUnavailable,
      )
      .length;

  /// Connected, but at least one rule is not fully usable.
  bool get isPartial =>
      isConnected &&
      rules.isNotEmpty &&
      problemRuleCount > 0 &&
      readyRuleCount > 0;
}
