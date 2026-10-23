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
  });
  final TunnelPhase phase;
  final String? profileId;
  final String? message;
  final int retryAttempt;
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
}
