import 'package:flutter/material.dart';

import '../core/host_trust.dart';

/// This is deliberately an explicit, blocking decision, never an auto-accept.
class HostTrustDialog extends StatefulWidget {
  const HostTrustDialog({
    super.key,
    required this.request,
    required this.onAnswer,
  });

  final HostTrustRequest request;
  final ValueChanged<bool> onAnswer;

  @override
  State<HostTrustDialog> createState() => _HostTrustDialogState();
}

class _HostTrustDialogState extends State<HostTrustDialog> {
  bool _verified = false;
  bool _answered = false;

  void _answer(bool accept) {
    if (_answered) return;
    setState(() => _answered = true);
    widget.onAnswer(accept);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final request = widget.request;
    return AlertDialog(
      scrollable: true,
      title: const Row(
        children: [
          Icon(Icons.verified_user_outlined),
          SizedBox(width: 12),
          Expanded(child: Text('核对服务器指纹')),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('这是首次连接此服务器。请通过管理员、服务器控制台等可信渠道核对主机公钥指纹，确认无误后再信任。'),
            const SizedBox(height: 20),
            Text('SSH 服务器', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            SelectableText(
              '${request.host}:${request.port}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 14),
            Text('主机密钥类型：${request.keyType}'),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SHA256 指纹',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    request.fingerprint,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: _verified,
              onChanged: _answered
                  ? null
                  : (value) => setState(() => _verified = value ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('我已通过可信渠道核对指纹'),
              subtitle: const Text('信任后会保存此指纹；指纹变化将阻止连接。'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: _answered ? null : () => _answer(false),
          child: const Text('拒绝连接'),
        ),
        FilledButton(
          onPressed: !_verified || _answered ? null : () => _answer(true),
          child: const Text('信任并继续'),
        ),
      ],
    );
  }
}
