import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../core/server_profile.dart';
import '../core/tunnel_status.dart';
import 'connection_panel.dart';
import 'host_trust_dialog.dart';
import 'portlink_theme.dart';
import 'server_list.dart';
import 'server_profile_dialog.dart';

/// The caller owns the controller and is responsible for initialization.
/// The UI never creates, initializes, shuts down, or disposes it.
class PortLinkApp extends StatelessWidget {
  const PortLinkApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => _PortLinkRoot(controller: controller);
}

class _PortLinkRoot extends StatefulWidget {
  const _PortLinkRoot({required this.controller});
  final AppController controller;

  @override
  State<_PortLinkRoot> createState() => _PortLinkRootState();
}

class _PortLinkRootState extends State<_PortLinkRoot> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '端口连 PortLink',
    debugShowCheckedModeBanner: false,
    theme: buildPortLinkTheme(Brightness.light),
    darkTheme: buildPortLinkTheme(Brightness.dark),
    themeMode: _themeMode,
    home: _PortLinkHome(
      controller: widget.controller,
      themeMode: _themeMode,
      onThemeChanged: (mode) => setState(() => _themeMode = mode),
    ),
    // Above the Navigator so a trust request also covers an open edit
    // dialog when saving an active profile triggers a fresh connection.
    builder: (context, child) => AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final request = widget.controller.pendingTrust;
        return Stack(
          fit: StackFit.expand,
          children: [
            ExcludeFocus(
              excluding: request != null,
              child: ExcludeSemantics(
                excluding: request != null,
                child: child ?? const SizedBox.shrink(),
              ),
            ),
            if (request != null)
              Overlay(
                key: ObjectKey(request),
                initialEntries: [
                  OverlayEntry(
                    builder: (context) => Stack(
                      fit: StackFit.expand,
                      children: [
                        const ModalBarrier(
                          dismissible: false,
                          color: Color(0x99000000),
                          semanticsLabel: '请先核对主机指纹或拒绝连接',
                        ),
                        SafeArea(
                          child: Center(
                            child: FocusScope(
                              autofocus: true,
                              child: HostTrustDialog(
                                request: request,
                                onAnswer: widget.controller.answerHostTrust,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        );
      },
    ),
  );
}

class _PortLinkHome extends StatefulWidget {
  const _PortLinkHome({
    required this.controller,
    required this.themeMode,
    required this.onThemeChanged,
  });

  final AppController controller;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;

  @override
  State<_PortLinkHome> createState() => _PortLinkHomeState();
}

class _PortLinkHomeState extends State<_PortLinkHome> {
  String? _localError;
  bool _copied = false;
  bool _dialogOpen = false;

  AppController get _controller => widget.controller;

  Future<void> _perform(Future<void> Function() action) async {
    if (mounted) setState(() => _localError = null);
    try {
      await action();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        // Never show arbitrary exception text: a plugin could include secrets.
        _localError = _controller.errorMessage ?? '操作未完成，请检查连接与系统安全存储后重试。';
      });
    }
  }

  ServerProfile? get _preferredProfile {
    if (_controller.activeProfile != null &&
        _controller.tunnelStatus.isActive) {
      return _controller.activeProfile;
    }
    for (final profile in _controller.profiles) {
      if (profile.id == _controller.defaultProfileId) return profile;
    }
    return _controller.profiles.isEmpty ? null : _controller.profiles.first;
  }

  Future<void> _edit([ServerProfile? profile]) async {
    if (_dialogOpen || !_controller.initialized || _controller.busy) return;
    setState(() {
      _localError = null;
      _dialogOpen = true;
    });
    try {
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) =>
            ServerProfileDialog(controller: _controller, profile: profile),
      );
    } finally {
      if (mounted) setState(() => _dialogOpen = false);
    }
  }

  Future<void> _delete(ServerProfile profile) async {
    if (_dialogOpen || !_controller.initialized || _controller.busy) return;
    setState(() => _dialogOpen = true);
    bool? confirmed;
    try {
      confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('删除这台服务器？'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                const Text('将删除此服务器配置及保存的密码，无法撤销。'),
                if (_controller.activeProfile?.id == profile.id)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text('这台服务器正在使用，删除时会停止当前连接。'),
                  ),
                if (_controller.defaultProfileId == profile.id &&
                    _controller.profiles.length > 1)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text('删除后将选用剩余的第一台服务器作为默认。'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('保留'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确认删除'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _dialogOpen = false);
    }
    if (confirmed == true &&
        mounted &&
        _controller.initialized &&
        !_controller.busy) {
      await _perform(() => _controller.deleteProfile(profile.id));
    }
  }

  void _connectProfile(String id) {
    if (!_controller.initialized || _controller.busy) return;
    _perform(() => _controller.connectProfile(id));
  }

  void _serverAction(ServerProfile profile, ServerAction action) {
    if (_controller.busy || !_controller.initialized) return;
    switch (action) {
      case ServerAction.edit:
        _edit(profile);
      case ServerAction.makeDefault:
        _perform(() => _controller.setDefault(profile.id));
      case ServerAction.delete:
        _delete(profile);
    }
  }

  Future<void> _copyAddress() async {
    try {
      await Clipboard.setData(const ClipboardData(text: localAddress));
      if (mounted) setState(() => _copied = true);
    } catch (_) {
      if (mounted) setState(() => _localError = '无法复制地址，请手动选择并复制本地地址。');
    }
  }

  Future<void> _openHttp() async {
    // This method is invoked only by a user click; never on connect/reconnect.
    if (!_controller.initialized ||
        _controller.tunnelStatus.phase != TunnelPhase.ready) {
      return;
    }
    try {
      final opened = await launchUrl(
        Uri.parse('http://127.0.0.1:3080'),
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted) {
        setState(() => _localError = '无法打开浏览器，请手动访问 http://127.0.0.1:3080。');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _localError = '无法打开浏览器，请手动访问 http://127.0.0.1:3080。');
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final status = _controller.tunnelStatus;
      final preferred = _preferredProfile;
      final initializationFailed =
          !_controller.initialized &&
          !_controller.busy &&
          _controller.errorMessage != null;
      final error = !_controller.initialized
          ? (_controller.errorMessage ?? _localError)
          : (_localError ?? _controller.errorMessage);
      final detail = status.message;
      final panel = ConnectionPanel(
        status: status,
        profile: preferred,
        busy: _controller.busy,
        initialized: _controller.initialized,
        canConnect: preferred != null,
        copied: _copied,
        onConnect: () {
          if (preferred != null) _connectProfile(preferred.id);
        },
        onDisconnect: () => _perform(_controller.disconnect),
        onCopy: _copyAddress,
        onOpenHttp: _openHttp,
      );
      final servers = ServerList(
        profiles: _controller.profiles,
        defaultProfileId: _controller.defaultProfileId,
        status: status,
        busy: _controller.busy,
        initialized: _controller.initialized,
        onAdd: _edit,
        onConnect: (profile) => _connectProfile(profile.id),
        onDisconnect: () => _perform(_controller.disconnect),
        onAction: _serverAction,
      );
      return PopScope(
        canPop: _controller.pendingTrust == null,
        child: Scaffold(
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 900;
                return SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 20 : 40,
                    24,
                    compact ? 20 : 40,
                    32,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1100),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Header(
                            themeMode: widget.themeMode,
                            onThemeChanged: widget.onThemeChanged,
                            compact: compact,
                          ),
                          const SizedBox(height: 28),
                          if (!_controller.initialized || _controller.busy)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 18),
                              child: Row(
                                children: [
                                  if (initializationFailed)
                                    Icon(
                                      Icons.lock_outline,
                                      size: 16,
                                      color: colors.error,
                                    )
                                  else
                                    SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: colors.primary,
                                      ),
                                    ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      initializationFailed
                                          ? '配置未加载，连接和修改已禁用'
                                          : !_controller.initialized
                                          ? '正在读取本机配置…'
                                          : '正在处理，请稍候…',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: colors.onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (error != null) ...[
                            _InlineNotice(
                              message: error,
                              isError: true,
                              onDismiss: !_controller.initialized
                                  ? null
                                  : () {
                                      setState(() => _localError = null);
                                      _controller.clearError();
                                    },
                            ),
                            const SizedBox(height: 20),
                          ],
                          if (detail != null &&
                              detail.isNotEmpty &&
                              detail != error) ...[
                            _InlineNotice(
                              message: detail,
                              isError: status.phase == TunnelPhase.failed,
                            ),
                            const SizedBox(height: 20),
                          ],
                          if (compact) ...[
                            panel,
                            const SizedBox(height: 28),
                            servers,
                          ] else
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(flex: 5, child: servers),
                                const SizedBox(width: 28),
                                Expanded(flex: 4, child: panel),
                              ],
                            ),
                          const SizedBox(height: 32),
                          const Divider(),
                          const SizedBox(height: 14),
                          Text(
                            '端口连 PortLink  ·  一条本地通道，连接你的服务',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
    },
  );
}

class _Header extends StatelessWidget {
  const _Header({
    required this.themeMode,
    required this.onThemeChanged,
    required this.compact,
  });
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [colors.primary, colors.primary.withAlpha(180)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(15),
          ),
          child: Icon(Icons.link_rounded, color: colors.onPrimary, size: 29),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '端口连',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                compact ? 'PortLink · 安全本地转发' : 'PortLink  /  简单、安全的本地转发',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        PopupMenuButton<ThemeMode>(
          tooltip: '外观设置',
          initialValue: themeMode,
          onSelected: onThemeChanged,
          icon: Icon(switch (themeMode) {
            ThemeMode.system => Icons.brightness_auto_outlined,
            ThemeMode.light => Icons.light_mode_outlined,
            ThemeMode.dark => Icons.dark_mode_outlined,
          }),
          itemBuilder: (context) => [
            for (final entry in const {
              ThemeMode.system: '跟随系统',
              ThemeMode.light: '浅色模式',
              ThemeMode.dark: '深色模式',
            }.entries)
              CheckedPopupMenuItem(
                value: entry.key,
                checked: themeMode == entry.key,
                child: Text(entry.value),
              ),
          ],
        ),
      ],
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({
    required this.message,
    required this.isError,
    this.onDismiss,
  });
  final String message;
  final bool isError;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = isError
        ? colors.onErrorContainer
        : colors.onSecondaryContainer;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        decoration: BoxDecoration(
          color: isError ? colors.errorContainer : colors.secondaryContainer,
          borderRadius: BorderRadius.circular(13),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Icon(
                isError ? Icons.error_outline : Icons.info_outline,
                color: foreground,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: SelectableText(
                  message,
                  style: TextStyle(color: foreground, height: 1.6),
                ),
              ),
            ),
            if (onDismiss != null)
              IconButton(
                tooltip: '关闭提示',
                visualDensity: VisualDensity.compact,
                onPressed: onDismiss,
                icon: Icon(Icons.close, size: 18, color: foreground),
              ),
          ],
        ),
      ),
    );
  }
}
