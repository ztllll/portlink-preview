import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';

import '../data/host_trust_store.dart';
import 'host_trust.dart';
import 'server_profile.dart';
import 'ssh_transport.dart';
import 'tunnel_status.dart';

abstract interface class TunnelEngine {
  Stream<TunnelStatus> get statuses;
  TunnelStatus get status;
  Future<void> connect(
    ServerProfile profile,
    String password, {
    required HostTrustPrompt onTrustHost,
  });
  Future<void> disconnect();
  Future<void> dispose();
}

final class TunnelTiming {
  const TunnelTiming({
    this.connectTimeout = const Duration(seconds: 12),
    this.handshakeTimeout = const Duration(seconds: 20),
    this.authTimeout = const Duration(seconds: 15),
    this.trustTimeout = const Duration(seconds: 90),
    this.probeTimeout = const Duration(seconds: 5),
    this.pingTimeout = const Duration(seconds: 8),
    this.healthInterval = const Duration(seconds: 15),
    this.operationTimeout = const Duration(seconds: 30),
    this.closeTimeout = const Duration(seconds: 2),
    this.retryBase = const Duration(seconds: 1),
    this.retryMax = const Duration(seconds: 30),
    this.maxRetries,
  });
  final Duration connectTimeout, handshakeTimeout, authTimeout, trustTimeout;
  final Duration probeTimeout,
      pingTimeout,
      healthInterval,
      operationTimeout,
      closeTimeout;
  final Duration retryBase, retryMax;

  /// Null keeps retrying transient network failures until explicitly stopped.
  final int? maxRetries;
}

/// One generation owns one listener, session, health/retry timer and its relays.
/// No password is exposed in status, JSON, exception text or logs.
final class SshTunnelEngine implements TunnelEngine {
  SshTunnelEngine({
    required this._trustStore,
    this._connector = const DartSshConnector(),
    this._timing = const TunnelTiming(),
    double Function()? jitter,
  }) : _listenPort = localPort,
       _jitter = jitter ?? Random.secure().nextDouble;

  /// Test harness only: production construction always binds fixed port 3080.
  /// This changes only the local listener; the SSH target remains port 3080.
  SshTunnelEngine.forTesting({
    required this._trustStore,
    required int listenPort,
    this._connector = const DartSshConnector(),
    this._timing = const TunnelTiming(),
    double Function()? jitter,
  }) : assert(listenPort > 0 && listenPort <= 65535),
       _listenPort = listenPort,
       _jitter = jitter ?? Random.secure().nextDouble;

  static const localPort = 3080;
  static const targetHost = '127.0.0.1';
  final HostTrustStore _trustStore;
  final int _listenPort;
  final SshConnector _connector;
  final TunnelTiming _timing;
  final double Function() _jitter;
  final _statuses = StreamController<TunnelStatus>.broadcast();
  TunnelStatus _status = const TunnelStatus(phase: TunnelPhase.idle);
  _Run? _run;
  bool _disposed = false;
  int _generation = 0;
  Future<void> _cleanupBarrier = Future<void>.value();

  @override
  Stream<TunnelStatus> get statuses => _statuses.stream;
  @override
  TunnelStatus get status => _status;
  bool _current(_Run run) =>
      !_disposed &&
      identical(_run, run) &&
      run.generation == _generation &&
      !run.cancelled.isCompleted;

  void _emit(_Run run, TunnelPhase phase, String message) {
    if (!_current(run)) return;
    _status = TunnelStatus(
      phase: phase,
      profileId: run.profile.id,
      message: message,
      retryAttempt: run.attempt,
    );
    _statuses.add(_status);
  }

  @override
  Future<void> connect(
    ServerProfile profile,
    String password, {
    required HostTrustPrompt onTrustHost,
  }) async {
    if (_disposed) throw StateError('连接引擎已关闭');
    final error = profile.validate();
    if (error != null) throw ArgumentError(error);
    if (password.isEmpty) throw ArgumentError('SSH 密码不能为空');
    final old = _run;
    final run = _Run(++_generation, profile, password, onTrustHost);
    _run = run;
    if (old != null) {
      old.cancel();
      await _closeResources(old);
    }
    if (!_current(run)) return;
    _emit(run, TunnelPhase.connecting, '正在连接 SSH…');
    await _attempt(run);
    // Initial failure schedules a timer; callers never await the retry loop.
  }

  Future<T> _bounded<T>(
    _Run run,
    Future<T> operation,
    Duration timeout, {
    void Function(T value)? discard,
    int? attemptToken,
  }) async {
    final result = Completer<T>();
    final subscription = run.cancellations.stream.listen((_) {
      if (!result.isCompleted) result.completeError(const _Cancelled());
    });
    final timer = Timer(timeout, () {
      if (!result.isCompleted) result.completeError(TimeoutException('操作超时'));
    });
    operation.then(
      (value) {
        if (result.isCompleted ||
            !_current(run) ||
            (attemptToken != null && run.attemptToken != attemptToken)) {
          try {
            discard?.call(value);
          } on Object {
            /* cleanup must not escape */
          }
          if (!result.isCompleted) result.completeError(const _Cancelled());
        } else {
          result.complete(value);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    if (!_current(run) && !result.isCompleted) {
      result.completeError(const _Cancelled());
    }
    try {
      return await result.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }

  Future<bool> _verify(
    _Run run,
    int attemptToken,
    _HostVerification verification,
    String type,
    String fingerprint,
  ) async {
    if (!verification.received.isCompleted) verification.received.complete();
    bool valid() => _current(run) && run.attemptToken == attemptToken;
    try {
      if (!valid()) throw const _Cancelled();
      final stored = await _bounded(
        run,
        _trustStore.readFingerprint(
          run.profile.host,
          run.profile.sshPort,
          type,
        ),
        _timing.operationTimeout,
      );
      if (!valid()) throw const _Cancelled();
      if (stored != null) {
        if (stored != fingerprint) throw const HostKeyChangedException();
        verification.accepted = true;
        return true;
      }
      _emit(run, TunnelPhase.verifyingHost, '请通过可信渠道核验主机指纹');
      final accepted = await _bounded(
        run,
        run.prompt(
          HostTrustRequest(
            host: run.profile.host,
            port: run.profile.sshPort,
            keyType: type,
            fingerprint: fingerprint,
          ),
        ),
        _timing.trustTimeout,
      );
      if (!valid()) throw const _Cancelled();
      if (!accepted) throw const HostTrustRejectedException();
      await _bounded(
        run,
        _trustStore.trust(
          run.profile.host,
          run.profile.sshPort,
          type,
          fingerprint,
        ),
        _timing.operationTimeout,
      );
      if (!valid()) throw const _Cancelled();
      verification.accepted = true;
      _emit(run, TunnelPhase.connecting, '主机已核验，正在认证…');
      return true;
    } on Object catch (error) {
      if (valid()) run.trustError = error;
      return false;
    } finally {
      if (!verification.checked.isCompleted) verification.checked.complete();
    }
  }

  Future<void> _attempt(_Run run) async {
    final attemptToken = ++run.attemptToken;
    final verification = _HostVerification();
    try {
      run.trustError = null;
      run.sessionError = null;
      final session = await _bounded<SshSession>(
        run,
        _connector.connect(
          run.profile,
          run.password!,
          verifyHost: (type, fingerprint) =>
              _verify(run, attemptToken, verification, type, fingerprint),
          connectTimeout: _timing.connectTimeout,
          handshakeTimeout: _timing.handshakeTimeout + _timing.trustTimeout,
          authTimeout: _timing.authTimeout,
        ),
        _timing.connectTimeout,
        discard: (late) {
          unawaited(_quietClose(late));
        },
        attemptToken: attemptToken,
      );
      if (!_current(run) || run.attemptToken != attemptToken) {
        await _quietClose(session);
        return;
      }
      run.session = session;
      // Attach error handlers immediately, even while authentication is pending.
      unawaited(
        session.done.then(
          (_) => _sessionEnded(run, session),
          onError: (Object error, StackTrace stack) =>
              _sessionEnded(run, session, error),
        ),
      );
      final authenticated = session.authenticated;
      // Observe authentication errors now, even if the host-verification stage
      // is still waiting. A silent TCP peer gets the real handshake deadline,
      // not the (longer) human trust-dialog budget.
      unawaited(
        authenticated.then((_) {}, onError: (Object _, StackTrace _) {}),
      );
      await _bounded(
        run,
        Future.any<void>([authenticated, verification.received.future]),
        _timing.handshakeTimeout,
        attemptToken: attemptToken,
      );
      if (verification.received.isCompleted) {
        await _bounded(
          run,
          verification.checked.future,
          _timing.trustTimeout + _timing.operationTimeout * 2,
          attemptToken: attemptToken,
        );
      }
      if (run.trustError != null) throw run.trustError!;
      await _bounded(
        run,
        authenticated,
        _timing.handshakeTimeout + _timing.authTimeout,
        attemptToken: attemptToken,
      );
      if (run.trustError != null) throw run.trustError!;
      if (!verification.accepted) throw const HostTrustRejectedException();
      if (run.sessionError != null) throw run.sessionError!;
      // ServerSocket.bind is real and exclusive, not an optimistic status flag.
      ServerSocket listener;
      try {
        listener = await _bounded(
          run,
          ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            _listenPort,
            shared: false,
          ),
          _timing.connectTimeout,
          discard: (late) {
            unawaited(late.close());
          },
          attemptToken: attemptToken,
        );
      } on SocketException {
        throw const _BindFailure();
      }
      if (!_current(run) || run.attemptToken != attemptToken) {
        await listener.close();
        return;
      }
      run.listener = listener;
      run.subscription = listener.listen(
        (socket) => _accept(run, session, socket),
        onError: (Object error) {
          unawaited(_fail(run, const _BindFailure()));
        },
      );
      final reachable = await _probe(run, session, attemptToken);
      if (!_current(run) || !identical(run.session, session)) return;
      if (run.sessionError != null) throw run.sessionError!;
      run.established = true;
      run.attempt = 0;
      _emitTarget(run, reachable);
      _scheduleHealth(run, session);
    } on Object catch (error) {
      if (!_current(run)) return;
      // The library wraps host/auth errors; preserve our safe trust classification.
      await _fail(run, run.trustError ?? error);
    }
  }

  void _discardChannel(ForwardConnection channel) {
    unawaited(channel.done.then((_) {}, onError: (Object _, StackTrace _) {}));
    channel.destroy();
  }

  Future<bool> _probe(_Run run, SshSession session, [int? token]) async {
    final attemptToken = token ?? run.attemptToken;
    try {
      final channel = await _bounded(
        run,
        session.open(targetHost, localPort),
        _timing.probeTimeout,
        discard: _discardChannel,
        attemptToken: attemptToken,
      );
      // Opening direct-tcpip is the probe: no protocol-specific application bytes.
      channel.done.then((_) {}, onError: (Object _, StackTrace _) {});
      channel.destroy();
      return true;
    } on _Cancelled {
      rethrow;
    } on Object {
      return false;
    }
  }

  void _emitTarget(_Run run, bool reachable) => _emit(
    run,
    reachable ? TunnelPhase.ready : TunnelPhase.targetUnavailable,
    reachable ? '已连接 · 127.0.0.1:3080' : 'SSH 已连接，远端 127.0.0.1:3080 暂不可用',
  );

  void _scheduleHealth(_Run run, SshSession session) {
    if (!_current(run)) return;
    run.timer?.cancel();
    final attemptToken = run.attemptToken;
    run.timer = Timer(_timing.healthInterval, () async {
      run.timer = null;
      try {
        await _bounded(
          run,
          session.ping(),
          _timing.pingTimeout,
          attemptToken: attemptToken,
        );
        if (!_current(run) || !identical(run.session, session)) return;
        final reachable = await _probe(run, session, attemptToken);
        if (!_current(run) || !identical(run.session, session)) return;
        _emitTarget(run, reachable);
        _scheduleHealth(run, session);
      } on Object catch (error) {
        if (_current(run) && identical(run.session, session)) {
          await _fail(run, error);
        }
      }
    });
  }

  Future<void> _sessionEnded(
    _Run run,
    SshSession session, [
    Object? error,
  ]) async {
    if (!_current(run) || !identical(run.session, session)) return;
    run.sessionError = error ?? const _NetworkClosed();
    if (run.established) await _fail(run, run.sessionError!);
  }

  void _accept(_Run run, SshSession session, Socket socket) {
    if (!_current(run) ||
        !identical(run.session, session) ||
        run.sockets.length >= 128) {
      socket.destroy();
      return;
    }
    run.sockets.add(socket);
    // Each accepted stream opens its own SSH channel; no serial accept loop.
    unawaited(_relay(run, session, socket));
  }

  Future<void> _relay(_Run run, SshSession session, Socket socket) async {
    ForwardConnection? channel;
    final attemptToken = run.attemptToken;
    try {
      final remote = await _bounded<ForwardConnection>(
        run,
        session.open(targetHost, localPort),
        _timing.probeTimeout,
        discard: _discardChannel,
        attemptToken: attemptToken,
      );
      channel = remote;
      if (!identical(run.session, session)) return;
      run.channels.add(remote);
      remote.done.then((_) {}, onError: (Object _, StackTrace _) {});
      // addStream propagates consumer pause/resume. EOF closes only that write
      // half; the opposite direction continues until its own EOF. Native SSH
      // flow-control windows and paused streams bound buffers.
      Future<void> upload() async {
        await for (final bytes in socket) {
          await _bounded(
            run,
            remote.sink.addStream(Stream.value(bytes)),
            _timing.operationTimeout,
            attemptToken: attemptToken,
          );
          await _bounded(
            run,
            remote.flush(),
            _timing.operationTimeout,
            attemptToken: attemptToken,
          );
        }
        await _bounded(
          run,
          remote.sink.close(),
          _timing.operationTimeout,
          attemptToken: attemptToken,
        );
      }

      Future<void> download() async {
        await for (final bytes in remote.stream) {
          socket.add(bytes);
          await _bounded(
            run,
            socket.flush(),
            _timing.operationTimeout,
            attemptToken: attemptToken,
          );
        }
        await _bounded(
          run,
          socket.close(),
          _timing.operationTimeout,
          attemptToken: attemptToken,
        );
      }

      await Future.wait([upload(), download()], eagerError: true);
    } on Object {
      // Channel refusal/timeout affects this socket, not an otherwise live SSH
      // session. Health probing classifies target availability independently.
    } finally {
      socket.destroy();
      run.sockets.remove(socket);
      if (channel != null) {
        run.channels.remove(channel);
        channel.destroy();
      }
    }
  }

  bool _transient(Object error) {
    if (error is HostKeyChangedException ||
        error is HostTrustRejectedException ||
        error is _BindFailure ||
        error is SSHHostkeyError ||
        error is SSHAuthFailError ||
        error is FormatException ||
        error is FileSystemException) {
      return false;
    }
    if (error is SSHHandshakeError) {
      return error.message == 'Handshake timed out';
    }
    if (error is SSHAuthAbortError) {
      if (error.reason != null) return _transient(error.reason!);
      // These are library-defined messages, never remote descriptions. Password
      // rejection uses SSHAuthFailError and must not enter this retry path.
      return error.message == 'Authentication timed out' ||
          error.message == 'Connection closed before authentication';
    }
    if (error is SSHSocketError) return _transient(error.error);
    return error is SocketException ||
        error is TimeoutException ||
        error is _NetworkClosed;
  }

  Future<void> _fail(_Run run, Object error) async {
    if (!_current(run) || run.recovering) return;
    run.recovering = true;
    ++run.attemptToken; // Retire host callbacks belonging to the failed SSH attempt.
    await _closeResources(run);
    if (!_current(run)) return;
    final retry =
        _transient(error) &&
        run.trustError == null &&
        (_timing.maxRetries == null || run.attempt < _timing.maxRetries!);
    if (!retry) {
      run.password = null;
      final message = switch (error) {
        HostKeyChangedException() => const HostKeyChangedException().toString(),
        HostTrustRejectedException() =>
          const HostTrustRejectedException().toString(),
        _BindFailure() => '本机 127.0.0.1:3080 已被占用或无法监听，请关闭占用程序后重试',
        SSHAuthFailError() || SSHAuthAbortError() => 'SSH 认证失败，请检查用户名和密码',
        FormatException() || FileSystemException() => '安全配置无法读取或保存，连接已阻止',
        _ => '连接失败或重试次数已达上限，请检查网络和 SSH 配置后重试',
      };
      _emit(run, TunnelPhase.failed, message);
      return;
    }
    run.attempt++;
    final base =
        _timing.retryBase.inMilliseconds * pow(2, min(run.attempt - 1, 20));
    final millis = min(
      _timing.retryMax.inMilliseconds,
      (base * (0.8 + 0.4 * _jitter().clamp(0, 1))).round(),
    );
    _emit(run, TunnelPhase.reconnecting, '连接中断，正在等待重连…');
    run.timer = Timer(Duration(milliseconds: millis), () async {
      run.timer = null;
      if (!_current(run)) return;
      run.recovering = false;
      await _attempt(run);
    });
  }

  Future<void> _quietClose(SshSession session) async {
    // A connector can finish after cancellation, before _attempt attached its
    // regular handlers. Observe terminal auth/transport errors before closing.
    unawaited(
      session.authenticated.then((_) {}, onError: (Object _, StackTrace _) {}),
    );
    unawaited(session.done.then((_) {}, onError: (Object _, StackTrace _) {}));
    try {
      await session.close().timeout(_timing.closeTimeout);
    } on Object {
      /* bounded cleanup */
    }
  }

  Future<void> _closeResources(_Run run) {
    // Switching/disconnecting must await a cleanup already started by health
    // failure, rather than racing a still-closing previous listener.
    final closing = run.closing;
    if (closing != null) return closing;
    final resources = _closeResourcesNow(run);
    final operation = Future.wait<void>([_cleanupBarrier, resources])
        .then<void>((_) {});
    _cleanupBarrier = operation;
    run.closing = operation;
    operation.then((_) {
      if (identical(run.closing, operation)) run.closing = null;
    });
    return operation;
  }

  Future<void> _closeResourcesNow(_Run run) async {
    run.timer?.cancel();
    run.timer = null;
    run.established = false;
    final listener = run.listener;
    run.listener = null;
    final subscription = run.subscription;
    run.subscription = null;
    final session = run.session;
    run.session = null;
    for (final socket in run.sockets.toList()) {
      socket.destroy();
    }
    run.sockets.clear();
    for (final channel in run.channels.toList()) {
      channel.destroy();
    }
    run.channels.clear();
    Future<void> cleanup(Future<dynamic> operation) async {
      try {
        await operation.timeout(_timing.closeTimeout);
      } on Object {
        /* best effort */
      }
    }

    await Future.wait([
      if (listener != null) cleanup(listener.close()),
      if (subscription != null) cleanup(subscription.cancel()),
      if (session != null) _quietClose(session),
    ]);
  }

  @override
  Future<void> disconnect() async {
    ++_generation;
    final run = _run;
    _run = null;
    if (run != null) {
      run.cancel();
      await _closeResources(run);
    }
    if (!_disposed && _run == null) {
      _status = const TunnelStatus(phase: TunnelPhase.idle);
      _statuses.add(_status);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await disconnect();
    await _statuses.close();
  }
}

final class _Run {
  _Run(this.generation, this.profile, this.password, this.prompt);
  final int generation;
  final ServerProfile profile;
  String? password;
  final HostTrustPrompt prompt;
  final cancelled = Completer<void>();
  final cancellations = StreamController<void>.broadcast(sync: true);
  SshSession? session;
  Future<void>? closing;
  ServerSocket? listener;
  StreamSubscription<Socket>? subscription;
  Timer? timer;
  final sockets = <Socket>{};
  final channels = <ForwardConnection>{};
  Object? trustError, sessionError;
  bool established = false, recovering = false;
  int attempt = 0, attemptToken = 0;
  void cancel() {
    password = null;
    if (!cancelled.isCompleted) {
      cancelled.complete();
      cancellations.add(null);
      unawaited(cancellations.close());
    }
  }
}

final class _HostVerification {
  bool accepted = false;
  final received = Completer<void>();
  final checked = Completer<void>();
}

final class _Cancelled implements Exception {
  const _Cancelled();
}

final class _BindFailure implements Exception {
  const _BindFailure();
}

final class _NetworkClosed implements Exception {
  const _NetworkClosed();
}
