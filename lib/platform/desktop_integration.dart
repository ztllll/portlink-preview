// Compatibility facade pinned by pubspec.lock.
// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:tray_manager/legacy.dart' as tray;
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../app_controller.dart';
import '../core/tunnel_status.dart';

/// Desktop shell only. SSH ownership remains in AppController.
class DesktopIntegration with WindowListener, tray.TrayListener {
  DesktopIntegration(
    this.controller, {
    tray.TrayManager? trayManager,
    WindowManager? windows,
    Future<void> Function()? onShutdown,
  }) : _tray = trayManager ?? tray.trayManager,
       _window = windows ?? windowManager,
       _onShutdown = onShutdown ?? controller.shutdown;
  final AppController controller;
  final tray.TrayManager _tray;
  final WindowManager _window;
  final Future<void> Function() _onShutdown;
  AppLifecycleListener? _lifecycle;
  Future<void>? _shutdown;
  Future<void>? _quitOperation;
  Future<void>? _updateOperation;
  bool _enabled = false, _quitting = false, _updating = false, _dirty = false;
  String? _lastIcon;
  String? warning;
  Object? _lastTrust;
  String? _lastError;
  TunnelPhase? _lastPhase;

  static bool get isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  Future<void> initialize() async {
    if (!isDesktop) return;
    await _window.ensureInitialized();
    await _window.setTitle('端口连 PortLink');
    await _window.setMinimumSize(const Size(430, 540));
    await _window.setSize(const Size(960, 680));
    await _window.center();
    _window.addListener(this);
    _tray.addListener(this);
    await _window.setPreventClose(true);
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await prepareForExit();
        return AppExitResponse.exit;
      },
    );
    try {
      await _setTrayIcon('idle');
      _lastIcon = 'idle';
      await _window.setPreventClose(true);
      _enabled = true;
      controller.addListener(_changed);
      await _update();
    } catch (_) {
      _enabled = false;
      controller.removeListener(_changed);
      warning = '状态栏图标初始化失败，窗口将保持可见；关闭窗口会停止转发。';
      controller.reportPlatformWarning(warning!);
      await _window.setPreventClose(true);
    }
    await _window.show();
    await _window.focus();
  }

  Future<void> _setTrayIcon(String state) => _tray.setIcon(
    Platform.isWindows
        ? 'assets/tray/windows_$state.ico'
        : Platform.isMacOS
        // The native asset loader reads the exact file, not Flutter's variants.
        // Supply 44px artwork explicitly, then display it at 22 logical points.
        ? 'assets/tray/$state@2x.png'
        : 'assets/tray/$state.png',
    // A macOS template image discards our required red/green status colours.
    isTemplate: false,
    iconSize: 22,
  );

  Future<void> finishStartup() async {
    if (_enabled &&
        warning == null &&
        controller.defaultProfileId != null &&
        controller.tunnelStatus.phase == TunnelPhase.ready &&
        controller.errorMessage == null &&
        controller.pendingTrust == null) {
      await _window.hide();
    }
  }

  void _changed() {
    final trust = controller.pendingTrust;
    final error = controller.errorMessage;
    final phase = controller.tunnelStatus.phase;
    if ((trust != null && !identical(trust, _lastTrust)) ||
        (error != null && error != _lastError) ||
        (phase == TunnelPhase.failed && phase != _lastPhase)) {
      unawaited(showWindow());
    }
    _lastTrust = trust;
    _lastError = error;
    _lastPhase = phase;
    unawaited(_update());
  }

  Future<void> _update() {
    _dirty = true;
    return _updateOperation ??= _updateNow().whenComplete(() {
      _updateOperation = null;
    });
  }

  Future<void> _updateNow() async {
    if (!_enabled || _quitting) return;
    if (_updating) {
      _dirty = true;
      return;
    }
    _updating = true;
    try {
      do {
        _dirty = false;
        final status = controller.tunnelStatus;
        final icon = switch (status.phase) {
          TunnelPhase.ready => 'ready',
          TunnelPhase.failed => 'failed',
          TunnelPhase.idle => 'idle',
          _ => 'pending',
        };
        if (_lastIcon != icon) {
          // Only ready is green. Even an authenticated tunnel whose target
          // probe is failing must use a red icon, never a false healthy signal.
          await _setTrayIcon(icon);
          _lastIcon = icon;
        }
        final label = switch (status.phase) {
          TunnelPhase.idle => '未连接',
          TunnelPhase.connecting => '正在连接',
          TunnelPhase.verifyingHost => '等待确认主机指纹',
          TunnelPhase.ready => '转发可用',
          TunnelPhase.targetUnavailable => '远端 3080 暂不可达',
          TunnelPhase.reconnecting => '正在重连',
          TunnelPhase.failed => '连接失败',
        };
        final profile = controller.activeProfile;
        final caption = profile == null ? label : '$label · ${profile.name}';
        await _tray.setToolTip('端口连 · $caption');
        await _tray.setContextMenu(
          tray.Menu(
            items: [
              tray.MenuItem(key: 'status', label: caption, disabled: true),
              tray.MenuItem(key: 'show', label: '管理服务器…'),
              tray.MenuItem(key: 'copy', label: '复制本地地址'),
              tray.MenuItem(
                key: 'http',
                label: '打开 HTTP 页面',
                disabled:
                    !controller.initialized ||
                    status.phase != TunnelPhase.ready,
              ),
              tray.MenuItem.separator(),
              if (status.isActive)
                tray.MenuItem(key: 'stop', label: '停止转发')
              else
                tray.MenuItem(
                  key: 'connect',
                  label: '连接默认服务器',
                  disabled:
                      controller.busy || controller.defaultProfileId == null,
                ),
              if (controller.profiles.isNotEmpty)
                tray.MenuItem.submenu(
                  key: 'servers',
                  label: '切换服务器',
                  submenu: tray.Menu(
                    items: [
                      for (final p in controller.profiles)
                        tray.MenuItem(
                          key: 'server:${p.id}',
                          label: p.name,
                          disabled: controller.busy,
                        ),
                    ],
                  ),
                ),
              tray.MenuItem.separator(),
              tray.MenuItem(key: 'quit', label: '退出并停止转发'),
            ],
          ),
        );
      } while (_dirty && !_quitting);
    } catch (_) {
      _enabled = false;
      controller.removeListener(_changed);
      warning = '状态栏无法更新，窗口将保持可见；关闭窗口会停止转发。';
      controller.reportPlatformWarning(warning!);
      await _window.setPreventClose(true);
      await showWindow();
    } finally {
      _updating = false;
    }
  }

  Future<void> showWindow() async {
    if (_quitting || !isDesktop) return;
    await _window.show();
    await _window.focus();
  }

  @override
  void onTrayIconMouseDown() => unawaited(_tray.popUpContextMenu());
  @override
  void onTrayIconRightMouseDown() => unawaited(_tray.popUpContextMenu());
  @override
  void onTrayMenuItemClick(tray.MenuItem menuItem) =>
      unawaited(_activate(menuItem.key));
  Future<void> _activate(String? key) async {
    try {
      if (key == 'show') {
        await showWindow();
      } else if (key == 'copy') {
        await Clipboard.setData(const ClipboardData(text: '127.0.0.1:3080'));
      } else if (key == 'http') {
        if (!controller.initialized ||
            controller.tunnelStatus.phase != TunnelPhase.ready) {
          return;
        }
        await launchUrl(
          Uri.parse('http://127.0.0.1:3080'),
          mode: LaunchMode.externalApplication,
        );
      } else if (key == 'stop') {
        await controller.disconnect();
      } else if (key == 'connect') {
        final id = controller.defaultProfileId;
        if (id != null) await controller.connectProfile(id);
      } else if (key != null && key.startsWith('server:')) {
        await controller.connectProfile(key.substring(7));
      } else if (key == 'quit') {
        await quit();
      }
    } catch (_) {
      await showWindow();
    }
  }

  @override
  void onWindowClose() {
    if (_enabled && !_quitting) {
      unawaited(_window.hide());
    } else {
      unawaited(quit());
    }
  }

  Future<void> prepareForExit() => _shutdown ??= _prepareForExit();

  Future<void> _prepareForExit() async {
    _quitting = true;
    controller.removeListener(_changed);
    _tray.removeListener(this);
    _window.removeListener(this);
    try {
      await _onShutdown();
    } finally {
      await _updateOperation;
      try {
        await _tray.destroy();
      } catch (_) {}
      _lifecycle?.dispose();
      _lifecycle = null;
      // If startup later displays a failure screen, its close button must work.
      // Cleanup has completed, so the native close no longer needs intercepting.
      try {
        await _window.setPreventClose(false);
      } catch (_) {}
    }
  }

  Future<void> quit() => _quitOperation ??= _quit();

  Future<void> _quit() async {
    try {
      await prepareForExit();
    } finally {
      await _window.destroy();
    }
  }
}
