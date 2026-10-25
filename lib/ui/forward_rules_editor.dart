import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../core/forward_rule.dart';

/// Editable list of port-forward rules for one server. The owner reads the
/// current rules through [ForwardRulesEditorState.collect].
class ForwardRulesEditor extends StatefulWidget {
  const ForwardRulesEditor({
    super.key,
    required this.initial,
    required this.enabled,
  });

  final List<ForwardRule> initial;
  final bool enabled;

  @override
  State<ForwardRulesEditor> createState() => ForwardRulesEditorState();
}

class _RuleRow {
  _RuleRow(ForwardRule rule)
    : id = rule.id,
      enabled = rule.enabled,
      label = TextEditingController(text: rule.label),
      bind = TextEditingController(text: rule.bindHost),
      local = TextEditingController(text: rule.localPort.toString()),
      target = TextEditingController(text: rule.targetHost),
      remote = TextEditingController(text: rule.remotePort.toString());

  final String id;
  bool enabled;
  final TextEditingController label, bind, local, target, remote;

  void dispose() {
    label.dispose();
    bind.dispose();
    local.dispose();
    target.dispose();
    remote.dispose();
  }
}

class ForwardRulesEditorState extends State<ForwardRulesEditor> {
  final _rows = <_RuleRow>[];

  @override
  void initState() {
    super.initState();
    for (final rule in widget.initial) {
      _rows.add(_RuleRow(rule));
    }
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  /// Returns the rules as typed, or null with [error] set when a number field
  /// cannot be parsed. Semantic checks (ranges, duplicates) are done by
  /// [ForwardRule.validateAll] on the result.
  List<ForwardRule>? collect() {
    final result = <ForwardRule>[];
    for (final row in _rows) {
      final local = int.tryParse(row.local.text.trim());
      final remote = int.tryParse(row.remote.text.trim());
      if (local == null || remote == null) return null;
      result.add(
        ForwardRule(
          id: row.id,
          label: row.label.text.trim(),
          bindHost: row.bind.text.trim(),
          localPort: local,
          targetHost: row.target.text.trim(),
          remotePort: remote,
          enabled: row.enabled,
        ),
      );
    }
    return result;
  }

  void _add() {
    if (_rows.length >= ForwardRule.maxRules) return;
    final used = {
      for (final row in _rows) int.tryParse(row.local.text.trim()),
    };
    var port = 8080;
    while (used.contains(port) && port < 65535) {
      port++;
    }
    setState(() {
      _rows.add(
        _RuleRow(
          ForwardRule(
            id: const Uuid().v4().replaceAll('-', '').substring(0, 16),
            label: '端口 $port',
            localPort: port,
            remotePort: port,
          ),
        ),
      );
    });
  }

  void _remove(_RuleRow row) {
    if (_rows.length <= 1) return;
    setState(() {
      _rows.remove(row);
      row.dispose();
    });
  }

  String? _portValidator(String? value, int min) {
    final port = int.tryParse(value?.trim() ?? '');
    return port == null || port < min || port > 65535 ? '$min–65535' : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final enabled = widget.enabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('端口转发', style: theme.textTheme.titleSmall),
            ),
            TextButton.icon(
              key: const ValueKey('rule-add'),
              onPressed: enabled && _rows.length < ForwardRule.maxRules
                  ? _add
                  : null,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加端口'),
            ),
          ],
        ),
        Text(
          '本地地址:端口 → 经 SSH → 服务器可访问的目标地址:端口。'
          '本地地址默认 127.0.0.1，仅本机可用。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < _rows.length; i++) ...[
          _buildRow(context, i, _rows[i], enabled),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _buildRow(BuildContext context, int index, _RuleRow row, bool enabled) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final exposes = !ForwardRule.isLoopbackBind(row.bind.text.trim());
    final label = TextFormField(
      key: ValueKey('rule-label-$index'),
      controller: row.label,
      enabled: enabled,
      maxLength: 40,
      decoration: const InputDecoration(
        labelText: '名称',
        counterText: '',
        isDense: true,
      ),
      validator: (v) => (v?.trim().isEmpty ?? true) ? '请输入名称' : null,
    );
    final bind = TextFormField(
      key: ValueKey('rule-bind-$index'),
      controller: row.bind,
      enabled: enabled,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.number,
      onChanged: (_) => setState(() {}),
      decoration: const InputDecoration(labelText: '本地地址', isDense: true),
      validator: (v) {
        final text = v?.trim() ?? '';
        final address = InternetAddress.tryParse(text);
        return address == null || address.type != InternetAddressType.IPv4
            ? '填写 IPv4 地址'
            : null;
      },
    );
    final local = TextFormField(
      key: ValueKey('rule-local-$index'),
      controller: row.local,
      enabled: enabled,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: const InputDecoration(labelText: '本地端口', isDense: true),
      validator: (v) => _portValidator(v, ForwardRule.minLocalPort),
    );
    final target = TextFormField(
      key: ValueKey('rule-target-$index'),
      controller: row.target,
      enabled: enabled,
      autocorrect: false,
      enableSuggestions: false,
      decoration: const InputDecoration(labelText: '目标地址', isDense: true),
      validator: (v) {
        final text = v?.trim() ?? '';
        return text.isEmpty ? '请输入目标地址' : validateHostText(text);
      },
    );
    final remote = TextFormField(
      key: ValueKey('rule-remote-$index'),
      controller: row.remote,
      enabled: enabled,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: const InputDecoration(labelText: '目标端口', isDense: true),
      validator: (v) => _portValidator(v, 1),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant.withAlpha(160)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: label),
              Switch(
                key: ValueKey('rule-enabled-$index'),
                value: row.enabled,
                onChanged: enabled
                    ? (value) => setState(() => row.enabled = value)
                    : null,
              ),
              IconButton(
                key: ValueKey('rule-remove-$index'),
                tooltip: '删除此转发',
                onPressed: enabled && _rows.length > 1
                    ? () => _remove(row)
                    : null,
                icon: const Icon(Icons.delete_outline, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            // LayoutBuilder cannot sit inside an AlertDialog (intrinsic sizing),
            // so branch on the window width like the rest of the dialog does.
            child: Builder(
              builder: (context) {
                if (MediaQuery.of(context).size.width < 520) {
                  return Column(
                    children: [
                      Row(
                        children: [
                          Expanded(flex: 3, child: bind),
                          const SizedBox(width: 8),
                          Expanded(flex: 2, child: local),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(flex: 3, child: target),
                          const SizedBox(width: 8),
                          Expanded(flex: 2, child: remote),
                        ],
                      ),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: bind),
                    const SizedBox(width: 8),
                    Expanded(flex: 2, child: local),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(8, 10, 8, 0),
                      child: Icon(Icons.arrow_forward, size: 16),
                    ),
                    Expanded(flex: 3, child: target),
                    const SizedBox(width: 8),
                    Expanded(flex: 2, child: remote),
                  ],
                );
              },
            ),
          ),
          if (exposes)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 8, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, size: 16, color: colors.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '此地址会让同一网络中的其他设备也能访问该转发，且无需密码。仅在确有需要时使用。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.error,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
