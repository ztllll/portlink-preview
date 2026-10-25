import 'package:flutter/material.dart';

import '../core/server_profile.dart';
import '../core/tunnel_status.dart';

const localAddress = '127.0.0.1:3080';

class ConnectionPanel extends StatelessWidget {
  const ConnectionPanel({
    super.key,
    required this.status,
    required this.profile,
    required this.busy,
    required this.initialized,
    required this.canConnect,
    required this.onConnect,
    required this.onDisconnect,
    required this.onCopy,
    required this.onOpenHttp,
    required this.copied,
  });

  final TunnelStatus status;
  final ServerProfile? profile;
  final bool busy;
  final bool initialized;
  final bool canConnect;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onCopy;
  final VoidCallback onOpenHttp;
  final bool copied;

  String get _title => switch (status.phase) {
    TunnelPhase.idle => '连接你的远端服务',
    TunnelPhase.connecting => '正在建立安全连接',
    TunnelPhase.verifyingHost => '等待核对主机指纹',
    TunnelPhase.ready => '安全通道已就绪',
    TunnelPhase.reconnecting => '连接中断，正在重试',
    TunnelPhase.targetUnavailable => '通道已连接，服务暂不可用',
    TunnelPhase.failed => '连接未能完成',
  };

  String get _description => switch (status.phase) {
    TunnelPhase.idle => '选择一台服务器，将远端的 3080 端口带到本机。',
    TunnelPhase.connecting => '正在连接 SSH 服务器，随时可以取消。',
    TunnelPhase.verifyingHost => '请在弹窗中通过可信渠道核对指纹，未确认前不会继续。',
    TunnelPhase.ready => '仅监听本机回环地址，不向局域网公开本地端口。',
    TunnelPhase.reconnecting => '正在尝试恢复连接，你仍然可以停止。',
    TunnelPhase.targetUnavailable => '请检查服务器上的 127.0.0.1:3080 服务；通道保留并定期检查。',
    TunnelPhase.failed => '请查看下方提示，检查配置后手动重试。',
  };

  String get _phaseLabel => switch (status.phase) {
    TunnelPhase.idle => '未连接',
    TunnelPhase.connecting => '连接中',
    TunnelPhase.verifyingHost => '待验证',
    TunnelPhase.ready => '已连接',
    TunnelPhase.reconnecting => '重连中',
    TunnelPhase.targetUnavailable => '服务未就绪',
    TunnelPhase.failed => '连接失败',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isReady = status.phase == TunnelPhase.ready;
    final warning =
        status.phase == TunnelPhase.targetUnavailable ||
        status.phase == TunnelPhase.failed;
    final accent = warning
        ? colors.error
        : isReady
        ? (theme.brightness == Brightness.dark
              ? const Color(0xFF79D8B1)
              : const Color(0xFF147A5A))
        : colors.primary;
    final waiting =
        status.phase == TunnelPhase.connecting ||
        status.phase == TunnelPhase.reconnecting ||
        status.phase == TunnelPhase.verifyingHost;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: colors.outlineVariant.withAlpha(160)),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: accent.withAlpha(20),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  isReady ? Icons.link : Icons.lan_outlined,
                  color: accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text('本地转发', style: theme.textTheme.titleSmall)),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: accent.withAlpha(20),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (waiting)
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: accent,
                        ),
                      )
                    else
                      Icon(Icons.circle, size: 7, color: accent),
                    const SizedBox(width: 6),
                    Text(
                      _phaseLabel,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: accent,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Semantics(
            liveRegion: true,
            child: Text(
              _title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -.4,
              ),
            ),
          ),
          const SizedBox(height: 9),
          Text(
            _description,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.6,
            ),
          ),
          if (status.phase == TunnelPhase.reconnecting &&
              status.retryAttempt > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '重试次数：${status.retryAttempt}',
                style: theme.textTheme.labelMedium,
              ),
            ),
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            decoration: BoxDecoration(
              color: colors.primary.withAlpha(10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: colors.primary.withAlpha(25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '本地地址',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                const SelectableText(
                  localAddress,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -.4,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      Icons.arrow_forward,
                      size: 16,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '远端 127.0.0.1:3080',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                if (profile != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    '通过 ${profile!.name}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${profile!.username}@${profile!.host}:${profile!.sshPort}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: status.isActive
                ? OutlinedButton.icon(
                    // Cancellation must stay enabled during a busy connect.
                    onPressed: onDisconnect,
                    icon: const Icon(Icons.stop_rounded, size: 20),
                    label: Text(waiting ? '取消连接' : '停止连接'),
                  )
                : FilledButton.icon(
                    onPressed: initialized && canConnect && !busy
                        ? onConnect
                        : null,
                    icon: const Icon(Icons.link, size: 20),
                    label: Text(profile == null ? '连接默认服务器' : '连接服务器'),
                  ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              TextButton.icon(
                onPressed: onCopy,
                icon: Icon(
                  copied ? Icons.check : Icons.content_copy_outlined,
                  size: 17,
                ),
                label: Text(copied ? '地址已复制' : '复制地址'),
              ),
              TextButton.icon(
                onPressed: initialized && isReady ? onOpenHttp : null,
                icon: const Icon(Icons.open_in_new, size: 17),
                label: const Text('打开 HTTP 页面'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '仅当远端服务使用 HTTP 时打开，其他 TCP 服务请使用对应客户端。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
