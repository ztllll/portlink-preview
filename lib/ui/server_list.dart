import 'package:flutter/material.dart';

import '../core/server_profile.dart';
import '../core/tunnel_status.dart';

enum ServerAction { edit, makeDefault, delete }

class ServerList extends StatelessWidget {
  const ServerList({
    super.key,
    required this.profiles,
    required this.defaultProfileId,
    required this.status,
    required this.busy,
    required this.initialized,
    required this.onAdd,
    required this.onConnect,
    required this.onDisconnect,
    required this.onAction,
  });

  final List<ServerProfile> profiles;
  final String? defaultProfileId;
  final TunnelStatus status;
  final bool busy;
  final bool initialized;
  final VoidCallback onAdd;
  final ValueChanged<ServerProfile> onConnect;
  final VoidCallback onDisconnect;
  final void Function(ServerProfile profile, ServerAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final enabled = initialized && !busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Text(
                    '我的服务器',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Text(
                    '${profiles.length}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: enabled ? onAdd : null,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加服务器'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '默认服务器将在下次启动时自动连接。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 20),
        if (profiles.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 42),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: colors.outlineVariant.withAlpha(160)),
            ),
            child: Column(
              children: [
                Icon(Icons.dns_outlined, color: colors.primary, size: 36),
                const SizedBox(height: 16),
                Text('从第一台服务器开始', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  '准备好 SSH 地址、用户名和密码，即可建立本地安全通道。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: enabled ? onAdd : null,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加第一台服务器'),
                ),
              ],
            ),
          )
        else
          for (final profile in profiles) ...[
            _ServerCard(
              key: ValueKey('server-${profile.id}'),
              profile: profile,
              isDefault: profile.id == defaultProfileId,
              active: status.isActive && status.profileId == profile.id,
              waiting:
                  status.phase == TunnelPhase.connecting ||
                  status.phase == TunnelPhase.verifyingHost ||
                  status.phase == TunnelPhase.reconnecting,
              enabled: enabled,
              onConnect: () => onConnect(profile),
              onDisconnect: onDisconnect,
              onAction: (action) => onAction(profile, action),
            ),
            const SizedBox(height: 12),
          ],
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_outline, size: 16, color: colors.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '密码存于系统安全凭据库。只建立你主动选择的连接，不上传服务器信息。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    super.key,
    required this.profile,
    required this.isDefault,
    required this.active,
    required this.waiting,
    required this.enabled,
    required this.onConnect,
    required this.onDisconnect,
    required this.onAction,
  });

  final ServerProfile profile;
  final bool isDefault;
  final bool active;
  final bool waiting;
  final bool enabled;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final ValueChanged<ServerAction> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: active
              ? colors.primary.withAlpha(150)
              : colors.outlineVariant.withAlpha(160),
          width: active ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: colors.primary.withAlpha(15),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  Icons.dns_outlined,
                  size: 21,
                  color: colors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${profile.username}@${profile.host}:${profile.sshPort}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              PopupMenuButton<ServerAction>(
                tooltip: '${profile.name}的更多操作',
                enabled: enabled,
                onSelected: onAction,
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: ServerAction.edit,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.edit_outlined, size: 20),
                      title: Text('编辑服务器'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem(
                    value: ServerAction.makeDefault,
                    enabled: !isDefault,
                    child: const ListTile(
                      dense: true,
                      leading: Icon(Icons.star_outline, size: 20),
                      title: Text('设为默认'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: ServerAction.delete,
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        Icons.delete_outline,
                        size: 20,
                        color: colors.error,
                      ),
                      title: Text(
                        '删除服务器',
                        style: TextStyle(color: colors.error),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 7,
                  runSpacing: 6,
                  children: [
                    if (isDefault)
                      _Tag(
                        icon: Icons.star_rounded,
                        label: '默认',
                        color: colors.primary,
                      ),
                    if (active)
                      _Tag(
                        icon: Icons.circle,
                        label: waiting ? '连接中' : '使用中',
                        color: colors.primary,
                      ),
                    if (!isDefault && !active)
                      Text(
                        'SSH · 固定转发 3080',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (active)
                OutlinedButton(
                  onPressed: onDisconnect,
                  child: Text(waiting ? '取消' : '停止'),
                )
              else
                OutlinedButton(
                  onPressed: enabled ? onConnect : null,
                  child: const Text('连接'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withAlpha(16),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: icon == Icons.circle ? 6 : 13, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ],
    ),
  );
}
