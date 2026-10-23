// Compatibility facade pinned by pubspec.lock.
// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:tray_manager/legacy.dart' as tray;
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../app_controller.dart';
import '../core/tunnel_status.dart';

/// Desktop shell only. SSH ownership remains in AppController.
class DesktopIntegration with WindowListener, tray.TrayListener {
  DesktopIntegration(this.controller);
  final AppController controller;
  bool _enabled = false, _quitting = false, _updating = false, _dirty = false;
  String? _lastIcon;
  String? warning;

  static bool get isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  Future<void> initialize() async {
    if (!isDesktop) return;
    await windowManager.ensureInitialized();
    await windowManager.setTitle('端口连 PortLink');
    await windowManager.setMinimumSize(const Size(430, 540));
    await windowManager.setSize(const Size(960, 680));
    await windowManager.center();
    windowManager.addListener(this);
    tray.trayManager.addListener(this);
    try {
      await tray.trayManager.setIcon(
        Platform.isWindows
            ? 'assets/tray/windows_idle.ico'
            : 'assets/tray/idle.png',
        isTemplate: Platform.isMacOS,
      );
      await windowManager.setPreventClose(true);
      _enabled = true;
      controller.addListener(_changed);
      await _update();
    } catch (_) {
      _enabled = false;
      controller.removeListener(_changed);
      warning = '状态栏图标初始化失败，窗口将保持可见；关闭窗口会停止转发。';
      await windowManager.setPreventClose(false);
    }
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> finishStartup() async {
    if (_enabled &&
        warning == null &&
        controller.defaultProfileId != null &&
        controller.tunnelStatus.phase == TunnelPhase.ready &&
        controller.errorMessage == null &&
        controller.pendingTrust == null) {
      await windowManager.hide();
    }
  }

  void _changed() {
    if (controller.pendingTrust != null ||
        controller.errorMessage != null ||
        controller.tunnelStatus.phase == TunnelPhase.failed) {
      unawaited(showWindow());
    }
    unawaited(_update());
  }

  Future<void> _update() async {
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
          await tray.trayManager.setIcon(
            Platform.isWindows
                ? 'assets/tray/windows_$icon.ico'
                : 'assets/tray/$icon.png',
            isTemplate: Platform.isMacOS,
          );
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
        await tray.trayManager.setToolTip('端口连 · $caption');
        await tray.trayManager.setContextMenu(
          tray.Menu(
            items: [
              tray.MenuItem(key: 'status', label: caption, disabled: true),
              tray.MenuItem(key: 'show', label: '管理服务器…'),
              tray.MenuItem(key: 'copy', label: '复制本地地址'),
              tray.MenuItem(
                key: 'http',
                label: '打开 HTTP 页面',
                disabled: !status.isConnected,
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
      warning = '无法更新状态栏，请打开窗口查看连接状态。';
      await windowManager.setPreventClose(false);
      await showWindow();
    } finally {
      _updating = false;
    }
  }

  Future<void> showWindow() async {
    if (_quitting || !isDesktop) return;
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconMouseDown() => unawaited(tray.trayManager.popUpContextMenu());
  @override
  void onTrayIconRightMouseDown() =>
      unawaited(tray.trayManager.popUpContextMenu());
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
      unawaited(windowManager.hide());
    } else {
      unawaited(quit());
    }
  }

  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    controller.removeListener(_changed);
    try {
      await controller.shutdown();
    } finally {
      try {
        await tray.trayManager.destroy();
      } catch (_) {}
      await windowManager.destroy();
    }
  }
}
