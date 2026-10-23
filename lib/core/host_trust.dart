final class HostTrustRequest {
  const HostTrustRequest({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
  });
  final String host;
  final int port;
  final String keyType;
  final String fingerprint;
}

typedef HostTrustPrompt = Future<bool> Function(HostTrustRequest request);

final class HostKeyChangedException implements Exception {
  const HostKeyChangedException();
  @override
  String toString() => '主机密钥或算法已变化，连接已阻止。请通过可信渠道核验。';
}

final class HostTrustRejectedException implements Exception {
  const HostTrustRejectedException();
  @override
  String toString() => '未信任该主机，连接已取消';
}
