import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Coordinates the Android foreground session with the *same* Dart isolate
/// that owns the SSH engine. No second isolate or background plugin is used.
///
/// The controller must install a stop handler before [start], disconnect the
/// SSH engine before [stop], and stop this session after fatal connection errors.
/// Android start failures are intentional: a hidden notification or a background
/// start must never be reported as a protected forwarding session.
class AndroidSession {
  static const _channel = MethodChannel('dev.portlink/session');

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> Function()? _stopHandler;
  Future<void>? _initialization;
  Future<void>? _starting;
  Future<bool>? _handlingStop;
  bool _initialized = false;
  bool _disposed = false;
  int _generation = 0;

  Future<void> initialize() async {
    if (!_isAndroid) return;
    if (_disposed) throw StateError('Android 会话已关闭');
    if (_initialized) return;
    final existing = _initialization;
    if (existing != null) return existing;
    final operation = _initializeAndroid();
    _initialization = operation;
    try {
      await operation;
    } finally {
      _initialization = null;
    }
  }

  Future<void> _initializeAndroid() async {
    _channel.setMethodCallHandler(_handleNativeCall);
    try {
      await _channel.invokeMethod<void>('initialize');
      _initialized = true;
    } catch (_) {
      _channel.setMethodCallHandler(null);
      rethrow;
    }
  }

  void setStopHandler(Future<void> Function() handler) {
    if (_disposed) throw StateError('Android 会话已关闭');
    _stopHandler = handler;
  }

  /// Completes only after Android has successfully entered foreground-service
  /// state. Call before opening SSH sockets; do not suppress platform errors.
  Future<void> start() async {
    if (!_isAndroid) return;
    final generation = _generation;
    await initialize();
    _checkStartGeneration(generation);
    if (_stopHandler == null) {
      throw StateError('开始 Android 会话前必须设置断开连接处理器');
    }
    final existing = _starting;
    if (existing != null) {
      await existing;
      _checkStartGeneration(generation);
      return;
    }
    final operation = _channel.invokeMethod<void>('start');
    _starting = operation;
    try {
      await operation;
      _checkStartGeneration(generation);
    } finally {
      if (identical(_starting, operation)) _starting = null;
    }
  }

  void _checkStartGeneration(int generation) {
    if (_disposed || generation != _generation) {
      throw PlatformException(code: 'cancelled', message: '本次 Android 会话已取消');
    }
  }

  /// Releases the foreground service, not the SSH connection. The controller
  /// owns that connection and must close it first. Also cancels a pending start.
  Future<void> stop() async {
    if (!_isAndroid) return;
    ++_generation;
    _starting = null;
    if (!_initialized) return;
    await _channel.invokeMethod<void>('stop');
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method != 'stopRequested') {
      throw MissingPluginException('Unknown Android session method');
    }
    if (_disposed || _stopHandler == null) return false;
    final existing = _handlingStop;
    if (existing != null) return existing;
    final operation = _disconnectForNativeStop();
    _handlingStop = operation;
    try {
      return await operation;
    } finally {
      _handlingStop = null;
    }
  }

  Future<bool> _disconnectForNativeStop() async {
    try {
      await _stopHandler!();
      return true;
    } catch (_) {
      // The native watchdog destroys the tunnel-owning FlutterEngine when
      // disconnect cannot be confirmed. Never acknowledge a failed disconnect.
      return false;
    }
  }

  /// Call only after the controller has disposed/disconnected its SSH engine.
  Future<void> dispose() async {
    if (_disposed) return;
    // Close admission synchronously. Native stop can await a platform response;
    // no new start/handler may enter while that cleanup is still pending.
    _disposed = true;
    try {
      await stop();
    } finally {
      _stopHandler = null;
      if (_isAndroid) _channel.setMethodCallHandler(null);
    }
  }
}
