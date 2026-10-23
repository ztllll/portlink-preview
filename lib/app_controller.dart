import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'core/host_trust.dart';
import 'core/server_profile.dart';
import 'core/tunnel_engine.dart';
import 'core/tunnel_status.dart';
import 'data/profile_repository.dart';
import 'data/secret_store.dart';

/// Owns configuration transactions and the one permitted forwarding session.
/// UI and platform integrations observe this controller; neither owns sockets.
class AppController extends ChangeNotifier {
  AppController({
    required ProfileRepository repository,
    required SecretStore secrets,
    required TunnelEngine engine,
    Future<void> Function()? startSession,
    Future<void> Function()? stopSession,
    String Function()? newId,
  }) : _repository = repository,
       _secrets = secrets,
       _engine = engine,
       _startSession = startSession ?? _noop,
       _stopSession = stopSession ?? _noop,
       _newId = newId ?? const Uuid().v4 {
    _status = engine.status;
    _subscription = engine.statuses.listen(_onStatus);
  }

  static Future<void> _noop() async {}
  final ProfileRepository _repository;
  final SecretStore _secrets;
  final TunnelEngine _engine;
  final Future<void> Function() _startSession, _stopSession;
  final String Function() _newId;
  late final StreamSubscription<TunnelStatus> _subscription;
  List<ServerProfile> _profiles = const [];
  String? _defaultProfileId, _errorMessage, _platformWarning;
  late TunnelStatus _status;
  bool _initialized = false, _busy = false, _closed = false, _disposed = false;
  int _epoch = 0;
  HostTrustRequest? _pendingTrust;
  Completer<bool>? _trustAnswer;
  Future<void>? _initializing, _shuttingDown;
  Completer<void>? _durableMutation;

  bool get initialized => _initialized;
  bool get busy => _busy;
  List<ServerProfile> get profiles => _profiles;
  String? get defaultProfileId => _defaultProfileId;
  TunnelStatus get tunnelStatus => _status;
  String? get errorMessage => _errorMessage;
  String? get platformWarning => _platformWarning;
  void reportPlatformWarning(String message) {
    if (_closed) return;
    _platformWarning = message;
    _notify();
  }

  HostTrustRequest? get pendingTrust => _pendingTrust;
  ServerProfile? get activeProfile => _find(_status.profileId);

  ServerProfile? _find(String? id) {
    for (final p in _profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _onStatus(TunnelStatus status) {
    if (_closed) return;
    _status = status;
    if (status.phase != TunnelPhase.verifyingHost) _cancelTrust();
    if (status.phase == TunnelPhase.failed) {
      final epoch = _epoch;
      // Recheck before stopping: a queued failure must not stop a new session.
      unawaited(
        Future<void>(() async {
          if (!_closed &&
              epoch == _epoch &&
              _engine.status.phase == TunnelPhase.failed) {
            try {
              await _stopSession();
            } catch (_) {
              _errorMessage = '连接已停止，但系统会话清理失败，请退出应用重试。';
              _notify();
            }
          }
        }),
      );
    }
    _notify();
  }

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    if (_closed) return;
    _busy = true;
    _notify();
    try {
      final snapshot = await _repository.load();
      if (_closed) return;
      _profiles = List.unmodifiable(snapshot.profiles);
      _defaultProfileId = snapshot.defaultProfileId;
      _initialized = true;
      _busy = false;
      _notify();
      final id = _defaultProfileId;
      if (id != null) await connectProfile(id);
    } catch (_) {
      _errorMessage = '无法读取配置。为防止覆盖原数据，已禁止修改；请检查配置文件或恢复备份后重启。';
    } finally {
      _busy = false;
      _notify();
    }
  }

  void clearError() {
    _errorMessage = null;
    _notify();
  }

  Future<void> _mutate(
    Future<void> Function() operation, {
    bool durable = false,
  }) async {
    if (_busy || _closed) return;
    if (!_initialized) {
      _errorMessage = '配置尚未成功加载，不能修改。';
      _notify();
      return;
    }
    final drain = durable ? Completer<void>() : null;
    if (drain != null) _durableMutation = drain;
    _busy = true;
    _errorMessage = null;
    _notify();
    try {
      await operation();
    } on _UserError catch (e) {
      _errorMessage = e.message;
    } catch (_) {
      _errorMessage = '操作失败。请检查配置目录和系统安全凭据存储，密码不会回退为明文保存。';
    } finally {
      _busy = false;
      if (identical(_durableMutation, drain)) _durableMutation = null;
      drain?.complete();
      _notify();
    }
  }

  Future<void> saveProfile({
    String? id,
    required String name,
    required String host,
    required int sshPort,
    required String username,
    String? password,
    required bool makeDefault,
  }) => _mutate(() async {
    final existing = id == null ? null : _find(id);
    if (id != null && existing == null) throw const _UserError('服务器配置不存在。');
    if (existing == null && (password == null || password.isEmpty)) {
      throw const _UserError('新增服务器需要 SSH 密码。');
    }
    final profile = ServerProfile(
      id: id ?? _newId(),
      name: name.trim(),
      host: host.trim(),
      sshPort: sshPort,
      username: username.trim(),
    );
    final invalid = profile.validate();
    if (invalid != null) throw _UserError(invalid);
    final next = [..._profiles];
    final index = next.indexWhere((p) => p.id == profile.id);
    if (index < 0) {
      next.add(profile);
    } else {
      next[index] = profile;
    }
    var defaultId = _defaultProfileId;
    if (makeDefault || next.length == 1) defaultId = profile.id;
    if (!makeDefault && defaultId == profile.id && next.length > 1) {
      defaultId = next.firstWhere((p) => p.id != profile.id).id;
    }
    final snapshot = ProfileSnapshot(
      profiles: next,
      defaultProfileId: defaultId,
    );
    snapshot.toJson(); // Validate metadata before touching the OS secret store.
    final replacingPassword = password != null && password.isNotEmpty;
    final oldPassword = replacingPassword
        ? await _secrets.readPassword(profile.id)
        : null;
    if (replacingPassword) await _secrets.writePassword(profile.id, password);
    try {
      await _repository.save(snapshot);
    } catch (_) {
      if (replacingPassword) {
        try {
          if (oldPassword == null) {
            await _secrets.deletePassword(profile.id);
          } else {
            await _secrets.writePassword(profile.id, oldPassword);
          }
        } catch (_) {
          throw const _UserError('保存失败，旧凭据也未能恢复。请重新编辑并保存 SSH 密码。');
        }
      }
      rethrow;
    }
    if (_closed) return;
    _profiles = List.unmodifiable(next);
    _defaultProfileId = defaultId;
    _notify();
    if (_status.profileId == profile.id && _status.isActive) {
      await _connect(profile);
    }
  }, durable: true);

  Future<void> setDefault(String id) => _mutate(() async {
    if (_find(id) == null) throw const _UserError('服务器配置不存在。');
    await _repository.save(
      ProfileSnapshot(profiles: _profiles, defaultProfileId: id),
    );
    if (_closed) return;
    _defaultProfileId = id;
  }, durable: true);

  Future<void> deleteProfile(String id) => _mutate(() async {
    if (_find(id) == null) return;
    if (_status.profileId == id) await disconnect();
    final next = _profiles.where((p) => p.id != id).toList();
    final defaultId = _defaultProfileId == id
        ? (next.isEmpty ? null : next.first.id)
        : _defaultProfileId;
    await _repository.save(
      ProfileSnapshot(profiles: next, defaultProfileId: defaultId),
    );
    if (!_closed) {
      _profiles = List.unmodifiable(next);
      _defaultProfileId = defaultId;
      _notify();
    }
    try {
      await _secrets.deletePassword(id);
    } catch (_) {
      throw const _UserError('配置已删除，但系统凭据清理失败；安全存储中可能保留该项密码。');
    }
  }, durable: true);

  Future<void> connectProfile(String id) => _mutate(() async {
    final profile = _find(id);
    if (profile == null) throw const _UserError('服务器配置不存在。');
    await _connect(profile);
  });

  Future<void> _connect(ServerProfile profile) async {
    if (_closed) return;
    final epoch = ++_epoch;
    _cancelTrust();
    await _engine.disconnect();
    await _stopSession();
    if (_closed || epoch != _epoch) return;
    _status = TunnelStatus(
      phase: TunnelPhase.connecting,
      profileId: profile.id,
      message: '正在读取安全凭据并准备连接…',
    );
    _notify();
    String? password;
    try {
      password = await _secrets.readPassword(profile.id);
    } catch (_) {
      if (_closed || epoch != _epoch) return;
      _status = TunnelStatus(
        phase: TunnelPhase.failed,
        profileId: profile.id,
        message: '系统安全凭据存储暂不可用，请解锁后重试。',
      );
      throw const _UserError('系统安全凭据存储暂不可用，请解锁后重试。');
    }
    if (_closed || epoch != _epoch) return;
    if (password == null || password.isEmpty) {
      _status = TunnelStatus(
        phase: TunnelPhase.failed,
        profileId: profile.id,
        message: '无法读取 SSH 密码，请解锁系统凭据存储或编辑服务器重新保存密码。',
      );
      throw const _UserError('无法读取 SSH 密码，请解锁系统凭据存储或重新保存密码。');
    }
    try {
      await _startSession();
      if (_closed || epoch != _epoch) {
        await _stopSession();
        return;
      }
      await _engine.connect(
        profile,
        password,
        onTrustHost: (request) async {
          if (_closed || epoch != _epoch) return false;
          _cancelTrust();
          final answer = Completer<bool>();
          _trustAnswer = answer;
          _pendingTrust = request;
          _notify();
          final accepted = await answer.future;
          if (identical(_trustAnswer, answer)) {
            _trustAnswer = null;
            _pendingTrust = null;
            _notify();
          }
          return accepted && !_closed && epoch == _epoch;
        },
      );
      if (_closed || epoch != _epoch) return;
      _status = _engine.status;
      if (!_status.isActive) await _stopSession();
    } catch (_) {
      if (_closed || epoch != _epoch) return;
      await _engine.disconnect();
      await _stopSession();
      _status = TunnelStatus(
        phase: TunnelPhase.failed,
        profileId: profile.id,
        message: '无法启动连接，请检查系统通知权限、凭据存储与网络。',
      );
      rethrow;
    }
  }

  void answerHostTrust(bool accept) {
    final answer = _trustAnswer;
    _trustAnswer = null;
    _pendingTrust = null;
    if (answer != null && !answer.isCompleted) answer.complete(accept);
    _notify();
  }

  void _cancelTrust() {
    final answer = _trustAnswer;
    _trustAnswer = null;
    _pendingTrust = null;
    if (answer != null && !answer.isCompleted) answer.complete(false);
  }

  /// Cancellation deliberately bypasses busy, including during host-key prompts.
  Future<void> disconnect() async {
    ++_epoch;
    _cancelTrust();
    try {
      await _engine.disconnect();
      await _stopSession();
      _status = _engine.status;
    } catch (_) {
      _errorMessage = '停止连接失败，请退出应用以释放连接。';
      _notify();
      rethrow; // Native foreground-service stop must not acknowledge failure.
    }
    _notify();
  }

  Future<void> shutdown() => _shuttingDown ??= _shutdown();
  Future<void> _shutdown() async {
    if (_closed) return;
    _closed = true;
    ++_epoch;
    _cancelTrust();
    final pendingWrite = _durableMutation?.future;
    await _subscription.cancel();
    try {
      await _engine.dispose();
    } finally {
      try {
        await _stopSession();
      } finally {
        // Do not terminate between a keychain write and metadata commit/rollback.
        // Connect-only operations are cancelled above and never block this drain.
        await pendingWrite;
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(shutdown().catchError((Object _) {}));
    super.dispose();
  }
}

final class _UserError implements Exception {
  const _UserError(this.message);
  final String message;
}
